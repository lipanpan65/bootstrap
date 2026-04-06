# Prometheus 可观测性

> Prometheus / Node Exporter / Alertmanager 的统一入口。

## 常用命令

```bash
sudo ./observability/prometheus/install.sh server --yes
sudo ./observability/prometheus/install.sh node-exporter --yes
sudo ./observability/prometheus/install.sh alertmanager --yes
sudo ./observability/prometheus/install.sh all --yes
```

## 兼容说明

- 当前入口会转发到旧路径 `prometheus/install.sh`。
- 旧路径继续保留，以兼容现有使用方式与远程分发链路。
