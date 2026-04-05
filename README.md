# bootstrap

> 一键服务安装工具 — 基于 `curl | bash` 的轻量化基础设施初始化脚本集

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- <service> [args...]
```

## 支持的服务

| 服务 | 说明 | 状态 |
|------|------|------|
| `k8s` | Kubernetes 集群（master / worker） | ✅ 可用 |
| `pgsql` | PostgreSQL 备份与恢复 | ✅ 可用 |
| `docker` | Docker / containerd 单独安装 | 🚧 开发中 |
| `redis` | Redis | 🚧 开发中 |
| `nginx` | Nginx | 🚧 开发中 |
| `prometheus` | Prometheus 监控（Server / Node Exporter / Alertmanager） | ✅ 可用 |

## 使用示例

### K8s 集群

```bash
# 初始化 master 节点
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s master

# 初始化 worker 节点
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s worker

# 全自动模式（跳过确认）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s master --yes

# worker 加入后，为未标记节点打上 worker 角色标签
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s label-workers
```

### PostgreSQL 备份与恢复

```bash
# 整库备份
./pgsql/backup.sh -H 10.0.0.1 -U postgres -d mydb --yes

# 只备份指定表
./pgsql/backup.sh -d mydb -t users -t orders --yes

# 排除大表
./pgsql/backup.sh -d mydb -T audit_logs --yes

# 只备份表结构
./pgsql/backup.sh -d mydb --schema-only --yes

# 恢复到指定数据库
./pgsql/restore.sh mydb_20260402_120000.dump -d mydb --yes

# 恢复到新库（自动创建）
./pgsql/restore.sh mydb.dump -d mydb_new --yes

# 查看帮助
./pgsql/backup.sh --help
./pgsql/restore.sh --help
```

### Prometheus 监控

```bash
# 安装 Prometheus Server（监控服务器��
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus server

# 安装 Node Exporter（每台被监控机器）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus node-exporter

# 安装 Alertmanager（告警管理）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus alertmanager

# 一次安装全部组件
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus all --yes

# 自定义版本和保留时间
sudo ./prometheus/install.sh server -v 2.53.4 -r 30d --yes

# 查看帮助
./prometheus/install.sh --help
```

### 直接执行子脚本（本地克隆后）

```bash
git clone https://github.com/lipanpan65/bootstrap.git
cd bootstrap

sudo ./k8s/install.sh master
sudo ./k8s/install.sh worker --yes

# worker 加入后，为未标记节点打上 worker 角色标签
sudo ./k8s/install.sh label-workers

# Prometheus 全组件安装
sudo ./prometheus/install.sh all --yes
```

## 目录结构

```
bootstrap/
├── install.sh              # 统一入口，负责服务分发
├── README.md
├── CLAUDE.md               # Claude Code 项目规范
├── LICENSE
│
├── common/
│   └── lib.sh              # 公共函数库（颜色、日志、预检等）
│
├── docs/
│   ├── k8s-install.md          # K8s 安装详解
│   ├── k8s-dashboard.md        # K8s Dashboard 详解
│   ├── pgsql-backup-restore.md # PostgreSQL 备份恢复详解
│   ├── pgsql-test-plan.md      # PostgreSQL 测试方案
│   └── prometheus-install.md   # Prometheus 安装详解
│
├── k8s/
│   └── install.sh          # K8s 集群安装（master / worker）
│
├── prometheus/
│   └─�� install.sh          # Prometheus 监控安装（server / node-exporter / alertmanager）
│
└── pgsql/
    ├── backup.sh            # PostgreSQL 备份脚本
    ├── restore.sh           # PostgreSQL 恢复脚本
    ├── test_pgsql.sh        # 单元测试（mock）
    └── test_integration.sh  # 集成测试（真实数据库）
```

## K8s 安装说明

### 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 |
| 架构 | amd64 / arm64 |
| 内存 | master >= 2GB，worker >= 1GB |
| 网络 | 节点间互通，可访问阿里云镜像源 |

### 安装步骤

**1. 所有节点：执行 master 或 worker 安装脚本**

- 前置准备（关闭 swap、内核参数）
- 安装 containerd（阿里云源）
- 安装 kubelet / kubeadm / kubectl（阿里云源，锁定 v1.30）
- 预拉取镜像

**2. Flannel 镜像处理**

脚本会按以下顺序自动处理 Flannel 镜像：

1. 检测当前目录是否有 `flannel.tar` / `flannel-cni.tar`，有则直接导入
2. 尝试从 ghcr.io 直接拉取（海外节点自动走此路径）
3. 以上均失败时，提示手动离线导入

如需手动离线导入（国内节点 ghcr.io 不可达）：

```bash
# 海外节点导出
ctr -n k8s.io images pull ghcr.io/flannel-io/flannel:v0.28.1
ctr -n k8s.io images pull ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1
ctr -n k8s.io images export flannel.tar ghcr.io/flannel-io/flannel:v0.28.1
ctr -n k8s.io images export flannel-cni.tar ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1
```

scp 到各节点当前目录，脚本会自动检测并导入。

**3. master 节点：初始化集群**

初始化完成后，join 命令自动保存至 `/root/k8s-join-command.sh`

**4. worker 节点：加入集群**

执行脚本后粘贴 master 输出的 join 命令即可。

**5. 为 worker 节点打标签**

worker 加入后默认 ROLES 显示 `<none>`，在 master 上执行：

```bash
sudo ./k8s/install.sh label-workers
```

自动为所有未标记的节点打上 `worker` 角色标签。

### 特性

- **幂等性** — 重复执行自动跳过已完成步骤
- **阿里云镜像源** — 全程使用国内镜像，无需科学上网
- **Flannel 智能拉取** — 自动尝试在线拉取，失败后回退到离线导入
- **Worker 自动标记** — `label-workers` 子命令一键为未标记节点打上 worker 角色
- **amd64 / arm64 自适应** — 自动识别架构
- **分阶段确认** — 关键步骤前打印说明，支持 `--yes` 全自动
- **日志记录** — 所有操作写入 `/var/log/k8s-install.log`

## PostgreSQL 备份恢复说明

支持四种备份格式（custom / directory / tar / plain），推荐使用 custom 格式（`-Fc`）。

### 核心能力

- **整库 / 选择性备份** — 支持按表、按 schema 过滤，支持排除
- **四种格式** — custom（推荐）、directory（并行）、tar、plain SQL
- **自动清理** — 基于文件名时间戳的过期备份清理
- **自动创建目标库** — 恢复时目标库不存在会自动创建
- **并行恢复** — custom / directory 格式支持 `-j N` 多线程恢复
- **安全校验** — 数据库名合法性校验，备份文件权限 600
- **分阶段确认** — 关键步骤前打印执行摘要，支持 `--yes` 全自动

详见 [备份恢复详解](docs/pgsql-backup-restore.md)。

## Prometheus 监控说明

基于二进制部署 Prometheus 监控体系，包含三个组件：

| 组件 | 部署位置 | 端口 | 说明 |
|------|----------|------|------|
| Prometheus Server | 监控服务器（1台） | 9090 | 核心：指标抓取、存储、查询 |
| Node Exporter | 每台被监控机器（N台） | 9100 | 暴露机器级指标（CPU/内存/磁盘/网络） |
| Alertmanager | 通常与 Server 同机（1台） | 9093 | 告警路由、分组、通知 |

### 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 |
| 架构 | amd64 / arm64 |
| 内存 | Server ≥ 2GB，Node Exporter / Alertmanager 无特殊要求 |
| 网络 | 需能访问 GitHub releases 下载二进制包 |

### 特性

- **三组件独立安装** — 按需选择 server / node-exporter / alertmanager，或 all 一键全装
- **幂等性** — 重复执行自动跳过已完成步骤，已有配置文件不覆盖
- **自动关联** — 安装 node-exporter 或 alertmanager 时，自动启用 Prometheus 的 scrape 配置
- **amd64 / arm64 自适应** — 自动识别架构下载对应二进制
- **配置校验** — 安装后自动使用 promtool / amtool 验证配置语法
- **健康检查** — 启动后自动验证 /-/healthy 端点
- **分阶段确认** — 关键步骤前打印说明，支持 `--yes` 全自动
- **日志记录** — 所有操作写入 `/var/log/prometheus-install.log`

详见 [Prometheus 安装详解](docs/prometheus-install.md)。

## 开发指南

### 新增服务脚本模板

```bash
mkdir -p myservice
cat > myservice/install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# 加载公共库（兼容三种执行方式）
_load_lib() {
    local bootstrap_url="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/lipanpan65/bootstrap/master}"
    local tmp_lib="/tmp/_bootstrap_lib_$$.sh"
    local candidates=(
        "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/../common/lib.sh"
        "$(pwd)/common/lib.sh"
    )
    for path in "${candidates[@]}"; do
        [[ -f "$path" ]] && { source "$path"; return 0; }
    done
    curl -fsSL "${bootstrap_url}/common/lib.sh" -o "$tmp_lib" \
        || { echo "无法加载 common/lib.sh"; exit 1; }
    source "$tmp_lib"
    _bootstrap_tmp_lib="$tmp_lib"
    _bootstrap_cleanup_lib() { rm -f "$_bootstrap_tmp_lib"; }
    trap '_bootstrap_cleanup_lib' EXIT
}
_load_lib

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
LOG_FILE="/var/log/myservice-install.log"

main() {
    print_banner "MyService 安装" "版本: x.x.x"
    preflight_base "MyService" 1
    # ... 安装逻辑
}

main "$@"
EOF
chmod +x myservice/install.sh
```

公共库 `common/lib.sh` 提供：`log` `ok` `warn` `error` `step` `info` `confirm` `print_banner` `preflight_base` `require_root` `cmd_exists` `service_running` `get_arch` `get_ubuntu_codename` `get_mem_gb` `check_connectivity`

## License

Apache 2.0
