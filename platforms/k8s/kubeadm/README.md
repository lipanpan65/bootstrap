# kubeadm 集群管理

> 面向真实节点的 Kubernetes 集群安装与管理入口。

## 常用命令

```bash
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers
```

## 兼容说明

- 当前入口会转发到旧路径 `k8s/install.sh`。
- 旧路径继续保留，避免打断现有 `install.sh` 分发和历史脚本。
