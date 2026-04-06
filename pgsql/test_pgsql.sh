#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../services/pgsql/tests/test_pgsql.sh"

if [[ ! -f "${TARGET_SCRIPT}" ]]; then
    echo "兼容入口失败：未找到新路径脚本 ${TARGET_SCRIPT}" >&2
    exit 1
fi

exec bash "${TARGET_SCRIPT}" "$@"
