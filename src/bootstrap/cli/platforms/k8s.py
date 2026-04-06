from __future__ import annotations

import json
from typing import Annotated

import typer

from bootstrap.core.platforms.k8s.kind import (
    create_cluster,
    delete_cluster,
    install_tools,
    show_status,
)
from bootstrap.core.platforms.k8s.kubeadm import (
    install_dashboard,
    label_workers,
    run_init,
    run_join,
)
from bootstrap.models.platforms.k8s import (
    KindCommandResult,
    KindCreateParams,
    KindDeleteParams,
    KindInstallParams,
    KindStatusParams,
    KubeadmCommandResult,
    KubeadmDashboardParams,
    KubeadmInitParams,
    KubeadmJoinParams,
)

app = typer.Typer(help="Kubernetes 相关能力", no_args_is_help=True)
kubeadm_app = typer.Typer(help="kubeadm 集群操作", no_args_is_help=True)
kind_app = typer.Typer(help="kind 学习集群操作", no_args_is_help=True)


def _output_mode(ctx: typer.Context) -> str:
    return (ctx.obj or {}).get("output", "text")


def _print_json(data: object) -> None:
    typer.echo(json.dumps(data, indent=2, ensure_ascii=False))


def _print_kind_result(result: KindCommandResult) -> None:
    typer.echo(result.summary)
    if result.cluster_name:
        typer.echo(f"集群: {result.cluster_name}")
    typer.echo(f"退出码: {result.returncode}")


def _print_kubeadm_result(result: KubeadmCommandResult) -> None:
    typer.echo(result.summary)
    typer.echo(f"动作: {result.action}")
    typer.echo(f"退出码: {result.returncode}")


@kubeadm_app.command("init")
def kubeadm_init(
    ctx: typer.Context,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    result = run_init(KubeadmInitParams(yes=yes))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kubeadm_result(result)
    raise typer.Exit(code=result.returncode)


@kubeadm_app.command("join")
def kubeadm_join(
    ctx: typer.Context,
    join_command: Annotated[str | None, typer.Option("--join-command", help="非交互 join 命令")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    result = run_join(KubeadmJoinParams(join_command=join_command, yes=yes))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kubeadm_result(result)
    raise typer.Exit(code=result.returncode)


@kubeadm_app.command("label-workers")
def kubeadm_label_workers(ctx: typer.Context) -> None:
    result = label_workers()
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kubeadm_result(result)
    raise typer.Exit(code=result.returncode)


@kubeadm_app.command("dashboard")
def kubeadm_dashboard(
    ctx: typer.Context,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    result = install_dashboard(KubeadmDashboardParams(yes=yes))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kubeadm_result(result)
    raise typer.Exit(code=result.returncode)


@kind_app.command("create")
def kind_create(
    ctx: typer.Context,
    name: Annotated[str, typer.Option("--name", "-n", help="集群名称")] = "learn",
    workers: Annotated[int, typer.Option("--workers", "-w", help="worker 数量")] = 2,
    kind_version: Annotated[str | None, typer.Option("--kind-version", help="kind 版本")] = None,
    mirror: Annotated[str | None, typer.Option("--mirror", help="镜像加速地址")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    result = create_cluster(
        KindCreateParams(
            name=name,
            workers=workers,
            kind_version=kind_version,
            mirror=mirror,
            yes=yes,
        )
    )
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kind_result(result)
    raise typer.Exit(code=result.returncode)


@kind_app.command("install")
def kind_install(
    ctx: typer.Context,
    kind_version: Annotated[str | None, typer.Option("--kind-version", help="kind 版本")] = None,
    mirror: Annotated[str | None, typer.Option("--mirror", help="镜像加速地址")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
) -> None:
    result = install_tools(KindInstallParams(kind_version=kind_version, mirror=mirror, yes=yes))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kind_result(result)
    raise typer.Exit(code=result.returncode)


@kind_app.command("delete")
def kind_delete(
    ctx: typer.Context,
    name: Annotated[str, typer.Option("--name", "-n", help="集群名称")] = "learn",
) -> None:
    result = delete_cluster(KindDeleteParams(name=name))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kind_result(result)
    raise typer.Exit(code=result.returncode)


@kind_app.command("status")
def kind_status(
    ctx: typer.Context,
    name: Annotated[str, typer.Option("--name", "-n", help="集群名称")] = "learn",
) -> None:
    result = show_status(KindStatusParams(name=name))
    if _output_mode(ctx) == "json":
        _print_json(result.model_dump())
    else:
        _print_kind_result(result)
    raise typer.Exit(code=result.returncode)


app.add_typer(kubeadm_app, name="kubeadm")
app.add_typer(kind_app, name="kind")
