# bootstrap

> 基础设施初始化与运维脚本仓库，统一收敛到领域化目录结构与 Python CLI。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- <service> [args...]
```

当前根入口支持：

- `k8s`
- `kind`
- `prometheus`

## 本地直接执行

```bash
# kubeadm 集群
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers

# kind 学习集群
sudo ./platforms/k8s/kind/install.sh create --yes
sudo ./platforms/k8s/kind/install.sh status
sudo ./platforms/k8s/kind/install.sh delete

# PostgreSQL 备份与恢复
./services/pgsql/backup/run.sh -d mydb --yes
./services/pgsql/restore/run.sh mydb.dump -d mydb_new --yes

# Prometheus
sudo ./observability/prometheus/install.sh server --yes
sudo ./observability/prometheus/install.sh all --yes
```

## Python CLI

推荐使用 `uv` 管理开发环境：

```bash
uv python install 3.11
uv venv --python 3.11
source .venv/bin/activate
uv sync --dev
```

常用命令：

```bash
uv run bootstrap --help
uv run bootstrap version

uv run bootstrap pgsql backup -d mydb --yes
uv run bootstrap pgsql restore mydb.dump -d mydb_new --yes

uv run bootstrap k8s kubeadm init --yes
uv run bootstrap k8s kubeadm join
uv run bootstrap k8s kind create --name dev --yes

uv run bootstrap tools list
uv run bootstrap tools schema pgsql.backup
```

CLI 只保留 canonical 命名：

- `bootstrap k8s kubeadm init`
- `bootstrap k8s kubeadm join`
- `bootstrap k8s kubeadm label-workers`
- `bootstrap k8s kubeadm dashboard`
- `bootstrap k8s kind create`
- `bootstrap tools schema pgsql.backup`

## 测试

```bash
# Python 单元测试
uv run pytest tests/unit -v

# PostgreSQL Bash 单元测试
bash services/pgsql/tests/test_pgsql.sh

# PostgreSQL Bash 集成测试
bash services/pgsql/tests/test_integration.sh
```

`services/pgsql/tests/test_integration.sh` 需要：

- `pg-source`：`127.0.0.1:5434/testdb`
- `pg-target`：`127.0.0.1:5433`
- 可用的 `pg_dump`、`pg_restore`、`psql`、`pg_isready`

## 目录结构

```text
bootstrap/
├── install.sh
├── common/
│   └── lib.sh
├── platforms/
│   └── k8s/
│       ├── README.md
│       ├── kubeadm/
│       │   ├── install.sh
│       │   └── README.md
│       └── kind/
│           ├── install.sh
│           └── README.md
├── services/
│   └── pgsql/
│       ├── README.md
│       ├── backup/
│       │   └── run.sh
│       ├── restore/
│       │   └── run.sh
│       └── tests/
│           ├── test_pgsql.sh
│           └── test_integration.sh
├── observability/
│   └── prometheus/
│       ├── install.sh
│       └── README.md
├── src/
│   └── bootstrap/
├── tests/
│   └── unit/
└── docs/
    ├── README.md
    ├── architecture/
    ├── cli-refactor-design.md
    ├── plans/
    ├── platforms/
    ├── services/
    └── observability/
```

## 文档

- [Docs 总说明](docs/README.md)
- [架构文档说明](docs/architecture/README.md)
- [Kubernetes 安装](docs/platforms/k8s/install.md)
- [Kubernetes Dashboard](docs/platforms/k8s/dashboard.md)
- [kubeadm 说明](docs/platforms/k8s/kubeadm.md)
- [Kind 说明](docs/platforms/k8s/kind.md)
- [PostgreSQL 备份恢复](docs/services/pgsql/backup-restore.md)
- [PostgreSQL 测试方案](docs/services/pgsql/test-plan.md)
- [Prometheus 安装](docs/observability/prometheus/install.md)
- [CLI 设计与结构](docs/cli-refactor-design.md)
- [规划与路线图](docs/plans/README.md)
