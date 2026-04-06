# kubeadm 文档

## 入口

`./platforms/k8s/kubeadm/install.sh`

## 子命令

- `master`
- `worker`
- `label-workers`
- `dashboard`

## 示例

```bash
sudo ./platforms/k8s/kubeadm/install.sh master
sudo ./platforms/k8s/kubeadm/install.sh worker --yes
sudo ./platforms/k8s/kubeadm/install.sh label-workers
sudo ./platforms/k8s/kubeadm/install.sh dashboard --yes
```
