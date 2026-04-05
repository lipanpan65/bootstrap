#!/usr/bin/env bash
# ============================================================
# install.sh — bootstrap 统一入口
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
#     | sudo bash -s -- <service> [args...]
#
# 示例:
#   | sudo bash -s -- k8s master
#   | sudo bash -s -- k8s master --yes
#   | sudo bash -s -- k8s worker
#   | sudo bash -s -- redis
#   | sudo bash -s -- nginx
# ============================================================

set -euo pipefail

BOOTSTRAP_BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
TMP_DIR="/tmp/bootstrap-$$"

# ────────────────────────────────────────────────────────────
# 颜色（此时 lib.sh 还未加载，内联定义）
# ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

error() { echo -e "${RED}[ERROR]${NC} ❌ $*" >&2; exit 1; }
log()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    ✅ $*"; }

# ────────────────────────────────────────────────────────────
# 支持的服务列表
# ────────────────────────────────────────────────────────────
SUPPORTED_SERVICES=("k8s" "docker" "redis" "nginx" "prometheus")

usage() {
    echo ""
    echo -e "${BOLD}bootstrap — 一键服务安装工具${NC}"
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  curl -fsSL ${BOOTSTRAP_BASE_URL}/install.sh | sudo bash -s -- <service> [args...]"
    echo ""
    echo -e "${BOLD}支持的服务:${NC}"
    echo "  k8s     [master|worker] [--yes]   K8s 集群"
    echo "  docker  [--yes]                   Docker / containerd"
    echo "  redis   [--yes]                   Redis"
    echo "  nginx   [--yes]                   Nginx"
    echo "  prometheus [server|node-exporter|alertmanager|all] [--yes]  Prometheus 监控"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  ... | sudo bash -s -- k8s master"
    echo "  ... | sudo bash -s -- k8s master --yes"
    echo "  ... | sudo bash -s -- redis"
    echo ""
    exit 1
}

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then usage; fi

SERVICE="$1"
shift  # 剩余参数传递给子脚本

# 验证服务名
valid=false
for s in "${SUPPORTED_SERVICES[@]}"; do
    if [[ "$s" == "$SERVICE" ]]; then valid=true; break; fi
done
if [[ "$valid" == false ]]; then
    echo -e "${RED}不支持的服务: ${SERVICE}${NC}"
    echo "支持的服务: ${SUPPORTED_SERVICES[*]}"
    usage
fi

# ────────────────────────────────────────────────────────────
# 下载并执行子脚本
# ────────────────────────────────────────────────────────────
SCRIPT_URL="${BOOTSTRAP_BASE_URL}/${SERVICE}/install.sh"
LIB_URL="${BOOTSTRAP_BASE_URL}/common/lib.sh"

log "服务: ${BOLD}${SERVICE}${NC}"
log "来源: ${SCRIPT_URL}"
echo ""

# 创建临时目录（保留 lib.sh，子脚本能 source 到）
mkdir -p "${TMP_DIR}/common"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 下载 lib.sh
log "下载 common/lib.sh ..."
curl -fsSL "$LIB_URL" -o "${TMP_DIR}/common/lib.sh" \
    || error "无法下载 common/lib.sh，请检查网络"
ok "lib.sh 下载完成"

# 下载子脚本
log "下载 ${SERVICE}/install.sh ..."
curl -fsSL "$SCRIPT_URL" -o "${TMP_DIR}/install.sh" \
    || error "无法下载 ${SERVICE}/install.sh，请检查服务名是否正确"
chmod +x "${TMP_DIR}/install.sh"
ok "${SERVICE}/install.sh 下载完成"

echo ""

# 执行子脚本
# cd 到 TMP_DIR，子脚本通过 $(pwd)/common/lib.sh 能找到 lib
export BOOTSTRAP_BASE_URL
cd "${TMP_DIR}"
bash "install.sh" "$@"