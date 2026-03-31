#!/usr/bin/env bash
# ============================================================
# common/lib.sh — 公共函数库
# 所有服务安装脚本通过以下方式引用：
#
#   本地开发：source "$(dirname "$0")/../common/lib.sh"
#   远程执行：curl 下载后 source
# ============================================================

# 防止重复 source
if [[ -n "${_LIB_LOADED:-}" ]]; then return 0; fi
_LIB_LOADED=1

# ────────────────────────────────────────────────────────────
# 颜色常量
# ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────
# 日志函数
# LOG_FILE 由调用方脚本设置，默认 /var/log/bootstrap-install.log
# ────────────────────────────────────────────────────────────
LOG_FILE="${LOG_FILE:-/var/log/bootstrap-install.log}"

_ensure_log_file() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/bootstrap-install.log"
}

log()   {
    _ensure_log_file
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "${BLUE}[INFO]${NC}  $msg" | tee -a "$LOG_FILE"
}

ok()    {
    _ensure_log_file
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "${GREEN}[OK]${NC}    ✅ $msg" | tee -a "$LOG_FILE"
}

warn()  {
    _ensure_log_file
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "${YELLOW}[WARN]${NC}  ⚠️  $msg" | tee -a "$LOG_FILE"
}

error() {
    _ensure_log_file
    local msg="[$(date '+%H:%M:%S')] $*"
    echo -e "${RED}[ERROR]${NC} ❌ $msg" | tee -a "$LOG_FILE"
    exit 1
}

step()  {
    _ensure_log_file
    echo -e "\n${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo "[$(date '+%H:%M:%S')] STEP: $*" >> "$LOG_FILE"
}

info()  { echo -e "  ${CYAN}→${NC} $*"; echo "    $*" >> "$LOG_FILE" 2>/dev/null || true; }

# ────────────────────────────────────────────────────────────
# 交互函数
# AUTO_YES 由调用方设置（--yes 参数时为 true）
# ────────────────────────────────────────────────────────────
AUTO_YES="${AUTO_YES:-false}"

confirm() {
    if [[ "$AUTO_YES" == true ]]; then
        return 0
    fi
    echo ""
    echo -e "${YELLOW}按 Enter 继续，Ctrl+C 退出...${NC}"
    read -r
}

# ────────────────────────────────────────────────────────────
# 系统检测工具
# ────────────────────────────────────────────────────────────

# 检查命令是否存在
cmd_exists() { command -v "$1" &>/dev/null; }

# 检查 systemd 服务是否运行中
service_running() { systemctl is-active --quiet "$1" 2>/dev/null; }

# 检查是否 root 权限
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 或 sudo 执行此脚本"
    fi
}

# 获取系统架构（amd64 / arm64）
get_arch() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       echo "$arch" ;;
    esac
}

# 获取 Ubuntu 版本代号（focal / jammy / noble）
get_ubuntu_codename() { lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2; }

# 获取内存大小（GB）
get_mem_gb() { awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo; }

# 检查网络连通性
check_connectivity() {
    local url="${1:-https://mirrors.aliyun.com}"
    curl -sf --max-time 5 "$url" > /dev/null 2>&1
}

# ────────────────────────────────────────────────────────────
# 通用预检
# 调用方可在此基础上追加自己的检查
# ────────────────────────────────────────────────────────────
preflight_base() {
    local service_name="${1:-服务}"
    local min_mem_gb="${2:-1}"

    step "[预检] 环境检查 — ${service_name}"

    require_root

    # 系统检查
    if grep -qi ubuntu /etc/os-release 2>/dev/null; then
        local os_ver
        os_ver=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        ok "系统: Ubuntu ${os_ver} ($(get_arch))"
    else
        warn "当前系统非 Ubuntu，脚本未经过充分测试"
    fi

    # 内存检查
    local mem_gb
    mem_gb=$(get_mem_gb)
    if [[ "$mem_gb" -lt "$min_mem_gb" ]]; then
        warn "内存 ${mem_gb}GB，建议至少 ${min_mem_gb}GB"
    else
        ok "内存: ${mem_gb}GB"
    fi

    # 网络检查
    info "检查阿里云镜像源连通性..."
    if check_connectivity "https://mirrors.aliyun.com"; then
        ok "阿里云镜像源可达"
    else
        warn "阿里云镜像源连通性异常，安装可能受影响"
    fi
}

# ────────────────────────────────────────────────────────────
# 远程 lib 加载助手
# 子脚本在远程执行时用此函数动态加载 lib.sh
# ────────────────────────────────────────────────────────────
BOOTSTRAP_BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"

load_lib_remote() {
    local tmp_lib="/tmp/_bootstrap_lib.sh"
    if [[ ! -f "$tmp_lib" ]]; then
        curl -fsSL "${BOOTSTRAP_BASE_URL}/common/lib.sh" -o "$tmp_lib" \
            || { echo "❌ 无法下载 common/lib.sh"; exit 1; }
    fi
    # shellcheck source=/dev/null
    source "$tmp_lib"
}

# ────────────────────────────────────────────────────────────
# Banner 打印
# ────────────────────────────────────────────────────────────
print_banner() {
    local title="${1:-}"
    local subtitle="${2:-}"
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗ "
    echo "  ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗"
    echo "  ██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝"
    echo "  ██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝ "
    echo "  ██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║     "
    echo "  ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     "
    echo -e "${NC}"
    if [[ -n "$title" ]]; then echo -e "  ${BOLD}▸ ${title}${NC}"; fi
    if [[ -n "$subtitle" ]]; then echo -e "  ${CYAN}${subtitle}${NC}"; fi
    echo -e "  日志: ${LOG_FILE}"
    echo ""
}