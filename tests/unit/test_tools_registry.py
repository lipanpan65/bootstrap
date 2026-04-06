from __future__ import annotations

from bootstrap.tools.registry import canonical_tool_name, get_schema, list_tools


def test_list_tools_contains_namespaced_entries() -> None:
    tools = list_tools()

    assert "pgsql.backup" in tools
    assert "k8s.kubeadm.init" in tools
    assert "k8s.kind.create" in tools


def test_alias_maps_to_canonical_name() -> None:
    assert canonical_tool_name("pgsql_backup") == "pgsql.backup"
    assert canonical_tool_name("k8s_init") == "k8s.kubeadm.init"


def test_get_schema_supports_alias_name() -> None:
    schema = get_schema("pgsql_backup")

    assert "properties" in schema
    assert "database" in schema["properties"]
    assert schema["properties"]["database"]["type"] == "string"
