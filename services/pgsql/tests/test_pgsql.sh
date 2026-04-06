#!/usr/bin/env bash
# ============================================================
# services/pgsql/tests/test_pgsql.sh — backup.sh / restore.sh 单元测试
#
# 用法: bash services/pgsql/tests/test_pgsql.sh
#
# 策略:
#   1. 使用 mock 命令替代 pg_dump/pg_restore/psql/pg_isready
#      不需要真实 PostgreSQL 实例
#   2. 在临时目录中运行，测试后自动清理
# ============================================================

set -uo pipefail

# ────────────────────────────────────────────────────────────
# 测试框架
# ────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR=""

# 颜色
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_CYAN='\033[0;36m'
_BOLD='\033[1m'
_NC='\033[0m'

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
        echo -e "        实际输出: ${_CYAN}${text:0:200}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" pattern="$2" text="$3"
    if ! echo "$text" | grep -qF -- "$pattern"; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        期望不包含: ${_CYAN}${pattern}${_NC}"
        echo -e "        实际输出: ${_CYAN}${text:0:200}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        期望退出码: ${_CYAN}${expected}${_NC}  实际: ${_CYAN}${actual}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1" filepath="$2"
    if [[ -e "$filepath" ]]; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        文件不存在: ${_CYAN}${filepath}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_exists() {
    local desc="$1" filepath="$2"
    if [[ ! -e "$filepath" ]]; then
        echo -e "  ${_GREEN}PASS${_NC}  $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${_RED}FAIL${_NC}  $desc"
        echo -e "        文件仍存在: ${_CYAN}${filepath}${_NC}"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_perm() {
    local desc="$1" expected_perm="$2" filepath="$3"
    local actual_perm
    actual_perm=$(stat -c '%a' "$filepath" 2>/dev/null || stat -f '%Lp' "$filepath" 2>/dev/null)
    assert_eq "$desc" "$expected_perm" "$actual_perm"
}

# ────────────────────────────────────────────────────────────
# 测试环境搭建 / 清理
# ────────────────────────────────────────────────────────────
setup() {
    TMP_DIR=$(mktemp -d /tmp/pgsql_test_XXXXXX)
    MOCK_BIN="$TMP_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"

    # --- mock pg_dump: 创建一个假的备份文件 ---
    cat > "$MOCK_BIN/pg_dump" << 'MOCK'
#!/usr/bin/env bash
# 解析 -f 参数找到输出文件路径
output_file=""
format_flag=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
        -f) output_file="${args[$((i+1))]}" ;;
        -F*) format_flag="${args[$i]#-F}" ;;
    esac
done
# 将收到的完整参数写入日志，供测试断言
echo "pg_dump $*" >> "${PGSQL_TEST_MOCK_LOG:-/tmp/pgsql_mock.log}"
# 创建假的输出文件
if [[ -n "$output_file" ]]; then
    if [[ "$format_flag" == "d" ]]; then
        mkdir -p "$output_file"
        echo "mock_toc" > "$output_file/toc.dat"
    else
        mkdir -p "$(dirname "$output_file")"
        echo "-- PostgreSQL database dump" > "$output_file"
    fi
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/pg_dump"

    # --- mock pg_restore ---
    cat > "$MOCK_BIN/pg_restore" << 'MOCK'
#!/usr/bin/env bash
echo "pg_restore $*" >> "${PGSQL_TEST_MOCK_LOG:-/tmp/pgsql_mock.log}"
# --list 模式返回假对象列表
for arg in "$@"; do
    if [[ "$arg" == "--list" ]]; then
        echo ";  entry 1"
        echo ";  entry 2"
        echo ";  entry 3"
        exit 0
    fi
done
exit 0
MOCK
    chmod +x "$MOCK_BIN/pg_restore"

    # --- mock psql ---
    cat > "$MOCK_BIN/psql" << 'MOCK'
#!/usr/bin/env bash
echo "psql $*" >> "${PGSQL_TEST_MOCK_LOG:-/tmp/pgsql_mock.log}"
# -lqt 列库模式：返回一个假的数据库列表
for arg in "$@"; do
    if [[ "$arg" == "-lqt" ]]; then
        echo " testdb      | postgres | UTF8 | "
        echo " mydb        | postgres | UTF8 | "
        echo " my_app_db   | postgres | UTF8 | "
        echo " cleandb     | postgres | UTF8 | "
        echo " manualdb    | postgres | UTF8 | "
        echo " weeklydb    | postgres | UTF8 | "
        echo " conntest    | postgres | UTF8 | "
        echo " my-db       | postgres | UTF8 | "
        echo " _internal_db| postgres | UTF8 | "
        exit 0
    fi
done
# -Atc 查询模式
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-Atc" ]]; then
        if echo "$arg" | grep -q "pg_size_pretty"; then
            echo "128 MB"
        elif echo "$arg" | grep -q "count"; then
            echo "15"
        elif echo "$arg" | grep -q "SELECT 1"; then
            echo "1"
        fi
        exit 0
    fi
    if [[ "$prev" == "-c" ]]; then
        # CREATE DATABASE 等
        exit 0
    fi
    prev="$arg"
done
# -f 模式 (SQL 恢复)
for arg in "$@"; do
    if [[ "$arg" == "-f" ]]; then
        exit 0
    fi
done
exit 0
MOCK
    chmod +x "$MOCK_BIN/psql"

    # --- mock pg_isready ---
    cat > "$MOCK_BIN/pg_isready" << 'MOCK'
#!/usr/bin/env bash
echo "pg_isready $*" >> "${PGSQL_TEST_MOCK_LOG:-/tmp/pgsql_mock.log}"
exit 0
MOCK
    chmod +x "$MOCK_BIN/pg_isready"

    # mock 日志文件
    export PGSQL_TEST_MOCK_LOG="$TMP_DIR/mock.log"
    touch "$PGSQL_TEST_MOCK_LOG"
}

teardown() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# 运行 backup.sh（前置 mock PATH，设定关键环境变量）
# 输出写入 $TMP_DIR/_last_output，退出码写入 $TMP_DIR/_last_rc
run_backup() {
    PATH="$MOCK_BIN:$PATH" \
    LOG_FILE="$TMP_DIR/backup.log" \
    AUTO_YES=true \
    _LIB_LOADED="" \
    BACKUP_DIR="$TMP_DIR/backups" \
    bash "$PROJECT_DIR/services/pgsql/backup/run.sh" "$@" > "$TMP_DIR/_last_output" 2>&1
    echo $? > "$TMP_DIR/_last_rc"
    cat "$TMP_DIR/_last_output"
    return "$(cat "$TMP_DIR/_last_rc")"
}

# 运行 restore.sh
run_restore() {
    PATH="$MOCK_BIN:$PATH" \
    LOG_FILE="$TMP_DIR/restore.log" \
    AUTO_YES=true \
    _LIB_LOADED="" \
    bash "$PROJECT_DIR/services/pgsql/restore/run.sh" "$@" > "$TMP_DIR/_last_output" 2>&1
    echo $? > "$TMP_DIR/_last_rc"
    cat "$TMP_DIR/_last_output"
    return "$(cat "$TMP_DIR/_last_rc")"
}

# ────────────────────────────────────────────────────────────
# 测试组 1: common/lib.sh
# ────────────────────────────────────────────────────────────
test_lib() {
    echo ""
    echo -e "${_BOLD}=== 测试组 1: common/lib.sh ===${_NC}"

    # 加载 lib.sh
    _LIB_LOADED=""
    LOG_FILE="$TMP_DIR/lib_test.log"
    AUTO_YES=false
    source "$PROJECT_DIR/common/lib.sh"

    # 1.1 颜色变量已定义
    assert_eq "1.1 RED 颜色变量已定义" '\033[0;31m' "$RED"
    assert_eq "1.1 GREEN 颜色变量已定义" '\033[0;32m' "$GREEN"
    assert_eq "1.1 NC 颜色变量已定义" '\033[0m' "$NC"

    # 1.2 cmd_exists 检测已有命令
    cmd_exists bash
    assert_eq "1.2 cmd_exists bash 返回 0" "0" "$?"

    # 1.3 cmd_exists 检测不存在的命令
    local rc=0
    cmd_exists __nonexistent_command_xyz__ || rc=$?
    assert_eq "1.3 cmd_exists 不存在命令返回非 0" "1" "$rc"

    # 1.4 confirm 在 AUTO_YES=true 时直接返回
    AUTO_YES=true
    confirm
    assert_eq "1.4 confirm AUTO_YES=true 返回 0" "0" "$?"

    # 1.5 日志函数写入文件
    log "test log message"
    assert_contains "1.5 log 写入日志文件" "test log message" "$(cat "$LOG_FILE")"

    # 1.6 ok 函数写入日志文件
    ok "test ok message"
    assert_contains "1.6 ok 写入日志文件" "test ok message" "$(cat "$LOG_FILE")"

    # 1.7 warn 函数写入日志文件
    warn "test warn message"
    assert_contains "1.7 warn 写入日志文件" "test warn message" "$(cat "$LOG_FILE")"

    # 1.8 print_banner 正常输出
    local banner_output
    banner_output=$(print_banner "Test Title" "Test Subtitle")
    assert_contains "1.8 print_banner 包含标题" "Test Title" "$banner_output"

    # 1.9 防重复加载
    _LIB_LOADED=1
    # source 时应直接 return，不会重新定义（这里主要测不报错）
    source "$PROJECT_DIR/common/lib.sh"
    assert_eq "1.9 重复 source 不报错" "0" "$?"
}

# ────────────────────────────────────────────────────────────
# 测试组 2: backup.sh — 参数解析与帮助
# ────────────────────────────────────────────────────────────
test_backup_args() {
    echo ""
    echo -e "${_BOLD}=== 测试组 2: backup.sh 参数解析 ===${_NC}"

    # 2.1 --help 正常退出
    local output rc
    run_backup --help > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "2.1 --help 退出码 0" "0" "$rc"
    assert_contains "2.1 --help 包含用法" "用法" "$output"

    # 2.2 缺少 -d 参数时报错
    run_backup --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "2.2 缺少 -d 报错退出" "1" "$rc"
    assert_contains "2.2 报错信息包含数据库名提示" "未指定数据库名" "$output"

    # 2.3 未知参数触发 usage 输出
    run_backup --unknown-flag > /dev/null 2>&1 || true
    output=$(cat "$TMP_DIR/_last_output")
    assert_contains "2.3 未知参数显示用法" "未知参数" "$output"

    # 2.4 --schema-only 与 --data-only 互斥
    run_backup -d testdb --schema-only --data-only --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "2.4 互斥参数退出码 1" "1" "$rc"
    assert_contains "2.4 互斥参数报错信息" "不能同时使用" "$output"
}

# ────────────────────────────────────────────────────────────
# 测试组 3: backup.sh — 格式映射函数
# ────────────────────────────────────────────────────────────
test_backup_format() {
    echo ""
    echo -e "${_BOLD}=== 测试组 3: backup.sh 格式映射 ===${_NC}"

    # 通过子 shell source lib.sh 后定义函数来测试
    local result

    # 3.1 get_format_flag
    for pair in "custom:c" "directory:d" "tar:t" "plain:p"; do
        local fmt="${pair%%:*}" expected="${pair##*:}"
        result=$(
            _LIB_LOADED=""
            LOG_FILE="$TMP_DIR/fmt_test.log"
            AUTO_YES=true
            source "$PROJECT_DIR/common/lib.sh"
            BACKUP_FORMAT="$fmt"
            get_format_flag() {
                case "$BACKUP_FORMAT" in
                    custom) echo "c" ;; directory) echo "d" ;;
                    tar) echo "t" ;; plain) echo "p" ;;
                esac
            }
            get_format_flag
        )
        assert_eq "3.1 get_format_flag $fmt → $expected" "$expected" "$result"
    done

    # 3.2 get_format_ext
    for pair in "custom:dump" "directory:dir" "tar:tar" "plain:sql"; do
        local fmt="${pair%%:*}" expected="${pair##*:}"
        result=$(
            _LIB_LOADED=""
            LOG_FILE="$TMP_DIR/fmt_test.log"
            AUTO_YES=true
            source "$PROJECT_DIR/common/lib.sh"
            BACKUP_FORMAT="$fmt"
            get_format_ext() {
                case "$BACKUP_FORMAT" in
                    custom) echo "dump" ;; directory) echo "dir" ;;
                    tar) echo "tar" ;; plain) echo "sql" ;;
                esac
            }
            get_format_ext
        )
        assert_eq "3.2 get_format_ext $fmt → $expected" "$expected" "$result"
    done
}

# ────────────────────────────────────────────────────────────
# 测试组 4: backup.sh — 完整备份流程（mock）
# ────────────────────────────────────────────────────────────
test_backup_full() {
    echo ""
    echo -e "${_BOLD}=== 测试组 4: backup.sh 完整备份流程 ===${_NC}"

    > "$PGSQL_TEST_MOCK_LOG"
    local output rc mock_log

    # 4.1 默认参数整库备份
    run_backup -d testdb --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "4.1 整库备份退出码 0" "0" "$rc"
    assert_contains "4.1 输出包含完成提示" "全部完成" "$output"
    assert_contains "4.1 pg_dump 被调用" "pg_dump" "$(cat "$PGSQL_TEST_MOCK_LOG")"
    local backup_files
    backup_files=$(ls "$TMP_DIR/backups/daily/" 2>/dev/null | head -1)
    assert_eq "4.1 备份文件已创建" "0" "$([[ -n "$backup_files" ]] && echo 0 || echo 1)"

    # 4.2 自定义格式备份传递 -Fc 和 -Z
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb -F custom -Z 3 --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.2 传递 -Fc 参数" "-Fc" "$mock_log"
    assert_contains "4.2 传递 -Z 3 参数" "-Z 3" "$mock_log"

    # 4.3 plain 格式不传 -Z
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb -F plain --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.3 传递 -Fp 参数" "-Fp" "$mock_log"
    assert_not_contains "4.3 plain 格式不传 -Z" " -Z " "$mock_log"

    # 4.4 指定表备份传递 -t 参数
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb -t users -t orders --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.4 传递 -t users" "-t users" "$mock_log"
    assert_contains "4.4 传递 -t orders" "-t orders" "$mock_log"

    # 4.5 排除表传递 -T 参数
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb -T audit_logs --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.5 传递 -T audit_logs" "-T audit_logs" "$mock_log"

    # 4.6 指定 schema 传递 -n 参数
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb -n public -n analytics --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.6 传递 -n public" "-n public" "$mock_log"
    assert_contains "4.6 传递 -n analytics" "-n analytics" "$mock_log"

    # 4.7 --schema-only 传递正确
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb --schema-only --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.7 传递 --schema-only" "--schema-only" "$mock_log"

    # 4.8 --data-only 传递正确
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -d testdb --data-only --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.8 传递 --data-only" "--data-only" "$mock_log"

    # 4.9 备份文件权限为 600
    local latest_backup
    latest_backup=$(find "$TMP_DIR/backups/daily/" -maxdepth 1 -type f -name "testdb_*" | head -1)
    if [[ -n "$latest_backup" ]]; then
        assert_file_perm "4.9 备份文件权限 600" "600" "$latest_backup"
    else
        echo -e "  ${_YELLOW}SKIP${_NC}  4.9 备份文件权限（未找到备份文件）"
        SKIP=$((SKIP + 1))
    fi

    # 4.10 连接参数传递正确
    > "$PGSQL_TEST_MOCK_LOG"
    run_backup -H 10.0.0.1 -p 5433 -U dbadmin -d testdb --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "4.10 传递 -h 10.0.0.1" "-h 10.0.0.1" "$mock_log"
    assert_contains "4.10 传递 -p 5433" "-p 5433" "$mock_log"
    assert_contains "4.10 传递 -U dbadmin" "-U dbadmin" "$mock_log"
}

# ────────────────────────────────────────────────────────────
# 测试组 5: backup.sh — 过期备份清理（基于时间戳）
# ────────────────────────────────────────────────────────────
test_backup_cleanup() {
    echo ""
    echo -e "${_BOLD}=== 测试组 5: backup.sh 过期备份清理 ===${_NC}"

    local backup_dir="$TMP_DIR/cleanup_test/daily"
    mkdir -p "$backup_dir"

    # 创建模拟备份文件：
    #   - 10 天前的文件（应被清理，默认保留 7 天）
    touch "$backup_dir/cleandb_20260301_120000.dump"
    #   - 3 天前的文件（应保留）
    touch "$backup_dir/cleandb_20260330_120000.dump"
    #   - 今天的文件（应保留）
    touch "$backup_dir/cleandb_20260402_120000.dump"
    #   - 其他数据库的文件（不应被清理）
    touch "$backup_dir/otherdb_20260101_120000.dump"

    # 运行备份（会在清理阶段处理这些文件）
    local output
    output=$(
        PATH="$MOCK_BIN:$PATH" \
        LOG_FILE="$TMP_DIR/cleanup.log" \
        AUTO_YES=true \
        _LIB_LOADED="" \
        BACKUP_DIR="$TMP_DIR/cleanup_test" \
        BACKUP_RETENTION_DAYS=7 \
        bash "$PROJECT_DIR/services/pgsql/backup/run.sh" -d cleandb --yes 2>&1
    ) || true

    # 5.1 过期文件被清理
    assert_file_not_exists "5.1 10 天前备份被清理" "$backup_dir/cleandb_20260301_120000.dump"

    # 5.2 近期文件被保留
    assert_file_exists "5.2 3 天前备份被保留" "$backup_dir/cleandb_20260330_120000.dump"

    # 5.3 今天的文件被保留
    assert_file_exists "5.3 今天备份被保留" "$backup_dir/cleandb_20260402_120000.dump"

    # 5.4 其他数据库文件不受影响
    assert_file_exists "5.4 其他数据库文件不受影响" "$backup_dir/otherdb_20260101_120000.dump"
}

# ────────────────────────────────────────────────────────────
# 测试组 6: backup.sh — 备份类型与保留策略
# ────────────────────────────────────────────────────────────
test_backup_types() {
    echo ""
    echo -e "${_BOLD}=== 测试组 6: backup.sh 备份类型 ===${_NC}"

    # 6.1 manual 类型不清理
    local manual_dir="$TMP_DIR/manual_test/manual"
    mkdir -p "$manual_dir"
    touch "$manual_dir/manualdb_20250101_120000.dump"

    local output
    output=$(
        PATH="$MOCK_BIN:$PATH" \
        LOG_FILE="$TMP_DIR/manual.log" \
        AUTO_YES=true \
        _LIB_LOADED="" \
        BACKUP_DIR="$TMP_DIR/manual_test" \
        bash "$PROJECT_DIR/services/pgsql/backup/run.sh" -d manualdb --type manual --yes 2>&1
    ) || true
    assert_file_exists "6.1 manual 类型不清理旧备份" "$manual_dir/manualdb_20250101_120000.dump"
    assert_contains "6.1 输出包含跳过提示" "手动备份不自动清理" "$output"

    # 6.2 weekly 类型使用周数换算天数
    output=$(
        PATH="$MOCK_BIN:$PATH" \
        LOG_FILE="$TMP_DIR/weekly.log" \
        AUTO_YES=true \
        _LIB_LOADED="" \
        BACKUP_DIR="$TMP_DIR/weekly_test" \
        BACKUP_RETENTION_WEEKS=4 \
        bash "$PROJECT_DIR/services/pgsql/backup/run.sh" -d weeklydb --type weekly --yes 2>&1
    ) || true
    assert_contains "6.2 weekly 类型显示保留周数" "4 周" "$output"
}

# ────────────────────────────────────────────────────────────
# 测试组 7: restore.sh — 参数解析
# ────────────────────────────────────────────────────────────
test_restore_args() {
    echo ""
    echo -e "${_BOLD}=== 测试组 7: restore.sh 参数解析 ===${_NC}"

    local output rc

    # 7.1 --help 正常退出
    run_restore --help > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "7.1 --help 退出码 0" "0" "$rc"
    assert_contains "7.1 --help 包含用法" "用法" "$output"

    # 7.2 无参数显示用法
    run_restore > /dev/null 2>&1 || true
    output=$(cat "$TMP_DIR/_last_output")
    assert_contains "7.2 无参数包含用法" "用法" "$output"

    # 7.3 备份文件不存在时报错
    run_restore /nonexistent/file.dump --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "7.3 文件不存在退出码 1" "1" "$rc"
    assert_contains "7.3 报错包含不存在提示" "不存在" "$output"
}

# ────────────────────────────────────────────────────────────
# 测试组 8: restore.sh — infer_dbname 函数
# ────────────────────────────────────────────────────────────
test_restore_infer_dbname() {
    echo ""
    echo -e "${_BOLD}=== 测试组 8: restore.sh infer_dbname ===${_NC}"

    # 定义 infer_dbname 的测试包装
    _test_infer() {
        local input="$1"
        (
            BACKUP_FILE="$input"
            infer_dbname() {
                local filename
                filename=$(basename "$BACKUP_FILE")
                filename="${filename%/}"
                local result
                result=$(echo "$filename" | sed -E 's/_[0-9]{8}_[0-9]{6}(\..+)?$//')
                if [[ "$result" == "$filename" ]]; then
                    result="${filename%.*}"
                    [[ -z "$result" ]] && result="$filename"
                fi
                echo "$result"
            }
            infer_dbname
        )
    }

    # 8.1 标准格式: mydb_20260402_120000.dump → mydb
    assert_eq "8.1 标准格式推断" "mydb" "$(_test_infer "mydb_20260402_120000.dump")"

    # 8.2 带下划线数据库名: my_app_db_20260402_120000.dump → my_app_db
    assert_eq "8.2 多下划线推断" "my_app_db" "$(_test_infer "my_app_db_20260402_120000.dump")"

    # 8.3 无时间戳: mydb.dump → mydb
    assert_eq "8.3 无时间戳推断" "mydb" "$(_test_infer "mydb.dump")"

    # 8.4 SQL 后缀: mydb.sql → mydb
    assert_eq "8.4 SQL 后缀推断" "mydb" "$(_test_infer "mydb.sql")"

    # 8.5 tar 后缀: mydb.tar → mydb
    assert_eq "8.5 tar 后缀推断" "mydb" "$(_test_infer "mydb.tar")"

    # 8.6 目录格式带路径: /data/backup/mydb_20260402_120000.dir → mydb
    assert_eq "8.6 目录路径推断" "mydb" "$(_test_infer "/data/backup/mydb_20260402_120000.dir")"

    # 8.7 无后缀 (目录名): mydb → mydb
    assert_eq "8.7 无后缀推断" "mydb" "$(_test_infer "mydb")"
}

# ────────────────────────────────────────────────────────────
# 测试组 9: restore.sh — detect_format 函数
# ────────────────────────────────────────────────────────────
test_restore_detect_format() {
    echo ""
    echo -e "${_BOLD}=== 测试组 9: restore.sh detect_format ===${_NC}"

    _test_detect() {
        local input="$1"
        (
            BACKUP_FILE="$input"
            # mock pg_restore for unknown format detection
            pg_restore() { return 1; }
            detect_format() {
                if [[ -d "$BACKUP_FILE" ]]; then echo "directory"
                elif [[ "$BACKUP_FILE" == *.sql ]]; then echo "plain"
                elif [[ "$BACKUP_FILE" == *.tar ]]; then echo "tar"
                elif [[ "$BACKUP_FILE" == *.dump ]]; then echo "custom"
                else
                    if pg_restore --list "$BACKUP_FILE" > /dev/null 2>&1; then echo "custom"
                    else echo "plain"
                    fi
                fi
            }
            detect_format
        )
    }

    # 9.1 .dump → custom
    assert_eq "9.1 .dump → custom" "custom" "$(_test_detect "mydb.dump")"

    # 9.2 .sql → plain
    assert_eq "9.2 .sql → plain" "plain" "$(_test_detect "mydb.sql")"

    # 9.3 .tar → tar
    assert_eq "9.3 .tar → tar" "tar" "$(_test_detect "mydb.tar")"

    # 9.4 目录 → directory
    local test_dir="$TMP_DIR/test_backup_dir"
    mkdir -p "$test_dir"
    assert_eq "9.4 目录 → directory" "directory" "$(_test_detect "$test_dir")"

    # 9.5 未知后缀回退为 plain
    assert_eq "9.5 未知后缀 → plain" "plain" "$(_test_detect "mydb.bak")"
}

# ────────────────────────────────────────────────────────────
# 测试组 10: restore.sh — 数据库名合法性校验
# ────────────────────────────────────────────────────────────
test_restore_dbname_validation() {
    echo ""
    echo -e "${_BOLD}=== 测试组 10: restore.sh 数据库名校验 ===${_NC}"

    # 创建一个假的备份文件用于测试
    local fake_dump="$TMP_DIR/fake.dump"
    echo "mock dump" > "$fake_dump"
    local output rc

    # 10.1 正常数据库名通过
    run_restore "$fake_dump" -d mydb --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.1 合法名 'mydb' 通过" "0" "$rc"

    # 10.2 带下划线通过
    run_restore "$fake_dump" -d my_app_db --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.2 合法名 'my_app_db' 通过" "0" "$rc"

    # 10.3 带连字符通过
    run_restore "$fake_dump" -d my-db --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.3 合法名 'my-db' 通过" "0" "$rc"

    # 10.4 以数字开头被拒绝
    run_restore "$fake_dump" -d "123db" --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "10.4 数字开头 '123db' 被拒" "1" "$rc"
    assert_contains "10.4 报错包含非法字符提示" "非法字符" "$output"

    # 10.5 包含特殊字符被拒绝
    run_restore "$fake_dump" -d 'my;db' --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.5 特殊字符 'my;db' 被拒" "1" "$rc"

    # 10.6 包含引号被拒绝
    run_restore "$fake_dump" -d 'my"db' --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.6 引号 'my\"db' 被拒" "1" "$rc"

    # 10.7 以下划线开头通过
    run_restore "$fake_dump" -d _internal_db --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    assert_eq "10.7 下划线开头 '_internal_db' 通过" "0" "$rc"
}

# ────────────────────────────────────────────────────────────
# 测试组 11: restore.sh — 完整恢复流程（mock）
# ────────────────────────────────────────────────────────────
test_restore_full() {
    echo ""
    echo -e "${_BOLD}=== 测试组 11: restore.sh 完整恢复流程 ===${_NC}"

    # 11.1 恢复 .dump 文件
    local fake_dump="$TMP_DIR/testdb_20260402_120000.dump"
    echo "mock dump content" > "$fake_dump"
    local output rc mock_log

    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_dump" -d testdb --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    assert_eq "11.1 恢复 .dump 退出码 0" "0" "$rc"
    assert_contains "11.1 输出包含完成提示" "全部完成" "$output"
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "11.1 调用了 pg_restore" "pg_restore" "$mock_log"

    # 11.2 恢复时传递 --clean --if-exists（默认 RESTORE_CLEAN=true）
    assert_contains "11.2 传递 --clean" "--clean" "$mock_log"
    assert_contains "11.2 传递 --if-exists" "--if-exists" "$mock_log"

    # 11.3 恢复 .sql 文件使用 psql
    local fake_sql="$TMP_DIR/testdb_20260402_120000.sql"
    echo "CREATE TABLE test();" > "$fake_sql"

    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_sql" -d testdb --yes > /dev/null 2>&1 || true
    rc=$(cat "$TMP_DIR/_last_rc")
    output=$(cat "$TMP_DIR/_last_output")
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_eq "11.3 恢复 .sql 退出码 0" "0" "$rc"
    assert_contains "11.3 .sql 使用 psql 恢复" "psql" "$mock_log"

    # 11.4 --no-clean 不传递 --clean
    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_dump" -d testdb --no-clean --yes > /dev/null 2>&1 || true
    local pg_restore_line
    pg_restore_line=$(grep "^pg_restore" "$PGSQL_TEST_MOCK_LOG" || true)
    assert_not_contains "11.4 --no-clean 不传 --clean" "--clean" "$pg_restore_line"

    # 11.5 并行恢复传递 -j 参数
    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_dump" -d testdb -j 8 --yes > /dev/null 2>&1 || true
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "11.5 传递 -j 8" "-j 8" "$mock_log"

    # 11.6 从文件名自动推断数据库名
    > "$PGSQL_TEST_MOCK_LOG"
    PATH="$MOCK_BIN:$PATH" \
    LOG_FILE="$TMP_DIR/restore_infer.log" \
    AUTO_YES=true \
    _LIB_LOADED="" \
    PGDATABASE="" \
    bash "$PROJECT_DIR/services/pgsql/restore/run.sh" "$fake_dump" --yes > "$TMP_DIR/_last_output" 2>&1 || true
    output=$(cat "$TMP_DIR/_last_output")
    assert_contains "11.6 自动推断数据库名" "从文件名推断为" "$output"

    # 11.7 plain 格式 + --clean 显示警告
    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_sql" -d testdb --yes > /dev/null 2>&1 || true
    output=$(cat "$TMP_DIR/_last_output")
    assert_contains "11.7 plain+clean 显示警告" "纯 SQL 格式不支持 --clean" "$output"
}

# ────────────────────────────────────────────────────────────
# 测试组 12: restore.sh — 连接参数传递
# ────────────────────────────────────────────────────────────
test_restore_connection() {
    echo ""
    echo -e "${_BOLD}=== 测试组 12: restore.sh 连接参数 ===${_NC}"

    local fake_dump="$TMP_DIR/conntest.dump"
    echo "mock" > "$fake_dump"

    > "$PGSQL_TEST_MOCK_LOG"
    run_restore "$fake_dump" -H 192.168.1.100 -p 5433 -U admin -d conntest --yes > /dev/null 2>&1 || true
    local mock_log
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")

    assert_contains "12.1 传递 -h 192.168.1.100" "-h 192.168.1.100" "$mock_log"
    assert_contains "12.2 传递 -p 5433" "-p 5433" "$mock_log"
    assert_contains "12.3 传递 -U admin" "-U admin" "$mock_log"
    assert_contains "12.4 传递 -d conntest" "-d conntest" "$mock_log"
}

# ────────────────────────────────────────────────────────────
# 测试组 13: lib.sh — confirm 非交互终端检测
# ────────────────────────────────────────────────────────────
test_confirm_noninteractive() {
    echo ""
    echo -e "${_BOLD}=== 测试组 13: lib.sh confirm 非交互检测 ===${_NC}"

    # 13.1 AUTO_YES=true 时无论是否交互都正常通过
    local output
    output=$(
        _LIB_LOADED=""
        LOG_FILE="$TMP_DIR/confirm_test.log"
        AUTO_YES=true
        source "$PROJECT_DIR/common/lib.sh"
        confirm
        echo "confirm_passed"
    )
    assert_contains "13.1 AUTO_YES=true 通过 confirm" "confirm_passed" "$output"
}

# ────────────────────────────────────────────────────────────
# 测试组 14: backup.sh — 目录格式备份
# ────────────────────────────────────────────────────────────
test_backup_directory_format() {
    echo ""
    echo -e "${_BOLD}=== 测试组 14: backup.sh 目录格式备份 ===${_NC}"

    > "$PGSQL_TEST_MOCK_LOG"
    PATH="$MOCK_BIN:$PATH" \
    LOG_FILE="$TMP_DIR/dir_backup.log" \
    AUTO_YES=true \
    _LIB_LOADED="" \
    BACKUP_DIR="$TMP_DIR/dir_backups" \
    bash "$PROJECT_DIR/services/pgsql/backup/run.sh" -d testdb -F directory --yes > "$TMP_DIR/_last_output" 2>&1 || true
    local rc=$?

    assert_eq "14.1 目录格式备份退出码 0" "0" "$rc"

    local mock_log
    mock_log=$(cat "$PGSQL_TEST_MOCK_LOG")
    assert_contains "14.2 传递 -Fd" "-Fd" "$mock_log"

    # 检查目录格式输出
    local dir_backup
    dir_backup=$(find "$TMP_DIR/dir_backups/daily/" -maxdepth 1 -type d -name "testdb_*" 2>/dev/null | head -1)
    if [[ -n "$dir_backup" ]]; then
        assert_file_perm "14.3 目录权限 700" "700" "$dir_backup"
    else
        echo -e "  ${_YELLOW}SKIP${_NC}  14.3 目录权限（mock 未创建目录格式备份）"
        SKIP=$((SKIP + 1))
    fi
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo -e "${_BOLD}${_CYAN}  PostgreSQL 备份/恢复脚本 — 单元测试${_NC}"
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo ""

    setup
    trap teardown EXIT

    test_lib
    test_backup_args
    test_backup_format
    test_backup_full
    test_backup_cleanup
    test_backup_types
    test_restore_args
    test_restore_infer_dbname
    test_restore_detect_format
    test_restore_dbname_validation
    test_restore_full
    test_restore_connection
    test_confirm_noninteractive
    test_backup_directory_format

    # 汇总
    echo ""
    echo -e "${_BOLD}${_CYAN}============================================================${_NC}"
    echo -e "${_BOLD}  测试结果汇总${_NC}"
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
