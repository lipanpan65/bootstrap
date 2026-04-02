#!/usr/bin/env bash
# ============================================================
# pgsql/restore.sh — PostgreSQL 数据库恢复脚本
#
# 用法:
#   ./pgsql/restore.sh <backup_file> [选项...]
#   ./pgsql/restore.sh mydb.dump -H 10.0.0.1 -d mydb --yes
#   ./pgsql/restore.sh mydb.dump -d mydb_new -j 8 --yes
#   ./pgsql/restore.sh --help
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    local candidates=(
        "$(cd "$(dirname "${BASH_SOURCE[0]:-restore.sh}")" 2>/dev/null && pwd)/../common/lib.sh"
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
# 配置
# ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/pgsql-restore.log"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-}"
RESTORE_JOBS="${RESTORE_JOBS:-4}"
RESTORE_CLEAN="${RESTORE_CLEAN:-true}"

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
BACKUP_FILE=""

usage() {
    echo ""
    echo -e "${BOLD}PostgreSQL 数据库恢复脚本${NC}"
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 <backup_file> [选项...]"
    echo ""
    echo -e "${BOLD}参数:${NC}"
    echo "  backup_file                备份文件路径（.dump / .sql / .tar / 目录）"
    echo ""
    echo -e "${BOLD}连接参数:${NC}"
    echo -e "  -H, --host <host>          目标数据库地址            当前值: ${CYAN}${PGHOST}${NC}"
    echo -e "  -p, --port <port>          目标数据库端口            当前值: ${CYAN}${PGPORT}${NC}"
    echo -e "  -U, --user <user>          连接用户                  当前值: ${CYAN}${PGUSER}${NC}"
    echo -e "  -d, --database <name>      目标数据库名（默认从文件名推断）当前值: ${CYAN}${PGDATABASE:-未设置（自动推断）}${NC}"
    echo ""
    echo -e "${BOLD}恢复参数:${NC}"
    echo -e "  -j, --jobs <n>             并行恢复线程数            当前值: ${CYAN}${RESTORE_JOBS}${NC}"
    echo -e "  --clean / --no-clean       恢复前是否清除已有对象    当前值: ${CYAN}${RESTORE_CLEAN}${NC}"
    echo ""
    echo -e "${BOLD}其他:${NC}"
    echo "  -y, --yes                  跳过所有确认提示，自动执行"
    echo "  -h, --help                 显示此帮助信息"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  # 恢复自定义格式备份"
    echo "  $0 mydb_20260402_120000.dump"
    echo ""
    echo "  # 恢复到指定数据库"
    echo "  $0 mydb.dump -d mydb_new --yes"
    echo ""
    echo "  # 远程恢复，8 线程并行"
    echo "  $0 mydb.dump -H 10.0.0.1 -d mydb -j 8 --yes"
    echo ""
    echo "  # 恢复纯 SQL 格式"
    echo "  $0 mydb_20260402_120000.sql -d mydb"
    echo ""
    echo -e "${BOLD}实际执行的命令（默认配置）:${NC}"
    echo -e "  ${CYAN}pg_restore -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d <database> -v --clean --if-exists -j ${RESTORE_JOBS} <backup_file>${NC}"
    echo -e "  ${CYAN}psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d <database> -f <backup_file.sql>${NC}  (纯 SQL 格式)"
    echo ""
    exit 0
}

if [[ $# -eq 0 ]]; then usage; fi

# 校验参数值是否存在（允许以 - 开头的值，如 --schema-only 后不会误调此函数）
require_arg() {
    if [[ -z "${2:-}" ]]; then
        echo "错误: $1 需要一个参数值"; usage
    fi
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)       require_arg "$1" "${2:-}"; PGHOST="$2";        shift 2 ;;
        -p|--port)       require_arg "$1" "${2:-}"; PGPORT="$2";        shift 2 ;;
        -U|--user)       require_arg "$1" "${2:-}"; PGUSER="$2";        shift 2 ;;
        -d|--database)   require_arg "$1" "${2:-}"; PGDATABASE="$2";    shift 2 ;;
        -j|--jobs)       require_arg "$1" "${2:-}"; RESTORE_JOBS="$2";  shift 2 ;;
        --clean)         RESTORE_CLEAN=true;  shift ;;
        --no-clean)      RESTORE_CLEAN=false; shift ;;
        -y|--yes)        AUTO_YES=true;       shift ;;
        -h|--help)       usage ;;
        -*)              echo "未知选项: $1"; usage ;;
        *)
            if [[ -z "$BACKUP_FILE" ]]; then
                BACKUP_FILE="$1"; shift
            else
                echo "多余参数: $1"; usage
            fi
            ;;
    esac
done

if [[ -z "$BACKUP_FILE" ]]; then
    error "请指定备份文件路径"
fi

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────

# 从备份文件名推断数据库名
infer_dbname() {
    local filename
    filename=$(basename "$BACKUP_FILE")
    filename="${filename%/}"  # 去除尾部斜杠（目录场景）

    # 优先匹配 dbname_YYYYMMDD_HHMMSS.ext 格式
    local result
    result=$(echo "$filename" | sed -E 's/_[0-9]{8}_[0-9]{6}(\..+)?$//')

    # 如果没有时间戳，去掉文件后缀作为数据库名（如 mydb.dump → mydb）
    if [[ "$result" == "$filename" ]]; then
        result="${filename%.*}"
        # 防护无后缀场景（如目录名 mydb），确保不返回空串
        [[ -z "$result" ]] && result="$filename"
    fi

    echo "$result"
}

# 检测备份格式
detect_format() {
    if [[ -d "$BACKUP_FILE" ]]; then
        echo "directory"
    elif [[ "$BACKUP_FILE" == *.sql ]]; then
        echo "plain"
    elif [[ "$BACKUP_FILE" == *.tar ]]; then
        echo "tar"
    elif [[ "$BACKUP_FILE" == *.dump ]]; then
        echo "custom"
    else
        # 尝试用 pg_restore --list 判断
        if pg_restore --list "$BACKUP_FILE" > /dev/null 2>&1; then
            echo "custom"
        else
            echo "plain"
        fi
    fi
}

# ────────────────────────────────────────────────────────────
# Step 1: 前置检查
# ────────────────────────────────────────────────────────────
preflight() {
    step "[Step 1/3] 前置检查"
    info "检查备份文件"
    info "检查数据库连通性"
    info "确认目标数据库"
    confirm

    # 检查备份文件
    if [[ ! -e "$BACKUP_FILE" ]]; then
        error "备份文件不存在: ${BACKUP_FILE}"
    fi

    local file_size
    if [[ -d "$BACKUP_FILE" ]]; then
        file_size=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
    else
        file_size=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
    fi

    local fmt
    fmt=$(detect_format)
    ok "备份文件: ${BACKUP_FILE}（${file_size}，格式: ${fmt}）"

    # 检查工具
    if [[ "$fmt" == "plain" ]]; then
        if ! cmd_exists psql; then
            error "psql 未安装，请先执行: apt-get install -y postgresql-client"
        fi
    else
        if ! cmd_exists pg_restore; then
            error "pg_restore 未安装，请先执行: apt-get install -y postgresql-client"
        fi
    fi

    # 推断数据库名
    if [[ -z "$PGDATABASE" ]]; then
        PGDATABASE=$(infer_dbname)
        if [[ -z "$PGDATABASE" ]]; then
            error "无法从文件名推断数据库名，请使用 -d <database> 参数指定"
        fi
        warn "未指定 PGDATABASE，从文件名推断为: ${PGDATABASE}"
    fi

    # 校验数据库名合法性（防止 SQL 注入）
    if [[ ! "$PGDATABASE" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        error "数据库名包含非法字符: ${PGDATABASE}（只允许字母、数字、下划线、连字符，且不能以数字开头）"
    fi
    ok "目标数据库: ${PGDATABASE}"

    # 检查连通性
    info "连接 ${PGHOST}:${PGPORT} ..."
    if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q 2>/dev/null; then
        ok "数据库连接正常"
    else
        error "无法连接数据库 ${PGHOST}:${PGPORT}"
    fi

    # 检查目标数据库是否存在
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$PGDATABASE"; then
        warn "数据库 ${PGDATABASE} 已存在，恢复将覆盖现有数据"
    else
        info "数据库 ${PGDATABASE} 不存在，将自动创建"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 2: 执行恢复
# ────────────────────────────────────────────────────────────
do_restore() {
    step "[Step 2/3] 执行恢复"

    local fmt
    fmt=$(detect_format)

    # 构建恢复模式描述
    local clean_desc="否（追加到已有数据）"
    if [[ "$RESTORE_CLEAN" == "true" ]]; then
        clean_desc="是（先删除已有对象再恢复）"
    fi

    local parallel_desc="不支持（${fmt} 格式）"
    if [[ "$fmt" == "custom" || "$fmt" == "directory" ]]; then
        parallel_desc="${RESTORE_JOBS} 线程并行"
    fi

    local db_status="已存在"
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$PGDATABASE"; then
        db_status="不存在，将自动创建"
    fi

    # 获取备份文件大小
    local file_size
    if [[ -d "$BACKUP_FILE" ]]; then
        file_size=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
    else
        file_size=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
    fi

    # 打印执行摘要
    echo ""
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo -e "${BOLD}  即将执行以下恢复操作：${NC}"
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo -e "  备份文件:   ${CYAN}${BACKUP_FILE}${NC} (${file_size}，格式: ${CYAN}${fmt}${NC})"
    echo -e "  目标实例:   ${CYAN}${PGHOST}:${PGPORT}${NC} (用户: ${CYAN}${PGUSER}${NC})"
    echo -e "  目标数据库: ${CYAN}${PGDATABASE}${NC} (${db_status})"
    echo -e "  清除旧数据: ${CYAN}${clean_desc}${NC}"
    echo -e "  并行恢复:   ${CYAN}${parallel_desc}${NC}"
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo ""
    confirm

    # 如果目标数据库不存在，先创建
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$PGDATABASE"; then
        log "创建数据库 ${PGDATABASE} ..."
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -c "CREATE DATABASE \"${PGDATABASE}\";" 2>> "$LOG_FILE"
        ok "数据库 ${PGDATABASE} 已创建"
    fi

    local start_time
    start_time=$(date +%s)

    log "开始恢复 ${PGDATABASE} ..."

    if [[ "$fmt" == "plain" ]]; then
        # 纯 SQL 格式：使用 psql
        if [[ "$RESTORE_CLEAN" == "true" ]]; then
            warn "纯 SQL 格式不支持 --clean 参数，恢复将直接执行 SQL（追加模式）。如需清除旧数据，请先手动 DROP DATABASE 后重建"
        fi
        local psql_cmd="psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -v ON_ERROR_STOP=1 -f $BACKUP_FILE"
        log "执行命令:"
        echo -e "  ${CYAN}${psql_cmd}${NC}"
        echo "$psql_cmd" >> "$LOG_FILE"
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
            -v ON_ERROR_STOP=1 -f "$BACKUP_FILE" 2> >(tee -a "$LOG_FILE" >&2)
    else
        # 二进制格式：使用 pg_restore
        local restore_args=(
            -h "$PGHOST"
            -p "$PGPORT"
            -U "$PGUSER"
            -d "$PGDATABASE"
            -v
        )

        if [[ "$RESTORE_CLEAN" == "true" ]]; then
            restore_args+=("--clean" "--if-exists")
        fi

        # 并行恢复（仅自定义格式和目录格式支持）
        if [[ "$fmt" == "custom" || "$fmt" == "directory" ]]; then
            restore_args+=("-j" "$RESTORE_JOBS")
        fi

        restore_args+=("$BACKUP_FILE")

        # 打印实际执行的命令
        log "执行命令:"
        echo -e "  ${CYAN}pg_restore ${restore_args[*]}${NC}"
        echo "pg_restore ${restore_args[*]}" >> "$LOG_FILE"

        pg_restore "${restore_args[@]}" 2> >(tee -a "$LOG_FILE" >&2) || {
            # pg_restore 在有 warning 时也会返回非零退出码
            warn "pg_restore 返回非零退出码，请检查日志中是否有严重错误: ${LOG_FILE}"
        }
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    ok "恢复完成，耗时: ${duration} 秒"
}

# ────────────────────────────────────────────────────────────
# Step 3: 恢复后验证
# ────────────────────────────────────────────────────────────
verify_restore() {
    step "[Step 3/3] 恢复后验证"
    info "检查数据库连通性和基本统计"
    confirm

    # 检查数据库是否可访问
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1;" > /dev/null 2>&1; then
        ok "数据库 ${PGDATABASE} 可正常访问"
    else
        error "数据库 ${PGDATABASE} 无法访问"
    fi

    # 统计表数量
    local table_count
    table_count=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Atc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
    ok "public schema 中共 ${table_count} 张表"

    # 获取数据库大小
    local db_size
    db_size=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Atc \
        "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "未知")
    ok "数据库大小: ${db_size}"
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== PostgreSQL 恢复开始 $(date) | 文件: ${BACKUP_FILE} ===" >> "$LOG_FILE"

    print_banner "PostgreSQL 数据库恢复" "主机: ${PGHOST}:${PGPORT} | 文件: $(basename "$BACKUP_FILE")"

    preflight
    do_restore
    verify_restore

    echo ""
    ok "全部完成！日志: ${LOG_FILE}"
    echo ""
}

main "$@"
