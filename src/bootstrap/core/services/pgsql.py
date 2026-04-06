from __future__ import annotations

import re
from pathlib import Path

from bootstrap.models.services.pgsql import (
    PgsqlBackupParams,
    PgsqlBackupFile,
    PgsqlBackupResult,
    PgsqlListBackupsParams,
    PgsqlRestoreParams,
    PgsqlRestoreResult,
)
from bootstrap.utils.shell import resolve_script, run_command


def _extract_backup_file(stdout: str) -> str | None:
    match = re.search(r"文件:\s+(\S+)", stdout)
    if match:
        return match.group(1)
    return None


def run_backup(params: PgsqlBackupParams) -> PgsqlBackupResult:
    script = resolve_script(
        "services/pgsql/backup/run.sh",
        "pgsql/backup.sh",
    )
    args = [
        str(script),
        "-d",
        params.database,
        "-H",
        params.host,
        "-p",
        str(params.port),
        "-U",
        params.user,
        "-F",
        params.format,
        "-Z",
        str(params.compress),
    ]
    for table in params.tables:
        args.extend(["-t", table])
    for table in params.exclude_tables:
        args.extend(["-T", table])
    if params.schema_only:
        args.append("--schema-only")
    if params.data_only:
        args.append("--data-only")
    if params.yes:
        args.append("--yes")
    result = run_command(args)
    backup_file = _extract_backup_file(result.stdout)
    next_actions: list[str] = []
    if result.returncode == 0 and backup_file:
        next_actions.append(f"可使用 restore 恢复该备份: {backup_file}")
    elif result.returncode != 0:
        next_actions.append("检查 stdout/stderr 及 Bash 日志输出")
    return PgsqlBackupResult(
        success=result.returncode == 0,
        returncode=result.returncode,
        command=result.args,
        stdout=result.stdout,
        stderr=result.stderr,
        summary="备份成功" if result.returncode == 0 else "备份失败",
        next_actions=next_actions,
        database=params.database,
        backup_file=backup_file,
    )


def run_restore(params: PgsqlRestoreParams) -> PgsqlRestoreResult:
    script = resolve_script(
        "services/pgsql/restore/run.sh",
        "pgsql/restore.sh",
    )
    args = [
        str(script),
        params.backup_file,
        "-H",
        params.host,
        "-p",
        str(params.port),
        "-U",
        params.user,
        "-j",
        str(params.jobs),
    ]
    if params.database:
        args.extend(["-d", params.database])
    args.append("--clean" if params.clean else "--no-clean")
    if params.yes:
        args.append("--yes")
    result = run_command(args)
    next_actions: list[str] = []
    if result.returncode == 0:
        next_actions.append("可连接目标数据库进行数据校验")
    else:
        next_actions.append("检查 stdout/stderr 及 Bash 日志输出")
    return PgsqlRestoreResult(
        success=result.returncode == 0,
        returncode=result.returncode,
        command=result.args,
        stdout=result.stdout,
        stderr=result.stderr,
        summary="恢复成功" if result.returncode == 0 else "恢复失败",
        next_actions=next_actions,
        database=params.database,
        backup_file=params.backup_file,
    )


def list_backups(params: PgsqlListBackupsParams) -> list[PgsqlBackupFile]:
    backup_dir = Path(params.output_dir)
    if not backup_dir.exists():
        return []
    files = sorted((path for path in backup_dir.rglob("*") if path.is_file()), reverse=True)
    return [
        PgsqlBackupFile(path=str(path), size_bytes=path.stat().st_size)
        for path in files
    ]
