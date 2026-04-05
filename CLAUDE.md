# CLAUDE.md — bootstrap 项目规范

## 项目概述

bootstrap 是一个基于 `curl | bash` 的轻量化基础设施初始化脚本集，用 bash 编写。目前包含三个服务模块：

- **k8s** — Kubernetes 集群一键安装（master / worker）
- **pgsql** — PostgreSQL 数据库备份与恢复
- **prometheus** — Prometheus 监控安装（server / node-exporter / alertmanager）

## 目录结构

```
bootstrap/
├── install.sh              # 统一入口（curl | bash 分发）
├── common/lib.sh           # 公共函数库（所有脚本都依赖）
├── k8s/install.sh          # K8s 安装脚本
├── pgsql/backup.sh         # PG 备份脚本
├── pgsql/restore.sh        # PG 恢复脚本
├── pgsql/test_pgsql.sh     # PG 单元测试（mock）
├── pgsql/test_integration.sh # PG 集成测试（需真实 PG）
├── prometheus/install.sh   # Prometheus 监控安装脚本
└── docs/                   # 详细文档
```

## 脚本编写规范

### 必须遵守

- 所有脚本以 `#!/usr/bin/env bash` 开头
- 所有脚本设置 `set -euo pipefail`
- 通过 `_load_lib` 加载 `common/lib.sh`，支持三种执行方式（本地克隆、install.sh 分发、curl 直接下载）
- 使用 `common/lib.sh` 提供的日志函数（`log`/`ok`/`warn`/`error`/`step`/`info`），不要自行 echo
- 关键操作前调用 `confirm` 等待用户确认，支持 `--yes` / `-y` 跳过
- 所有操作写入 `$LOG_FILE`

### common/lib.sh 提供的函数

| 函数 | 用途 |
|------|------|
| `log` / `ok` / `warn` / `error` | 日志输出（error 会 exit 1） |
| `step` / `info` | 步骤标题 / 子步骤说明 |
| `confirm` | 等待用户确认（AUTO_YES=true 时跳过） |
| `print_banner` | 打印 ASCII banner |
| `cmd_exists` | 检查命令是否存在 |
| `require_root` | 检查 root 权限 |
| `preflight_base` | 通用预检（系统、内存、网络） |
| `get_arch` / `get_ubuntu_codename` / `get_mem_gb` | 系统信息 |

### 参数解析约定

- 使用 `while [[ $# -gt 0 ]]; do case "$1" in ... esac done` 模式
- 短选项和长选项都要支持（如 `-d` / `--database`）
- 需要值的参数用 `require_arg` 校验
- 提供 `-h` / `--help` 显示用法
- 提供 `-y` / `--yes` 跳过确认

### 脚本结构模式

```bash
#!/usr/bin/env bash
set -euo pipefail

_load_lib    # 加载公共库
# 配置（默认值、环境变量）
# 参数解析（while case）
# 工具函数
# Step 1: preflight
# Step 2: 核心操作
# Step N: 验证
main() { ... }
main "$@"
```

## 测试规范

### 单元测试（mock）

- 文件命名：`test_<module>.sh`
- 通过创建 mock 可执行文件替代外部命令（pg_dump 等），插入 PATH 头部
- mock 将接收到的参数写入日志文件，测试通过读取日志断言参数正确性
- 在 `/tmp` 下创建临时目录，测试后自动清理
- 不依赖任何外部服务

### 集成测试

- 文件命名：`test_integration.sh`
- 需要真实的服务实例（如 Docker PG 容器）
- 连接信息在脚本头部配置
- 测试后自动清理创建的数据库和临时文件

### 运行测试

```bash
# 单元测试
bash pgsql/test_pgsql.sh

# 集成测试（需要 PG 实例）
bash pgsql/test_integration.sh
```

## 文档规范

- 每个服务目录下有一个精简的 `README.md`（快速开始 + 链接）
- 详细文档统一放在 `docs/` 目录下，命名格式：`<service>-<topic>.md`
- 根 `README.md` 包含所有服务的概览和使用示例

## 开发环境

### 当前测试环境

- 宿主机：Ubuntu 22.04，postgresql-client v14
- Docker PG 实例：
  - pg-source（127.0.0.1:5434）— 备份源，PostgreSQL 17
  - pg-target（127.0.0.1:5433）— 恢复目标，PostgreSQL 17
  - 密码：postgres

### 注意事项

- 宿主机 pg 客户端版本（v14）低于 Docker PG 版本（v17），`pg_restore --list` 在宿主机上无法解析 v17 的 dump 文件，但备份和恢复本身不受影响（因为 pg_dump/pg_restore 连接的是远程 PG 服务器）
- 建议升级宿主机 postgresql-client 到 v17 以保持版本一致
