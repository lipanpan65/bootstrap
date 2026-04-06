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


def list_tools() -> list[str]:
    return sorted(TOOL_MODELS.keys())


def canonical_tool_name(name: str) -> str:
    return name


def get_schema(name: str) -> dict:
    canonical_name = canonical_tool_name(name)
    model = TOOL_MODELS[canonical_name]
    return model.model_json_schema()
