from __future__ import annotations

from unittest.mock import patch

from typer.testing import CliRunner

from bootstrap.cli.main import app


runner = CliRunner()


def test_top_level_help_shows_command_groups() -> None:
    result = runner.invoke(app, ["--help"])

    assert result.exit_code == 0
    assert "pgsql" in result.stdout
    assert "k8s" in result.stdout
    assert "tools" in result.stdout


def test_k8s_help_shows_nested_groups() -> None:
    result = runner.invoke(app, ["k8s", "--help"])

    assert result.exit_code == 0
    assert "kubeadm" in result.stdout
    assert "kind" in result.stdout
    assert "kubeadm" in result.stdout


def test_kubeadm_nested_help_is_available() -> None:
    result = runner.invoke(app, ["k8s", "kubeadm", "init", "--help"])

    assert result.exit_code == 0
    assert "--yes" in result.stdout


def test_kind_nested_help_is_available() -> None:
    result = runner.invoke(app, ["k8s", "kind", "create", "--help"])

    assert result.exit_code == 0
    assert "--workers" in result.stdout
    assert "--kind-version" in result.stdout


def test_tools_schema_supports_canonical_name() -> None:
    result = runner.invoke(app, ["tools", "schema", "pgsql.backup"])

    assert result.exit_code == 0
    assert "database" in result.stdout


def test_pgsql_backup_supports_json_output() -> None:
    with patch("bootstrap.cli.services.pgsql.run_backup") as mock_run:
        mock_run.return_value.model_dump.return_value = {
            "success": True,
            "returncode": 0,
            "summary": "备份成功",
            "database": "appdb",
            "backup_file": "/tmp/appdb.dump",
        }
        mock_run.return_value.returncode = 0

        result = runner.invoke(
            app,
            ["--output", "json", "pgsql", "backup", "-d", "appdb", "--yes"],
        )

    assert result.exit_code == 0
    assert '"success": true' in result.stdout
    assert '"database": "appdb"' in result.stdout


def test_kind_create_supports_json_output() -> None:
    with patch("bootstrap.cli.platforms.k8s.create_cluster") as mock_run:
        mock_run.return_value.model_dump.return_value = {
            "success": True,
            "returncode": 0,
            "summary": "kind 集群创建成功",
            "cluster_name": "dev",
        }
        mock_run.return_value.returncode = 0

        result = runner.invoke(
            app,
            ["--output", "json", "k8s", "kind", "create", "--name", "dev", "--yes"],
        )

    assert result.exit_code == 0
    assert '"success": true' in result.stdout
    assert '"cluster_name": "dev"' in result.stdout


def test_kubeadm_init_supports_json_output() -> None:
    with patch("bootstrap.cli.platforms.k8s.run_init") as mock_run:
        mock_run.return_value.model_dump.return_value = {
            "success": True,
            "returncode": 0,
            "summary": "kubeadm 初始化成功",
            "action": "init",
        }
        mock_run.return_value.returncode = 0

        result = runner.invoke(
            app,
            ["--output", "json", "k8s", "kubeadm", "init", "--yes"],
        )

    assert result.exit_code == 0
    assert '"success": true' in result.stdout
    assert '"action": "init"' in result.stdout


def test_k8s_init_alias_is_no_longer_available() -> None:
    result = runner.invoke(app, ["k8s", "init", "--yes"])

    assert result.exit_code != 0
