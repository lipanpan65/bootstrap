#!/usr/bin/env bash
# ============================================================
# prometheus/install.sh — Prometheus 监控安装脚本
#
# 本地执行:
#   sudo ./observability/prometheus/install.sh server [--yes]
#   sudo ./observability/prometheus/install.sh node-exporter [--yes]
#   sudo ./observability/prometheus/install.sh alertmanager [--yes]
#   sudo ./observability/prometheus/install.sh all [--yes]
#
# 远程执行（通过顶层 install.sh 分发）:
#   curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
#     | sudo bash -s -- prometheus server
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库（兼容三种执行方式）
#   1. 本地克隆后直接执行：sudo ./observability/prometheus/install.sh server
#   2. 顶层 install.sh 分发（下载到 /tmp/bootstrap-$$/ 后执行）
#   3. curl | bash 直接执行子脚本（不推荐，但兜底支持）
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    # 候选路径列表（按优先级）
    local candidates=(
        # 情况 1：本地克隆，脚本在 observability/prometheus/install.sh，lib 在 ../../common/lib.sh
        "$(cd "$(dirname "${BASH_SOURCE[0]:-install.sh}")" 2>/dev/null && pwd)/../../common/lib.sh"
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

# ────────────────────────────────────────────────────────────
# Prometheus 专属配置
# ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/prometheus-install.log"

# 版本号（默认值）
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.53.4}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-0.27.0}"

# Server 配置
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_DATA_DIR="${PROMETHEUS_DATA_DIR:-/var/lib/prometheus}"
PROMETHEUS_CONFIG=""  # 用户自定义配置文件路径，为空则生成默认配置

# Node Exporter 配置
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"

# Alertmanager 配置
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
ALERTMANAGER_CONFIG=""  # 用户自定义配置文件路径

# GitHub 下载基础 URL（可通过环境变量覆盖为镜像站）
GITHUB_DL_URL="${GITHUB_DL_URL:-https://github.com}"

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
ROLE=""

require_arg() {
    if [[ -z "${2:-}" ]]; then
        echo "错误: $1 需要一个参数值"
        usage
    fi
}

usage() {
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 server [选项]          安装 Prometheus Server"
    echo "  $0 node-exporter [选项]   安装 Node Exporter"
    echo "  $0 alertmanager [选项]    安装 Alertmanager"
    echo "  $0 all [选项]             安装全部组件"
    echo ""
    echo -e "${BOLD}通用选项:${NC}"
    echo "  -y, --yes                 跳过所有确认提示"
    echo "  -h, --help                显示帮助信息"
    echo ""
    echo -e "${BOLD}Server 选项:${NC}"
    echo "  -v, --version VERSION     Prometheus 版本 (默认: ${PROMETHEUS_VERSION})"
    echo "  -p, --port PORT           监听端口 (默认: ${PROMETHEUS_PORT})"
    echo "  -r, --retention TIME      数据保留时间 (默认: ${PROMETHEUS_RETENTION})"
    echo "  --data-dir DIR            数据目录 (默认: ${PROMETHEUS_DATA_DIR})"
    echo "  --config FILE             自定义配置文件（跳过默认配置生成）"
    echo ""
    echo -e "${BOLD}Node Exporter 选项:${NC}"
    echo "  -v, --version VERSION     Node Exporter 版本 (默认: ${NODE_EXPORTER_VERSION})"
    echo "  --port PORT               监听端口 (默认: ${NODE_EXPORTER_PORT})"
    echo ""
    echo -e "${BOLD}Alertmanager 选项:${NC}"
    echo "  -v, --version VERSION     Alertmanager 版本 (默认: ${ALERTMANAGER_VERSION})"
    echo "  --port PORT               监听端口 (默认: ${ALERTMANAGER_PORT})"
    echo "  --config FILE             自定义配置文件"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  $0 server --yes"
    echo "  $0 server -v 2.53.4 -r 30d --yes"
    echo "  $0 node-exporter --yes"
    echo "  $0 all --yes"
    echo ""
    exit 1
}

if [[ $# -eq 0 ]]; then usage; fi

# 先提取 ROLE（第一个非选项参数）
case "$1" in
    server|node-exporter|alertmanager|all) ROLE="$1"; shift ;;
    --help|-h) usage ;;
    *) echo "未知子命令: $1"; usage ;;
esac

# 解析剩余选项
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)    require_arg "$1" "${2:-}"; PROMETHEUS_VERSION="$2"; NODE_EXPORTER_VERSION="$2"; ALERTMANAGER_VERSION="$2"; shift 2 ;;
        -p|--port)       require_arg "$1" "${2:-}"; PROMETHEUS_PORT="$2"; shift 2 ;;
        -r|--retention)  require_arg "$1" "${2:-}"; PROMETHEUS_RETENTION="$2"; shift 2 ;;
        --data-dir)      require_arg "$1" "${2:-}"; PROMETHEUS_DATA_DIR="$2"; shift 2 ;;
        --port)          require_arg "$1" "${2:-}"
                         # 根据 ROLE 设置对应端口
                         case "$ROLE" in
                             server)        PROMETHEUS_PORT="$2" ;;
                             node-exporter) NODE_EXPORTER_PORT="$2" ;;
                             alertmanager)  ALERTMANAGER_PORT="$2" ;;
                         esac
                         shift 2 ;;
        --config)        require_arg "$1" "${2:-}"
                         case "$ROLE" in
                             server)       PROMETHEUS_CONFIG="$2" ;;
                             alertmanager) ALERTMANAGER_CONFIG="$2" ;;
                             *) warn "--config 仅适用于 server 和 alertmanager" ;;
                         esac
                         shift 2 ;;
        -y|--yes)        AUTO_YES=true; shift ;;
        -h|--help)       usage ;;
        *)               echo "未知参数: $1"; usage ;;
    esac
done

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────

# 检查端口是否被占用
check_port_available() {
    local port="$1"
    local name="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        error "端口 ${port} 已被占用，${name} 无法启动。请检查: ss -tlnp | grep :${port}"
    fi
    ok "端口 ${port} 可用"
}

# 检查组件是否在运行（兼容 systemd 和容器环境）
component_running() {
    local service_name="$1"   # systemd 服务名
    local process_name="$2"   # 进程名（用于 pgrep 兜底）

    # 优先用 systemctl
    if cmd_exists systemctl && service_running "$service_name"; then
        return 0
    fi

    # 兜底：检查进程是否存在
    pgrep -x "$process_name" &>/dev/null
}

# 下载并解压二进制包
# 注意: 此函数通过 echo 返回解压目录路径，所有日志输出重定向到 fd3 避免污染返回值
download_and_extract() {
    local component="$1"  # prometheus / node_exporter / alertmanager
    local version="$2"
    local arch
    arch=$(get_arch)

    local tarball="${component}-${version}.linux-${arch}.tar.gz"
    local url="${GITHUB_DL_URL}/prometheus/${component}/releases/download/v${version}/${tarball}"
    local tmp_file="/tmp/${tarball}"
    local tmp_extract="/tmp/${component}-${version}.linux-${arch}"

    info "下载 ${component} v${version} (${arch})..." >&3
    info "URL: ${url}" >&3

    if [[ -f "$tmp_file" ]]; then
        ok "文件已存在，跳过下载: ${tmp_file}" >&3
    else
        curl -fSL --progress-bar "$url" -o "$tmp_file" \
            || error "下载失败: ${url}\n请检查版本号是否正确，或设置 GITHUB_DL_URL 使用镜像站"
        ok "下载完成" >&3
    fi

    info "解压到 /tmp/ ..." >&3
    tar xzf "$tmp_file" -C /tmp/
    ok "解压完成: ${tmp_extract}" >&3

    echo "$tmp_extract"
}

# ────────────────────────────────────────────────────────────
# Prometheus Server 安装
# ────────────────────────────────────────────────────────────

install_server_preflight() {
    step "[Step 1/5] 前置检查"
    info "检查 root 权限（require_root）"
    info "检查系统: Ubuntu 20.04/22.04/24.04，架构: amd64/arm64"
    info "检查内存 ≥ 2GB"
    info "检查网络连通性（阿里云镜像源）"
    info "检查端口 ${PROMETHEUS_PORT} 是否可用（ss -tlnp | grep :${PROMETHEUS_PORT}）"
    confirm

    preflight_base "Prometheus Server" 2

    # 幂等：已安装则检查是否在运行
    if component_running prometheus prometheus; then
        local ver
        ver=$(/usr/local/bin/prometheus --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
        warn "Prometheus (${ver}) 已在运行。继续将覆盖安装"
        confirm
    else
        check_port_available "$PROMETHEUS_PORT" "Prometheus Server"
    fi
}

install_server_user() {
    step "[Step 2/5] 创建用户与目录"
    info "useradd --no-create-home --shell /bin/false prometheus"
    info "mkdir -p /etc/prometheus          （配置文件目录）"
    info "mkdir -p /etc/prometheus/rules    ���告警规则目录）"
    info "mkdir -p ${PROMETHEUS_DATA_DIR}   （TSDB 数据目录）"
    info "chown prometheus:prometheus 上述目录"
    confirm

    if id prometheus &>/dev/null; then
        ok "用户 prometheus 已存在"
    else
        useradd --no-create-home --shell /bin/false prometheus
        ok "用户 prometheus 已创建"
    fi

    mkdir -p /etc/prometheus
    mkdir -p /etc/prometheus/rules
    mkdir -p "$PROMETHEUS_DATA_DIR"

    chown -R prometheus:prometheus /etc/prometheus
    chown -R prometheus:prometheus "$PROMETHEUS_DATA_DIR"
    ok "目录已创建并设置权限"
}

install_server_binary() {
    local arch
    arch=$(get_arch)
    step "[Step 3/5] 下载并安装二进制"
    info "下载: ${GITHUB_DL_URL}/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${arch}.tar.gz"
    info "cp prometheus  → /usr/local/bin/prometheus"
    info "cp promtool    → /usr/local/bin/promtool"
    info "cp consoles/、console_libraries/ → /etc/prometheus/"
    confirm

    local extract_dir
    extract_dir=$(download_and_extract "prometheus" "$PROMETHEUS_VERSION")

    # 安装二进制
    cp "${extract_dir}/prometheus" /usr/local/bin/
    cp "${extract_dir}/promtool"   /usr/local/bin/
    chown prometheus:prometheus /usr/local/bin/prometheus
    chown prometheus:prometheus /usr/local/bin/promtool

    # 安装 console 模板
    if [[ -d "${extract_dir}/consoles" ]]; then
        cp -r "${extract_dir}/consoles" /etc/prometheus/
        cp -r "${extract_dir}/console_libraries" /etc/prometheus/
        chown -R prometheus:prometheus /etc/prometheus/consoles
        chown -R prometheus:prometheus /etc/prometheus/console_libraries
    fi

    # 清理
    rm -rf "$extract_dir"

    local ver
    ver=$(prometheus --version 2>&1 | head -1 | awk '{print $3}')
    ok "Prometheus ${ver} 安装完成"
    ok "promtool $(promtool --version 2>&1 | head -1 | awk '{print $3}') 安装完成"
}

install_server_config() {
    step "[Step 4/5] 配置"
    info "生成 /etc/prometheus/prometheus.yml（scrape 自身 :${PROMETHEUS_PORT}）"
    info "创建 /etc/systemd/system/prometheus.service"
    info "  ExecStart: prometheus --config.file=/etc/prometheus/prometheus.yml"
    info "             --storage.tsdb.path=${PROMETHEUS_DATA_DIR}"
    info "             --storage.tsdb.retention.time=${PROMETHEUS_RETENTION}"
    info "             --web.listen-address=0.0.0.0:${PROMETHEUS_PORT}"
    info "             --web.enable-lifecycle"
    info "验证配置: promtool check config /etc/prometheus/prometheus.yml"
    confirm

    # 配置文件
    if [[ -n "$PROMETHEUS_CONFIG" ]]; then
        if [[ ! -f "$PROMETHEUS_CONFIG" ]]; then
            error "自定义配置文件不存在: $PROMETHEUS_CONFIG"
        fi
        cp "$PROMETHEUS_CONFIG" /etc/prometheus/prometheus.yml
        ok "已使用自定义配置: ${PROMETHEUS_CONFIG}"
    elif [[ -f /etc/prometheus/prometheus.yml ]]; then
        ok "配置文件已存在，保留现有配置"
    else
        cat > /etc/prometheus/prometheus.yml <<'PROMYML'
# Prometheus 配置文件
# 文档: https://prometheus.io/docs/prometheus/latest/configuration/configuration/

global:
  scrape_interval: 15s
  evaluation_interval: 15s

# 告警规则文件（Alertmanager 安装后取消注释）
# rule_files:
#   - "/etc/prometheus/rules/*.yml"

# Alertmanager 关联（Alertmanager 安装后取消注释）
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ["localhost:9093"]

scrape_configs:
  # 监控 Prometheus 自身
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # 监控 Node Exporter（安装后取消注释）
  # - job_name: "node"
  #   static_configs:
  #     - targets: ["localhost:9100"]
PROMYML
        chown prometheus:prometheus /etc/prometheus/prometheus.yml
        ok "默认配置文件已生成"
    fi

    # 验证配置
    if ! promtool check config /etc/prometheus/prometheus.yml; then
        error "配置文件语法错误，请检查 /etc/prometheus/prometheus.yml"
    fi
    ok "配置文件语法检查通过"

    # systemd 服务文件
    if cmd_exists systemctl; then
        cat > /etc/systemd/system/prometheus.service <<SERVICEEOF
[Unit]
Description=Prometheus Monitoring System
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=${PROMETHEUS_DATA_DIR} \\
    --storage.tsdb.retention.time=${PROMETHEUS_RETENTION} \\
    --web.listen-address=0.0.0.0:${PROMETHEUS_PORT} \\
    --web.console.templates=/etc/prometheus/consoles \\
    --web.console.libraries=/etc/prometheus/console_libraries \\
    --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
        ok "systemd 服务文件已创建"
    else
        warn "未检测到 systemctl，跳过 systemd 服务文件创建"
    fi
}

install_server_start() {
    step "[Step 5/5] 启动与验证"

    local start_cmd="/usr/local/bin/prometheus \
--config.file=/etc/prometheus/prometheus.yml \
--storage.tsdb.path=${PROMETHEUS_DATA_DIR} \
--storage.tsdb.retention.time=${PROMETHEUS_RETENTION} \
--web.listen-address=0.0.0.0:${PROMETHEUS_PORT} \
--web.console.templates=/etc/prometheus/consoles \
--web.console.libraries=/etc/prometheus/console_libraries \
--web.enable-lifecycle"

    if cmd_exists systemctl; then
        info "systemctl daemon-reload"
        info "systemctl enable --now prometheus"
    else
        warn "未检测到 systemctl（容器环境），将直接启动进程"
        info "nohup su -s /bin/bash prometheus -c '${start_cmd}'"
    fi
    info "健康检查: curl -sf http://localhost:${PROMETHEUS_PORT}/-/healthy"
    info "就绪检查: curl -sf http://localhost:${PROMETHEUS_PORT}/-/ready"
    confirm

    if cmd_exists systemctl; then
        systemctl daemon-reload
        systemctl enable --now prometheus --quiet
    else
        # 容器环境：直接启动进程
        nohup su -s /bin/bash prometheus -c "$start_cmd" > /var/log/prometheus.log 2>&1 &
        ok "Prometheus 已通过 nohup 后台启动（PID: $!）"
        ok "日志: /var/log/prometheus.log"
    fi

    # 等待启动
    local healthy=false
    for _ in $(seq 1 12); do
        if curl -sf "http://localhost:${PROMETHEUS_PORT}/-/healthy" &>/dev/null; then
            healthy=true
            break
        fi
        sleep 1
    done

    if [[ "$healthy" == true ]]; then
        ok "Prometheus Server 已启动并健康"
        ok "Web UI: http://localhost:${PROMETHEUS_PORT}"
    else
        if cmd_exists systemctl; then
            warn "健康检查未通过，请检查日志: journalctl -u prometheus -f"
        else
            warn "健康检查未通过，请检查日志: /var/log/prometheus.log"
        fi
    fi
}

install_server() {
    install_server_preflight
    install_server_user
    install_server_binary
    install_server_config
    install_server_start
}

# ────────────────────────────────────────────────────────────
# Node Exporter 安装
# ────────────────────────────────────────────────────────────

install_node_exporter_preflight() {
    step "[Step 1/5] 前置检查"
    info "检查 root 权限（require_root）"
    info "检查系统: Ubuntu，架构: amd64/arm64"
    info "检查端口 ${NODE_EXPORTER_PORT} 是否可用（ss -tlnp | grep :${NODE_EXPORTER_PORT}）"
    confirm

    preflight_base "Node Exporter" 0

    if component_running prometheus-node-exporter node_exporter; then
        local ver
        ver=$(/usr/local/bin/node_exporter --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
        warn "Node Exporter (${ver}) 已在运行。继续将覆盖安装"
        confirm
    else
        check_port_available "$NODE_EXPORTER_PORT" "Node Exporter"
    fi
}

install_node_exporter_user() {
    step "[Step 2/5] 创建用户"
    info "useradd --no-create-home --shell /bin/false node_exporter"
    info "（Node Exporter 无配置文件，无需创建数据目录）"
    confirm

    if id node_exporter &>/dev/null; then
        ok "用户 node_exporter 已存在"
    else
        useradd --no-create-home --shell /bin/false node_exporter
        ok "用户 node_exporter 已创建"
    fi
}

install_node_exporter_binary() {
    local arch
    arch=$(get_arch)
    step "[Step 3/5] 下载并安装二进制"
    info "下载: ${GITHUB_DL_URL}/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${arch}.tar.gz"
    info "cp node_exporter → /usr/local/bin/node_exporter"
    confirm

    local extract_dir
    extract_dir=$(download_and_extract "node_exporter" "$NODE_EXPORTER_VERSION")

    cp "${extract_dir}/node_exporter" /usr/local/bin/
    chown node_exporter:node_exporter /usr/local/bin/node_exporter

    rm -rf "$extract_dir"

    local ver
    ver=$(node_exporter --version 2>&1 | head -1 | awk '{print $3}')
    ok "Node Exporter ${ver} 安装完成"
}

install_node_exporter_config() {
    step "[Step 4/5] 配置 systemd 服务"
    if cmd_exists systemctl; then
        info "创建 /etc/systemd/system/prometheus-node-exporter.service"
        info "  ExecStart: node_exporter --web.listen-address=0.0.0.0:${NODE_EXPORTER_PORT}"
        info "  User: node_exporter"
    else
        warn "未检测到 systemctl，跳过 systemd 服务文件创建"
    fi
    confirm

    if cmd_exists systemctl; then
        cat > /etc/systemd/system/prometheus-node-exporter.service <<SERVICEEOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \\
    --web.listen-address=0.0.0.0:${NODE_EXPORTER_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
        ok "systemd 服务文件已创建"
    fi
}

install_node_exporter_start() {
    step "[Step 5/5] 启动与验证"

    local start_cmd="/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:${NODE_EXPORTER_PORT}"

    if cmd_exists systemctl; then
        info "systemctl daemon-reload"
        info "systemctl enable --now prometheus-node-exporter"
    else
        warn "未检测到 systemctl（容器环境），将直接启动进程"
        info "nohup su -s /bin/bash node_exporter -c '${start_cmd}'"
    fi
    info "验证指标端点: curl -sf http://localhost:${NODE_EXPORTER_PORT}/metrics"
    confirm

    if cmd_exists systemctl; then
        systemctl daemon-reload
        systemctl enable --now prometheus-node-exporter --quiet
    else
        nohup su -s /bin/bash node_exporter -c "$start_cmd" > /var/log/node_exporter.log 2>&1 &
        ok "Node Exporter 已通过 nohup 后台启动（PID: $!）"
        ok "日志: /var/log/node_exporter.log"
    fi

    # 等待启动
    local ready=false
    for _ in $(seq 1 12); do
        if curl -sf "http://localhost:${NODE_EXPORTER_PORT}/metrics" &>/dev/null; then
            ready=true
            break
        fi
        sleep 1
    done

    if [[ "$ready" == true ]]; then
        ok "Node Exporter 已启动"
        ok "指标端点: http://localhost:${NODE_EXPORTER_PORT}/metrics"
    else
        if cmd_exists systemctl; then
            warn "启动检查未通过，请检查日志: journalctl -u prometheus-node-exporter -f"
        else
            warn "启动检查未通过，请检查日志: /var/log/node_exporter.log"
        fi
    fi
}

install_node_exporter() {
    install_node_exporter_preflight
    install_node_exporter_user
    install_node_exporter_binary
    install_node_exporter_config
    install_node_exporter_start
}

# ────────────────────────────────────────────────────────────
# Alertmanager 安装
# ────────────────────────────────────────────────────────────

install_alertmanager_preflight() {
    step "[Step 1/5] 前置检查"
    info "检查 root 权限（require_root）"
    info "检查系统: Ubuntu，架构: amd64/arm64"
    info "检查端口 ${ALERTMANAGER_PORT} 是否可用（ss -tlnp | grep :${ALERTMANAGER_PORT}）"
    confirm

    preflight_base "Alertmanager" 0

    if component_running prometheus-alertmanager alertmanager; then
        local ver
        ver=$(/usr/local/bin/alertmanager --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
        warn "Alertmanager (${ver}) 已在运行。继续将覆盖安装"
        confirm
    else
        check_port_available "$ALERTMANAGER_PORT" "Alertmanager"
    fi
}

install_alertmanager_user() {
    step "[Step 2/5] 创建用户与目录"
    info "useradd --no-create-home --shell /bin/false alertmanager"
    info "mkdir -p /etc/alertmanager       （配置文件目录）"
    info "mkdir -p /var/lib/alertmanager   （数据目录）"
    info "chown alertmanager:alertmanager 上述目录"
    confirm

    if id alertmanager &>/dev/null; then
        ok "用户 alertmanager 已存在"
    else
        useradd --no-create-home --shell /bin/false alertmanager
        ok "用户 alertmanager 已创建"
    fi

    mkdir -p /etc/alertmanager
    mkdir -p /var/lib/alertmanager

    chown -R alertmanager:alertmanager /etc/alertmanager
    chown -R alertmanager:alertmanager /var/lib/alertmanager
    ok "目录已创建并设置权限"
}

install_alertmanager_binary() {
    local arch
    arch=$(get_arch)
    step "[Step 3/5] 下载并安装二进制"
    info "下载: ${GITHUB_DL_URL}/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${arch}.tar.gz"
    info "cp alertmanager → /usr/local/bin/alertmanager"
    info "cp amtool       → /usr/local/bin/amtool"
    confirm

    local extract_dir
    extract_dir=$(download_and_extract "alertmanager" "$ALERTMANAGER_VERSION")

    cp "${extract_dir}/alertmanager" /usr/local/bin/
    cp "${extract_dir}/amtool"       /usr/local/bin/
    chown alertmanager:alertmanager /usr/local/bin/alertmanager
    chown alertmanager:alertmanager /usr/local/bin/amtool

    rm -rf "$extract_dir"

    local ver
    ver=$(alertmanager --version 2>&1 | head -1 | awk '{print $3}')
    ok "Alertmanager ${ver} 安装完成"
    ok "amtool 安装完成"
}

install_alertmanager_config() {
    step "[Step 4/5] 配置"
    info "生成 /etc/alertmanager/alertmanager.yml（默认 route → default receiver）"
    info "创建 /etc/systemd/system/prometheus-alertmanager.service"
    info "  ExecStart: alertmanager --config.file=/etc/alertmanager/alertmanager.yml"
    info "             --storage.path=/var/lib/alertmanager"
    info "             --web.listen-address=0.0.0.0:${ALERTMANAGER_PORT}"
    info "验证配置: amtool check-config /etc/alertmanager/alertmanager.yml"
    confirm

    # 配置文件
    if [[ -n "$ALERTMANAGER_CONFIG" ]]; then
        if [[ ! -f "$ALERTMANAGER_CONFIG" ]]; then
            error "自定义配置文件不存在: $ALERTMANAGER_CONFIG"
        fi
        cp "$ALERTMANAGER_CONFIG" /etc/alertmanager/alertmanager.yml
        ok "已使用自定义配置: ${ALERTMANAGER_CONFIG}"
    elif [[ -f /etc/alertmanager/alertmanager.yml ]]; then
        ok "配置文件已存在，保留现有配置"
    else
        cat > /etc/alertmanager/alertmanager.yml <<'AMYML'
# Alertmanager 配置文件
# 文档: https://prometheus.io/docs/alerting/latest/configuration/

global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'
    # 默认不发送通知，仅在 Web UI 展示
    # 配置邮件通知示例：
    # email_configs:
    #   - to: 'admin@example.com'
    #     from: 'alertmanager@example.com'
    #     smarthost: 'smtp.example.com:587'
    #
    # 配置 Webhook 通知示例（钉钉/飞书等）：
    # webhook_configs:
    #   - url: 'http://webhook-url:8060/send'
AMYML
        chown alertmanager:alertmanager /etc/alertmanager/alertmanager.yml
        ok "默认配置文件已生成"
    fi

    # 验证配置
    if ! amtool check-config /etc/alertmanager/alertmanager.yml; then
        error "配置文件语法错误，请检查 /etc/alertmanager/alertmanager.yml"
    fi
    ok "配置文件语法检查通过"

    # systemd 服务文件
    if cmd_exists systemctl; then
        cat > /etc/systemd/system/prometheus-alertmanager.service <<SERVICEEOF
[Unit]
Description=Prometheus Alertmanager
Documentation=https://prometheus.io/docs/alerting/latest/alertmanager/
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \\
    --config.file=/etc/alertmanager/alertmanager.yml \\
    --storage.path=/var/lib/alertmanager \\
    --web.listen-address=0.0.0.0:${ALERTMANAGER_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
        ok "systemd 服务文件已创建"
    else
        warn "未检测到 systemctl，跳过 systemd 服务文件创建"
    fi
}

install_alertmanager_start() {
    step "[Step 5/5] 启动与验证"

    local start_cmd="/usr/local/bin/alertmanager \
--config.file=/etc/alertmanager/alertmanager.yml \
--storage.path=/var/lib/alertmanager \
--web.listen-address=0.0.0.0:${ALERTMANAGER_PORT}"

    if cmd_exists systemctl; then
        info "systemctl daemon-reload"
        info "systemctl enable --now prometheus-alertmanager"
    else
        warn "未检测到 systemctl（容器环境），将直接启动进程"
        info "nohup su -s /bin/bash alertmanager -c '${start_cmd}'"
    fi
    info "健康检查: curl -sf http://localhost:${ALERTMANAGER_PORT}/-/healthy"
    confirm

    if cmd_exists systemctl; then
        systemctl daemon-reload
        systemctl enable --now prometheus-alertmanager --quiet
    else
        nohup su -s /bin/bash alertmanager -c "$start_cmd" > /var/log/alertmanager.log 2>&1 &
        ok "Alertmanager 已通过 nohup 后台启动（PID: $!）"
        ok "日志: /var/log/alertmanager.log"
    fi

    # 等待启动
    local healthy=false
    for _ in $(seq 1 12); do
        if curl -sf "http://localhost:${ALERTMANAGER_PORT}/-/healthy" &>/dev/null; then
            healthy=true
            break
        fi
        sleep 1
    done

    if [[ "$healthy" == true ]]; then
        ok "Alertmanager 已启动并健康"
        ok "Web UI: http://localhost:${ALERTMANAGER_PORT}"
    else
        if cmd_exists systemctl; then
            warn "健康检查未通过，请检查日志: journalctl -u prometheus-alertmanager -f"
        else
            warn "健康检查未通过，请检查日志: /var/log/alertmanager.log"
        fi
    fi
}

install_alertmanager() {
    install_alertmanager_preflight
    install_alertmanager_user
    install_alertmanager_binary
    install_alertmanager_config
    install_alertmanager_start
}

# ────────────────────────────────────────────────────────────
# Server 安装后：自动启用已安装组件的 scrape 配置
# ────────────────────────────────────────────────────────────
enable_scrape_targets() {
    local config="/etc/prometheus/prometheus.yml"
    [[ -f "$config" ]] || return 0

    local changed=false

    # 如果 node-exporter 已安装且配置中是注释状态，则取消注释
    if component_running prometheus-node-exporter node_exporter; then
        if grep -q '# - job_name: "node"' "$config"; then
            sed -i \
                -e 's/^  # - job_name: "node"/  - job_name: "node"/' \
                -e 's/^  #   static_configs:/    static_configs:/' \
                -e 's/^  #     - targets: \["localhost:9100"\]/      - targets: ["localhost:9100"]/' \
                "$config"
            ok "已启用 Node Exporter scrape 配置"
            changed=true
        fi
    fi

    # 如果 alertmanager 已安装，启用相关配置
    if component_running prometheus-alertmanager alertmanager; then
        if grep -q '# alerting:' "$config"; then
            sed -i \
                -e 's/^# alerting:/alerting:/' \
                -e 's/^#   alertmanagers:/  alertmanagers:/' \
                -e 's/^#     - static_configs:/    - static_configs:/' \
                -e 's/^#         - targets: \["localhost:9093"\]/        - targets: ["localhost:9093"]/' \
                -e 's/^# rule_files:/rule_files:/' \
                -e 's|^#   - "/etc/prometheus/rules/\*\.yml"|  - "/etc/prometheus/rules/*.yml"|' \
                "$config"
            ok "已启用 Alertmanager 关联配置"
            changed=true
        fi
    fi

    # 重载配置
    if [[ "$changed" == true ]]; then
        if promtool check config "$config" &>/dev/null; then
            curl -sf -X POST "http://localhost:${PROMETHEUS_PORT}/-/reload" &>/dev/null \
                || systemctl reload prometheus 2>/dev/null \
                || warn "配置已更新，请手动重载: systemctl reload prometheus"
            ok "Prometheus 配置已重载"
        else
            warn "配置文件语法检查失败，请手动检查: promtool check config $config"
        fi
    fi
}

# ────────────────────────────────────────────────────────────
# 打印完成信息
# ────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  Prometheus 监控安装完成！${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""

    if component_running prometheus prometheus; then
        echo -e "  ${GREEN}✅${NC} Prometheus Server  → ${CYAN}http://localhost:${PROMETHEUS_PORT}${NC}"
    fi
    if component_running prometheus-node-exporter node_exporter; then
        echo -e "  ${GREEN}✅${NC} Node Exporter      → ${CYAN}http://localhost:${NODE_EXPORTER_PORT}/metrics${NC}"
    fi
    if component_running prometheus-alertmanager alertmanager; then
        echo -e "  ${GREEN}✅${NC} Alertmanager       → ${CYAN}http://localhost:${ALERTMANAGER_PORT}${NC}"
    fi

    echo ""
    echo -e "${BOLD}常用命令:${NC}"
    echo -e "  查看服务状态:  ${CYAN}sudo systemctl status prometheus${NC}"
    echo -e "  查看 targets:  ${CYAN}curl -s http://localhost:${PROMETHEUS_PORT}/api/v1/targets | python3 -m json.tool${NC}"
    echo -e "  验证配置:      ${CYAN}promtool check config /etc/prometheus/prometheus.yml${NC}"
    echo -e "  热重载配置:    ${CYAN}curl -X POST http://localhost:${PROMETHEUS_PORT}/-/reload${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    # fd3 指向终端，供 download_and_extract 在子 shell 中输出日志
    exec 3>&1

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Prometheus 安装开始 $(date) | 组件: $ROLE ===" >> "$LOG_FILE"

    case "$ROLE" in
        server)
            print_banner "Prometheus Server 安装" "版本: ${PROMETHEUS_VERSION} | 端口: ${PROMETHEUS_PORT} | 保留: ${PROMETHEUS_RETENTION}"
            install_server
            enable_scrape_targets
            ;;
        node-exporter)
            print_banner "Node Exporter 安装" "版本: ${NODE_EXPORTER_VERSION} | 端口: ${NODE_EXPORTER_PORT}"
            install_node_exporter
            # 如果 server 也在本机运行，自动启用 scrape
            if component_running prometheus prometheus; then
                enable_scrape_targets
            fi
            ;;
        alertmanager)
            print_banner "Alertmanager 安装" "版本: ${ALERTMANAGER_VERSION} | 端口: ${ALERTMANAGER_PORT}"
            install_alertmanager
            # 如果 server 也在本机运行，自动启用关联
            if component_running prometheus prometheus; then
                enable_scrape_targets
            fi
            ;;
        all)
            print_banner "Prometheus 全组件安装" "Server + Node Exporter + Alertmanager"
            install_server
            install_node_exporter
            install_alertmanager
            enable_scrape_targets
            ;;
    esac

    print_summary

    echo ""
    ok "全部完成！日志: ${LOG_FILE}"
    echo ""
}

main "$@"
