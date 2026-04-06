from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated

import typer

from bootstrap.core.services.pgsql import list_backups, run_backup, run_restore
from bootstrap.models.services.pgsql import (
    PgsqlBackupParams,
    PgsqlBackupResult,
    PgsqlListBackupsParams,
    PgsqlRestoreParams,
    PgsqlRestoreResult,
)

app = typer.Typer(help="PostgreSQL 备份与恢复", no_args_is_help=True)


def _output_mode(ctx: typer.Context) -> str:
    return (ctx.obj or {}).get("output", "text")


def _print_command_result(result: PgsqlBackupResult | PgsqlRestoreResult) -> None:
    typer.echo(result.summary)
    if isinstance(result, PgsqlBackupResult):
        typer.echo(f"数据库: {result.database}")
        if result.backup_file:
            typer.echo(f"备份文件: {result.backup_file}")
    if isinstance(result, PgsqlRestoreResult):
        if result.database:
            typer.echo(f"目标数据库: {result.database}")
        typer.echo(f"备份文件: {result.backup_file}")
    typer.echo(f"退出码: {result.returncode}")


def _print_json(data: object) -> None:
    typer.echo(json.dumps(data, indent=2, ensure_ascii=False))


@app.command()
def backup(
    ctx: typer.Context,
    database: Annotated[str, typer.Option("--database", "-d", help="数据库名")],
    host: Annotated[str, typer.Option("--host", "-H", help="数据库地址")] = "127.0.0.1",
    port: Annotated[int, typer.Option("--port", "-p", help="数据库端口")] = 5432,
    user: Annotated[str, typer.Option("--user", "-U", help="数据库用户名")] = "postgres",
    format: Annotated[str, typer.Option("--format", "-F", help="备份格式")] = "custom",
    compress: Annotated[int, typer.Option("--compress", "-Z", help="压缩级别")] = 6,
    table: Annotated[list[str] | None, typer.Option("--table", "-t", help="仅备份指定表")] = None,
    exclude_table: Annotated[list[str] | None, typer.Option("--exclude-table", "-T", help="排除指定表")] = None,
    schema_only: Annotated[bool, typer.Option("--schema-only", help="只备份结构")] = False,
    data_only: Annotated[bool, typer.Option("--data-only", help="只备份数据")] = False,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    params = PgsqlBackupParams(
        database=database,
        host=host,
        port=port,
        user=user,
        format=format,
        compress=compress,
        tables=table or [],
        exclude_tables=exclude_table or [],
        schema_only=schema_only,
        data_only=data_only,
        yes=yes,
    )
    result = run_backup(params)
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_command_result(result)
    raise typer.Exit(code=result.returncode)


@app.command()
def restore(
    ctx: typer.Context,
    backup_file: Annotated[str, typer.Argument(help="备份文件路径")],
    database: Annotated[str | None, typer.Option("--database", "-d", help="目标数据库名")] = None,
    host: Annotated[str, typer.Option("--host", "-H", help="数据库地址")] = "127.0.0.1",
    port: Annotated[int, typer.Option("--port", "-p", help="数据库端口")] = 5432,
    user: Annotated[str, typer.Option("--user", "-U", help="数据库用户名")] = "postgres",
    jobs: Annotated[int, typer.Option("--jobs", "-j", help="并发恢复线程数")] = 4,
    clean: Annotated[bool, typer.Option("--clean/--no-clean", help="恢复前是否清理旧对象")] = True,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    params = PgsqlRestoreParams(
        backup_file=backup_file,
        database=database,
        host=host,
        port=port,
        user=user,
        jobs=jobs,
        clean=clean,
        yes=yes,
    )
    result = run_restore(params)
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_command_result(result)
    raise typer.Exit(code=result.returncode)


@app.command("list-backups")
def list_backups_command(
    ctx: typer.Context,
    output_dir: Annotated[str, typer.Option("--output-dir", help="备份目录")] = "/data/backup/pgsql",
) -> None:
    backups = list_backups(PgsqlListBackupsParams(output_dir=output_dir))
    if _output_mode(ctx) == "json":
        _print_json([backup.model_dump() for backup in backups])
        return
    for backup in backups:
        typer.echo(f"{Path(backup.path)} ({backup.size_bytes} bytes)")
