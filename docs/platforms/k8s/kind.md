# Kind 文档

## 入口

`./platforms/k8s/kind/install.sh`

## 子命令

- `create`
- `install`
- `status`
- `delete`

## 示例

```bash
sudo ./platforms/k8s/kind/install.sh create --yes
sudo ./platforms/k8s/kind/install.sh create --name dev --workers 2 --yes
sudo ./platforms/k8s/kind/install.sh status
sudo ./platforms/k8s/kind/install.sh delete
```
