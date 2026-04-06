# CLAUDE.md — bootstrap 项目规范

## 项目概述

`bootstrap` 是一个以 Bash 为主、以 Python CLI 为辅助入口的基础设施脚本仓库。当前主结构已经收敛到：

- `platforms/`：平台能力，如 `k8s/kubeadm`、`k8s/kind`
- `services/`：服务能力，如 `pgsql`
- `observability/`：可观测性能力，如 `prometheus`

旧顶层兼容目录已经移除，新路径是唯一入口。

## 目录结构

```text
bootstrap/
├── install.sh
├── common/lib.sh
├── platforms/k8s/kubeadm/install.sh
├── platforms/k8s/kind/install.sh
├── services/pgsql/backup/run.sh
├── services/pgsql/restore/run.sh
├── services/pgsql/tests/test_pgsql.sh
├── services/pgsql/tests/test_integration.sh
├── observability/prometheus/install.sh
├── src/bootstrap/
├── tests/unit/
└── docs/
    ├── README.md
    ├── architecture/
    ├── cli-refactor-design.md
    ├── plans/
    ├── platforms/
    ├── services/
    └── observability/
```

## Bash 约定

- 所有脚本使用 `#!/usr/bin/env bash`
- 所有脚本使用 `set -euo pipefail`
- 通过 `_load_lib` 加载 `common/lib.sh`
- 使用 `log` / `ok` / `warn` / `error` / `step` / `info`
- 关键操作前使用 `confirm`，支持 `--yes` / `-y`
- 对外示例一律使用最终路径，不再引用历史兼容路径

## 命名约定

- Kubernetes 真实节点能力统一放在 `platforms/k8s/kubeadm/`
- Kind 能力统一放在 `platforms/k8s/kind/`
- PostgreSQL 统一放在 `services/pgsql/`
- Prometheus 统一放在 `observability/prometheus/`
- Python CLI 只保留 canonical 命令，不保留下划线 Tool 名称或短别名

## 文档约定

- 文档总分类与命名规则见 `docs/README.md`
- 稳定架构说明放在 `docs/architecture/`
- 稳定使用文档放在 `docs/platforms/`、`docs/services/`、`docs/observability/`
- 规划、路线图、演进设计放在 `docs/plans/`
- `docs/cli-refactor-design.md` 当前保留在 `docs/` 根目录，作为跨领域稳定设计说明

## 测试约定

### Python

```bash
uv run pytest tests/unit -v
```

### PostgreSQL Bash

```bash
bash services/pgsql/tests/test_pgsql.sh
bash services/pgsql/tests/test_integration.sh
```

`test_integration.sh` 需要两套真实 PostgreSQL：

- `pg-source`：`127.0.0.1:5434/testdb`
- `pg-target`：`127.0.0.1:5433`

## Python / uv 开发约定

- Python 版本固定为 `.python-version` 中声明的版本
- 使用 `uv sync --dev` 安装依赖
- 使用 `uv run ...` 执行 CLI、测试和辅助脚本
- 若新增依赖，应同步更新 `pyproject.toml` 和 `uv.lock`
