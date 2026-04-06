# Prometheus 安装

## 入口

`./observability/prometheus/install.sh`

## 组件

- `server`
- `node-exporter`
- `alertmanager`
- `all`

## 示例

```bash
sudo ./observability/prometheus/install.sh server --yes
sudo ./observability/prometheus/install.sh node-exporter --yes
sudo ./observability/prometheus/install.sh alertmanager --yes
sudo ./observability/prometheus/install.sh all --yes
```
