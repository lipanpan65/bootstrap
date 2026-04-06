# Kubernetes Platforms

> Kubernetes 相关平台能力入口，当前包含 `kubeadm` 与 `kind` 两种实现。

## 目录

- `kubeadm/`：面向真实节点集群安装与管理
- `kind/`：面向本地学习与测试的 Kind 集群

## 说明

- 该目录是新的目标结构入口。
- 现有 Bash 实现仍保留旧路径，以兼容 `curl | bash` 和历史命令。
- 新路径脚本会转发到当前稳定的 Bash 实现。
