# Prometheus 监控安装详解

> 本文档配合 `prometheus/install.sh server|node-exporter|alertmanager` 脚本使用，详细解释每个组件的安装步骤、原理和验证方法。

## 什么是 Prometheus

Prometheus 是一个开源的系统监控和告警工具，最初由 SoundCloud 开发，现为 CNCF 毕业项目。它的核心能力包括：

- **多维数据模型** — 时间序列数据由 metric 名称和 key-value 标签标识
- **PromQL** — 强大的查询语言，支持聚合、过滤、数学运算
- **Pull 模式** — 主动从目标拉取指标，无需在被监控端安装 agent（只需 exporter）
- **服务发现** — 支持 K8s、Consul、DNS 等自动发现监控目标
- **告警能力** — 通过 Alertmanager 实现告警路由、分组、静默、抑制

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                      Prometheus 监控体系                         │
│                                                                 │
│  ┌─────────────────┐                                            │
│  │ Prometheus Server│     Pull /metrics                         │
│  │                 │─────────────────┬──────────────┐           │
│  │  - 抓取 (scrape)│                 │              │           │
│  │  - 存储 (TSDB)  │                 ▼              ▼           │
│  │  - 查询 (PromQL)│         ┌──────────────┐ ┌──────────┐     │
│  │  - 规则评估     │         │ Node Exporter│ │ 应用指标  │     │
│  │                 │         │  :9100       │ │  :8080   │     │
│  └────────┬────────┘         │ (机器指标)    │ │ (/metrics)│     │
│           │                  └──────────────┘ └──────────┘     │
│           │ 触发告警                                            │
│           ▼                                                     │
│  ┌─────────────────┐                                            │
│  │  Alertmanager   │     通知                                   │
│  │    :9093        │────────► 邮件 / Slack / 微信 / Webhook     │
│  │  - 路由         │                                            │
│  │  - 分组         │                                            │
│  │  - 静默         │                                            │
│  └─────────────────┘                                            │
│                                                                 │
│  ┌─────────────────┐                                            │
│  │  Grafana (可选)  │     数据源: Prometheus                     │
│  │    :3000        │     可视化仪表盘                            │
│  └─────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

**与 K8s 的架构区别：**

| | K8s | Prometheus |
|--|-----|-----------|
| 模式 | master/worker 集群 | 中心化 pull（无 master/worker 概念） |
| 扩展 | 加 worker 节点 | 加 exporter / 联邦 / remote-write |
| 通信 | worker → master 注册 | server → exporter 主动拉取 |

**组件对应关系：**

| 组件 | 部署位置 | 数量 | 类比 |
|------|----------|------|------|
| Prometheus Server | 监控服务器 | 1 台（或少数几台） | 类似 K8s master |
| Node Exporter | 每台被监控机器 | N 台 | 类似 K8s worker |
| Alertmanager | 通常与 server 同机 | 1 台 | 独立告警组件 |

## 使用方式

```bash
# 本地执行
sudo ./prometheus/install.sh server                # 安装 Prometheus Server
sudo ./prometheus/install.sh server --yes           # 全自动模式
sudo ./prometheus/install.sh node-exporter          # 安装 Node Exporter
sudo ./prometheus/install.sh alertmanager           # 安装 Alertmanager
sudo ./prometheus/install.sh all                    # 安装全部组件

# 远程执行（curl | bash）
curl -fsSL https://raw.githubusercontent.com/lipanpan65/bootstrap/master/install.sh \
  | sudo bash -s -- prometheus server

# 自定义参数
sudo ./prometheus/install.sh server \
  --version 2.53.4 \
  --port 9090 \
  --retention 30d \
  --yes
```

## 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04 |
| 架构 | amd64 / arm64 |
| 内存 | server ≥ 2GB，node-exporter / alertmanager ≥ 512MB |
| 磁盘 | server 数据目录建议 SSD，容量取决于监控规模和保留时间 |
| 网络 | server 需能访问所有 exporter 的端口；需能访问 GitHub releases 下载二进制 |
| 权限 | root 或 sudo |

**默认端口：**

| 组件 | 端口 | 用途 |
|------|------|------|
| Prometheus Server | 9090 | Web UI + API + 自身 metrics |
| Node Exporter | 9100 | 机器指标暴露 |
| Alertmanager | 9093 | Web UI + API |

## 安装步骤详解

### Server 安装（5 步）

#### Step 1/5 — 前置检查

```bash
preflight_base "Prometheus" 2    # root 权限、系统检查、内存 ≥ 2GB
ss -tlnp | grep :9090            # 检查端口未被占用
```

**为什么检查端口：**
Prometheus 默认监听 9090 端口。如果端口已被占用（比如已有一个 Prometheus 实例），启动会失败。脚本提前检测避免安装到一半才发现冲突。

#### Step 2/5 — 创建用户与目录

```bash
# 创建专用系统用户（无 home 目录、无登录 shell）
useradd --no-create-home --shell /bin/false prometheus

# 创建配置和数据目录
mkdir -p /etc/prometheus          # 配置文件目录
mkdir -p /var/lib/prometheus      # TSDB 数据目录

# 设置目录权限
chown prometheus:prometheus /etc/prometheus
chown prometheus:prometheus /var/lib/prometheus
```

**为什么创建专用用户：**
安全最佳实践。Prometheus 不需要 root 权限运行，使用独立的低权限用户可以：
- 限制进程的文件系统访问范围
- 防止被攻击后影响整个系统
- 便于审计和权限管理

#### Step 3/5 — 下载并安装

```bash
# 检测系统架构
arch=$(uname -m)    # x86_64 → amd64, aarch64 → arm64

# 从 GitHub releases 下载
curl -fsSL https://github.com/prometheus/prometheus/releases/download/v${VERSION}/prometheus-${VERSION}.linux-${arch}.tar.gz \
  -o /tmp/prometheus.tar.gz

# 解压
tar xzf /tmp/prometheus.tar.gz -C /tmp/

# 安装二进制文件
cp /tmp/prometheus-${VERSION}.linux-${arch}/prometheus     /usr/local/bin/
cp /tmp/prometheus-${VERSION}.linux-${arch}/promtool       /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/{prometheus,promtool}

# 安装默认配置和控制台模板
cp -r /tmp/prometheus-${VERSION}.linux-${arch}/consoles     /etc/prometheus/
cp -r /tmp/prometheus-${VERSION}.linux-${arch}/console_libraries /etc/prometheus/
```

**安装了什么：**

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/prometheus` | Prometheus Server 主程序 |
| `/usr/local/bin/promtool` | 配置检查和调试工具（验证 prometheus.yml 语法、检查规则文件等） |
| `/etc/prometheus/consoles/` | 内置 Web 控制台模板 |
| `/etc/prometheus/console_libraries/` | 控制台模板依赖的 JS/CSS 库 |

**关于 promtool：**
`promtool` 是 Prometheus 自带的命令行工具，非常有用：
```bash
# 验证配置文件语法
promtool check config /etc/prometheus/prometheus.yml

# 验证告警规则文件
promtool check rules /etc/prometheus/rules.yml

# 执行 PromQL 查询（调试用）
promtool query instant http://localhost:9090 'up == 1'
```

#### Step 4/5 — 配置

**主配置文件 `/etc/prometheus/prometheus.yml`：**

```yaml
# 全局配置
global:
  scrape_interval: 15s        # 默认抓取间隔（每 15 秒拉取一次指标）
  evaluation_interval: 15s    # 规则评估间隔（每 15 秒评估一次告警规则）

# 抓取配置
scrape_configs:
  # 监控 Prometheus 自身
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # 监控 Node Exporter（机器指标）
  - job_name: "node"
    static_configs:
      - targets: ["localhost:9100"]
```

**配置项解释：**

| 配置项 | 说明 |
|--------|------|
| `scrape_interval` | Prometheus 多久去拉取一次指标。15s 是合理的默认值，过低会增加负载，过高会降低监控精度 |
| `evaluation_interval` | 多久评估一次告警规则和 recording rules。通常与 scrape_interval 保持一致 |
| `job_name` | 监控任务的名称，会作为标签 `job="prometheus"` 附加到所有指标上 |
| `static_configs.targets` | 要抓取的目标地址列表。格式为 `host:port`，Prometheus 会访问 `http://host:port/metrics` |

**如何添加更多监控目标：**
```yaml
scrape_configs:
  # ... 已有配置 ...

  # 添加新的监控目标
  - job_name: "my-app"
    static_configs:
      - targets: ["10.0.0.1:8080", "10.0.0.2:8080"]
    metrics_path: "/metrics"      # 默认就是 /metrics，可省略
    scrape_interval: 30s          # 可覆盖全局 scrape_interval
```

**systemd 服务文件 `/etc/systemd/system/prometheus.service`：**

```ini
[Unit]
Description=Prometheus Monitoring System
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time=15d \
    --web.listen-address=0.0.0.0:9090 \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**关键启动参数：**

| 参数 | 说明 |
|------|------|
| `--config.file` | 主配置文件路径 |
| `--storage.tsdb.path` | TSDB 数据存储目录 |
| `--storage.tsdb.retention.time` | 数据保留时间（默认 15d）。超过此时间的数据自动清理 |
| `--web.listen-address` | 监听地址和端口 |
| `--web.enable-lifecycle` | 启用 `/-/reload` 和 `/-/quit` HTTP 端点，方便热重载配置 |

**关于数据保留（retention）：**
Prometheus 的 TSDB 按时间分块存储数据（默认每 2 小时一个 block）。`retention.time` 控制保留多长时间的数据，过期的 block 自动删除。磁盘占用估算：
```
磁盘 ≈ 抓取间隔频率 × 指标数量 × 每个样本约 1-2 字节 × 保留时间
```
示例：1000 个指标，15s 间隔，保留 15 天 ≈ 约 1-2 GB。

#### Step 5/5 — 启动与验证

```bash
# 重载 systemd 配置
systemctl daemon-reload

# 启动并设置开机自启
systemctl enable --now prometheus

# 验证服务状态
systemctl is-active prometheus       # 应返回 "active"

# 健康检查
curl -sf http://localhost:9090/-/healthy    # 应返回 "Prometheus Server is Healthy."
curl -sf http://localhost:9090/-/ready      # 应返回 "Prometheus Server is Ready."
```

### Node Exporter 安装（5 步）

#### Step 1/5 — 前置检查

```bash
preflight_base "Node Exporter" 0    # 内存要求低，不做最低内存检查
ss -tlnp | grep :9100               # 检查端口未被占用
```

#### Step 2/5 — 创建用户

```bash
useradd --no-create-home --shell /bin/false node_exporter
```

Node Exporter 不需要配置文件和数据目录，只需要一个运行用户。

#### Step 3/5 — 下载并安装

```bash
curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${arch}.tar.gz \
  -o /tmp/node_exporter.tar.gz

tar xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-${VERSION}.linux-${arch}/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
```

#### Step 4/5 — 配置 systemd

```ini
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address=0.0.0.0:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Node Exporter 暴露的关键指标：**

| 指标 | 说明 |
|------|------|
| `node_cpu_seconds_total` | CPU 各状态（user/system/idle/iowait）的累计时间 |
| `node_memory_MemTotal_bytes` | 总内存 |
| `node_memory_MemAvailable_bytes` | 可用内存 |
| `node_filesystem_avail_bytes` | 磁盘可用空间 |
| `node_disk_io_time_seconds_total` | 磁盘 I/O 耗时 |
| `node_network_receive_bytes_total` | 网络接收字节数 |
| `node_network_transmit_bytes_total` | 网络发送字节数 |
| `node_load1` / `node_load5` / `node_load15` | 系统负载 |

#### Step 5/5 — 启动与验证

```bash
systemctl daemon-reload
systemctl enable --now node_exporter

# 验证
systemctl is-active node_exporter
curl -sf http://localhost:9100/metrics | head -5
```

### Alertmanager 安装（5 步）

#### Step 1/5 — 前置检查

```bash
preflight_base "Alertmanager" 0
ss -tlnp | grep :9093
```

#### Step 2/5 — 创建用户与目录

```bash
useradd --no-create-home --shell /bin/false alertmanager
mkdir -p /etc/alertmanager
mkdir -p /var/lib/alertmanager
chown alertmanager:alertmanager /etc/alertmanager
chown alertmanager:alertmanager /var/lib/alertmanager
```

#### Step 3/5 — 下载并安装

```bash
curl -fsSL https://github.com/prometheus/alertmanager/releases/download/v${VERSION}/alertmanager-${VERSION}.linux-${arch}.tar.gz \
  -o /tmp/alertmanager.tar.gz

tar xzf /tmp/alertmanager.tar.gz -C /tmp/
cp /tmp/alertmanager-${VERSION}.linux-${arch}/alertmanager    /usr/local/bin/
cp /tmp/alertmanager-${VERSION}.linux-${arch}/amtool          /usr/local/bin/
chown alertmanager:alertmanager /usr/local/bin/{alertmanager,amtool}
```

**amtool** 是 Alertmanager 的命令行工具：
```bash
# 查看当前告警
amtool alert --alertmanager.url=http://localhost:9093

# 手动静默一个告警
amtool silence add alertname=HighMemory --alertmanager.url=http://localhost:9093

# 查看当前静默规则
amtool silence query --alertmanager.url=http://localhost:9093
```

#### Step 4/5 — 配置

**默认配置 `/etc/alertmanager/alertmanager.yml`：**

```yaml
global:
  resolve_timeout: 5m           # 告警在多久没有新触发后自动标记为已解决

route:
  group_by: ['alertname']       # 按告警名分组
  group_wait: 10s               # 新分组等待 10s 再发送（等待同组其他告警到达）
  group_interval: 10s           # 同组告警的发送间隔
  repeat_interval: 1h           # 已发送的告警重复发送间隔
  receiver: 'default'           # 默认接收器

receivers:
  - name: 'default'
    # 默认配置不发送通知，仅在 Web UI 展示
    # 实际使用时配置 email/slack/webhook 等
```

**告警路由原理：**

```
告警触发 → route 匹配 → group_by 分组 → group_wait 等待
                                              ↓
                                         发送给 receiver
                                              ↓
                                    group_interval 后再次发送新告警
                                              ↓
                                    repeat_interval 后重复提醒
```

**常见 receiver 配置示例：**

```yaml
receivers:
  # 邮件通知
  - name: 'email'
    email_configs:
      - to: 'admin@example.com'
        from: 'alertmanager@example.com'
        smarthost: 'smtp.example.com:587'

  # Webhook 通知（如飞书、钉钉）
  - name: 'webhook'
    webhook_configs:
      - url: 'http://dingtalk-webhook:8060/dingtalk/ops/send'
```

**将 Alertmanager 集成到 Prometheus：**

安装 Alertmanager 后，需要在 `prometheus.yml` 中添加关联配置：

```yaml
# 在 prometheus.yml 中添加
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - "/etc/prometheus/rules/*.yml"
```

**示例告警规则 `/etc/prometheus/rules/basic.yml`：**

```yaml
groups:
  - name: basic
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "实例 {{ $labels.instance }} 宕机"
          description: "{{ $labels.instance }} 已经超过 1 分钟无法访问"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "内存使用率超过 90%"
```

#### Step 5/5 — 启动与验证

```bash
systemctl daemon-reload
systemctl enable --now alertmanager

systemctl is-active alertmanager
curl -sf http://localhost:9093/-/healthy
```

## 配置参数说明

### install.sh 参数

**通用参数（所有子命令）：**

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `-y, --yes` | 不启用 | 跳过所有确认提示 |
| `-h, --help` | — | 显示帮助信息 |

**server 子命令参数：**

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `-v, --version` | `2.53.4` | Prometheus Server 版本号 |
| `-p, --port` | `9090` | 监听端口 |
| `-r, --retention` | `15d` | 数据保留时间（如 `15d`、`30d`、`1y`） |
| `--data-dir` | `/var/lib/prometheus` | TSDB 数据存储目录 |
| `--config` | (无) | 自定义配置文件路径（指定后跳过默认配置生成） |

**node-exporter 子命令参数：**

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `-v, --version` | `1.8.2` | Node Exporter 版本号 |
| `--port` | `9100` | 监听端口 |

**alertmanager 子命令参数：**

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `-v, --version` | `0.27.0` | Alertmanager 版本号 |
| `--port` | `9093` | 监听端口 |
| `--config` | (无) | 自定义配置文件路径 |

## 安装后验证

### 快速验证（脚本自动执行）

```bash
# 1. 服务状态
sudo systemctl status prometheus
sudo systemctl status prometheus-node-exporter
sudo systemctl status alertmanager

# 2. 健康检查
curl http://localhost:9090/-/healthy       # "Prometheus Server is Healthy."
curl http://localhost:9090/-/ready         # "Prometheus Server is Ready."
curl http://localhost:9093/-/healthy       # "OK"

# 3. Node Exporter 指标
curl -s http://localhost:9100/metrics | head -5
```

### 功能验证

```bash
# 4. 查看所有 scrape targets 的状态
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool
# 所有 target 的 health 应为 "up"

# 5. 执行 PromQL 查询 — 检查所有目标是否存活
curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool
# 所有 value 应为 "1"

# 6. 查询 Node Exporter 指标 — CPU 使用率
curl -s 'http://localhost:9090/api/v1/query?query=100-(avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100)' \
  | python3 -m json.tool

# 7. 查询内存使用率
curl -s 'http://localhost:9090/api/v1/query?query=(1-node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)*100' \
  | python3 -m json.tool

# 8. 使用 promtool 验证配置文件
promtool check config /etc/prometheus/prometheus.yml
```

### Web UI 验证

| 组件 | URL | 用途 |
|------|-----|------|
| Prometheus | `http://<server-ip>:9090` | 查询、图表、targets 状态、配置查看 |
| Prometheus Targets | `http://<server-ip>:9090/targets` | 查看所有监控目标的抓取状态 |
| Alertmanager | `http://<server-ip>:9093` | 查看/管理告警、静默规则 |
| Node Exporter | `http://<server-ip>:9100/metrics` | 原始指标数据（调试用） |

## 常见问题

### Prometheus 启动失败

```bash
# 查看详细日志
journalctl -u prometheus -f

# 验证配置文件语法
promtool check config /etc/prometheus/prometheus.yml
```

常见原因：
- 配置文件 YAML 语法错误（缩进、冒号后缺少空格）
- 端口被占用：`ss -tlnp | grep :9090`
- 数据目录权限错误：`ls -la /var/lib/prometheus/`
- 版本号不存在（下载失败）

### Target 显示 DOWN

在 Prometheus Web UI → Status → Targets 中查看详细错误。

常见原因：
- 目标服务未启动：`systemctl status node_exporter`
- 防火墙阻断：`curl http://<target>:9100/metrics`
- 配置中 target 地址错误
- Prometheus 和 target 之间网络不通

```bash
# 从 Prometheus 服务器测试连通性
curl -sf http://<target-ip>:9100/metrics | head -5
```

### 数据存储占用过大

```bash
# 查看 TSDB 数据目录大小
du -sh /var/lib/prometheus/

# 查看各个 block 的大小
ls -lh /var/lib/prometheus/
```

解决方案：
- 减少 `--storage.tsdb.retention.time`（如从 30d 改为 15d）
- 增加 `scrape_interval`（如从 15s 改为 30s）
- 减少不必要的指标（通过 `metric_relabel_configs` 丢弃）

### 告警不发送通知

```bash
# 1. 检查 Alertmanager 是否在运行
systemctl status alertmanager

# 2. 检查 Prometheus 是否连接到 Alertmanager
curl -s http://localhost:9090/api/v1/alertmanagers | python3 -m json.tool

# 3. 检查告警规则是否加载
curl -s http://localhost:9090/api/v1/rules | python3 -m json.tool

# 4. 检查 Alertmanager 配置
amtool check-config /etc/alertmanager/alertmanager.yml
```

### 如何热重载配置（不重启服务）

```bash
# 方法 1：发送 SIGHUP 信号
kill -HUP $(pidof prometheus)

# 方法 2：调用 HTTP 端点（需要 --web.enable-lifecycle 启动参数）
curl -X POST http://localhost:9090/-/reload
```

### 如何完全卸载

```bash
# 停止服务
systemctl stop prometheus prometheus-node-exporter alertmanager
systemctl disable prometheus prometheus-node-exporter alertmanager

# 删除 systemd unit 文件
rm -f /etc/systemd/system/prometheus.service
rm -f /etc/systemd/system/prometheus-node-exporter.service
rm -f /etc/systemd/system/alertmanager.service
systemctl daemon-reload

# 删除二进制文件
rm -f /usr/local/bin/{prometheus,promtool,node_exporter,alertmanager,amtool}

# 删除配置和数据（谨慎！数据不可恢复）
rm -rf /etc/prometheus /var/lib/prometheus
rm -rf /etc/alertmanager /var/lib/alertmanager

# 删除用户
userdel prometheus
userdel node_exporter
userdel alertmanager
```

## 安装后常用命令

```bash
# 服务管理
sudo systemctl start prometheus             # 启动
sudo systemctl stop prometheus              # 停止
sudo systemctl restart prometheus           # 重启
sudo systemctl status prometheus            # 状态
journalctl -u prometheus -f                 # 实时日志

# 配置检查
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/*.yml

# PromQL 查询（命令行）
promtool query instant http://localhost:9090 'up'
promtool query instant http://localhost:9090 'node_memory_MemAvailable_bytes / 1024 / 1024'

# Alertmanager 管理
amtool alert --alertmanager.url=http://localhost:9093                  # 查看告警
amtool silence add alertname=TestAlert -d 1h --alertmanager.url=http://localhost:9093  # 静默
amtool check-config /etc/alertmanager/alertmanager.yml                # 配置检查

# 常用 PromQL 表达式
# CPU 使用率
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# 磁盘使用率
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# 网络流量（每秒接收/发送 MB）
rate(node_network_receive_bytes_total{device="eth0"}[5m]) / 1024 / 1024
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) / 1024 / 1024
```

## 参考

- [Prometheus 官方文档](https://prometheus.io/docs/introduction/overview/)
- [Prometheus 下载页面](https://prometheus.io/download/)
- [Node Exporter GitHub](https://github.com/prometheus/node_exporter)
- [Alertmanager GitHub](https://github.com/prometheus/alertmanager)
- [PromQL 查询语法](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Alerting Rules 配置](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
