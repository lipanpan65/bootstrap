# K8s 集群安装详解

> 本文档配合 `k8s/install.sh master|worker` 脚本使用，详细解释每个安装步骤的原理和背景知识。

## 什么是 Kubernetes

Kubernetes（简称 K8s）是一个开源的容器编排平台，用于自动化部署、扩展和管理容器化应用。它的核心能力包括：

- **自动调度** — 根据资源需求将容器分配到合适的节点
- **自愈能力** — 自动重启失败的容器、替换不健康的节点
- **水平扩展** — 根据负载动态增减应用副本数
- **服务发现** — 通过 DNS 和 Service 实现容器间通信
- **滚动更新** — 零停机发布新版本

## 集群架构

```
┌─────────────────────────────────────────────────────┐
│                    K8s 集群                          │
│                                                     │
│  ┌──────────────┐    ┌──────────┐   ┌──────────┐   │
│  │   Master      │    │ Worker 1 │   │ Worker 2 │   │
│  │              │    │          │   │          │   │
│  │  API Server  │    │  kubelet │   │  kubelet │   │
│  │  Scheduler   │◄──►│  kube-   │   │  kube-   │   │
│  │  Controller  │    │  proxy   │   │  proxy   │   │
│  │  etcd        │    │          │   │          │   │
│  │  kubelet     │    │  [Pods]  │   │  [Pods]  │   │
│  └──────────────┘    └──────────┘   └──────────┘   │
│         │                                           │
│         ▼                                           │
│  ┌──────────────┐                                   │
│  │ Flannel CNI  │  ← Pod 间网络通信                  │
│  └──────────────┘                                   │
└─────────────────────────────────────────────────────┘
```

**关键组件：**

| 组件 | 角色 | 说明 |
|------|------|------|
| API Server | Master | 集群的统一入口，所有操作都通过它 |
| Scheduler | Master | 决定 Pod 运行在哪个节点上 |
| Controller Manager | Master | 维护集群期望状态（如副本数、节点健康） |
| etcd | Master | 分布式键值存储，保存集群所有状态数据 |
| kubelet | 所有节点 | 管理节点上的容器生命周期 |
| kube-proxy | 所有节点 | 维护节点上的网络规则，实现 Service 转发 |
| Flannel | 所有节点 | CNI 网络插件，实现跨节点 Pod 通信 |

## 使用方式

```bash
# 本地执行
sudo ./k8s/install.sh master          # 初始化 master 节点
sudo ./k8s/install.sh master --yes    # 全自动模式
sudo ./k8s/install.sh worker          # 初始化 worker 节点
sudo ./k8s/install.sh label-workers   # 为 worker 打角色标签
sudo ./k8s/install.sh dashboard       # 安装 Dashboard（详见 k8s-dashboard.md）

# 远程执行（curl | bash）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s master
```

## 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 |
| 架构 | amd64 / arm64 |
| 内存 | master ≥ 2GB，worker ≥ 1GB |
| 网络 | 节点间互通，可访问阿里云镜像源 |
| 权限 | root 或 sudo |

## 安装步骤详解

### Step 1/6 — 前置准备

#### 1.1 关闭 swap

```bash
swapoff -a
sed -i '/\sswap\s/ s/^[^#]/#&/' /etc/fstab
```

**为什么要关闭 swap：**
K8s 的调度器根据节点的可用内存来分配 Pod。如果开启了 swap，实际内存使用量会变得不可预测，可能导致：
- 调度器认为节点有足够内存，但实际已在使用 swap（性能极差）
- kubelet 默认会拒绝在开启 swap 的节点上运行

`swapoff -a` 临时关闭 swap，`sed` 修改 `/etc/fstab` 确保重启后也不会自动挂载 swap。

#### 1.2 加载内核模块

```bash
modprobe overlay
modprobe br_netfilter
```

| 模块 | 用途 |
|------|------|
| `overlay` | 容器使用 OverlayFS 作为存储驱动，实现镜像的分层存储 |
| `br_netfilter` | 使 Linux 桥接流量经过 iptables 处理，K8s Service 的网络转发依赖此功能 |

#### 1.3 配置内核网络参数

```bash
net.bridge.bridge-nf-call-iptables  = 1    # 桥接的 IPv4 流量经过 iptables
net.bridge.bridge-nf-call-ip6tables = 1    # 桥接的 IPv6 流量经过 iptables
net.ipv4.ip_forward                 = 1    # 开启 IP 转发，Pod 跨节点通信必需
```

**为什么需要这些参数：**
K8s 的 Service 通过 iptables/IPVS 规则实现负载均衡。Pod 之间的网络流量经过 Linux 网桥时，必须经过 iptables 处理才能正确路由。`ip_forward` 允许节点作为路由器转发数据包，这是跨节点 Pod 通信的基础。

### Step 2/6 — 安装 containerd

```bash
apt-get install -y containerd.io
containerd config default > /etc/containerd/config.toml
```

**什么是 containerd：**
containerd 是一个工业级的容器运行时，负责管理容器的完整生命周期（拉取镜像、创建容器、启停容器等）。K8s 从 v1.24 起移除了对 Docker 的直接支持（dockershim），改为通过 CRI（Container Runtime Interface）与 containerd 通信。

**关键配置修改：**

| 配置项 | 修改 | 原因 |
|--------|------|------|
| `SystemdCgroup = true` | false → true | K8s 推荐使用 systemd 作为 cgroup 驱动，与 kubelet 保持一致，避免资源管理冲突 |
| `sandbox_image` | 默认 → 阿里云镜像 | pause 容器是每个 Pod 的基础容器，负责持有网络命名空间。使用阿里云镜像避免国内拉取失败 |

**关键概念 — cgroup：**
cgroup（Control Groups）是 Linux 内核功能，用于限制和隔离进程的资源使用（CPU、内存等）。K8s 用 cgroup 确保每个 Pod 不会超过分配的资源。systemd 和 cgroupfs 是两种 cgroup 驱动，整个系统必须统一使用一种，否则会出现资源管理异常。

### Step 3/6 — 安装 kubelet / kubeadm / kubectl

```bash
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
```

**三件套各自的职责：**

| 工具 | 角色 | 说明 |
|------|------|------|
| `kubeadm` | 集群管理 | 初始化集群（`kubeadm init`）和加入节点（`kubeadm join`）的工具 |
| `kubelet` | 节点代理 | 运行在每个节点上，接收 API Server 指令，管理本节点的 Pod |
| `kubectl` | 客户端 CLI | 与 API Server 交互的命令行工具，用于查看和管理集群资源 |

**为什么要 `apt-mark hold`：**
锁定版本号，防止 `apt-get upgrade` 时意外升级。K8s 组件版本必须一致，升级需要按照官方流程（先升级 master，再升级 worker），不能随意更新。

**为什么使用阿里云镜像源：**
K8s 官方仓库 `pkgs.k8s.io` 在国内访问不稳定。阿里云提供完整的镜像仓库，包内容与官方一致，只是托管在国内 CDN 上。

### Step 4/6 — 预拉取镜像

```bash
# master 节点拉取控制平面镜像
kubeadm config images pull \
    --image-repository registry.aliyuncs.com/google_containers \
    --kubernetes-version v1.30.14

# 所有节点拉取 pause 镜像
ctr -n k8s.io images pull registry.aliyuncs.com/google_containers/pause:3.10.1
```

**为什么要预拉取：**
`kubeadm init` 时会拉取镜像，如果网络不通会导致初始化超时失败。提前拉取可以：
- 验证镜像源是否可达
- 加速初始化过程
- 出问题时更容易定位（是镜像问题还是集群配置问题）

**关键概念 — pause 容器：**
每个 Pod 中都有一个隐藏的 pause 容器（也叫 infra container）。它的作用是：
- 持有 Pod 的网络命名空间（IP 地址属于 pause 容器）
- 作为 Pod 内其他容器的"父进程"，回收僵尸进程
- Pod 内所有容器共享 pause 容器的网络栈，因此它们可以用 `localhost` 互相通信

**为什么要 tag 镜像：**

```bash
ctr -n k8s.io images tag \
    registry.aliyuncs.com/google_containers/pause:3.10.1 \
    registry.k8s.io/pause:3.10.1
```

kubelet 默认从 `registry.k8s.io` 拉取 pause 镜像。我们从阿里云拉取后，给它打上官方标签，kubelet 就能直接使用本地镜像，不会再尝试从官方仓库拉取。

### Step 5/6 — 导入 Flannel 镜像

**什么是 CNI（Container Network Interface）：**
CNI 是 K8s 的网络插件规范。K8s 本身不提供 Pod 间的跨节点网络，需要第三方插件实现。常见的 CNI 插件：

| 插件 | 特点 |
|------|------|
| Flannel | 简单轻量，适合学习和小规模集群 |
| Calico | 功能丰富，支持网络策略，适合生产环境 |
| Cilium | 基于 eBPF，高性能，适合大规模集群 |

**本脚本使用 Flannel**，理由：配置简单、资源占用低、与 K8s 兼容性好。

**Flannel 的工作原理（VXLAN 模式）：**

```
Node 1 (10.244.0.0/24)          Node 2 (10.244.1.0/24)
┌─────────────────────┐         ┌─────────────────────┐
│  Pod A (10.244.0.2)  │         │  Pod B (10.244.1.3)  │
│         │            │         │         ▲            │
│    cni0 bridge       │         │    cni0 bridge       │
│         │            │         │         │            │
│   flannel.1 (VXLAN)──┼────────►┼──flannel.1 (VXLAN)  │
│         │            │  封装    │         │            │
│       eth0 ──────────┼────────►┼──── eth0             │
└─────────────────────┘  物理网络 └─────────────────────┘
```

每个节点分配一个子网（如 10.244.0.0/24），Flannel 通过 VXLAN 隧道将不同节点的 Pod 网络打通。`10.244.0.0/16` 是整个集群的 Pod 网络 CIDR。

**镜像获取策略（三级回退）：**

1. 检测本地 tar 文件 → 直接导入
2. 从 ghcr.io 在线拉取 → 海外节点自动走此路径
3. 提示手动离线导入 → 国内节点兜底方案

### Step 6/6 — 初始化集群（master）/ 加入集群（worker）

#### Master 初始化

```bash
kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --image-repository registry.aliyuncs.com/google_containers \
    --kubernetes-version v1.30.14
```

**各参数含义：**

| 参数 | 值 | 说明 |
|------|-----|------|
| `--pod-network-cidr` | `10.244.0.0/16` | Pod 网络的 IP 段，必须与 Flannel 配置一致 |
| `--image-repository` | 阿里云仓库 | 控制平面组件的镜像源 |
| `--kubernetes-version` | `v1.30.14` | 指定安装版本，避免拉取最新版导致不兼容 |

**`kubeadm init` 做了什么：**

1. 生成 CA 证书和各组件的 TLS 证书（保存在 `/etc/kubernetes/pki/`）
2. 生成 API Server、Controller Manager、Scheduler 的静态 Pod 配置
3. 启动 etcd（单节点模式）
4. 等待控制平面 Pod 就绪
5. 生成 `admin.conf`（kubectl 的凭证文件）
6. 生成 join token（worker 加入集群用）

**配置 kubectl：**

```bash
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
```

`admin.conf` 包含 API Server 地址和客户端证书。kubectl 通过读取 `~/.kube/config` 来连接集群。

**安装 Flannel CNI：**

```bash
kubectl apply -f kube-flannel.yml
```

在 `kubeadm init` 之后立即安装 CNI 插件。没有 CNI 插件，节点会一直处于 `NotReady` 状态，因为 kubelet 发现没有网络插件，不会将节点标记为就绪。

**Worker 标签：**

`kubeadm init` 完成后，脚本自动为 ROLES 显示 `<none>` 的节点打上 `worker` 标签。也可以后续手动执行：

```bash
sudo ./k8s/install.sh label-workers
```

#### Worker 加入

```bash
kubeadm join <master-ip>:6443 \
    --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

**各参数含义：**

| 参数 | 说明 |
|------|------|
| `<master-ip>:6443` | API Server 的地址和端口 |
| `--token` | 加入集群的认证 token，有效期 24 小时 |
| `--discovery-token-ca-cert-hash` | CA 证书的 SHA256 哈希，防止中间人攻击 |

**`kubeadm join` 做了什么：**

1. 使用 token 向 API Server 发起认证
2. 验证 CA 证书哈希（确认连接的是正确的集群）
3. 下载集群配置
4. 生成 kubelet 的证书和配置（`/etc/kubernetes/kubelet.conf`）
5. 启动 kubelet，节点加入集群

## 配置参数说明

| 参数 | 值 | 可修改 | 说明 |
|------|-----|--------|------|
| `K8S_VERSION` | `v1.30` | 是 | K8s 大版本号，用于 apt 仓库地址 |
| `K8S_PATCH_VERSION` | `v1.30.14` | 是 | 完整版本号，用于镜像拉取 |
| `K8S_IMAGE_REPO` | `registry.aliyuncs.com/google_containers` | 是 | 镜像仓库地址 |
| `POD_NETWORK_CIDR` | `10.244.0.0/16` | 谨慎 | Pod 网络段，须与 CNI 插件配置一致 |
| `FLANNEL_VERSION` | `v0.28.1` | 是 | Flannel 版本 |
| `CONTAINERD_PAUSE_IMAGE` | `...pause:3.10.1` | 是 | pause 容器镜像 |

## 常见问题

### 节点一直 NotReady

```bash
kubectl describe node <node-name>
```

常见原因：
- CNI 插件未安装或 Pod 未就绪：`kubectl -n kube-flannel get pods`
- kubelet 未运行：`systemctl status kubelet`
- 容器运行时异常：`systemctl status containerd`

### kubeadm init 失败

```bash
# 查看详细日志
journalctl -u kubelet -f

# 重置后重试
kubeadm reset -f
rm -rf /etc/kubernetes/ /var/lib/etcd/
```

常见原因：
- swap 未关闭
- 端口被占用（6443、10250 等）
- 镜像拉取失败

### token 过期（24 小时后 worker 无法加入）

```bash
# 在 master 上重新生成
kubeadm token create --print-join-command
```

### Pod 无法跨节点通信

```bash
# 检查 Flannel Pod 状态
kubectl -n kube-flannel get pods -o wide

# 检查节点上的 flannel 网络
ip addr show flannel.1
```

常见原因：
- Flannel Pod 未运行
- 节点间的 UDP 8472 端口未放行（VXLAN 流量）
- `--pod-network-cidr` 与 Flannel 配置不匹配

### 如何重置集群

```bash
# 在所有节点上执行
kubeadm reset -f
rm -rf /etc/kubernetes/ /var/lib/etcd/ $HOME/.kube
iptables -F && iptables -t nat -F && iptables -t mangle -F
```

> **注意：** 这会彻底删除集群，所有数据丢失。

## 安装后常用命令

```bash
# 查看节点
kubectl get nodes

# 查看所有 Pod（所有 namespace）
kubectl get pods -A

# 查看系统组件状态
kubectl get pods -n kube-system

# 查看集群信息
kubectl cluster-info

# 查看某个 Pod 的详情
kubectl describe pod <pod-name> -n <namespace>

# 查看 Pod 日志
kubectl logs <pod-name> -n <namespace>

# 进入容器
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash
```

## 参考

- [Kubernetes 官方文档](https://kubernetes.io/docs/)
- [kubeadm 安装指南](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
- [Flannel GitHub](https://github.com/flannel-io/flannel)
- [containerd 配置参考](https://github.com/containerd/containerd/blob/main/docs/getting-started.md)
