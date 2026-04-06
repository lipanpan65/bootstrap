#!/usr/bin/env bash
# ============================================================
# kind/install.sh — Kind K8s 学习环境一键安装
#
# 本地执行:
#   sudo ./platforms/k8s/kind/install.sh create [--yes]     安装工具并创建集群
#   sudo ./platforms/k8s/kind/install.sh install [--yes]    只安装工具
#   sudo ./platforms/k8s/kind/install.sh delete             删除集群
#   sudo ./platforms/k8s/kind/install.sh status             查看集群状态
#
# 远程执行（通过顶层 install.sh 分发）:
#   curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
#     | sudo bash -s -- kind create
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库（兼容三种执行方式）
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    local candidates=(
        "$(cd "$(dirname "${BASH_SOURCE[0]:-install.sh}")" 2>/dev/null && pwd)/../../../common/lib.sh"
        "$(pwd)/common/lib.sh"
    )

    for path in "${candidates[@]}"; do
        if [[ -f "$path" ]]; then
            # shellcheck source=/dev/null
            source "$path"
            return 0
        fi
    done

    echo "→ 下载 common/lib.sh ..."
    curl -fsSL "${bootstrap_url}/common/lib.sh" -o "$tmp_lib" \
        || { echo "❌ 无法加载 common/lib.sh"; exit 1; }
    # shellcheck source=/dev/null
    source "$tmp_lib"
    _bootstrap_tmp_lib="$tmp_lib"
    _bootstrap_cleanup_lib() { rm -f "$_bootstrap_tmp_lib"; }
    trap '_bootstrap_cleanup_lib' EXIT
}

_load_lib

# ────────────────────────────────────────────────────────────
# Kind 专属配置
# ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/kind-install.log"

KIND_VERSION="${KIND_VERSION:-0.27.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-}"  # 空则自动获取最新稳定版
CLUSTER_NAME="${CLUSTER_NAME:-learn}"
WORKER_COUNT="${WORKER_COUNT:-2}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-}"  # 镜像加速，如 https://mirror.aliyuncs.com
API_PORT="${API_PORT:-6443}"

# NodePort 映射范围
NODEPORT_START="${NODEPORT_START:-30000}"
NODEPORT_END="${NODEPORT_END:-30010}"

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
ACTION=""

usage() {
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 create [选项]     安装工具并创建 Kind 集群"
    echo "  $0 install [选项]    只安装 kind + kubectl 工具"
    echo "  $0 delete            删除集群"
    echo "  $0 status            查看集群状态"
    echo ""
    echo -e "${BOLD}选项:${NC}"
    echo "  -n, --name NAME            集群名称 (默认: ${CLUSTER_NAME})"
    echo "  -w, --workers N            Worker 节点数 (默认: ${WORKER_COUNT})"
    echo "  --kind-version VERSION     Kind 版本 (默认: ${KIND_VERSION})"
    echo "  --mirror REGISTRY          容器镜像加速地址"
    echo "  -y, --yes                  跳过确认"
    echo "  -h, --help                 显示帮助"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  $0 create --yes                    # 快速创建 1 master + 2 worker"
    echo "  $0 create -w 3 -n dev --yes        # 3 个 worker，集群名 dev"
    echo "  $0 create --mirror https://mirror.aliyuncs.com --yes"
    echo "  $0 delete -n dev                   # 删除 dev 集群"
    echo ""
    exit 1
}

if [[ $# -eq 0 ]]; then usage; fi

case "$1" in
    create|install|delete|status) ACTION="$1"; shift ;;
    --help|-h) usage ;;
    *) echo "未知子命令: $1"; usage ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)         CLUSTER_NAME="${2:?--name 需要参数}"; shift 2 ;;
        -w|--workers)      WORKER_COUNT="${2:?--workers 需要参数}"; shift 2 ;;
        --kind-version)    KIND_VERSION="${2:?--kind-version 需要参数}"; shift 2 ;;
        --mirror)          MIRROR_REGISTRY="${2:?--mirror 需要参数}"; shift 2 ;;
        -y|--yes)          AUTO_YES=true; shift ;;
        -h|--help)         usage ;;
        *)                 echo "未知参数: $1"; usage ;;
    esac
done

# ────────────────────────────────────────────────────────────
# 环境检测
# ────────────────────────────────────────────────────────────
check_prerequisites() {
    step "[Step 1/4] 环境检查"
    info "检查 root 权限"
    info "检查 Docker 是否可用"
    info "检查 cgroup 配置"
    confirm

    require_root

    # Docker
    if ! cmd_exists docker; then
        error "Docker 未安装。请先安装 Docker: curl -fsSL https://get.docker.com | sh"
    fi
    if ! docker info &>/dev/null; then
        error "Docker 未运行。请启动 Docker: systemctl start docker"
    fi
    local docker_ver
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    ok "Docker ${docker_ver}"

    # cgroup
    local cgroup_ver="v1"
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        cgroup_ver="v2"
    fi
    ok "cgroup ${cgroup_ver}"

    # 检查是否在容器中
    if [[ -f /.dockerenv ]] || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        info "检测到容器环境，检查必要权限..."

        # 检查 privileged
        if ! ip link add dummy_test type dummy 2>/dev/null; then
            warn "容器可能缺少 privileged 权限"
            warn "请确保容器启动时添加: --privileged"
        else
            ip link del dummy_test 2>/dev/null
            ok "privileged 权限正常"
        fi

        # 检查 cgroup 可写
        if [[ "$cgroup_ver" == "v2" ]]; then
            if [[ -w /sys/fs/cgroup/ ]]; then
                ok "/sys/fs/cgroup 可写"
            else
                warn "/sys/fs/cgroup 不可写，Kind 可能无法创建集群"
                warn "请确保容器挂载: -v /sys/fs/cgroup:/sys/fs/cgroup:rw"
            fi
        fi
    fi
}

# ────────────────────────────────────────────────────────────
# 安装工具
# ────────────────────────────────────────────────────────────
install_tools() {
    step "[Step 2/4] 安装工具"

    local arch
    arch=$(get_arch)

    # Kind
    if cmd_exists kind; then
        local current_ver
        current_ver=$(kind version | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        if [[ "$current_ver" == "$KIND_VERSION" ]]; then
            ok "kind v${KIND_VERSION} 已安装"
        else
            info "更新 kind: v${current_ver} → v${KIND_VERSION}"
            info "下载: https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}"
            confirm
            curl -fsSL "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}" -o /usr/local/bin/kind
            chmod +x /usr/local/bin/kind
            ok "kind v${KIND_VERSION} 已更新"
        fi
    else
        info "下载: https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}"
        confirm
        curl -fsSL "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}" -o /usr/local/bin/kind
        chmod +x /usr/local/bin/kind
        ok "kind v${KIND_VERSION} 已安装"
    fi

    # kubectl
    if cmd_exists kubectl; then
        local kubectl_ver
        kubectl_ver=$(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | grep -oP 'v[\d.]+' || echo "unknown")
        ok "kubectl ${kubectl_ver} 已安装"
    else
        if [[ -z "$KUBECTL_VERSION" ]]; then
            info "获取最新 kubectl 版本..."
            KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")
        fi
        info "下载: https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
        confirm
        curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl
        chmod +x /usr/local/bin/kubectl
        ok "kubectl ${KUBECTL_VERSION} 已安装"
    fi
}

# ────────────────────────────────────────────────────────────
# 创建集群
# ────────────────────────────────────────────────────────────
create_cluster() {
    step "[Step 3/4] 创建 Kind 集群"

    # 检查集群是否已存在
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "集群 '${CLUSTER_NAME}' 已存在"
        info "如需重建，先执行: $0 delete -n ${CLUSTER_NAME}"
        info "跳过创建，直接验证..."
        return 0
    fi

    info "集群名称: ${CLUSTER_NAME}"
    info "节点配置: 1 master + ${WORKER_COUNT} worker"
    info "API 端口: ${API_PORT}"
    info "NodePort 范围: ${NODEPORT_START}-${NODEPORT_END}"
    if [[ -n "$MIRROR_REGISTRY" ]]; then
        info "镜像加速: ${MIRROR_REGISTRY}"
    fi
    confirm

    # 生成配置
    local config_file="/tmp/kind-config-$$.yaml"

    cat > "$config_file" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: ${API_PORT}
EOF

    # 镜像加速
    if [[ -n "$MIRROR_REGISTRY" ]]; then
        cat >> "$config_file" <<EOF
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["${MIRROR_REGISTRY}"]
EOF
    fi

    # 节点配置
    cat >> "$config_file" <<EOF
nodes:
  - role: control-plane
    extraPortMappings:
EOF

    # NodePort 映射
    for port in $(seq "$NODEPORT_START" "$NODEPORT_END"); do
        cat >> "$config_file" <<EOF
      - containerPort: ${port}
        hostPort: ${port}
        protocol: TCP
EOF
    done

    # Worker 节点
    for _ in $(seq 1 "$WORKER_COUNT"); do
        cat >> "$config_file" <<EOF
  - role: worker
EOF
    done

    info "配置文件:"
    cat "$config_file" | while IFS= read -r line; do
        info "  $line"
    done

    # 创建集群
    log "开始创建集群（可能需要 2-5 分钟）..."
    if kind create cluster --name "$CLUSTER_NAME" --config "$config_file" --wait 180s 2>&1 | tee -a "$LOG_FILE"; then
        ok "集群 '${CLUSTER_NAME}' 创建成功"
    else
        error "集群创建失败，请检查日志: ${LOG_FILE}"
    fi

    rm -f "$config_file"
}

# ────────────────────────────────────────────────────────────
# 验证集群
# ────────────────────────────────────────────────────────────
verify_cluster() {
    step "[Step 4/4] 验证集群"

    # 确保 kubeconfig 已设置
    kind get kubeconfig --name "$CLUSTER_NAME" > /tmp/kind-kubeconfig-$$ 2>/dev/null
    export KUBECONFIG="/tmp/kind-kubeconfig-$$"

    # 也写入默认位置
    mkdir -p "$HOME/.kube"
    kind get kubeconfig --name "$CLUSTER_NAME" > "$HOME/.kube/config" 2>/dev/null
    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "${sudo_home}/.kube"
        kind get kubeconfig --name "$CLUSTER_NAME" > "${sudo_home}/.kube/config" 2>/dev/null
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "${sudo_home}/.kube/config"
    fi

    info "kubectl get nodes"
    kubectl get nodes 2>&1 | tee -a "$LOG_FILE"
    echo ""

    info "kubectl get pods -A"
    kubectl get pods -A 2>&1 | tee -a "$LOG_FILE"
    echo ""

    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_count
    ready_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)

    if [[ "$ready_count" -eq "$node_count" ]] && [[ "$node_count" -gt 0 ]]; then
        ok "所有 ${node_count} 个节点 Ready"
    else
        warn "${ready_count}/${node_count} 个节点 Ready"
    fi

    rm -f "/tmp/kind-kubeconfig-$$"
}

# ────────────────────────────────────────────────────────────
# 打印完成信息
# ────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  Kind K8s 集群就绪！${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
    echo -e "${BOLD}集群信息:${NC}"
    echo -e "  名称:     ${CYAN}${CLUSTER_NAME}${NC}"
    echo -e "  节点:     1 master + ${WORKER_COUNT} worker"
    echo -e "  API:      ${CYAN}https://127.0.0.1:${API_PORT}${NC}"
    echo -e "  NodePort: ${NODEPORT_START}-${NODEPORT_END}"
    echo ""
    echo -e "${BOLD}常用命令:${NC}"
    echo -e "  查看节点:      ${CYAN}kubectl get nodes${NC}"
    echo -e "  部署应用:      ${CYAN}kubectl create deployment nginx --image=nginx --replicas=2${NC}"
    echo -e "  暴露服务:      ${CYAN}kubectl expose deployment nginx --port=80 --type=NodePort${NC}"
    echo -e "  加载本地镜像:  ${CYAN}kind load docker-image my-app:v1 --name ${CLUSTER_NAME}${NC}"
    echo -e "  删除集群:      ${CYAN}kind delete cluster --name ${CLUSTER_NAME}${NC}"
    echo -e "  查看集群:      ${CYAN}kind get clusters${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────
# 删除集群
# ────────────────────────────────────────────────────────────
delete_cluster() {
    print_banner "Kind 集群删除" "集群: ${CLUSTER_NAME}"

    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "集群 '${CLUSTER_NAME}' 不存在"
        return 0
    fi

    step "删除集群 '${CLUSTER_NAME}'"
    info "kind delete cluster --name ${CLUSTER_NAME}"
    info "这将删除集群的所有节点容器和网络"
    confirm

    kind delete cluster --name "$CLUSTER_NAME"
    ok "集群 '${CLUSTER_NAME}' 已删除"
}

# ────────────────────────────────────────────────────────────
# 查看状态
# ────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BOLD}Kind 集群状态${NC}"
    echo ""

    local clusters
    clusters=$(kind get clusters 2>/dev/null || true)

    if [[ -z "$clusters" ]]; then
        info "没有运行中的 Kind 集群"
        return 0
    fi

    echo -e "${BOLD}集群列表:${NC}"
    echo "$clusters" | while IFS= read -r name; do
        echo -e "  ${GREEN}●${NC} ${name}"
    done
    echo ""

    # 如果指定的集群存在，显示详情
    if echo "$clusters" | grep -q "^${CLUSTER_NAME}$"; then
        echo -e "${BOLD}集群 '${CLUSTER_NAME}' 详情:${NC}"
        echo ""

        # 节点容器
        docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
            --format "  {{.Names}}\t{{.Status}}" 2>/dev/null

        echo ""

        # K8s 节点
        if kind get kubeconfig --name "$CLUSTER_NAME" > /tmp/kind-status-$$ 2>/dev/null; then
            KUBECONFIG="/tmp/kind-status-$$" kubectl get nodes 2>/dev/null | sed 's/^/  /'
            rm -f "/tmp/kind-status-$$"
        fi
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Kind 安装开始 $(date) | 操作: $ACTION ===" >> "$LOG_FILE"

    case "$ACTION" in
        create)
            print_banner "Kind K8s 集群安装" "集群: ${CLUSTER_NAME} | 节点: 1 master + ${WORKER_COUNT} worker"
            check_prerequisites
            install_tools
            create_cluster
            verify_cluster
            print_summary
            ;;
        install)
            print_banner "Kind 工具安装" "kind v${KIND_VERSION} + kubectl"
            check_prerequisites
            install_tools
            ok "工具安装完成"
            info "创建集群: $0 create --yes"
            ;;
        delete)
            delete_cluster
            ;;
        status)
            show_status
            ;;
    esac

    echo ""
    ok "完成！日志: ${LOG_FILE}"
    echo ""
}

main "$@"
