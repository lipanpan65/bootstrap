# Kind 学习集群

> 面向本地学习、开发和测试的 Kind 集群入口。

## 常用命令

```bash
sudo ./platforms/k8s/kind/install.sh create --yes
sudo ./platforms/k8s/kind/install.sh status
sudo ./platforms/k8s/kind/install.sh delete
```

## 兼容说明

- 当前入口会转发到旧路径 `kind/install.sh`。
- 旧路径继续保留，以兼容 `curl | bash` 和既有使用方式。
