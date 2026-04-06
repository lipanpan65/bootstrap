from __future__ import annotations

from unittest.mock import patch

from bootstrap.core.platforms.k8s.kind import create_cluster, show_status
from bootstrap.models.platforms.k8s import KindCreateParams, KindStatusParams
from bootstrap.utils.shell import CommandResult


def test_create_cluster_returns_structured_result() -> None:
    params = KindCreateParams(name="dev", workers=2, yes=True)

    with patch("bootstrap.core.platforms.k8s.kind._script", return_value="/tmp/kind.sh"):
        with patch(
            "bootstrap.core.platforms.k8s.kind.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="集群创建完成",
                stderr="",
            ),
        ) as mock_run:
            result = create_cluster(params)

    args = mock_run.call_args.args[0]
    assert result.success is True
    assert result.cluster_name == "dev"
    assert result.returncode == 0
    assert result.summary == "kind 集群创建成功"
    assert args[:2] == ["/tmp/kind.sh", "create"]
    assert ["--name", "dev"] in [args[i : i + 2] for i in range(len(args) - 1)]
    assert ["--workers", "2"] in [args[i : i + 2] for i in range(len(args) - 1)]
    assert "--yes" in args


def test_show_status_returns_structured_result() -> None:
    params = KindStatusParams(name="learn")

    with patch("bootstrap.core.platforms.k8s.kind._script", return_value="/tmp/kind.sh"):
        with patch(
            "bootstrap.core.platforms.k8s.kind.run_command",
            return_value=CommandResult(
                args=[],
                returncode=0,
                stdout="集群状态输出",
                stderr="",
            ),
        ):
            result = show_status(params)

    assert result.success is True
    assert result.cluster_name == "learn"
    assert result.summary == "kind 集群状态获取成功"
