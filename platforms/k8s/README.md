# Kubernetes Platforms

> Kubernetes 相关平台能力入口，当前包含 `kubeadm` 与 `kind` 两种实现。

## 目录

- `kubeadm/`：面向真实节点集群安装与管理
- `kind/`：面向本地学习与测试的 Kind 集群

## 入口

```bash
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers

sudo ./platforms/k8s/kind/install.sh create --yes
sudo ./platforms/k8s/kind/install.sh status
```
