from __future__ import annotations

from bootstrap.models.platforms.k8s import (
    KubeadmCommandResult,
    KubeadmDashboardParams,
    KubeadmInitParams,
    KubeadmJoinParams,
)
from bootstrap.utils.shell import resolve_script, run_command


def _script() -> str:
    return str(resolve_script("platforms/k8s/kubeadm/install.sh"))


def _result_for(action: str, args: list[str], input_text: str | None = None) -> KubeadmCommandResult:
    result = run_command(args, input_text=input_text)
    summary_map = {
        "init": "kubeadm 初始化成功",
        "join": "kubeadm 节点加入成功",
        "label-workers": "worker 标签操作成功",
        "dashboard": "Dashboard 安装成功",
    }
    failure_map = {
        "init": "kubeadm 初始化失败",
        "join": "kubeadm 节点加入失败",
        "label-workers": "worker 标签操作失败",
        "dashboard": "Dashboard 安装失败",
    }
    next_actions: list[str] = []
    if result.returncode == 0:
        if action == "init":
            next_actions.append("可继续执行 kubeadm join 或安装 dashboard")
        elif action == "join":
            next_actions.append("可回到 master 节点执行 label-workers")
        elif action == "dashboard":
            next_actions.append("可继续检查 kubernetes-dashboard 命名空间状态")
    else:
        next_actions.append("检查 stdout/stderr 及脚本日志输出")
    return KubeadmCommandResult(
        success=result.returncode == 0,
        returncode=result.returncode,
        command=result.args,
        stdout=result.stdout,
        stderr=result.stderr,
        summary=summary_map[action] if result.returncode == 0 else failure_map[action],
        next_actions=next_actions,
        action=action,
    )


def run_init(params: KubeadmInitParams) -> KubeadmCommandResult:
    args = [_script(), "master"]
    if params.yes:
        args.append("--yes")
    return _result_for("init", args)


def run_join(params: KubeadmJoinParams) -> KubeadmCommandResult:
    args = [_script(), "worker"]
    if params.yes:
        args.append("--yes")
    input_text = f"{params.join_command.strip()}\n" if params.join_command else None
    return _result_for("join", args, input_text=input_text)


def label_workers() -> KubeadmCommandResult:
    return _result_for("label-workers", [_script(), "label-workers"])


def install_dashboard(params: KubeadmDashboardParams) -> KubeadmCommandResult:
    args = [_script(), "dashboard"]
    if params.yes:
        args.append("--yes")
    return _result_for("dashboard", args)
