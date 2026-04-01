# K8s Dashboard 安装详解

> 本文档配合 `k8s/install.sh dashboard` 脚本使用，详细解释每个安装步骤的原理和背景知识。

## 什么是 Kubernetes Dashboard

Kubernetes Dashboard 是 K8s 官方提供的 Web UI 管理工具，可以通过浏览器查看和管理集群资源，包括：

- 查看节点、Pod、Deployment、Service 等资源状态
- 实时查看 Pod 日志
- 在线编辑资源 YAML
- 执行容器内命令（类似 `kubectl exec`）

对于学习 K8s 来说，Dashboard 提供了直观的可视化界面，帮助理解集群内部的资源关系。

## 版本选择

| 版本 | 架构 | 部署方式 | 适用场景 |
|------|------|----------|----------|
| v2.7.0（经典版） | 单体应用 | `kubectl apply` 单个 YAML | 学习、测试、小规模集群 |
| v7.x（新架构） | 微服务，含 Kong 网关 | Helm Chart | 生产环境 |

本脚本使用 **v2.7.0**，理由：
- 无额外依赖（不需要 Helm）
- 部署简单，一个 YAML 文件搞定
- 与 K8s v1.30 兼容良好
- 功能完整，满足学习和日常管理需求

## 使用方式

**前提：** 集群已通过 `k8s/install.sh master` 初始化完成。

```bash
# 本地执行（在 master 节点上）
sudo ./k8s/install.sh dashboard

# 全自动模式（跳过确认提示）
sudo ./k8s/install.sh dashboard --yes

# 远程执行（curl | bash）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s dashboard
```

安装完成后会输出：
- 访问地址：`https://<节点IP>:30443`
- 登录 Token：同时保存在 `/root/dashboard-token.txt`

## 安装步骤详解

### Step 1/5 — 前置检查

```bash
kubectl cluster-info          # 验证集群可达
kubectl get nodes             # 验证节点状态
```

**为什么需要前置检查：**
- Dashboard 是部署在集群内部的应用，如果集群本身不可用，部署必然失败
- 脚本检查 `admin.conf` 和节点 Ready 状态，确保集群处于健康状态
- 幂等设计：如果 `kubernetes-dashboard` namespace 已存在，说明之前已部署过，自动跳过

### Step 2/5 — 部署 Dashboard

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
```

**这个 YAML 创建了什么：**

| 资源类型 | 名称 | 作用 |
|----------|------|------|
| Namespace | `kubernetes-dashboard` | Dashboard 的独立命名空间，与业务隔离 |
| ServiceAccount | `kubernetes-dashboard` | Dashboard 应用自身的运行身份 |
| Service | `kubernetes-dashboard` | 集群内部访问入口（默认 ClusterIP） |
| Deployment | `dashboard-metrics-scraper` | 采集集群指标，在 Dashboard 上显示 CPU/内存图表 |
| Deployment | `kubernetes-dashboard` | Dashboard Web 应用本体 |
| Secret/ConfigMap | 多个 | TLS 证书、配置文件等 |
| Role/RoleBinding | 多个 | Dashboard 应用自身的最小权限（只能读取自己 namespace 的资源） |

**关键概念 — Namespace：**
K8s 用 Namespace 做资源隔离。Dashboard 部署在独立的 `kubernetes-dashboard` namespace 中，不会影响你的业务应用。可以用 `kubectl get all -n kubernetes-dashboard` 查看该 namespace 下的所有资源。

### Step 3/5 — 创建管理员账户

```yaml
# ServiceAccount — 创建一个身份
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin
  namespace: kubernetes-dashboard
---
# ClusterRoleBinding — 给这个身份授权
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin        # K8s 内置的最高权限角色
subjects:
- kind: ServiceAccount
  name: admin
  namespace: kubernetes-dashboard
```

**关键概念 — RBAC（基于角色的访问控制）：**

K8s 的权限体系由三部分组成：

```
Subject（谁）  →  RoleBinding（绑定关系）  →  Role（能做什么）
```

- **ServiceAccount**：Pod 内应用的身份标识。Dashboard 需要一个 ServiceAccount 来调用 K8s API
- **ClusterRole**：定义一组权限（如：可以读取所有 Pod、可以删除 Deployment 等）
- **ClusterRoleBinding**：将 ServiceAccount 和 ClusterRole 关联起来

`cluster-admin` 是 K8s 内置的超级管理员角色，拥有集群所有权限。我们把 `admin` 绑定到这个角色，这样登录 Dashboard 后可以查看和操作所有资源。

> **生产环境注意：** 不应使用 `cluster-admin`，应该创建自定义 ClusterRole，只赋予必要的权限（最小权限原则）。

### Step 4/5 — 暴露服务（NodePort）

```bash
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard \
  --type='json' \
  -p='[
    {"op":"replace","path":"/spec/type","value":"NodePort"},
    {"op":"replace","path":"/spec/ports/0/nodePort","value":30443}
  ]'
```

**关键概念 — Service 类型：**

K8s Service 有三种常用类型：

| 类型 | 访问方式 | 适用场景 |
|------|----------|----------|
| ClusterIP（默认） | 只能集群内部访问 | 微服务间通信 |
| NodePort | 通过 `<节点IP>:<端口>` 外部访问 | 开发测试，端口范围 30000-32767 |
| LoadBalancer | 通过云厂商负载均衡器访问 | 生产环境 |

Dashboard 默认使用 ClusterIP，外部无法访问。我们将其改为 NodePort 并固定端口 30443（方便记忆，443 是 HTTPS 默认端口）。

**为什么选 NodePort 而不是 LoadBalancer：**
- NodePort 不依赖云厂商，任何环境都能用
- 学习环境下 NodePort 最简单直接
- 固定端口号避免每次部署变化

### Step 5/5 — 生成访问凭证

```yaml
# 创建长期 Token（不过期）
apiVersion: v1
kind: Secret
metadata:
  name: admin-secret
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin
type: kubernetes.io/service-account-token
```

**关键概念 — Token 认证：**

K8s 从 v1.24 开始不再自动为 ServiceAccount 生成永久 token。有两种方式获取 token：

| 方式 | 命令 | 有效期 | 适用场景 |
|------|------|--------|----------|
| 临时 token | `kubectl create token admin` | 默认 1 小时 | 临时使用 |
| 长期 token | 创建 Secret（如上） | 永不过期 | Dashboard 长期使用 |

脚本使用 Secret 方式创建长期 token，避免频繁重新登录。

> **安全提醒：** 长期 token 不会过期，如果泄露需要手动删除 Secret 来吊销。

## 访问 Dashboard

部署完成后，通过以下方式访问：

```
URL:  https://<节点IP>:30443
账户: admin（ServiceAccount）
Token: 保存在 /root/dashboard-token.txt
```

Dashboard 登录页面提供两种认证方式：

| 方式 | 说明 |
|------|------|
| **Token** | 粘贴 ServiceAccount 的 token 字符串（脚本默认使用此方式） |
| **Kubeconfig** | 上传 kubeconfig 文件（适合多集群管理） |

选择 **Token** 方式，粘贴脚本输出的 token 即可登录。登录后的权限取决于 `admin` 所绑定的角色（`cluster-admin`，即集群最高权限）。

**注意事项：**

1. **HTTPS 自签证书** — 浏览器会提示"连接不安全"，这是因为 Dashboard 使用自签 TLS 证书。点击"高级" → "继续访问"即可
2. **安全组/防火墙** — 云服务器需在安全组中放行 30443 端口（TCP 协议）

## 常见问题

### Dashboard Pod 一直 Pending

```bash
kubectl describe pod -n kubernetes-dashboard -l k8s-app=kubernetes-dashboard
```

常见原因：
- 节点资源不足（CPU/内存）
- 镜像拉取失败（检查网络或镜像源）

### 登录后看不到任何资源

检查 ClusterRoleBinding 是否创建成功：

```bash
kubectl get clusterrolebinding admin-cluster-binding
```

如果不存在，重新执行脚本或手动创建。

### Token 过期或丢失

重新获取：

```bash
kubectl -n kubernetes-dashboard get secret admin-secret -o jsonpath='{.data.token}' | base64 -d
```

或重新生成临时 token：

```bash
kubectl -n kubernetes-dashboard create token admin
```

### 无法访问 30443 端口

1. 检查 Service 类型是否为 NodePort：
   ```bash
   kubectl -n kubernetes-dashboard get svc kubernetes-dashboard
   ```
2. 检查云服务器安全组是否放行 30443
3. 检查本地防火墙：`ufw status`

## 卸载 Dashboard

```bash
kubectl delete namespace kubernetes-dashboard
kubectl delete clusterrolebinding admin-cluster-binding
```

删除 namespace 会自动清理其下所有资源（Pod、Service、Secret 等）。

## 参考

- [Kubernetes Dashboard GitHub](https://github.com/kubernetes/dashboard)
- [K8s RBAC 官方文档](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [K8s Service 类型](https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types)
