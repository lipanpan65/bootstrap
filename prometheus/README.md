# Prometheus 监控

> 基于二进制部署的 Prometheus 监控体系一键安装工具，支持 Server、Node Exporter、Alertmanager。

## 快速开始

```bash
# 安装 Prometheus Server（监控服务器，1台）
sudo ./prometheus/install.sh server --yes

# 安装 Node Exporter（每台被监控机器）
sudo ./prometheus/install.sh node-exporter --yes

# 安装 Alertmanager（告警管理）
sudo ./prometheus/install.sh alertmanager --yes

# 一次安装全部组件
sudo ./prometheus/install.sh all --yes

# 自定义参数
sudo ./prometheus/install.sh server -v 2.53.4 -r 30d --port 9090 --yes

# 远程执行（curl | bash）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus server

# 查看帮助
./prometheus/install.sh --help
```

## 安装后验证

```bash
# 健康检查
curl http://localhost:9090/-/healthy
curl http://localhost:9100/metrics | head -5
curl http://localhost:9093/-/healthy

# 查看 targets 状态
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool

# PromQL 查询
curl -s 'http://localhost:9090/api/v1/query?query=up'
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本（server / node-exporter / alertmanager / all） |

## 详细文档

- [Prometheus 安装详解](../docs/prometheus-install.md) — 架构说明、步骤详解、参数说明、常见问题、常用命令
