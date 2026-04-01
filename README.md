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
| `docker` | Docker / containerd 单独安装 | 🚧 开发中 |
| `redis` | Redis | 🚧 开发中 |
| `nginx` | Nginx | 🚧 开发中 |

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
```

### 直接执行子脚本（本地克隆后）

```bash
git clone https://github.com/lipanpan65/bootstrap.git
cd bootstrap

sudo ./k8s/install.sh master
sudo ./k8s/install.sh worker --yes
```

## 目录结构

```
bootstrap/
├── install.sh              # 统一入口，负责服务分发
├── README.md
├── LICENSE
│
├── common/
│   └── lib.sh              # 公共函数库（颜色、日志、预检等）
│
└── k8s/
    └── install.sh          # K8s 集群安装（master / worker）
```

> 以下服务目录尚在规划中：`docker/`、`redis/`、`nginx/`

## K8s 安装说明

### 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 |
| 架构 | amd64 / arm64 |
| 内存 | master ≥ 2GB，worker ≥ 1GB |
| 网络 | 节点间互通，可访问阿里云镜像源 |

### 安装步骤

**1. 所有节点：执行 master 或 worker 安装脚本**

- 前置准备（关闭 swap、内核参数）
- 安装 containerd（阿里云源）
- 安装 kubelet / kubeadm / kubectl（阿里云源，锁定 v1.30）
- 预拉取镜像

**2. Flannel 镜像处理（ghcr.io 国内无法访问）**

在海外节点导出：

```bash
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

### 特性

- ✅ **幂等性** — 重复执行自动跳过已完成步骤
- ✅ **阿里云镜像源** — 全程使用国内镜像，无需科学上网
- ✅ **amd64 / arm64 自适应** — 自动识别架构
- ✅ **分阶段确认** — 关键步骤前打印说明，支持 `--yes` 全自动
- ✅ **日志记录** — 所有操作写入 `/var/log/k8s-install.log`

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

公共库 `common/lib.sh` 提供：`log` `ok` `warn` `error` `step` `info` `confirm` `preflight_base` `cmd_exists` `service_running` `get_arch` `get_ubuntu_codename`

## License

Apache 2.0