# Kubernetes Dashboard

## 入口

```bash
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
```

## 前置条件

- 集群已经通过 `master` / `worker` 流程完成初始化
- `kubectl` 能访问当前集群

## 相关命令

```bash
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers
```
