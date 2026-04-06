#!/usr/bin/env bash
# ============================================================
# k8s/install.sh — K8s 集群安装脚本
#
# 本地执行:
#   sudo ./platforms/k8s/kubeadm/install.sh master [--yes]
#   sudo ./platforms/k8s/kubeadm/install.sh worker [--yes]
#
# 远程执行（通过顶层 install.sh 分发）:
#   curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
#     | sudo bash -s -- k8s master
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库（兼容三种执行方式）
#   1. 本地克隆后直接执行：sudo ./platforms/k8s/kubeadm/install.sh master
#   2. 顶层 install.sh 分发（下载到 /tmp/bootstrap-$$/ 后执行）
#   3. curl | bash 直接执行子脚本（不推荐，但兜底支持）
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    # 候选路径列表（按优先级）
    local candidates=(
        # 情况 1：本地克隆，脚本在 k8s/install.sh，lib 在 ../common/lib.sh
        "$(cd "$(dirname "${BASH_SOURCE[0]:-install.sh}")" 2>/dev/null && pwd)/../../../common/lib.sh"
        # 情况 2：顶层 install.sh 分发，cd 到 TMP_DIR 后，lib 在 ./common/lib.sh
        "$(pwd)/common/lib.sh"
    )

    for path in "${candidates[@]}"; do
        if [[ -f "$path" ]]; then
            # shellcheck source=/dev/null
            source "$path"
            return 0
        fi
    done

    # 情况 3：兜底，从远程下载
    echo "→ 下载 common/lib.sh ..."
    curl -fsSL "${bootstrap_url}/common/lib.sh" -o "$tmp_lib" \
        || { echo "❌ 无法加载 common/lib.sh"; exit 1; }
    # shellcheck source=/dev/null
    source "$tmp_lib"
    # 注册清理
    _bootstrap_tmp_lib="$tmp_lib"
    _bootstrap_cleanup_lib() { rm -f "$_bootstrap_tmp_lib"; }
    trap '_bootstrap_cleanup_lib' EXIT
}

_load_lib

# 脚本所在目录（用于查找本地资源文件）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ────────────────────────────────────────────────────────────
# K8s 专属配置
# ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/k8s-install.log"
K8S_VERSION="v1.30"
K8S_PATCH_VERSION="v1.30.14"
K8S_IMAGE_REPO="registry.aliyuncs.com/google_containers"
CONTAINERD_PAUSE_IMAGE="${K8S_IMAGE_REPO}/pause:3.10.1"
POD_NETWORK_CIDR="10.244.0.0/16"
FLANNEL_VERSION="v0.28.1"
FLANNEL_CNI_VERSION="v1.9.0-flannel1"
DASHBOARD_VERSION="v2.7.0"
DASHBOARD_NODEPORT=30443

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
ROLE=""

usage() {
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 master [--yes]         初始化 master 节点"
    echo "  $0 worker [--yes]         初始化 worker 节点"
    echo "  $0 dashboard [--yes]      安装 K8s Dashboard"
    echo "  $0 label-workers          为未标记的节点打上 worker 标签"
    echo ""
    echo -e "${BOLD}选项:${NC}"
    echo "  --yes / -y    跳过所有确认提示，自动执行"
    echo ""
    exit 1
}

if [[ $# -eq 0 ]]; then usage; fi

for arg in "$@"; do
    case "$arg" in
        master|worker|dashboard|label-workers) ROLE="$arg" ;;
        --yes|-y)      AUTO_YES=true ;;
        --help|-h)     usage ;;
        *) echo "未知参数: $arg"; usage ;;
    esac
done

if [[ -z "$ROLE" ]]; then usage; fi

# ────────────────────────────────────────────────────────────
# Step 0: 前置准备（所有节点）
# ────────────────────────────────────────────────────────────
setup_prerequisites() {
    step "[Step 1/6] 前置准备"
    info "关闭 swap"
    info "加载内核模块：overlay、br_netfilter"
    info "配置内核网络参数"
    confirm

    # 关闭 swap
    if swapon --show | grep -q .; then
        swapoff -a
        ok "swap 已关闭"
    else
        ok "swap 本已关闭，跳过"
    fi
    sed -i '/\sswap\s/ s/^[^#]/#&/' /etc/fstab

    # 内核模块
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
    ok "内核模块已加载"

    # 内核网络参数
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system > /dev/null
    ok "内核参数已配置"
}

# ────────────────────────────────────────────────────────────
# Step 1: 安装 containerd（所有节点）
# ────────────────────────────────────────────────────────────
install_containerd() {
    step "[Step 2/6] 安装 containerd"
    info "添加阿里云 Docker 仓库"
    info "安装 containerd.io"
    info "配置 SystemdCgroup + 阿里云 pause 镜像"
    confirm

    if service_running containerd; then
        ok "containerd 已运行，更新配置..."
    else
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg

        install -m 0755 -d /usr/share/keyrings
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | \
            gpg --dearmor --yes -o /usr/share/keyrings/docker.gpg

        echo "deb [arch=$(get_arch) signed-by=/usr/share/keyrings/docker.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(get_ubuntu_codename) stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y -qq containerd.io
    fi

    # 生成/更新配置
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # 启用 SystemdCgroup
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    # 替换 pause 镜像（兼容新旧版字段名）
    if grep -q 'sandbox_image' /etc/containerd/config.toml; then
        sed -i "s|sandbox_image = \".*\"|sandbox_image = \"${CONTAINERD_PAUSE_IMAGE}\"|" \
            /etc/containerd/config.toml
    else
        sed -i "s|sandbox = '.*'|sandbox = '${CONTAINERD_PAUSE_IMAGE}'|" \
            /etc/containerd/config.toml
    fi

    systemctl restart containerd
    systemctl enable containerd --quiet

    if service_running containerd; then
        local ver
        ver=$(containerd --version | awk '{print $3}')
        ok "containerd ${ver} 运行中"
    else
        error "containerd 启动失败，请检查: journalctl -u containerd"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 2: 安装 kubelet / kubeadm / kubectl（所有节点）
# ────────────────────────────────────────────────────────────
install_k8s_tools() {
    step "[Step 3/6] 安装 kubelet / kubeadm / kubectl (${K8S_VERSION})"
    info "添加阿里云 K8s 仓库"
    info "安装三件套并锁定版本"
    confirm

    if cmd_exists kubeadm && kubeadm version &>/dev/null; then
        local installed
        installed=$(kubeadm version -o short 2>/dev/null || echo "unknown")
        ok "kubeadm 已安装 (${installed})，跳过"
        return
    fi

    mkdir -p /etc/apt/keyrings

    curl -fsSL "https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_VERSION}/deb/Release.key" | \
        gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://mirrors.aliyun.com/kubernetes-new/core/stable/${K8S_VERSION}/deb/ /" | \
        tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    ok "kubelet / kubeadm / kubectl 安装完成"
}

# ────────────────────────────────────────────────────────────
# Step 3: 预拉取镜像（所有节点）
# ────────────────────────────────────────────────────────────
pull_images() {
    step "[Step 4/6] 预拉取镜像"
    info "从阿里云拉取 K8s 核心镜像 (${K8S_PATCH_VERSION})"
    info "拉取并 tag pause 镜像"
    confirm

    if [[ "$ROLE" == "master" ]]; then
        kubeadm config images pull \
            --image-repository "${K8S_IMAGE_REPO}" \
            --kubernetes-version "${K8S_PATCH_VERSION}"
        ok "K8s 核心镜像拉取完成"
    fi

    if ! ctr -n k8s.io images pull "${CONTAINERD_PAUSE_IMAGE}"; then
        error "pause 镜像拉取失败，请检查网络后重试"
    fi
    ctr -n k8s.io images tag \
        "${CONTAINERD_PAUSE_IMAGE}" \
        "registry.k8s.io/pause:3.10.1" 2>/dev/null || true

    ok "pause 镜像就绪"
}

# ────────────────────────────────────────────────────────────
# Step 4: 导入 Flannel 镜像（所有节点）
# ────────────────────────────────────────────────────────────
import_flannel_images() {
    step "[Step 5/6] 导入 Flannel 镜像"

    local flannel_image="ghcr.io/flannel-io/flannel:${FLANNEL_VERSION}"
    local flannel_cni_image="ghcr.io/flannel-io/flannel-cni-plugin:${FLANNEL_CNI_VERSION}"
    local flannel_tar="flannel.tar"
    local flannel_cni_tar="flannel-cni.tar"

    # 幂等：镜像已存在则跳过
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "flannel-io/flannel:${FLANNEL_VERSION}"; then
        ok "Flannel 镜像已存在，跳过"
        return
    fi

    # 方式 1：本地 tar 文件导入
    if [[ -f "./${flannel_tar}" && -f "./${flannel_cni_tar}" ]]; then
        info "在当前目录找到 Flannel tar 文件，准备导入"
        confirm
        ctr -n k8s.io images import "./${flannel_tar}"
        ctr -n k8s.io images import "./${flannel_cni_tar}"
        ok "Flannel 镜像导入完成"
        return
    fi

    # 方式 2：直接从 ghcr.io 拉取
    info "尝试从 ghcr.io 直接拉取 Flannel 镜像..."
    if ctr -n k8s.io images pull "$flannel_image" 2>/dev/null \
        && ctr -n k8s.io images pull "$flannel_cni_image" 2>/dev/null; then
        ok "Flannel 镜像拉取完成"
        return
    fi

    # 方式 3：提示手动处理
    warn "ghcr.io 不可达且未找到本地镜像包，请在海外节点执行以下命令："
    echo ""
    echo -e "${CYAN}  # ① 海外节点导出：${NC}"
    echo "  ctr -n k8s.io images pull ${flannel_image}"
    echo "  ctr -n k8s.io images pull ${flannel_cni_image}"
    echo "  ctr -n k8s.io images export ${flannel_tar} ${flannel_image}"
    echo "  ctr -n k8s.io images export ${flannel_cni_tar} ${flannel_cni_image}"
    echo ""
    echo -e "${CYAN}  # ② scp 到本机当前目录：${NC}"
    echo "  scp ${flannel_tar} ${flannel_cni_tar} root@$(hostname -I | awk '{print $1}'):$(pwd)/"
    echo ""

    if [[ "$AUTO_YES" == true ]]; then
        warn "--yes 模式跳过，请手动导入后重新运行"
        return
    fi

    echo -e "${YELLOW}完成后按 Enter 重试导入，或 Ctrl+C 退出手动处理...${NC}"
    read -r < /dev/tty || true

    if [[ -f "./${flannel_tar}" && -f "./${flannel_cni_tar}" ]]; then
        ctr -n k8s.io images import "./${flannel_tar}"
        ctr -n k8s.io images import "./${flannel_cni_tar}"
        ok "Flannel 镜像导入完成"
    else
        warn "仍未找到文件，跳过。master 初始化后请手动导入并 apply Flannel"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 5（master）: 初始化集群
# ────────────────────────────────────────────────────────────
init_master() {
    step "[Step 6/6] 初始化 K8s 集群（master）"
    info "执行 kubeadm init"
    info "配置 kubectl 访问权限"
    info "安装 Flannel CNI"
    confirm

    # 幂等：已初始化则跳过 init
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        ok "集群已初始化（admin.conf 存在），跳过 kubeadm init"
    else
        kubeadm init \
            --pod-network-cidr="${POD_NETWORK_CIDR}" \
            --image-repository "${K8S_IMAGE_REPO}" \
            --kubernetes-version "${K8S_PATCH_VERSION}" \
            2>&1 | tee -a "$LOG_FILE"
        ok "kubeadm init 完成"
    fi

    # 配置 kubectl（root）
    mkdir -p "$HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
    chown "$(id -u):$(id -g)" "$HOME/.kube/config"

    # 同步给 sudo 原始用户
    if [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "${sudo_home}/.kube"
        cp -f /etc/kubernetes/admin.conf "${sudo_home}/.kube/config"
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "${sudo_home}/.kube/config"
        ok "kubectl 配置已同步到用户 ${SUDO_USER}"
    fi

    # 安装 Flannel CNI
    local flannel_yaml="/tmp/kube-flannel.yml"
    local flannel_local="${SCRIPT_DIR}/flannel/kube-flannel.yml"

    if [[ -f "$flannel_local" ]]; then
        info "使用本地 Flannel 配置文件"
        cp "$flannel_local" "$flannel_yaml"
    elif curl -fsSL --max-time 15 \
        "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
        -o "$flannel_yaml" 2>/dev/null; then
        ok "Flannel 配置文件下载成功"
    else
        warn "无法下载 Flannel 配置，请手动执行："
        echo "  kubectl apply -f https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
        return
    fi

    kubectl apply -f "$flannel_yaml"
    ok "Flannel CNI 已应用"

    # 等待节点 Ready（最多 120 秒）
    log "等待 master 节点 Ready..."
    local node_ready=false
    for _ in $(seq 1 24); do
        local status
        status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
        if [[ "$status" == "Ready" ]]; then
            node_ready=true
            ok "master 节点已 Ready"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    if [[ "$node_ready" == false ]]; then
        warn "等待超时（120s），节点尚未 Ready，请手动检查: kubectl get nodes"
    fi

    label_workers

    # 保存 join 命令
    local join_cmd_file="/root/k8s-join-command.sh"
    local join_cmd
    join_cmd=$(kubeadm token create --print-join-command)

    cat > "$join_cmd_file" <<EOF
#!/usr/bin/env bash
# Worker 节点加入集群
# 生成时间: $(date)
# token 有效期: 24 小时

sudo ${join_cmd}
EOF
    chmod +x "$join_cmd_file"

    # 打印完成信息
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  🎉 K8s master 初始化完成！${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
    echo -e "${BOLD}Worker 节点加入命令（已保存至 ${join_cmd_file}）：${NC}"
    echo ""
    echo -e "  ${CYAN}sudo ${join_cmd}${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  token 有效期 24 小时，过期后重新生成：${NC}"
    echo "  kubeadm token create --print-join-command"
    echo ""
    echo -e "查看节点状态: ${CYAN}kubectl get nodes${NC}"
    echo -e "查看系统组件: ${CYAN}kubectl get pods -n kube-system${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────
# 为未标记的节点打上 worker 标签
# ────────────────────────────────────────────────────────────
label_workers() {
    local labeled=false
    local node
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        kubectl label node "$node" node-role.kubernetes.io/worker= --overwrite 2>/dev/null \
            && ok "节点 ${node} 已标记为 worker" && labeled=true
    done < <(kubectl get nodes --no-headers 2>/dev/null | awk '$3 == "<none>" {print $1}')

    if [[ "$labeled" == false ]]; then
        ok "所有节点已有角色标签，无需标记"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 5（worker）: 加入集群
# ────────────────────────────────────────────────────────────
join_worker() {
    step "[Step 6/6] 加入集群（worker）"

    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        ok "此节点已加入集群（kubelet.conf 存在），跳过"
        return
    fi

    if [[ "$AUTO_YES" == true ]]; then
        error "--yes 模式无法自动获取 join 命令，请手动执行 kubeadm join"
    fi

    echo ""
    echo -e "${BOLD}请粘贴从 master 节点获取的 join 命令：${NC}"
    echo -e "${CYAN}（格式：kubeadm join <ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...）${NC}"
    echo ""
    read -rp "Join 命令: " JOIN_CMD < /dev/tty

    if [[ -z "$JOIN_CMD" ]]; then error "join 命令不能为空"; fi

    # 安全校验：只允许 kubeadm join 命令
    if [[ ! "$JOIN_CMD" =~ ^(sudo[[:space:]]+)?kubeadm[[:space:]]+join[[:space:]] ]]; then
        error "输入格式不正确，必须以 'kubeadm join' 开头"
    fi

    # 去掉用户可能多输入的 sudo 前缀（脚本本身已是 root）
    JOIN_CMD="${JOIN_CMD#sudo }"

    read -ra JOIN_ARGS <<< "$JOIN_CMD"
    "${JOIN_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"

    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        ok "worker 节点已成功加入集群"
        echo ""
        echo -e "${BOLD}请回到 master 节点验证：${NC}"
        echo -e "  ${CYAN}kubectl get nodes${NC}"
        echo ""
    else
        error "加入集群失败，请检查日志: $LOG_FILE"
    fi
}

# ────────────────────────────────────────────────────────────
# Dashboard 安装
# ────────────────────────────────────────────────────────────
install_dashboard() {
    print_banner "K8s Dashboard 安装" "版本: ${DASHBOARD_VERSION} | 端口: ${DASHBOARD_NODEPORT}"

    # ── Step 1/5: 前置检查 ──
    step "[Step 1/5] 前置检查"
    info "验证 kubectl 是否可用"
    info "验证集群节点是否 Ready"
    info "检查 Dashboard 是否已安装"
    confirm

    require_root

    if [[ ! -f /etc/kubernetes/admin.conf ]]; then
        error "未找到 admin.conf，请先执行 '$0 master' 初始化集群"
    fi

    export KUBECONFIG=/etc/kubernetes/admin.conf

    if ! kubectl get nodes &>/dev/null; then
        error "无法连接集群，请检查 kubectl 配置"
    fi
    ok "集群连接正常"

    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
    if [[ "$ready_nodes" -eq 0 ]]; then
        error "没有 Ready 状态的节点，请先确保集群正常运行"
    fi
    ok "集群有 ${ready_nodes} 个 Ready 节点"

    # ── Step 2/5: 部署 Dashboard ──
    step "[Step 2/5] 部署 Dashboard"
    info "部署 Dashboard ${DASHBOARD_VERSION} 到 kubernetes-dashboard namespace"
    info "包含: Dashboard Web UI、Metrics Scraper、相关 RBAC 配置"
    confirm

    local dashboard_yaml="/tmp/dashboard-${DASHBOARD_VERSION}.yaml"
    local dashboard_url="https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

    if kubectl get namespace kubernetes-dashboard &>/dev/null; then
        ok "kubernetes-dashboard namespace 已存在，更新部署..."
    fi

    if [[ ! -f "$dashboard_yaml" ]]; then
        info "下载 Dashboard YAML..."
        if ! curl -fsSL --max-time 30 "$dashboard_url" -o "$dashboard_yaml"; then
            error "无法下载 Dashboard YAML，请检查网络: ${dashboard_url}"
        fi
        ok "Dashboard YAML 下载完成"
    fi

    kubectl apply -f "$dashboard_yaml"
    ok "Dashboard 资源已部署"

    info "等待 Dashboard Deployment 就绪（最多 120s）..."
    if kubectl -n kubernetes-dashboard rollout status deployment/kubernetes-dashboard --timeout=120s 2>/dev/null; then
        ok "Dashboard Deployment 已就绪"
    else
        warn "Dashboard 尚未就绪，请稍后检查: kubectl -n kubernetes-dashboard get pods"
    fi

    # ── Step 3/5: 创建管理员账户 ──
    step "[Step 3/5] 创建管理员账户"
    info "创建 ServiceAccount: admin（用于 Dashboard 登录认证）"
    info "创建 ClusterRoleBinding: 将 admin 绑定到 cluster-admin 角色"
    info "说明: cluster-admin 拥有集群最高权限，生产环境建议使用更细粒度的 RBAC"
    confirm

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin
  namespace: kubernetes-dashboard
EOF
    ok "ServiceAccount admin 已创建"

    kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin
  namespace: kubernetes-dashboard
EOF
    ok "ClusterRoleBinding admin-cluster-binding 已创建"

    # ── Step 4/5: 暴露服务 ──
    step "[Step 4/5] 暴露服务（NodePort）"
    info "将 Dashboard Service 类型从 ClusterIP 改为 NodePort"
    info "固定端口: ${DASHBOARD_NODEPORT}（443 = HTTPS 默认端口，方便记忆）"
    info "修改后可通过 https://<节点IP>:${DASHBOARD_NODEPORT} 访问"
    confirm

    kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard \
        -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"nodePort\":${DASHBOARD_NODEPORT}}]}}"

    # 验证 NodePort 是否生效
    local actual_port
    actual_port=$(kubectl -n kubernetes-dashboard get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [[ "$actual_port" == "${DASHBOARD_NODEPORT}" ]]; then
        ok "Dashboard 已暴露到 NodePort ${DASHBOARD_NODEPORT}"
    else
        warn "NodePort 设置可能未生效，请手动检查: kubectl -n kubernetes-dashboard get svc kubernetes-dashboard"
    fi

    # ── Step 5/5: 生成访问凭证 ──
    step "[Step 5/5] 生成访问凭证"
    info "为 admin 创建长期 Token（Secret 方式，不过期）"
    info "说明: K8s v1.24+ 不再自动生成永久 token，需手动创建 Secret"
    confirm

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: admin-secret
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin
type: kubernetes.io/service-account-token
EOF

    # 等待 token 生成
    local token=""
    local retry=0
    while [[ -z "$token" && $retry -lt 10 ]]; do
        token=$(kubectl -n kubernetes-dashboard get secret admin-secret -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [[ -z "$token" ]]; then
            sleep 1
            retry=$((retry + 1))
        fi
    done

    if [[ -z "$token" ]]; then
        error "Token 生成失败，请手动检查: kubectl -n kubernetes-dashboard get secret admin-secret"
    fi

    # 保存 token
    local token_file="/root/dashboard-token.txt"
    cat > "$token_file" <<TOKENEOF
# K8s Dashboard 登录 Token
# 生成时间: $(date)
# 账户: admin (ServiceAccount)
# 权限: cluster-admin
# 有效期: 永久（删除 Secret 可吊销）

${token}
TOKENEOF
    chmod 600 "$token_file"
    ok "Token 已保存到 ${token_file}"

    # 获取节点 IP
    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

    # 打印完成信息
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  🎉 K8s Dashboard 安装完成！${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
    echo -e "${BOLD}访问地址:${NC}"
    echo -e "  ${CYAN}https://${node_ip}:${DASHBOARD_NODEPORT}${NC}"
    echo ""
    echo -e "${BOLD}登录方式:${NC}"
    echo -e "  选择 Token，粘贴以下内容："
    echo ""
    echo -e "  ${CYAN}${token}${NC}"
    echo ""
    echo -e "${BOLD}Token 文件:${NC} ${token_file}"
    echo ""
    echo -e "${YELLOW}⚠️  注意事项：${NC}"
    echo "  1. 浏览器会提示证书不安全（自签证书），点击「高级」→「继续访问」"
    echo "  2. 云服务器需在安全组中放行 ${DASHBOARD_NODEPORT} 端口（TCP）"
    echo ""
    echo -e "查看 Dashboard 状态: ${CYAN}kubectl -n kubernetes-dashboard get pods${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"

    # 轻量子命令：不走完整安装流程
    if [[ "$ROLE" == "label-workers" ]]; then
        require_root
        step "为 worker 节点打标签"
        label_workers
        return
    fi

    if [[ "$ROLE" == "dashboard" ]]; then
        install_dashboard
        return
    fi

    echo "=== K8s 安装开始 $(date) | 角色: $ROLE ===" >> "$LOG_FILE"

    print_banner "K8s 集群安装 — ${ROLE}" "版本: ${K8S_PATCH_VERSION} | 镜像源: 阿里云"

    local min_mem=2
    if [[ "$ROLE" == "worker" ]]; then min_mem=1; fi
    preflight_base "K8s" "$min_mem"

    setup_prerequisites
    install_containerd
    install_k8s_tools
    pull_images
    import_flannel_images

    if [[ "$ROLE" == "master" ]]; then
        init_master
    else
        join_worker
    fi

    echo ""
    ok "全部完成！日志: ${LOG_FILE}"
    echo ""
}

main "$@"