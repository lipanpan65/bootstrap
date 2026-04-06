from __future__ import annotations

import json
from typing import Annotated

import typer

from bootstrap.tools.registry import get_schema, list_tools

app = typer.Typer(help="查看可用 Tool 及其 Schema", no_args_is_help=True)


@app.command("list")
def list_command() -> None:
    for name in list_tools():
        typer.echo(name)


@app.command("schema")
def schema_command(
    name: Annotated[str, typer.Argument(help="Tool canonical 名称")],
) -> None:
    typer.echo(json.dumps(get_schema(name), indent=2, ensure_ascii=False))
