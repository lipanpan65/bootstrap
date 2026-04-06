from __future__ import annotations

from unittest.mock import patch

from bootstrap.core.platforms.k8s.kubeadm import install_dashboard, run_init, run_join
from bootstrap.models.platforms.k8s import (
    KubeadmDashboardParams,
    KubeadmInitParams,
    KubeadmJoinParams,
)
from bootstrap.utils.shell import CommandResult


def test_run_init_returns_structured_result() -> None:
    with patch("bootstrap.core.platforms.k8s.kubeadm._script", return_value="/tmp/kubeadm.sh"):
        with patch(
            "bootstrap.core.platforms.k8s.kubeadm.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="初始化完成",
                stderr="",
            ),
        ) as mock_run:
            result = run_init(KubeadmInitParams(yes=True))

    args = mock_run.call_args.args[0]
    assert result.success is True
    assert result.returncode == 0
    assert result.action == "init"
    assert result.summary == "kubeadm 初始化成功"
    assert args == ["/tmp/kubeadm.sh", "master", "--yes"]


def test_run_join_passes_join_command_input() -> None:
    with patch("bootstrap.core.platforms.k8s.kubeadm._script", return_value="/tmp/kubeadm.sh"):
        with patch(
            "bootstrap.core.platforms.k8s.kubeadm.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="加入成功",
                stderr="",
            ),
        ) as mock_run:
            result = run_join(
                KubeadmJoinParams(join_command="kubeadm join 1.1.1.1:6443 --token abc", yes=True)
            )

    assert result.success is True
    assert result.action == "join"
    assert mock_run.call_args.kwargs["input_text"] == "kubeadm join 1.1.1.1:6443 --token abc\n"


def test_install_dashboard_returns_structured_result() -> None:
    with patch("bootstrap.core.platforms.k8s.kubeadm._script", return_value="/tmp/kubeadm.sh"):
        with patch(
            "bootstrap.core.platforms.k8s.kubeadm.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="dashboard 安装完成",
                stderr="",
            ),
        ):
            result = install_dashboard(KubeadmDashboardParams(yes=True))

    assert result.success is True
    assert result.action == "dashboard"
    assert result.summary == "Dashboard 安装成功"
