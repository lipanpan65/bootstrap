from __future__ import annotations

from bootstrap.models.platforms.k8s import (
    KindCreateParams,
    KindDeleteParams,
    KindInstallParams,
    KindStatusParams,
    KubeadmDashboardParams,
    KubeadmInitParams,
    KubeadmJoinParams,
)
from bootstrap.models.services.pgsql import (
    PgsqlBackupParams,
    PgsqlListBackupsParams,
    PgsqlRestoreParams,
)


TOOL_MODELS = {
    "pgsql.backup": PgsqlBackupParams,
    "pgsql.restore": PgsqlRestoreParams,
    "pgsql.list_backups": PgsqlListBackupsParams,
    "k8s.kubeadm.init": KubeadmInitParams,
    "k8s.kubeadm.join": KubeadmJoinParams,
    "k8s.kubeadm.dashboard": KubeadmDashboardParams,
    "k8s.kind.create": KindCreateParams,
    "k8s.kind.install": KindInstallParams,
    "k8s.kind.delete": KindDeleteParams,
    "k8s.kind.status": KindStatusParams,
}

TOOL_ALIASES = {
    "pgsql_backup": "pgsql.backup",
    "pgsql_restore": "pgsql.restore",
    "pgsql_list_backups": "pgsql.list_backups",
    "k8s_init": "k8s.kubeadm.init",
    "k8s_join": "k8s.kubeadm.join",
    "k8s_dashboard": "k8s.kubeadm.dashboard",
}


def list_tools() -> list[str]:
    return sorted(TOOL_MODELS.keys())


def canonical_tool_name(name: str) -> str:
    return TOOL_ALIASES.get(name, name)


def get_schema(name: str) -> dict:
    canonical_name = canonical_tool_name(name)
    model = TOOL_MODELS[canonical_name]
    return model.model_json_schema()
