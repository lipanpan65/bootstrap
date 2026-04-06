#!/usr/bin/env bash
# ============================================================
# services/pgsql/backup/run.sh — PostgreSQL 数据库备份脚本
#
# 用法:
#   ./services/pgsql/backup/run.sh -d <database> [选项...]
#   ./services/pgsql/backup/run.sh -H 10.0.0.1 -U postgres -d mydb --yes
#   ./services/pgsql/backup/run.sh -d mydb -t users -t orders --yes
#   ./services/pgsql/backup/run.sh --help
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 加载公共库
# ────────────────────────────────────────────────────────────
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"

    local candidates=(
        "$(cd "$(dirname "${BASH_SOURCE[0]:-run.sh}")" 2>/dev/null && pwd)/../../../common/lib.sh"
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
LOG_FILE="/var/log/pgsql-backup.log"

# 连接参数（通过环境变量覆盖）
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-}"

# 备份参数
BACKUP_DIR="${BACKUP_DIR:-/data/backup/pgsql}"
BACKUP_FORMAT="${BACKUP_FORMAT:-custom}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-6}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_RETENTION_WEEKS="${BACKUP_RETENTION_WEEKS:-4}"
BACKUP_TYPE="${BACKUP_TYPE:-daily}"

# 数据过滤参数（逗号分隔，空值表示不过滤）
BACKUP_SCHEMAS="${BACKUP_SCHEMAS:-}"
BACKUP_EXCLUDE_SCHEMAS="${BACKUP_EXCLUDE_SCHEMAS:-}"
BACKUP_TABLES="${BACKUP_TABLES:-}"
BACKUP_EXCLUDE_TABLES="${BACKUP_EXCLUDE_TABLES:-}"
BACKUP_SCHEMA_ONLY="${BACKUP_SCHEMA_ONLY:-false}"
BACKUP_DATA_ONLY="${BACKUP_DATA_ONLY:-false}"

# ────────────────────────────────────────────────────────────
# 参数解析
# ────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo -e "${BOLD}PostgreSQL 数据库备份脚本${NC}"
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  $0 -d <database> [选项...]"
    echo ""
    echo -e "${BOLD}连接参数:${NC}"
    echo -e "  -H, --host <host>          数据库地址                当前值: ${CYAN}${PGHOST}${NC}"
    echo -e "  -p, --port <port>          数据库端口                当前值: ${CYAN}${PGPORT}${NC}"
    echo -e "  -U, --user <user>          连接用户                  当前值: ${CYAN}${PGUSER}${NC}"
    echo -e "  -d, --database <name>      数据库名（必填）          当前值: ${CYAN}${PGDATABASE:-未设置}${NC}"
    echo ""
    echo -e "${BOLD}备份参数:${NC}"
    echo -e "  -F, --format <fmt>         备份格式 (custom/directory/tar/plain)  当前值: ${CYAN}${BACKUP_FORMAT}${NC}"
    echo -e "  -Z, --compress <0-9>       压缩级别                  当前值: ${CYAN}${BACKUP_COMPRESS}${NC}"
    echo -e "  -o, --output-dir <dir>     备份存储目录              当前值: ${CYAN}${BACKUP_DIR}${NC}"
    echo -e "  --type <type>              备份类型 (daily/weekly/manual)  当前值: ${CYAN}${BACKUP_TYPE}${NC}"
    echo -e "  --retention-days <n>       每日备份保留天数          当前值: ${CYAN}${BACKUP_RETENTION_DAYS}${NC}"
    echo -e "  --retention-weeks <n>      每周备份保留周数          当前值: ${CYAN}${BACKUP_RETENTION_WEEKS}${NC}"
    echo ""
    echo -e "${BOLD}数据过滤:${NC}"
    echo -e "  -n, --schema <name>        只备份指定 schema（可多次指定）"
    echo -e "  -N, --exclude-schema <name>  排除指定 schema（可多次指定）"
    echo -e "  -t, --table <name>         只备份指定表（可多次指定）"
    echo -e "  -T, --exclude-table <name> 排除指定表（可多次指定）"
    echo -e "  --schema-only              只备份结构，不含数据"
    echo -e "  --data-only                只备份数据，不含结构"
    echo ""
    echo -e "${BOLD}其他:${NC}"
    echo "  -y, --yes                  跳过所有确认提示，自动执行"
    echo "  -h, --help                 显示此帮助信息"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  # 整库备份"
    echo "  $0 -d mydb"
    echo ""
    echo "  # 远程数据库备份"
    echo "  $0 -H 10.0.0.1 -U postgres -d mydb --yes"
    echo ""
    echo "  # 只备份指定表"
    echo "  $0 -d mydb -t users -t orders --yes"
    echo ""
    echo "  # 排除日志表"
    echo "  $0 -d mydb -T audit_logs -T event_logs --yes"
    echo ""
    echo "  # 只备份 public schema 的表结构"
    echo "  $0 -d mydb -n public --schema-only --yes"
    echo ""
    echo "  # 目录格式并行备份"
    echo "  $0 -d mydb -F directory --yes"
    echo ""
    echo -e "${BOLD}实际执行的 pg_dump 命令（默认配置）:${NC}"
    echo -e "  ${CYAN}pg_dump -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d <database> -Fc -Z ${BACKUP_COMPRESS} -v -f ${BACKUP_DIR}/${BACKUP_TYPE}/<db>_<timestamp>.dump${NC}"
    echo ""
    exit 0
}

# 校验参数值是否存在（允许以 - 开头的值，如 --schema-only 后不会误调此函数）
require_arg() {
    if [[ -z "${2:-}" ]]; then
        echo "错误: $1 需要一个参数值"; usage
    fi
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)           require_arg "$1" "${2:-}"; PGHOST="$2";                shift 2 ;;
        -p|--port)           require_arg "$1" "${2:-}"; PGPORT="$2";                shift 2 ;;
        -U|--user)           require_arg "$1" "${2:-}"; PGUSER="$2";                shift 2 ;;
        -d|--database)       require_arg "$1" "${2:-}"; PGDATABASE="$2";            shift 2 ;;
        -F|--format)         require_arg "$1" "${2:-}"; BACKUP_FORMAT="$2";         shift 2 ;;
        -Z|--compress)       require_arg "$1" "${2:-}"; BACKUP_COMPRESS="$2";       shift 2 ;;
        -o|--output-dir)     require_arg "$1" "${2:-}"; BACKUP_DIR="$2";            shift 2 ;;
        --type)              require_arg "$1" "${2:-}"; BACKUP_TYPE="$2";           shift 2 ;;
        --retention-days)    require_arg "$1" "${2:-}"; BACKUP_RETENTION_DAYS="$2"; shift 2 ;;
        --retention-weeks)   require_arg "$1" "${2:-}"; BACKUP_RETENTION_WEEKS="$2"; shift 2 ;;
        -n|--schema)         require_arg "$1" "${2:-}"; BACKUP_SCHEMAS="${BACKUP_SCHEMAS:+${BACKUP_SCHEMAS},}$2"; shift 2 ;;
        -N|--exclude-schema) require_arg "$1" "${2:-}"; BACKUP_EXCLUDE_SCHEMAS="${BACKUP_EXCLUDE_SCHEMAS:+${BACKUP_EXCLUDE_SCHEMAS},}$2"; shift 2 ;;
        -t|--table)          require_arg "$1" "${2:-}"; BACKUP_TABLES="${BACKUP_TABLES:+${BACKUP_TABLES},}$2"; shift 2 ;;
        -T|--exclude-table)  require_arg "$1" "${2:-}"; BACKUP_EXCLUDE_TABLES="${BACKUP_EXCLUDE_TABLES:+${BACKUP_EXCLUDE_TABLES},}$2"; shift 2 ;;
        --schema-only)       BACKUP_SCHEMA_ONLY=true;    shift ;;
        --data-only)         BACKUP_DATA_ONLY=true;      shift ;;
        -y|--yes)            AUTO_YES=true;              shift ;;
        -h|--help)           usage ;;
        *)                   echo "未知参数: $1"; usage ;;
    esac
done

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────

# 获取 pg_dump 输出格式参数
get_format_flag() {
    case "$BACKUP_FORMAT" in
        custom)    echo "c" ;;
        directory) echo "d" ;;
        tar)       echo "t" ;;
        plain)     echo "p" ;;
        *)         error "不支持的备份格式: $BACKUP_FORMAT（可选: custom/directory/tar/plain）" ;;
    esac
}

# 获取备份文件后缀
get_format_ext() {
    case "$BACKUP_FORMAT" in
        custom)    echo "dump" ;;
        directory) echo "dir" ;;
        tar)       echo "tar" ;;
        plain)     echo "sql" ;;
        *)         error "不支持的备份格式: $BACKUP_FORMAT（可选: custom/directory/tar/plain）" ;;
    esac
}

# ────────────────────────────────────────────────────────────
# Step 1: 前置检查
# ────────────────────────────────────────────────────────────
preflight() {
    step "[Step 1/4] 前置检查"
    info "检查 pg_dump 是否可用"
    info "检查数据库连通性"
    info "检查磁盘空间"
    confirm

    # 校验互斥参数
    if [[ "$BACKUP_SCHEMA_ONLY" == "true" && "$BACKUP_DATA_ONLY" == "true" ]]; then
        error "--schema-only 和 --data-only 不能同时使用"
    fi

    # 检查 pg_dump
    if ! cmd_exists pg_dump; then
        error "pg_dump 未安装，请先执行: apt-get install -y postgresql-client"
    fi
    local pg_ver
    pg_ver=$(pg_dump --version | awk '{print $NF}')
    ok "pg_dump 版本: ${pg_ver}"

    # 检查数据库名
    if [[ -z "$PGDATABASE" ]]; then
        error "未指定数据库名，请使用 -d <database> 参数指定"
    fi
    ok "目标数据库: ${PGDATABASE}"

    # 检查连通性
    info "连接 ${PGHOST}:${PGPORT} ..."
    if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q 2>/dev/null; then
        ok "数据库连接正常"
    else
        error "无法连接数据库 ${PGHOST}:${PGPORT}，请检查地址、端口和防火墙配置"
    fi

    # 检查数据库是否存在
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$PGDATABASE"; then
        # 获取数据库大小
        local db_size
        db_size=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Atc \
            "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "未知")
        ok "数据库 ${PGDATABASE} 存在，大小: ${db_size}"
    else
        error "数据库 ${PGDATABASE} 不存在"
    fi

    # 检查/创建备份目录
    local backup_subdir="${BACKUP_DIR}/${BACKUP_TYPE}"
    mkdir -p "$backup_subdir"
    local avail
    avail=$(df -h "$backup_subdir" | awk 'NR==2 {print $4}')
    ok "备份目录: ${backup_subdir}（可用空间: ${avail}）"
}

# ────────────────────────────────────────────────────────────
# Step 2: 执行备份
# ────────────────────────────────────────────────────────────
do_backup() {
    step "[Step 2/4] 执行备份"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local ext
    ext=$(get_format_ext)
    local fmt
    fmt=$(get_format_flag)
    local backup_subdir="${BACKUP_DIR}/${BACKUP_TYPE}"
    local backup_file="${backup_subdir}/${PGDATABASE}_${timestamp}.${ext}"

    # 构建备份范围描述
    local scope_desc=""
    if [[ -n "$BACKUP_TABLES" ]]; then
        scope_desc="指定表 [${BACKUP_TABLES}]"
    elif [[ -n "$BACKUP_SCHEMAS" ]]; then
        scope_desc="指定 schema [${BACKUP_SCHEMAS}] 下的所有表"
    else
        scope_desc="全库所有表"
    fi

    if [[ -n "$BACKUP_EXCLUDE_TABLES" ]]; then
        scope_desc="${scope_desc}（排除表: ${BACKUP_EXCLUDE_TABLES}）"
    fi
    if [[ -n "$BACKUP_EXCLUDE_SCHEMAS" ]]; then
        scope_desc="${scope_desc}（排除 schema: ${BACKUP_EXCLUDE_SCHEMAS}）"
    fi

    # 构建数据类型描述
    local data_desc="全量数据（结构 + 数据）"
    if [[ "$BACKUP_SCHEMA_ONLY" == "true" ]]; then
        data_desc="仅表结构（不含数据）"
    elif [[ "$BACKUP_DATA_ONLY" == "true" ]]; then
        data_desc="仅数据（不含表结构）"
    fi

    # 打印执行摘要
    echo ""
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo -e "${BOLD}  即将执行以下备份操作：${NC}"
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo -e "  实例:     ${CYAN}${PGHOST}:${PGPORT}${NC} (用户: ${CYAN}${PGUSER}${NC})"
    echo -e "  数据库:   ${CYAN}${PGDATABASE}${NC}"
    echo -e "  备份范围: ${CYAN}${scope_desc}${NC}"
    echo -e "  数据类型: ${CYAN}${data_desc}${NC}"
    echo -e "  备份格式: ${CYAN}${BACKUP_FORMAT} (-F${fmt})${NC}，压缩级别: ${CYAN}${BACKUP_COMPRESS}${NC}"
    echo -e "  输出文件: ${CYAN}${backup_file}${NC}"
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo ""
    confirm

    local start_time
    start_time=$(date +%s)

    log "开始备份 ${PGDATABASE} ..."

    local dump_args=(
        -h "$PGHOST"
        -p "$PGPORT"
        -U "$PGUSER"
        -d "$PGDATABASE"
        "-F${fmt}"
        -v
    )

    # 自定义格式和目录格式支持压缩级别
    if [[ "$fmt" == "c" || "$fmt" == "d" ]]; then
        dump_args+=("-Z" "$BACKUP_COMPRESS")
    fi

    # 数据过滤参数
    if [[ -n "$BACKUP_SCHEMAS" ]]; then
        IFS=',' read -ra _schemas <<< "$BACKUP_SCHEMAS"
        for _s in "${_schemas[@]}"; do
            dump_args+=("-n" "${_s// /}")
        done
    fi

    if [[ -n "$BACKUP_EXCLUDE_SCHEMAS" ]]; then
        IFS=',' read -ra _exc_schemas <<< "$BACKUP_EXCLUDE_SCHEMAS"
        for _s in "${_exc_schemas[@]}"; do
            dump_args+=("-N" "${_s// /}")
        done
    fi

    if [[ -n "$BACKUP_TABLES" ]]; then
        IFS=',' read -ra _tables <<< "$BACKUP_TABLES"
        for _t in "${_tables[@]}"; do
            dump_args+=("-t" "${_t// /}")
        done
    fi

    if [[ -n "$BACKUP_EXCLUDE_TABLES" ]]; then
        IFS=',' read -ra _exc_tables <<< "$BACKUP_EXCLUDE_TABLES"
        for _t in "${_exc_tables[@]}"; do
            dump_args+=("-T" "${_t// /}")
        done
    fi

    if [[ "$BACKUP_SCHEMA_ONLY" == "true" ]]; then
        dump_args+=("--schema-only")
    fi

    if [[ "$BACKUP_DATA_ONLY" == "true" ]]; then
        dump_args+=("--data-only")
    fi

    dump_args+=("-f" "$backup_file")

    # 打印实际执行的命令
    log "执行命令:"
    echo -e "  ${CYAN}pg_dump ${dump_args[*]}${NC}"
    echo "pg_dump ${dump_args[*]}" >> "$LOG_FILE"

    if pg_dump "${dump_args[@]}" 2> >(tee -a "$LOG_FILE" >&2); then
        local end_time
        end_time=$(date +%s)
        local duration=$(( end_time - start_time ))

        # 获取文件大小
        local file_size
        if [[ -d "$backup_file" ]]; then
            file_size=$(du -sh "$backup_file" | awk '{print $1}')
        else
            file_size=$(ls -lh "$backup_file" | awk '{print $5}')
        fi

        # 设置权限（目录需要 700 才能进入，文件用 600）
        if [[ -d "$backup_file" ]]; then
            chmod 700 "$backup_file"
            find "$backup_file" -maxdepth 1 -type f -exec chmod 600 {} +
        else
            chmod 600 "$backup_file"
        fi

        ok "备份完成"
        ok "文件: ${backup_file}"
        ok "大小: ${file_size}"
        ok "耗时: ${duration} 秒"
    else
        error "备份失败，请查看日志: ${LOG_FILE}"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 3: 清理过期备份
# ────────────────────────────────────────────────────────────
cleanup_old_backups() {
    step "[Step 3/4] 清理过期备份"

    local retention_days
    if [[ "$BACKUP_TYPE" == "weekly" ]]; then
        retention_days=$(( BACKUP_RETENTION_WEEKS * 7 ))
        info "保留策略: ${BACKUP_RETENTION_WEEKS} 周（${retention_days} 天）"
    elif [[ "$BACKUP_TYPE" == "manual" ]]; then
        info "手动备份不自动清理，跳过"
        return
    else
        retention_days="$BACKUP_RETENTION_DAYS"
        info "保留策略: ${retention_days} 天"
    fi
    confirm

    local backup_subdir="${BACKUP_DIR}/${BACKUP_TYPE}"
    local count=0
    local cutoff_ts
    cutoff_ts=$(date -d "-${retention_days} days" '+%Y%m%d_%H%M%S' 2>/dev/null) || \
        cutoff_ts=$(date -v-"${retention_days}"d '+%Y%m%d_%H%M%S' 2>/dev/null) || {
            warn "无法计算截止时间，回退到 mtime 方式清理"
            while IFS= read -r -d '' file; do
                log "删除过期备份: $(basename "$file")"
                rm -rf "$file"
                count=$((count + 1))
            done < <(find "$backup_subdir" -maxdepth 1 -name "${PGDATABASE}_*" -mtime "+${retention_days}" -print0 2>/dev/null)
            if [[ $count -gt 0 ]]; then ok "已清理 ${count} 个过期备份"; else ok "无过期备份需要清理"; fi
            return
        }

    # 基于文件名中的时间戳判断过期（避免 mtime 被修改导致误判）
    for file in "${backup_subdir}/${PGDATABASE}_"*; do
        [[ -e "$file" ]] || continue
        local basename_f
        basename_f=$(basename "$file")
        # 提取文件名中的时间戳 YYYYMMDD_HHMMSS
        local file_ts
        file_ts=$(echo "$basename_f" | sed -nE "s/^${PGDATABASE}_([0-9]{8}_[0-9]{6})\..+$/\1/p")
        [[ -z "$file_ts" ]] && continue
        if [[ "$file_ts" < "$cutoff_ts" ]]; then
            log "删除过期备份: ${basename_f}（时间戳: ${file_ts}，截止: ${cutoff_ts}）"
            rm -rf "$file"
            count=$((count + 1))
        fi
    done

    if [[ $count -gt 0 ]]; then
        ok "已清理 ${count} 个过期备份"
    else
        ok "无过期备份需要清理"
    fi
}

# ────────────────────────────────────────────────────────────
# Step 4: 验证备份
# ────────────────────────────────────────────────────────────
verify_backup() {
    step "[Step 4/4] 验证备份"

    local backup_subdir="${BACKUP_DIR}/${BACKUP_TYPE}"
    local latest
    latest=$(find "$backup_subdir" -maxdepth 1 -name "${PGDATABASE}_*" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | awk '{print $2}')

    if [[ -z "$latest" ]]; then
        warn "未找到备份文件，跳过验证"
        return
    fi

    info "验证最新备份: $(basename "$latest")"
    confirm

    local fmt
    fmt=$(get_format_flag)

    if [[ "$fmt" == "p" ]]; then
        # 纯 SQL 格式：检查文件头和尾
        if head -5 "$latest" | grep -q "PostgreSQL database dump"; then
            ok "SQL 文件头验证通过"
        else
            warn "SQL 文件头异常，建议手动检查"
        fi
    else
        # 二进制格式：使用 pg_restore --list 验证
        if pg_restore --list "$latest" > /dev/null 2>&1; then
            local obj_count
            obj_count=$(pg_restore --list "$latest" 2>/dev/null | grep -c ";" || true)
            ok "备份文件验证通过（包含 ${obj_count} 个对象）"
        else
            warn "备份文件验证失败，建议手动恢复测试"
        fi
    fi
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== PostgreSQL 备份开始 $(date) | 数据库: ${PGDATABASE:-未指定} ===" >> "$LOG_FILE"

    print_banner "PostgreSQL 数据库备份" "主机: ${PGHOST}:${PGPORT} | 格式: ${BACKUP_FORMAT}"

    preflight
    do_backup
    cleanup_old_backups
    verify_backup

    echo ""
    ok "全部完成！日志: ${LOG_FILE}"
    echo ""
}

main "$@"
