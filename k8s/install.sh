#!/usr/bin/env bash
# ============================================================
# k8s/install.sh — K8s 集群安装脚本
#
# 本地执行:
#   sudo ./k8s/install.sh master [--yes]
#   sudo ./k8s/install.sh worker [--yes]
#
# 远程执行（通过顶层 install.sh 分发）:
#   curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
#     | sudo bash -s -- k8s master
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库（兼容三种执行方式）
#   1. 本地克隆后直接执行：sudo ./k8s/install.sh master
#   2. 顶层 install.sh 分发（下载到 /tmp/bootstrap-$$/ 后执行）
#   3. curl | bash 直接执行子脚本（不推荐，但兜底支持）
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    # 候选路径列表（按优先级）
    local candidates=(
        # 情况 1：本地克隆，脚本在 k8s/install.sh，lib 在 ../common/lib.sh
        "$(cd "$(dirname "${BASH_SOURCE[0]:-install.sh}")" 2>/dev/null && pwd)/../common/lib.sh"
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

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
ROLE=""

usage() {
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 master [--yes]         初始化 master 节点"
    echo "  $0 worker [--yes]         初始化 worker 节点"
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
        master|worker|label-workers) ROLE="$arg" ;;
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