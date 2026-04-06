from __future__ import annotations

from bootstrap.models.platforms.k8s import (
    KindCommandResult,
    KindCreateParams,
    KindDeleteParams,
    KindInstallParams,
    KindStatusParams,
)
from bootstrap.utils.shell import resolve_script, run_command


def _script() -> str:
    return str(
        resolve_script(
            "platforms/k8s/kind/install.sh",
            "kind/install.sh",
        )
    )


def _append_common_flags(
    args: list[str],
    *,
    name: str | None = None,
    kind_version: str | None = None,
    mirror: str | None = None,
    yes: bool = False,
    workers: int | None = None,
) -> list[str]:
    if name:
        args.extend(["--name", name])
    if workers is not None:
        args.extend(["--workers", str(workers)])
    if kind_version:
        args.extend(["--kind-version", kind_version])
    if mirror:
        args.extend(["--mirror", mirror])
    if yes:
        args.append("--yes")
    return args


def _result_for(action: str, cluster_name: str | None, args: list[str]) -> KindCommandResult:
    result = run_command(args)
    summary_map = {
        "create": "kind 集群创建成功",
        "install": "kind 工具安装成功",
        "delete": "kind 集群删除成功",
        "status": "kind 集群状态获取成功",
    }
    failure_map = {
        "create": "kind 集群创建失败",
        "install": "kind 工具安装失败",
        "delete": "kind 集群删除失败",
        "status": "kind 集群状态获取失败",
    }
    next_actions: list[str] = []
    if result.returncode == 0:
        if action == "create" and cluster_name:
            next_actions.append(f"可继续查看状态: bootstrap k8s kind status --name {cluster_name}")
        elif action == "install":
            next_actions.append("可继续创建集群: bootstrap k8s kind create --yes")
        elif action == "status" and cluster_name:
            next_actions.append(f"可继续删除集群: bootstrap k8s kind delete --name {cluster_name}")
    else:
        next_actions.append("检查 stdout/stderr 及脚本日志输出")
    return KindCommandResult(
        success=result.returncode == 0,
        returncode=result.returncode,
        command=result.args,
        stdout=result.stdout,
        stderr=result.stderr,
        summary=summary_map[action] if result.returncode == 0 else failure_map[action],
        next_actions=next_actions,
        cluster_name=cluster_name,
    )


def create_cluster(params: KindCreateParams) -> KindCommandResult:
    args = _append_common_flags(
        [_script(), "create"],
        name=params.name,
        workers=params.workers,
        kind_version=params.kind_version,
        mirror=params.mirror,
        yes=params.yes,
    )
    return _result_for("create", params.name, args)


def install_tools(params: KindInstallParams) -> KindCommandResult:
    args = _append_common_flags(
        [_script(), "install"],
        kind_version=params.kind_version,
        mirror=params.mirror,
        yes=params.yes,
    )
    return _result_for("install", None, args)


def delete_cluster(params: KindDeleteParams) -> KindCommandResult:
    args = _append_common_flags([_script(), "delete"], name=params.name)
    return _result_for("delete", params.name, args)


def show_status(params: KindStatusParams) -> KindCommandResult:
    args = _append_common_flags([_script(), "status"], name=params.name)
    return _result_for("status", params.name, args)
