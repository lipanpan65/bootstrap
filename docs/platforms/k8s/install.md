# Kubernetes 安装

## 入口

`./platforms/k8s/kubeadm/install.sh`

## 常用命令

```bash
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
```

## 远程分发

```bash
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- k8s master
```

根入口会直接分发到 `platforms/k8s/kubeadm/install.sh`。
