# Kind K8s 学习环境

> 基于 Kind（Kubernetes in Docker）的一键 K8s 集群创建工具。

## 快速开始

```bash
# 安装工具并创建集群（1 master + 2 worker）
sudo ./kind/install.sh create --yes

# 自定义 worker 数量和集群名
sudo ./kind/install.sh create -w 3 -n dev --yes

# 使用镜像加速（国内推荐）
sudo ./kind/install.sh create --mirror https://mirror.aliyuncs.com --yes

# 远程执行
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- kind create --yes

# 查看集群状态
sudo ./kind/install.sh status

# 删除集群
sudo ./kind/install.sh delete
```

## 集群创建后

```bash
# 查看节点
kubectl get nodes

# 部署应用
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=NodePort

# 加载本地镜像（不需要推到远程仓库）
docker build -t my-app:v1 .
kind load docker-image my-app:v1
kubectl create deployment my-app --image=my-app:v1
```

## 环境要求

| 项目 | 要求 |
|------|------|
| Docker | 已安装并运行 |
| 权限 | root 或 sudo |
| 容器环境 | 需要 `privileged: true` + `cgroupns: host` + `/sys/fs/cgroup:rw` |

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本（create / install / delete / status） |

## 详细文档

- [Kind 官方文档](https://kind.sigs.k8s.io/)
- [Kind 快速入门](https://kind.sigs.k8s.io/docs/user/quick-start/)
