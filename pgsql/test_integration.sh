#!/usr/bin/env bash
# ============================================================
# pgsql/test_integration.sh — 集成测试（真实 PostgreSQL）
#
# 前置条件:
#   - pg-source (127.0.0.1:5434) 包含 testdb
#   - pg-target (127.0.0.1:5433) 用于恢复
#   - PGPASSWORD=postgres
#
# 用法: bash pgsql/test_integration.sh
# ============================================================

set -uo pipefail

# ────────────────────────────────────────────────────────────
# 配置
# ────────────────────────────────────────────────────────────
export PGPASSWORD=postgres
SRC_HOST="127.0.0.1"
SRC_PORT="5434"
TGT_HOST="127.0.0.1"
TGT_PORT="5433"
PG_USER="postgres"
SRC_DB="testdb"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR=$(mktemp -d /tmp/pgsql_inttest_XXXXXX)

# ────────────────────────────────────────────────────────────
# 测试框架（复用）
# ────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0

_RED='\033[0;31m'; _GREEN='\033[0;32m'; _YELLOW='\033[1;33m'
_CYAN='\033[0;36m'; _BOLD='\033[1m'; _NC='\033[0m'

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        期望: ${_CYAN}${expected}${_NC}"
        echo -e "        实际: ${_CYAN}${actual}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" pattern="$2" text="$3"
    if echo "$text" | grep -qF -- "$pattern"; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        期望包含: ${_CYAN}${pattern}${_NC}"
        echo -e "        实际: ${_CYAN}${text:0:200}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────
src_psql() { psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" "$@"; }
tgt_psql() { psql -h "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" "$@"; }

# 在目标库上删除指定数据库（如果存在）
drop_target_db() {
    local db="$1"
    tgt_psql -d postgres -c "DROP DATABASE IF EXISTS \"${db}\";" > /dev/null 2>&1 || true
}

# 获取指定库的表数量
get_table_count() {
    local host="$1" port="$2" db="$3"
    psql -h "$host" -p "$port" -U "$PG_USER" -d "$db" -Atc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null
}

# 获取指定表的行数
get_row_count() {
    local host="$1" port="$2" db="$3" table="$4"
    psql -h "$host" -p "$port" -U "$PG_USER" -d "$db" -Atc \
        "SELECT count(*) FROM \"${table}\";" 2>/dev/null
}

# 获取指定表的 MD5 校验（用于数据一致性）
get_table_md5() {
    local host="$1" port="$2" db="$3" table="$4"
    psql -h "$host" -p "$port" -U "$PG_USER" -d "$db" -Atc \
        "SELECT md5(string_agg(t::text, '' ORDER BY t)) FROM \"${table}\" t;" 2>/dev/null
}

run_backup_real() {
    PGPASSWORD=postgres \
    BACKUP_DIR="$BACKUP_DIR" \
    AUTO_YES=true \
    _LIB_LOADED="" \
    bash "$SCRIPT_DIR/backup.sh" "$@" 2>&1
}

run_restore_real() {
    PGPASSWORD=postgres \
    AUTO_YES=true \
    _LIB_LOADED="" \
    bash "$SCRIPT_DIR/restore.sh" "$@" 2>&1
}

# ────────────────────────────────────────────────────────────
# 清理
# ────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${_CYAN}清理测试数据库...${_NC}"
    for db in e2e_custom e2e_directory e2e_tar e2e_plain e2e_tables e2e_exclude e2e_schema_only e2e_data_only e2e_clean e2e_noclean e2e_autocreate e2e_parallel; do
        drop_target_db "$db"
    done
    rm -rf "$BACKUP_DIR"
    echo -e "${_CYAN}清理完成${_NC}"
}

trap cleanup EXIT

# ────────────────────────────────────────────────────────────
# E2E-1: 整库备份 → 恢复 → 数据一致性 (custom 格式)
# ────────────────────────────────────────────────────────────
test_e2e_custom() {
    echo ""
    echo -e "${_BOLD}=== E2E-1: 整库备份恢复 (custom 格式) ===${_NC}"

    local tgt_db="e2e_custom"
    drop_target_db "$tgt_db"

    # 备份
    local output
    output=$(run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" -F custom --yes 2>&1)
    local rc=$?
    assert_eq "E2E-1.1 备份退出码 0" "0" "$rc"

    # 找到备份文件
    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)
    assert_eq "E2E-1.2 备份文件存在" "0" "$([[ -f "$dump_file" ]] && echo 0 || echo 1)"

    # 文件大小 > 0
    local fsize
    fsize=$(stat -c %s "$dump_file" 2>/dev/null || echo 0)
    assert_eq "E2E-1.3 备份文件大小 > 0" "0" "$([[ $fsize -gt 0 ]] && echo 0 || echo 1)"

    # 权限 600
    local perm
    perm=$(stat -c '%a' "$dump_file" 2>/dev/null)
    assert_eq "E2E-1.4 备份文件权限 600" "600" "$perm"

    # pg_restore --list 验证
    # 注意：本地 pg_restore 版本可能低于 PG 服务器版本，此时 --list 会失败
    local list_rc=0
    pg_restore --list "$dump_file" > /dev/null 2>&1 || list_rc=$?
    if [[ $list_rc -eq 0 ]]; then
        echo -e "  ${_GREEN}PASS${_NC}  E2E-1.5 pg_restore --list 返回 0"
        PASS=$((PASS + 1))
    else
        local local_ver server_ver
        local_ver=$(pg_restore --version | awk '{print $NF}' | cut -d. -f1)
        server_ver=$(psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -Atc "SHOW server_version_num;" 2>/dev/null | head -c2)
        if [[ "$local_ver" -lt "$server_ver" ]]; then
            echo -e "  ${_YELLOW}SKIP${_NC}  E2E-1.5 pg_restore --list（本地 v${local_ver} < 服务器 v${server_ver}，版本不兼容）"
            SKIP=$((SKIP + 1))
        else
            echo -e "  ${_RED}FAIL${_NC}  E2E-1.5 pg_restore --list 返回 ${list_rc}"
            FAIL=$((FAIL + 1))
        fi
    fi

    # 恢复
    output=$(run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes 2>&1)
    rc=$?
    assert_eq "E2E-1.6 恢复退出码 0" "0" "$rc"

    # 验证：表数量一致
    local src_tables tgt_tables
    src_tables=$(get_table_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB")
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-1.7 表数量一致 (${src_tables})" "$src_tables" "$tgt_tables"

    # 验证：各表行数一致
    for table in users orders audit_logs; do
        local src_rows tgt_rows
        src_rows=$(get_row_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$table")
        tgt_rows=$(get_row_count "$TGT_HOST" "$TGT_PORT" "$tgt_db" "$table")
        assert_eq "E2E-1.8 ${table} 行数一致 (${src_rows})" "$src_rows" "$tgt_rows"
    done

    # 验证：数据 MD5 一致
    for table in users orders; do
        local src_md5 tgt_md5
        src_md5=$(get_table_md5 "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$table")
        tgt_md5=$(get_table_md5 "$TGT_HOST" "$TGT_PORT" "$tgt_db" "$table")
        assert_eq "E2E-1.9 ${table} 数据 MD5 一致" "$src_md5" "$tgt_md5"
    done
}

# ────────────────────────────────────────────────────────────
# E2E-2: directory 格式备份恢复
# ────────────────────────────────────────────────────────────
test_e2e_directory() {
    echo ""
    echo -e "${_BOLD}=== E2E-2: directory 格式备份恢复 ===${_NC}"

    local tgt_db="e2e_directory"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" -F directory --yes > /dev/null 2>&1
    assert_eq "E2E-2.1 备份退出码 0" "0" "$?"

    local dump_dir
    dump_dir=$(find "$BACKUP_DIR/daily/" -maxdepth 1 -name "${SRC_DB}_*.dir" -type d | sort | tail -1)
    assert_eq "E2E-2.2 备份目录存在" "0" "$([[ -d "$dump_dir" ]] && echo 0 || echo 1)"

    # toc.dat 存在
    assert_eq "E2E-2.3 toc.dat 存在" "0" "$([[ -f "$dump_dir/toc.dat" ]] && echo 0 || echo 1)"

    # 目录权限 700
    local perm
    perm=$(stat -c '%a' "$dump_dir" 2>/dev/null)
    assert_eq "E2E-2.4 目录权限 700" "700" "$perm"

    # 恢复
    run_restore_real "$dump_dir" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1
    assert_eq "E2E-2.5 恢复退出码 0" "0" "$?"

    local src_tables tgt_tables
    src_tables=$(get_table_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB")
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-2.6 表数量一致" "$src_tables" "$tgt_tables"
}

# ────────────────────────────────────────────────────────────
# E2E-3: tar 格式备份恢复
# ────────────────────────────────────────────────────────────
test_e2e_tar() {
    echo ""
    echo -e "${_BOLD}=== E2E-3: tar 格式备份恢复 ===${_NC}"

    local tgt_db="e2e_tar"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" -F tar --yes > /dev/null 2>&1
    assert_eq "E2E-3.1 备份退出码 0" "0" "$?"

    local tar_file
    tar_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.tar" -type f | sort | tail -1)
    assert_eq "E2E-3.2 tar 文件存在" "0" "$([[ -f "$tar_file" ]] && echo 0 || echo 1)"

    # 恢复
    run_restore_real "$tar_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1
    assert_eq "E2E-3.3 恢复退出码 0" "0" "$?"

    local src_tables tgt_tables
    src_tables=$(get_table_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB")
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-3.4 表数量一致" "$src_tables" "$tgt_tables"
}

# ────────────────────────────────────────────────────────────
# E2E-4: plain (SQL) 格式备份恢复
# ────────────────────────────────────────────────────────────
test_e2e_plain() {
    echo ""
    echo -e "${_BOLD}=== E2E-4: plain (SQL) 格式备份恢复 ===${_NC}"

    local tgt_db="e2e_plain"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" -F plain --yes > /dev/null 2>&1
    assert_eq "E2E-4.1 备份退出码 0" "0" "$?"

    local sql_file
    sql_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.sql" -type f | sort | tail -1)
    assert_eq "E2E-4.2 SQL 文件存在" "0" "$([[ -f "$sql_file" ]] && echo 0 || echo 1)"

    # 检查文件头
    local header
    header=$(head -5 "$sql_file")
    assert_contains "E2E-4.3 SQL 文件头正确" "PostgreSQL database dump" "$header"

    # 恢复
    run_restore_real "$sql_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1
    assert_eq "E2E-4.4 恢复退出码 0" "0" "$?"

    local src_tables tgt_tables
    src_tables=$(get_table_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB")
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-4.5 表数量一致" "$src_tables" "$tgt_tables"
}

# ────────────────────────────────────────────────────────────
# E2E-5: 只备份指定表
# ────────────────────────────────────────────────────────────
test_e2e_select_tables() {
    echo ""
    echo -e "${_BOLD}=== E2E-5: 只备份指定表 ===${_NC}"

    local tgt_db="e2e_tables"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" \
        -t users -t orders --yes > /dev/null 2>&1
    assert_eq "E2E-5.1 备份退出码 0" "0" "$?"

    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)

    run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1

    # 只有 users 和 orders，没有 audit_logs
    local tgt_tables
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-5.2 只恢复了 2 张表" "2" "$tgt_tables"

    # users 行数一致
    local src_rows tgt_rows
    src_rows=$(get_row_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "users")
    tgt_rows=$(get_row_count "$TGT_HOST" "$TGT_PORT" "$tgt_db" "users")
    assert_eq "E2E-5.3 users 行数一致" "$src_rows" "$tgt_rows"
}

# ────────────────────────────────────────────────────────────
# E2E-6: 排除指定表
# ────────────────────────────────────────────────────────────
test_e2e_exclude_table() {
    echo ""
    echo -e "${_BOLD}=== E2E-6: 排除指定表 ===${_NC}"

    local tgt_db="e2e_exclude"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" \
        -T audit_logs --yes > /dev/null 2>&1
    assert_eq "E2E-6.1 备份退出码 0" "0" "$?"

    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)

    run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1

    # 只有 users 和 orders（排除了 audit_logs）
    local tgt_tables
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-6.2 排除后只有 2 张表" "2" "$tgt_tables"

    # 确认 audit_logs 不存在
    local audit_exists
    audit_exists=$(tgt_psql -d "$tgt_db" -Atc \
        "SELECT count(*) FROM information_schema.tables WHERE table_name='audit_logs' AND table_schema='public';" 2>/dev/null)
    assert_eq "E2E-6.3 audit_logs 不存在" "0" "$audit_exists"
}

# ────────────────────────────────────────────────────────────
# E2E-7: 只备份表结构 (--schema-only)
# ────────────────────────────────────────────────────────────
test_e2e_schema_only() {
    echo ""
    echo -e "${_BOLD}=== E2E-7: 只备份表结构 ===${_NC}"

    local tgt_db="e2e_schema_only"
    drop_target_db "$tgt_db"

    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" \
        --schema-only --yes > /dev/null 2>&1
    assert_eq "E2E-7.1 备份退出码 0" "0" "$?"

    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)

    run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes > /dev/null 2>&1

    # 表存在
    local tgt_tables
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-7.2 表数量一致 (3)" "3" "$tgt_tables"

    # 但行数为 0
    local rows
    rows=$(get_row_count "$TGT_HOST" "$TGT_PORT" "$tgt_db" "users")
    assert_eq "E2E-7.3 users 行数为 0" "0" "$rows"

    rows=$(get_row_count "$TGT_HOST" "$TGT_PORT" "$tgt_db" "orders")
    assert_eq "E2E-7.4 orders 行数为 0" "0" "$rows"
}

# ────────────────────────────────────────────────────────────
# E2E-8: 恢复到不存在的库（自动创建）
# ────────────────────────────────────────────────────────────
test_e2e_auto_create() {
    echo ""
    echo -e "${_BOLD}=== E2E-8: 自动创建目标数据库 ===${_NC}"

    local tgt_db="e2e_autocreate"
    drop_target_db "$tgt_db"

    # 确认目标库不存在
    local exists
    exists=$(tgt_psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='${tgt_db}';" 2>/dev/null)
    assert_eq "E2E-8.1 目标库初始不存在" "" "$exists"

    # 先做一次备份
    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)

    # 恢复到不存在的库
    local output
    output=$(run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" --yes 2>&1)
    assert_eq "E2E-8.2 恢复退出码 0" "0" "$?"

    # 确认数据库被创建
    exists=$(tgt_psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='${tgt_db}';" 2>/dev/null)
    assert_eq "E2E-8.3 目标库已自动创建" "1" "$exists"

    # 验证数据
    local tgt_tables
    tgt_tables=$(get_table_count "$TGT_HOST" "$TGT_PORT" "$tgt_db")
    assert_eq "E2E-8.4 表数量正确" "3" "$tgt_tables"
}

# ────────────────────────────────────────────────────────────
# E2E-9: 并行恢复 (-j)
# ────────────────────────────────────────────────────────────
test_e2e_parallel() {
    echo ""
    echo -e "${_BOLD}=== E2E-9: 并行恢复 ===${_NC}"

    local tgt_db="e2e_parallel"
    drop_target_db "$tgt_db"

    # 做一次全量备份（避免拿到 schema-only 的备份文件）
    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" -F custom --yes > /dev/null 2>&1

    local dump_file
    dump_file=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_*.dump" -type f | sort | tail -1)

    run_restore_real "$dump_file" -H "$TGT_HOST" -p "$TGT_PORT" -U "$PG_USER" -d "$tgt_db" -j 4 --yes > /dev/null 2>&1
    assert_eq "E2E-9.1 并行恢复退出码 0" "0" "$?"

    # 验证数据一致
    for table in users orders audit_logs; do
        local src_rows tgt_rows
        src_rows=$(get_row_count "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$table")
        tgt_rows=$(get_row_count "$TGT_HOST" "$TGT_PORT" "$tgt_db" "$table")
        assert_eq "E2E-9.2 ${table} 行数一致 (-j 4)" "$src_rows" "$tgt_rows"
    done
}

# ────────────────────────────────────────────────────────────
# E2E-10: 过期清理（真实文件）
# ────────────────────────────────────────────────────────────
test_e2e_cleanup() {
    echo ""
    echo -e "${_BOLD}=== E2E-10: 过期备份清理 ===${_NC}"

    # 创建假的过期文件
    mkdir -p "$BACKUP_DIR/daily"
    touch "$BACKUP_DIR/daily/${SRC_DB}_20260101_120000.dump"
    touch "$BACKUP_DIR/daily/${SRC_DB}_20260102_120000.dump"

    # 执行新备份（会触发清理）
    run_backup_real -H "$SRC_HOST" -p "$SRC_PORT" -U "$PG_USER" -d "$SRC_DB" \
        --retention-days 7 --yes > /dev/null 2>&1

    # 过期文件应被清理
    assert_eq "E2E-10.1 过期文件 0101 被清理" "0" \
        "$([[ ! -f "$BACKUP_DIR/daily/${SRC_DB}_20260101_120000.dump" ]] && echo 0 || echo 1)"
    assert_eq "E2E-10.2 过期文件 0102 被清理" "0" \
        "$([[ ! -f "$BACKUP_DIR/daily/${SRC_DB}_20260102_120000.dump" ]] && echo 0 || echo 1)"

    # 新备份文件应存在
    local new_backups
    new_backups=$(find "$BACKUP_DIR/daily/" -name "${SRC_DB}_20260402_*.dump" -type f | wc -l)
    assert_eq "E2E-10.3 新备份文件存在" "0" "$([[ $new_backups -gt 0 ]] && echo 0 || echo 1)"
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo -e "${_BOLD}${_CYAN}  PostgreSQL 备份/恢复 — 集成测试${_NC}"
    echo -e "${_BOLD}${_CYAN}  源: ${SRC_HOST}:${SRC_PORT}/${SRC_DB}${_NC}"
    echo -e "${_BOLD}${_CYAN}  目标: ${TGT_HOST}:${TGT_PORT}${_NC}"
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"

    test_e2e_custom
    test_e2e_directory
    test_e2e_tar
    test_e2e_plain
    test_e2e_select_tables
    test_e2e_exclude_table
    test_e2e_schema_only
    test_e2e_auto_create
    test_e2e_parallel
    test_e2e_cleanup

    echo ""
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo -e "${_BOLD}  集成测试结果汇总${_NC}"
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo -e "  ${_GREEN}PASS: ${PASS}${_NC}"
    echo -e "  ${_RED}FAIL: ${FAIL}${_NC}"
    echo -e "  ${_YELLOW}SKIP: ${SKIP}${_NC}"
    echo -e "  总计: $((PASS + FAIL + SKIP))"
    echo ""

    if [[ $FAIL -gt 0 ]]; then
        echo -e "${_RED}${_BOLD}存在失败的测试用例！${_NC}"
        exit 1
    else
        echo -e "${_GREEN}${_BOLD}全部测试通过！${_NC}"
        exit 0
    fi
}

main
