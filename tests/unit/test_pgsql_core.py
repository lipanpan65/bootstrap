from __future__ import annotations

from unittest.mock import patch

from bootstrap.core.services.pgsql import run_backup, run_restore
from bootstrap.models.services.pgsql import PgsqlBackupParams, PgsqlRestoreParams
from bootstrap.utils.shell import CommandResult


def test_run_backup_builds_expected_command() -> None:
    params = PgsqlBackupParams(
        database="appdb",
        host="10.0.0.8",
        port=5433,
        user="postgres",
        format="custom",
        compress=5,
        tables=["users"],
        exclude_tables=["audit_logs"],
        schema_only=True,
        yes=True,
    )

    with patch("bootstrap.core.services.pgsql.resolve_script", return_value="/tmp/backup.sh"):
        with patch(
            "bootstrap.core.services.pgsql.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="备份完成\n文件: /data/backup/pgsql/daily/appdb_20260101_000000.dump",
                stderr="",
            ),
        ) as mock_run:
            result = run_backup(params)

    args = mock_run.call_args.args[0]
    assert result.success is True
    assert result.returncode == 0
    assert result.database == "appdb"
    assert result.backup_file == "/data/backup/pgsql/daily/appdb_20260101_000000.dump"
    assert args[:2] == ["/tmp/backup.sh", "-d"]
    assert "appdb" in args
    assert ["-H", "10.0.0.8"] == args[3:5]
    assert "--schema-only" in args
    assert "--yes" in args
    assert "-t" in args
    assert "-T" in args


def test_run_restore_builds_expected_command() -> None:
    params = PgsqlRestoreParams(
        backup_file="/data/backup/pgsql/daily/appdb.dump",
        database="appdb_restore",
        host="127.0.0.1",
        port=5432,
        user="postgres",
        jobs=8,
        clean=False,
        yes=True,
    )

    with patch("bootstrap.core.services.pgsql.resolve_script", return_value="/tmp/restore.sh"):
        with patch(
            "bootstrap.core.services.pgsql.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="恢复完成",
                stderr="",
            ),
        ) as mock_run:
            result = run_restore(params)

    args = mock_run.call_args.args[0]
    assert result.success is True
    assert result.returncode == 0
    assert result.database == "appdb_restore"
    assert result.backup_file == "/data/backup/pgsql/daily/appdb.dump"
    assert args[0] == "/tmp/restore.sh"
    assert args[1] == "/data/backup/pgsql/daily/appdb.dump"
    assert ["-d", "appdb_restore"] in [args[i : i + 2] for i in range(len(args) - 1)]
    assert ["-j", "8"] in [args[i : i + 2] for i in range(len(args) - 1)]
    assert "--no-clean" in args
    assert "--yes" in args
