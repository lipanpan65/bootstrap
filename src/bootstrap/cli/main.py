from __future__ import annotations

from typing import Annotated

import typer

from bootstrap import __version__
from bootstrap.cli.platforms.k8s import app as k8s_app
from bootstrap.cli.services.pgsql import app as pgsql_app
from bootstrap.cli.tools import app as tools_app

app = typer.Typer(
    name="bootstrap",
    help="基础设施初始化工具",
    no_args_is_help=True,
)

app.add_typer(pgsql_app, name="pgsql", help="PostgreSQL 备份与恢复")
app.add_typer(k8s_app, name="k8s", help="Kubernetes 相关操作")
app.add_typer(tools_app, name="tools", help="Tool 元数据与 Schema")


@app.callback()
def main(
    ctx: typer.Context,
    output: Annotated[str, typer.Option("--output", "-o", help="输出格式")] = "text",
) -> None:
    ctx.ensure_object(dict)
    ctx.obj["output"] = output


@app.command("version")
def version() -> None:
    typer.echo(__version__)
