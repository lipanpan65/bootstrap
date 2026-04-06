# Bootstrap CLI 重构设计方案

> 将 bootstrap 从 Bash 脚本集重构为 Python CLI 工具，同时作为 Agent 的 Tool 数据源。

## 目录

- [背景与目标](#背景与目标)
- [设计原则](#设计原则)
- [技术选型](#技术选型)
- [目录结构](#目录结构)
- [分层架构](#分层架构)
- [CLI 层设计](#cli-层设计)
- [Core 层设计](#core-层设计)
- [Agent Tool 层设计](#agent-tool-层设计)
- [Shell 脚本迁移策略](#shell-脚本迁移策略)
- [输出规范](#输出规范)
- [配置管理](#配置管理)
- [错误处理](#错误处理)
- [测试策略](#测试策略)
- [打包与分发](#打包与分发)
- [分阶段实施计划](#分阶段实施计划)
- [FAQ](#faq)

## 背景与目标

### 现状

bootstrap 当前是一个基于 `curl | bash` 的 Bash 脚本集，仓库内已有 `k8s`、`pgsql`、`prometheus` 三个已落地模块，统一通过仓库根目录的 `install.sh` 分发。各模块独立运行，输出以人类可读的终端文本为主，适合人工执行，但不适合作为 Python 库或 Agent Tool 直接复用。

### 为什么要重构

1. **Agent 集成** — 需要作为 AI Agent 的 Tool 数据源，要求结构化输入输出（JSON Schema 定义参数、JSON 返回结果）
2. **可编程性** — Bash 脚本难以作为库被其他程序导入调用，Python 模块可以同时服务 CLI 和 Agent 两个入口
3. **可测试性** — Python 的测试生态（pytest）远优于 Bash，便于维护复杂的测试用例
4. **可扩展性** — 后续新增模块（docker、redis、nginx）时，Python 的模块化组织更清晰

### 目标

| 目标 | 说明 |
|------|------|
| 双入口 | 同一份核心逻辑，CLI（给人用）和 Agent Tool（给 AI 用）共享 |
| 结构化输出 | Python Core / Tool 层返回结构化结果，CLI 层负责格式化为人类可读输出 |
| 渐进迁移 | 第一阶段 Python 壳 + Shell 子进程调用，后续按模块逐步纯 Python 化 |
| 向后兼容 | 现有仓库根目录 `install.sh` 和 Bash 入口继续可用，不先打断 `curl \| bash` 用法 |

### 非目标

- 不重写 k8s 安装逻辑为纯 Python（涉及大量系统级操作，Bash 更合适）
- 不构建 Web UI 或 REST API（Agent 通过 function calling 直接调用 Python 函数）
- 不支持 Windows（目标环境为 Linux 服务器）

### 实施范围（建议 v1）

- `v1` 只承诺落地 `pgsql` 的 Python CLI + Agent Tool 能力
- `k8s` 在 `v1` 只完成接口预研和非交互化改造设计，不承诺一次性全部 Agent 化
- 仓库中现有 `prometheus` 模块继续保持 Bash-only，可在后续阶段评估是否补 Python 包装层
- `v1` 不要求先迁移 Bash 文件目录结构，优先在现有仓库布局上并行引入 `src/bootstrap/`

## 设计原则

1. **Core 层无 I/O 副作用** — 核心函数返回数据结构，不直接 print 或写文件，便于 CLI 和 Agent 复用
2. **CLI 层只做展示** — 接收 Core 层返回值，格式化输出（人类可读 or JSON）
3. **Agent Tool 层只做适配** — 将 Core 层函数包装为符合 Agent 协议的 Tool 定义
4. **渐进替换** — 先并存、后替换；Python 优先复用现有 Bash 脚本，不以目录搬迁作为前置条件
5. **单一职责** — 每个模块只做一件事，模块间通过明确的接口通信

## 技术选型

| 组件 | 选择 | 理由 |
|------|------|------|
| CLI 框架 | **Typer** | 基于类型注解自动生成 CLI 参数和帮助文档，学习成本低，与 Agent Tool Schema 天然对齐 |
| 终端输出 | **Rich** | Typer 的默认依赖，提供彩色输出、表格、进度条，替代 `common/lib.sh` 的日志函数 |
| Agent 协议 | **JSON Schema** | 与 Claude function calling / OpenAI function calling 兼容，从 Python 类型注解自动生成 |
| 数据模型 | **Pydantic** | 参数校验 + JSON Schema 生成 + 序列化，一套模型同时服务 CLI 和 Agent |
| 子进程 | **subprocess** | 标准库，调用现有 Shell 脚本，捕获 stdout/stderr |
| 测试 | **pytest** | Python 生态标准，支持 fixture、参数化、mock |
| 打包 | **pyproject.toml** + **pip** | 标准 Python 打包方式，支持 `pip install .` 和 `pip install -e .` |
| Python 版本 | **>= 3.10** | 需要 `match` 语句和 `X \| Y` 类型联合语法 |

### 为什么选 Typer 而不是 Click

Typer 是 Click 的上层封装，两点关键优势：

1. **类型注解驱动** — 函数签名即 CLI 定义，参数类型、默认值、帮助文本一目了然
2. **与 Pydantic 配合** — 类型注解可同时用于 Pydantic 模型验证和 Typer CLI 解析，减少重复定义

```python
# Typer 风格：函数签名即 CLI 定义
@app.command()
def backup(
    database: Annotated[str, typer.Option("--database", "-d", help="数据库名")],
    host: Annotated[str, typer.Option("--host", "-H", help="数据库地址")] = "127.0.0.1",
    format: Annotated[str, typer.Option("--format", "-F", help="备份格式")] = "custom",
):
    ...
```

## 目录结构

推荐将仓库组织为“两层并存”的形态：

1. **Bash 服务目录按领域分组**：继续保留 `curl | bash` 友好性，但避免根目录一级服务无限平铺。
2. **Python 包按领域镜像**：`src/bootstrap/` 里的 CLI、Core、Tool、Model 也按相同领域拆分，降低后续新增模块时的心智负担。

`v1` 不要求一次性完成目录搬迁；可以先通过兼容入口和 shim 逐步把现有文件迁到目标结构。

```
bootstrap/
├── install.sh                      # 保留现有统一入口，继续服务 curl | bash
├── README.md                       # 项目说明（更新）
├── CLAUDE.md                       # Claude Code 项目规范（更新）
├── LICENSE
│
├── common/
│   └── lib.sh                      # Bash 公共库（跨领域复用）
│
├── platforms/                      # 基础平台/集群类能力
│   └── k8s/
│       ├── README.md               # K8s 领域快速开始
│       ├── shared/
│       │   └── lib.sh              # K8s 领域共享函数（可选，后续按需拆出）
│       ├── kubeadm/
│       │   ├── install.sh          # 现有 kubeadm 安装主脚本
│       │   └── README.md
│       └── kind/
│           ├── install.sh          # Kind 学习/本地集群安装脚本
│           └── README.md
│
├── services/                       # 面向业务服务或中间件的运维能力
│   └── pgsql/
│       ├── README.md               # PG 快速开始
│       ├── backup/
│       │   └── run.sh              # 原 backup.sh 的目标归位
│       ├── restore/
│       │   └── run.sh              # 原 restore.sh 的目标归位
│       └── tests/
│           ├── test_pgsql.sh
│           └── test_integration.sh
│
├── observability/                  # 可观测性相关能力
│   └── prometheus/
│       ├── install.sh              # 现有 Prometheus 脚本，先不纳入 v1 Python 化
│       └── README.md
│
├── pyproject.toml                  # Python 项目元数据、依赖、入口点
├── src/
│   └── bootstrap/                  # Python 包
│       ├── __init__.py
│       ├── cli/                    # CLI 层（Typer 入口）
│       │   ├── __init__.py
│       │   ├── main.py             # 顶层命令组：bootstrap <subcommand>
│       │   ├── platforms/
│       │   │   └── k8s.py
│       │   ├── services/
│       │   │   └── pgsql.py
│       │   └── observability/
│       │       └── prometheus.py   # 后续阶段补充
│       ├── core/                   # Core 层（业务逻辑，无 I/O）
│       │   ├── __init__.py
│       │   ├── platforms/
│       │   │   └── k8s/
│       │   │       ├── kubeadm.py
│       │   │       └── kind.py
│       │   ├── services/
│       │   │   └── pgsql.py
│       │   └── observability/
│       │       └── prometheus.py
│       ├── tools/                  # Agent Tool 层（Tool 定义）
│       │   ├── __init__.py
│       │   ├── registry.py
│       │   ├── platforms/
│       │   │   └── k8s.py
│       │   ├── services/
│       │   │   └── pgsql.py
│       │   └── observability/
│       │       └── prometheus.py
│       ├── models/                 # Pydantic 数据模型
│       │   ├── __init__.py
│       │   ├── platforms/
│       │   │   └── k8s.py
│       │   ├── services/
│       │   │   └── pgsql.py
│       │   └── observability/
│       │       └── prometheus.py
│       └── utils/
│           ├── __init__.py
│           ├── shell.py            # subprocess 封装，调用现有 Bash 脚本
│           ├── logging.py          # Rich 日志
│           └── system.py
│
├── tests/
│   ├── bash/                       # Bash 脚本相关测试/适配验证（可选，逐步建设）
│   ├── unit/
│   │   ├── conftest.py
│   │   ├── platforms/
│   │   │   └── test_k8s_core.py
│   │   ├── services/
│   │   │   ├── test_pgsql_core.py
│   │   │   ├── test_pgsql_cli.py
│   │   │   └── test_pgsql_tools.py
│   │   └── test_models.py
│   ├── integration/
│   │   └── services/
│   │       └── test_pgsql_e2e.py
│   └── fixtures/                   # 测试输入、样例输出、schema fixture
│
└── docs/
    ├── cli-refactor-design.md      # 本文档
    ├── architecture/               # 架构设计、迁移策略、约束说明
    ├── platforms/
    │   └── k8s/
    │       ├── install.md
    │       ├── dashboard.md
    │       ├── kubeadm.md
    │       └── kind.md
    ├── services/
    │   └── pgsql/
    │       ├── backup-restore.md
    │       └── test-plan.md
    └── observability/
        └── prometheus/
            └── install.md
```

### 与现有结构的关系

| 现有文件 | 目标位置 | 说明 |
|----------|---------|------|
| `install.sh` | `install.sh` + `src/bootstrap/` | 根入口保留；Python CLI 作为新增入口并存 |
| `common/lib.sh` | `common/lib.sh` + `src/bootstrap/utils/` | Bash 公共库保留，Python 侧补等价能力 |
| `k8s/install.sh` | `platforms/k8s/kubeadm/install.sh` + `src/bootstrap/core/platforms/k8s/kubeadm.py` | 先保留 Shell 实现，Python 通过 subprocess 调用 |
| `kind/install.sh` | `platforms/k8s/kind/install.sh` + `src/bootstrap/core/platforms/k8s/kind.py` | 将 Kind 明确归入 K8s 领域，避免长期与 K8s 平级漂移 |
| `k8s/README.md` | `platforms/k8s/README.md` + `docs/platforms/k8s/` | K8s 领域 README 保持精简，深文档按领域归档 |
| `kind/README.md` | `platforms/k8s/kind/README.md` + `docs/platforms/k8s/kind.md` | Kind 保留快速开始，同时补领域文档 |
| `pgsql/backup.sh` | `services/pgsql/backup/run.sh` + `src/bootstrap/core/services/pgsql.py` | `v1` 继续复用脚本，后续再评估纯 Python 化 |
| `pgsql/restore.sh` | `services/pgsql/restore/run.sh` + `src/bootstrap/core/services/pgsql.py` | 同上 |
| `pgsql/README.md` | `services/pgsql/README.md` + `docs/services/pgsql/` | README 提供最短路径，深度说明单独维护 |
| `prometheus/install.sh` | `observability/prometheus/install.sh` | 保持现状，暂不纳入 `v1` |
| `prometheus/README.md` | `observability/prometheus/README.md` + `docs/observability/prometheus/` | 继续保留快速开始定位 |
| `pgsql/test_*.sh` | `services/pgsql/tests/` + `tests/bash/` + `tests/unit/services/` | 先并存，再逐步把高价值用例迁到 pytest |

### 迁移策略补充

- `v1` 可以继续保留 `k8s/`、`kind/`、`pgsql/`、`prometheus/` 这些现有顶级目录，通过根 `install.sh` 或兼容 wrapper 转发到新位置。
- 物理目录迁移不应早于接口稳定；先固定命令和参数契约，再逐步搬迁文件更稳妥。
- 对外暴露的访问路径应尽量稳定，避免文档链接、`curl | bash` 用法、自动化脚本因目录整理而失效。

### 目录设计原则（推荐）

1. **先按领域分组，再按动作拆分**：先回答“这是谁的能力域”，再回答“这里有哪些脚本/子命令”。例如 `kind` 应属于 `k8s` 域，而不是长期与 `k8s` 平级。
2. **Bash 是入口层，不是遗留层**：保留脚本友好的入口，但脚本目录也要为长期增长预留层次，避免根目录和模块目录双重平铺。
3. **Python 包镜像 Bash 领域结构**：`cli / core / tools / models` 都按同一套领域边界组织，减少未来新增模块时的重复决策。
4. **README 负责快速开始，docs 负责深入说明**：模块内 README 保留最短路径，深入文档按领域沉淀到 `docs/`，而不是仅按受众拆分。
5. **测试同时按形态和领域拆分**：Bash 测试、单元测试、集成测试继续区分，但在各层内部也按 `platforms / services / observability` 分类，避免后期文件平铺失控。

## 分层架构

```
┌───────────────────────────────────────────────────────────────┐
│                        调用方                                  │
│                                                               │
│   人类用户 (终端)              AI Agent (function calling)      │
│        │                              │                       │
│        ▼                              ▼                       │
│  ┌──────────┐                 ┌──────────────┐                │
│  │ CLI 层    │                 │ Agent Tool 层 │               │
│  │ (Typer)  │                 │ (JSON Schema) │               │
│  └────┬─────┘                 └──────┬───────┘                │
│       │                              │                        │
│       │      ┌──────────────┐        │                        │
│       └─────►│   Core 层     │◄──────┘                        │
│              │  (业务逻辑)    │                                │
│              └──────┬───────┘                                 │
│                     │                                         │
│              ┌──────┴───────┐                                 │
│              │  Models 层    │                                 │
│              │ (Pydantic)   │                                 │
│              └──────┬───────┘                                 │
│                     │                                         │
│              ┌──────┴───────┐                                 │
│              │  Utils 层     │                                 │
│              │ (shell/log)  │                                 │
│              └──────┬───────┘                                 │
│                     │                                         │
│                     ▼                                         │
│              ┌──────────────┐                                 │
│              │ Bash 脚本     │  ← 过渡期通过 subprocess 调用    │
│              │ (现有仓库结构) │  ← 逐步替换为纯 Python           │
│              └──────────────┘                                 │
└───────────────────────────────────────────────────────────────┘
```

### 层间依赖规则

| 层 | 可以依赖 | 不可依赖 |
|---|---------|---------|
| CLI | Core, Models, Utils | Agent Tool |
| Agent Tool | Core, Models | CLI, Utils（不直接用） |
| Core | Models, Utils | CLI, Agent Tool |
| Models | 无（纯数据定义） | 任何其他层 |
| Utils | 无 | 任何其他层 |

## CLI 层设计

### 命令结构

```
bootstrap                          # 顶层命令
├── pgsql                          # PostgreSQL 子命令组
│   ├── backup                     # 备份
│   ├── restore                    # 恢复
│   └── list-backups               # 列出备份文件（新增）
│
├── k8s                            # Kubernetes 子命令组
│   ├── init                       # 初始化集群（原 master）
│   ├── join                       # 加入集群（原 worker）
│   ├── label-workers              # 为 worker 打标签
│   └── dashboard                  # 安装 Dashboard
│
├── tools                          # Agent Tool 管理（新增）
│   ├── list                       # 列出所有可用 Tool
│   └── schema                     # 输出指定 Tool 的 JSON Schema
│
└── version                        # 版本信息
```

### CLI 用法示例

```bash
# 安装后使用
pip install .
bootstrap pgsql backup -d mydb -H 10.0.0.1 --yes
bootstrap pgsql restore mydb.dump -d mydb_new --yes
bootstrap k8s init --yes
bootstrap k8s join

# JSON 输出模式（供脚本/Agent 使用）
bootstrap --output json pgsql backup -d mydb --yes

# 查看可用的 Agent Tools
bootstrap tools list
bootstrap tools schema pgsql_backup
```

### 命名规范与兼容别名策略

为避免后续 `k8s`、`kind`、`pgsql` 持续扩张时出现命名漂移，命名策略需要同时约束 **用户入口**、**内部实现**、**Tool 标识** 三个层面。

#### 1. 用户入口：优先短命令，但要保留长期可扩展性

- 对外 CLI 应尽量保持简短、稳定、便于记忆，例如 `bootstrap pgsql backup`。
- 当某个领域下只有一种主实现时，可以先使用扁平命名；一旦同领域下出现多种实现，主命名应升级为“领域 + 实现 + 动作”。
- 因此 `pgsql` 适合长期保持 `bootstrap pgsql backup` / `bootstrap pgsql restore`。
- `k8s` 则应为未来的多实现结构预留空间，推荐的长期主命名为：

```bash
bootstrap k8s kubeadm init
bootstrap k8s kubeadm join
bootstrap k8s kind create
bootstrap k8s kind delete
```

#### 2. 兼容别名：迁移期允许短命令，但不作为长期主入口

- 在 `v1` 和迁移阶段，可以继续保留简写别名：

```bash
bootstrap k8s init      # alias -> bootstrap k8s kubeadm init
bootstrap k8s join      # alias -> bootstrap k8s kubeadm join
```

- `curl | bash` 时代遗留的 `k8s master` / `k8s worker` 也应继续兼容一段时间，但文档中的主示例应逐步切换到 `init` / `join`。
- 兼容别名的目标是降低迁移成本，不应成为新增能力的默认命名模式。

#### 3. 内部实现：路径和包结构必须镜像领域边界

- Bash 脚本目录、Python 包、文档目录、测试目录都应遵循同一套领域边界。
- `kind` 属于 `k8s` 领域下的一种实现，不再作为长期顶级模块扩张。
- 推荐保持如下映射关系：

```text
CLI:        bootstrap k8s kubeadm init
Python:     bootstrap.core.platforms.k8s.kubeadm
Bash:       platforms/k8s/kubeadm/install.sh
Docs:       docs/platforms/k8s/kubeadm.md
```

#### 4. Tool 标识：优先可扩展命名空间

- Tool 名称应优先考虑长期扩展性，而不是只追求当前最短形式。
- 推荐的长期主命名使用分层命名空间：

```text
pgsql.backup
pgsql.restore
k8s.kubeadm.init
k8s.kubeadm.join
k8s.kind.create
```

- 如果 `v1` 为兼容现有实现仍保留下划线风格，如 `pgsql_backup`、`k8s_init`，应明确其为兼容别名，而非长期标准。

#### 5. 迁移期约束

- `v1` 可以先不物理搬迁 Bash 目录，但新增设计文档、Python 示例、Tool 命名都应以目标结构为准。
- 若 Python 代码在 `v1` 仍调用旧路径，应通过统一的路径解析层或兼容 wrapper 实现，而不要在各处硬编码两套路径。
- 新增能力时禁止继续引入新的顶级平级目录来绕过既定边界，例如不再新增与 `k8s` 平级的长期 `kind` 扩展路径。

### CLI 层代码示例

```python
# src/bootstrap/cli/main.py
import typer
from bootstrap.cli.platforms import k8s
from bootstrap.cli.services import pgsql

app = typer.Typer(
    name="bootstrap",
    help="基础设施初始化工具",
    no_args_is_help=True,
)

# 对外命令保持扁平，内部实现按领域分组存放
app.add_typer(pgsql.app, name="pgsql", help="PostgreSQL 备份与恢复")
app.add_typer(k8s.app, name="k8s", help="Kubernetes 集群管理")


@app.callback()
def main(
    output: Annotated[str, typer.Option("--output", "-o", help="输出格式")] = "text",
):
    """bootstrap — 基础设施初始化工具"""
    ctx = typer.get_current_context()
    ctx.ensure_object(dict)
    ctx.obj["output"] = output
```

```python
# src/bootstrap/cli/services/pgsql.py
import typer
from typing import Annotated, Optional
from bootstrap.core.services.pgsql import run_backup
from bootstrap.models.services.pgsql import BackupParams

app = typer.Typer(no_args_is_help=True)


@app.command()
def backup(
    database: Annotated[str, typer.Option("--database", "-d", help="数据库名")],
    host: Annotated[str, typer.Option("--host", "-H", help="数据库地址")] = "127.0.0.1",
    port: Annotated[int, typer.Option("--port", "-p", help="端口")] = 5432,
    user: Annotated[str, typer.Option("--user", "-U", help="用户名")] = "postgres",
    format: Annotated[str, typer.Option("--format", "-F", help="备份格式: custom/directory/tar/plain")] = "custom",
    compress: Annotated[int, typer.Option("--compress", "-Z", help="压缩级别 0-9")] = 6,
    tables: Annotated[Optional[list[str]], typer.Option("--table", "-t", help="只备份指定表")] = None,
    exclude_tables: Annotated[Optional[list[str]], typer.Option("--exclude-table", "-T", help="排除指定表")] = None,
    schema_only: Annotated[bool, typer.Option("--schema-only", help="只备份表结构")] = False,
    data_only: Annotated[bool, typer.Option("--data-only", help="只备份数据")] = False,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
):
    """备份 PostgreSQL 数据库"""
    params = BackupParams(
        database=database, host=host, port=port, user=user,
        format=format, compress=compress,
        tables=tables or [], exclude_tables=exclude_tables or [],
        schema_only=schema_only, data_only=data_only,
    )
    result = run_backup(params, interactive=not yes)

    # 根据 output 格式决定输出方式
    ctx = typer.get_current_context()
    if ctx.obj.get("output") == "json":
        print(result.model_dump_json(indent=2))
    else:
        _print_backup_result(result)
```

## Core 层设计

Core 层是业务逻辑的核心，不依赖任何 I/O 框架（不 print、不读 stdin），只接收参数模型、返回结果模型。

### 接口定义

```python
# src/bootstrap/core/services/pgsql.py

from bootstrap.models.services.pgsql import (
    BackupParams, BackupResult,
    RestoreParams, RestoreResult,
)


def run_backup(params: BackupParams, interactive: bool = False) -> BackupResult:
    """
    执行 PostgreSQL 备份。

    第一阶段：调用现有 `services/pgsql/backup/run.sh`（subprocess）
    第二阶段：纯 Python 实现（直接调用 pg_dump）

    Args:
        params: 备份参数
        interactive: 是否允许交互确认（CLI 传 True，Agent 传 False）

    Returns:
        BackupResult: 包含备份文件路径、大小、耗时等信息
    """
    ...


def run_restore(params: RestoreParams, interactive: bool = False) -> RestoreResult:
    """执行 PostgreSQL 恢复。"""
    ...


def list_backups(output_dir: str = "/data/backup/pgsql") -> list[BackupFileInfo]:
    """列出备份目录中的备份文件。"""
    ...
```

```python
# src/bootstrap/core/platforms/k8s/kubeadm.py

from bootstrap.models.platforms.k8s import InitParams, InitResult, JoinParams, JoinResult


def run_init(params: InitParams, interactive: bool = False) -> InitResult:
    """
    初始化 K8s master 节点。

    始终通过 subprocess 调用现有 `platforms/k8s/kubeadm/install.sh master`。
    K8s 安装涉及大量系统级操作（内核参数、systemd 服务），
    纯 Python 实现收益低，保持 Shell 脚本更合理。

    Returns:
        InitResult: 包含 join 命令、API Server 地址等信息
    """
    ...


def run_join(params: JoinParams, interactive: bool = False) -> JoinResult:
    """加入 K8s 集群。"""
    ...


def label_workers() -> LabelResult:
    """为未标记的 worker 节点打标签。"""
    ...
```

### Core 层的第一阶段实现（subprocess 调用）

```python
# src/bootstrap/core/services/pgsql.py — 第一阶段

import subprocess
import json
import time
from pathlib import Path

from bootstrap.models.services.pgsql import BackupParams, BackupResult
from bootstrap.utils.shell import run_script


def run_backup(params: BackupParams, interactive: bool = False) -> BackupResult:
    # Pydantic 在 BackupParams 实例化时已完成约束校验
    repo_root = Path(__file__).parent.parent.parent.parent
    script = repo_root / "services" / "pgsql" / "backup" / "run.sh"

    args = [
        str(script),
        "-d", params.database,
        "-H", params.host,
        "-p", str(params.port),
        "-U", params.user,
        "-F", params.format,
        "-Z", str(params.compress),
    ]
    for t in params.tables:
        args.extend(["-t", t])
    for t in params.exclude_tables:
        args.extend(["-T", t])
    if params.schema_only:
        args.append("--schema-only")
    if params.data_only:
        args.append("--data-only")
    if not interactive:
        args.append("--yes")

    start = time.time()
    result = run_script(args)
    elapsed = time.time() - start

    return BackupResult(
        success=result.returncode == 0,
        database=params.database,
        # v1 允许从 stdout 中提取结果；后续应升级为脚本显式输出 JSON 或结果文件
        file_path=_extract_backup_path(result.stdout),
        file_size=_get_file_size(result.stdout),
        format=params.format,
        elapsed_seconds=round(elapsed, 2),
        stdout=result.stdout,
        stderr=result.stderr,
    )
```

## Agent Tool 层设计

Agent Tool 层将 Core 层函数包装为 AI Agent 可调用的 Tool。核心职责：

1. 定义 Tool 的 JSON Schema（参数描述、类型约束）
2. 将 Agent 传入的参数转换为 Core 层的 Pydantic 模型
3. 将 Core 层返回的结果序列化为 JSON

### Tool 定义示例

```python
# src/bootstrap/tools/services/pgsql.py

from bootstrap.core.services.pgsql import run_backup, run_restore, list_backups
from bootstrap.models.services.pgsql import BackupParams, RestoreParams


def tool_pgsql_backup(
    database: str,
    host: str = "127.0.0.1",
    port: int = 5432,
    user: str = "postgres",
    format: str = "custom",
    compress: int = 6,
    tables: list[str] | None = None,
    exclude_tables: list[str] | None = None,
    schema_only: bool = False,
    data_only: bool = False,
) -> dict:
    """
    备份 PostgreSQL 数据库。

    支持四种备份格式（custom/directory/tar/plain），推荐使用 custom 格式。
    备份文件存储在 /data/backup/pgsql/ 目录下，自动按保留策略清理过期备份。

    Args:
        database: 要备份的数据库名（必填）
        host: 数据库地址
        port: 数据库端口
        user: 连接用户名
        format: 备份格式 - custom(推荐,支持并行恢复), directory, tar, plain
        compress: 压缩级别 0-9，默认 6
        tables: 只备份指定的表（可选）
        exclude_tables: 排除指定的表（可选）
        schema_only: 只备份表结构，不含数据
        data_only: 只备份数据，不含表结构

    Returns:
        dict: {success, database, file_path, file_size, format, elapsed_seconds}
    """
    params = BackupParams(
        database=database, host=host, port=port, user=user,
        format=format, compress=compress,
        tables=tables or [], exclude_tables=exclude_tables or [],
        schema_only=schema_only, data_only=data_only,
    )
    result = run_backup(params, interactive=False)
    return result.model_dump()


def tool_pgsql_restore(
    backup_file: str,
    database: str | None = None,
    host: str = "127.0.0.1",
    port: int = 5432,
    user: str = "postgres",
    jobs: int = 4,
    clean: bool = True,
) -> dict:
    """
    恢复 PostgreSQL 数据库。

    自动检测备份文件格式，选择合适的恢复方式（pg_restore 或 psql）。
    如果目标数据库不存在，会自动创建。

    Args:
        backup_file: 备份文件路径（.dump/.sql/.tar/目录）
        database: 目标数据库名（不指定则从文件名推断）
        host: 目标数据库地址
        port: 目标数据库端口
        user: 连接用户名
        jobs: 并行恢复线程数（仅 custom/directory 格式）
        clean: 恢复前是否删除已有对象

    Returns:
        dict: {success, database, backup_file, format, elapsed_seconds}
    """
    params = RestoreParams(
        backup_file=backup_file, database=database,
        host=host, port=port, user=user,
        jobs=jobs, clean=clean,
    )
    result = run_restore(params, interactive=False)
    return result.model_dump()


def tool_pgsql_list_backups(
    output_dir: str = "/data/backup/pgsql",
    database: str | None = None,
) -> dict:
    """
    列出备份目录中的备份文件。

    Args:
        output_dir: 备份目录路径
        database: 只列出指定数据库的备份（可选）

    Returns:
        dict: {backups: [{file_path, database, format, size, created_at}]}
    """
    backups = list_backups(output_dir)
    if database:
        backups = [b for b in backups if b.database == database]
    return {"backups": [b.model_dump() for b in backups]}
```

### Tool 注册表

```python
# src/bootstrap/tools/registry.py

from bootstrap.models.platforms.k8s import DashboardParams, InitParams, JoinParams, LabelWorkersParams
from bootstrap.models.services.pgsql import BackupParams, ListBackupsParams, RestoreParams
from bootstrap.tools.platforms.k8s import (
    tool_k8s_dashboard,
    tool_k8s_init,
    tool_k8s_join,
    tool_k8s_label_workers,
)
from bootstrap.tools.services.pgsql import (
    tool_pgsql_backup,
    tool_pgsql_restore,
    tool_pgsql_list_backups,
)


# 所有可用的 Tool
TOOLS = {
    "pgsql_backup": tool_pgsql_backup,
    "pgsql_restore": tool_pgsql_restore,
    "pgsql_list_backups": tool_pgsql_list_backups,
    "k8s_init": tool_k8s_init,
    "k8s_join": tool_k8s_join,
    "k8s_label_workers": tool_k8s_label_workers,
    "k8s_dashboard": tool_k8s_dashboard,
}

# 生成 Schema 时使用的输入模型和描述
TOOL_INPUT_MODELS = {
    "pgsql_backup": BackupParams,
    "pgsql_restore": RestoreParams,
    "pgsql_list_backups": ListBackupsParams,
    "k8s_init": InitParams,
    "k8s_join": JoinParams,
    "k8s_label_workers": LabelWorkersParams,
    "k8s_dashboard": DashboardParams,
}

TOOL_DESCRIPTIONS = {
    "pgsql_backup": "备份 PostgreSQL 数据库。",
    "pgsql_restore": "恢复 PostgreSQL 数据库。",
    "pgsql_list_backups": "列出备份目录中的备份文件。",
    "k8s_init": "初始化 K8s master 节点。",
    "k8s_join": "让 worker 节点加入集群。",
    "k8s_label_workers": "为未标记节点补 worker 标签。",
    "k8s_dashboard": "安装 K8s Dashboard。",
}


def get_tool(name: str):
    """获取指定名称的 Tool 函数。"""
    return TOOLS.get(name)


def get_all_schemas() -> list[dict]:
    """获取所有 Tool 的 JSON Schema（用于 Agent 注册）。"""
    schemas = []
    for name, model in TOOL_INPUT_MODELS.items():
        schemas.append(_model_to_tool_schema(name, model, TOOL_DESCRIPTIONS[name]))
    return schemas


def get_schema(name: str) -> dict | None:
    """获取指定 Tool 的 JSON Schema。"""
    model = TOOL_INPUT_MODELS.get(name)
    if model:
        return _model_to_tool_schema(name, model, TOOL_DESCRIPTIONS[name])
    return None
```

### 自动生成 JSON Schema

推荐以 **Pydantic 模型** 作为 Schema 真源，再由 Tool 层补充名称与说明。函数签名仍可保留为易用的 Python API，但不要把复杂约束完全依赖在 `inspect + docstring` 上，否则 `Literal`、数值范围、数组元素类型、互斥关系等信息容易丢失。

```python
from pydantic import BaseModel


def _model_to_tool_schema(name: str, model: type[BaseModel], description: str) -> dict:
    """
    将 Pydantic 输入模型转换为 Agent Tool JSON Schema。

    优点：
    - 与 CLI / Tool 共享同一份字段定义
    - 自动保留 enum、默认值、范围约束、数组元素类型
    - 避免手写 inspect 逻辑与真实参数模型漂移
    """
    schema = model.model_json_schema()
    return {
        "name": name,
        "description": description,
        "parameters": schema,
    }
```

对于 `confirm=False -> pending_confirmation -> confirm=True` 这种两阶段确认流程，可在输入模型中显式加入 `confirm: bool = False` 字段，并把执行计划的返回结构定义为独立的结果模型，避免把确认机制“藏”在 docstring 里。

### 生成的 JSON Schema 示例

```json
{
  "name": "pgsql_backup",
  "description": "备份 PostgreSQL 数据库。",
  "parameters": {
    "type": "object",
    "properties": {
      "database": {
        "type": "string",
        "description": "要备份的数据库名（必填）"
      },
      "host": {
        "type": "string",
        "description": "数据库地址",
        "default": "127.0.0.1"
      },
      "port": {
        "type": "integer",
        "description": "数据库端口",
        "default": 5432
      },
      "format": {
        "type": "string",
        "description": "备份格式 - custom(推荐,支持并行恢复), directory, tar, plain",
        "default": "custom"
      },
      "tables": {
        "type": "array",
        "items": {"type": "string"},
        "description": "只备份指定的表（可选）"
      },
      "schema_only": {
        "type": "boolean",
        "description": "只备份表结构，不含数据",
        "default": false
      }
    },
    "required": ["database"]
  }
}
```

### Agent 集成方式

```python
# 方式 1：Claude function calling
from bootstrap.tools.registry import get_all_schemas, get_tool

# 注册 Tools
tools = get_all_schemas()
response = client.messages.create(
    model="claude-sonnet-4-20250514",
    tools=tools,
    messages=[{"role": "user", "content": "帮我备份 mydb 数据库"}],
)

# 执行 Tool 调用
for block in response.content:
    if block.type == "tool_use":
        func = get_tool(block.name)
        result = func(**block.input)


# 方式 2：直接 import 使用
from bootstrap.tools.services.pgsql import tool_pgsql_backup

result = tool_pgsql_backup(database="mydb", host="10.0.0.1")
print(result)
# {"success": true, "file_path": "/data/backup/pgsql/daily/mydb_20260405_120000.dump", ...}
```

## Agent 集成深度设计

### Tool 粒度：查询 + 操作分离

Agent 在执行运维操作前，通常需要先**探查环境**再**执行操作**。例如用户说"帮我备份生产数据库"，Agent 的决策链路是：

```
用户: "帮我备份生产数据库"
    │
    ▼
Agent 调用 pgsql_check_connection(host="10.0.0.1")
    → {"reachable": true, "version": "PostgreSQL 17.2"}
    │
    ▼
Agent 调用 pgsql_list_databases(host="10.0.0.1")
    → {"databases": [{"name": "proddb", "size": "2.3 GB"}, ...]}
    │
    ▼
Agent 调用 pgsql_list_backups(database="proddb")
    → {"backups": [...], "latest": "2026-04-04 02:00:00"}
    │
    ▼
Agent 判断：上次备份是昨天，需要新备份；2.3GB 用 custom 格式
    │
    ▼
Agent 调用 pgsql_backup(database="proddb", host="10.0.0.1", format="custom")
    → {"success": true, "file_path": "...", "file_size": 824000000}
```

因此 Tool 应按**查询类**和**操作类**分组：

| Tool | 类型 | 副作用 | 需要确认 |
|------|------|--------|---------|
| `pgsql_check_connection` | 查询 | 无 | 否 |
| `pgsql_list_databases` | 查询 | 无 | 否 |
| `pgsql_list_backups` | 查询 | 无 | 否 |
| `pgsql_backup` | 操作 | 创建文件、清理过期备份 | 否（非破坏性） |
| `pgsql_restore` | 操作 | **覆盖目标数据库** | **是** |
| `k8s_get_nodes` | 查询 | 无 | 否 |
| `k8s_get_pods` | 查询 | 无 | 否 |
| `k8s_init` | 操作 | **初始化集群** | **是** |
| `k8s_join` | 操作 | 加入集群 | **是** |
| `k8s_label_workers` | 操作 | 修改标签 | 否 |
| `k8s_dashboard` | 操作 | 部署应用 | 否 |

**查询类 Tool 是 Agent 的"眼睛"**——安全、幂等、可反复调用，帮助 Agent 理解当前环境状态后做出正确决策。

### 查询类 Tool 示例

```python
# src/bootstrap/tools/services/pgsql.py

def tool_pgsql_check_connection(
    host: str = "127.0.0.1",
    port: int = 5432,
    user: str = "postgres",
) -> dict:
    """
    检测 PostgreSQL 连接可达性。

    在执行备份或恢复前，先调用此工具确认数据库可连接。

    Returns:
        dict: {reachable, version, latency_ms, error}
    """
    ...


def tool_pgsql_list_databases(
    host: str = "127.0.0.1",
    port: int = 5432,
    user: str = "postgres",
) -> dict:
    """
    列出 PostgreSQL 实例中的所有数据库及其大小。

    用于了解有哪些数据库可以备份，以及评估备份所需的磁盘空间。

    Returns:
        dict: {databases: [{name, size_bytes, size_human, owner, encoding}]}
    """
    ...
```

### 危险操作的确认机制

Agent 直接调用 `pgsql_restore --clean` 或 `k8s_init` 等破坏性操作时，没有人类确认环节。设计**两阶段确认机制**：

```
Agent 第一次调用（confirm=False，默认值）
    │
    ▼
Tool 返回执行计划（status="pending_confirmation"），不实际执行
    │
    ▼
Agent 将计划展示给用户，获得确认
    │
    ▼
Agent 第二次调用（confirm=True）
    │
    ▼
Tool 真正执行操作
```

对于 `k8s_join` 这类当前 Bash 版本依赖 `/dev/tty` 粘贴命令的流程，不能直接照搬为 Agent Tool。要进入 Python / Agent 体系，必须先把底层接口改成**非交互参数化**形式，例如显式传入 `join_command` 或拆成 `create_join_command` / `join_with_token` 两个步骤。

```python
def tool_pgsql_restore(
    backup_file: str,
    database: str | None = None,
    host: str = "127.0.0.1",
    port: int = 5432,
    user: str = "postgres",
    jobs: int = 4,
    clean: bool = True,
    confirm: bool = False,       # 关键参数
) -> dict:
    """
    恢复 PostgreSQL 数据库。

    首次调用（confirm=False）返回执行计划，不实际执行。
    确认后再次调用（confirm=True）才真正执行恢复。

    Args:
        ...
        confirm: 设为 True 确认执行。首次调用留空以获取执行计划。
    """
    if not confirm:
        # 返回执行计划
        plan = _build_restore_plan(backup_file, database, host, clean)
        return {
            "status": "pending_confirmation",
            "plan": plan,
            "warning": "此操作将覆盖目标数据库中的现有数据" if clean else None,
            "hint": "确认执行请再次调用并设置 confirm=True",
        }

    # confirm=True，真正执行
    params = RestoreParams(...)
    result = run_restore(params, interactive=False)
    return result.model_dump()
```

**执行计划示例：**

```json
{
  "status": "pending_confirmation",
  "plan": {
    "action": "restore",
    "backup_file": "/data/backup/pgsql/daily/proddb_20260405_020000.dump",
    "backup_size": "800 MB",
    "backup_format": "custom",
    "target_database": "proddb",
    "target_host": "10.0.0.1:5432",
    "will_drop_existing": true,
    "estimated_duration": "约 2-5 分钟"
  },
  "warning": "此操作将覆盖目标数据库中的现有数据",
  "hint": "确认执行请再次调用并设置 confirm=True"
}
```

### 返回值设计：信息密度与可操作性

Agent 需要从 Tool 返回值中**获取足够信息做下一步决策**。设计原则：

1. **精确的数值** — `file_size: 824000000` 而非 `"大约 800MB"`
2. **人类可读的辅助字段** — `file_size_human: "800 MB"`（Agent 展示给用户时用）
3. **上下文信息** — 告诉 Agent 当前状态和可选的后续操作
4. **错误时提供诊断信息** — 不只说"失败了"，还要说"为什么失败"和"怎么修"

```python
class BackupResult(BaseModel):
    """备份结果。"""
    # 核心状态
    success: bool
    error: str | None = None

    # 备份信息
    database: str
    file_path: str | None = None
    file_size: int | None = None
    file_size_human: str | None = None
    format: str
    elapsed_seconds: float

    # 上下文（帮助 Agent 决策）
    tables_count: int | None = None           # 备份了多少张表
    cleanup_summary: CleanupSummary | None = None  # 过期清理结果

    # Agent 提示
    next_actions: list[str] = Field(default_factory=list)


class CleanupSummary(BaseModel):
    """过期清理摘要。"""
    expired_removed: int     # 删除了几个过期文件
    remaining: int           # 还剩几个备份
    oldest_backup: str       # 最早的备份日期
```

**成功返回值示例：**

```json
{
  "success": true,
  "database": "proddb",
  "file_path": "/data/backup/pgsql/daily/proddb_20260405_120000.dump",
  "file_size": 824000000,
  "file_size_human": "786 MB",
  "format": "custom",
  "elapsed_seconds": 45.2,
  "tables_count": 67,
  "cleanup_summary": {
    "expired_removed": 2,
    "remaining": 6,
    "oldest_backup": "2026-03-30"
  },
  "next_actions": [
    "使用 pgsql_restore 可恢复此备份到目标数据库",
    "使用 pgsql_list_backups 可查看所有备份文件"
  ]
}
```

**失败返回值示例：**

```json
{
  "success": false,
  "database": "proddb",
  "error": "pg_dump: connection to server at \"10.0.0.1\", port 5432 failed: Connection refused",
  "format": "custom",
  "elapsed_seconds": 0.3,
  "diagnosis": {
    "probable_cause": "数据库服务未运行或网络不可达",
    "suggestions": [
      "使用 pgsql_check_connection 验证连接",
      "检查目标主机防火墙是否放行 5432 端口",
      "确认 PostgreSQL 服务正在运行"
    ]
  },
  "next_actions": [
    "使用 pgsql_check_connection 检测连接状态"
  ]
}
```

### Tool Docstring 规范

Tool 函数的 docstring 是 Agent 理解"这个工具能做什么"的唯一途径。需要包含：

1. **一句话摘要** — Agent 快速判断是否需要这个 Tool
2. **使用场景** — 什么时候该用这个 Tool
3. **参数说明** — 每个参数的含义和约束
4. **返回值说明** — 返回哪些字段
5. **注意事项** — 权限要求、副作用、前置条件

```python
def tool_pgsql_backup(
    database: str,
    host: str = "127.0.0.1",
    ...
) -> dict:
    """
    备份 PostgreSQL 数据库。

    使用场景：
    - 用户要求备份数据库时调用
    - 在执行危险操作（如数据库迁移）前，先备份作为保险

    前置条件：
    - 目标数据库可连接（可先调用 pgsql_check_connection 验证）
    - pg_dump 命令可用

    注意事项：
    - 备份文件存储在 output_dir 目录下，按 daily/weekly/manual 分类
    - 默认自动清理 7 天前的 daily 备份
    - schema_only 和 data_only 不能同时使用
    - 不会阻塞数据库读写操作

    Args:
        database: 要备份的数据库名（必填）
        host: 数据库地址，默认 127.0.0.1
        ...

    Returns:
        dict: {success, database, file_path, file_size, file_size_human,
               format, elapsed_seconds, tables_count, cleanup_summary, next_actions}
    """
```

### MCP Server 扩展（可选）

如果未来需要将 bootstrap 的 Tool 暴露为 MCP（Model Context Protocol）Server，架构天然支持：

```
Agent
  │
  ▼
MCP Client（Agent 框架内置）
  │
  ▼ (JSON-RPC over stdio/SSE)
MCP Server（bootstrap 新增薄层）
  │
  ▼
Tool Registry → Core 层 → Utils 层
```

MCP Server 只需要将 `tools/registry.py` 中的 Tool 注册为 MCP Tool，协议适配层非常薄：

```python
# src/bootstrap/mcp_server.py（未来扩展）

from mcp.server import Server
from bootstrap.tools.registry import TOOLS, get_all_schemas

server = Server("bootstrap")

for name, func in TOOLS.items():
    server.add_tool(name, func)

if __name__ == "__main__":
    server.run()
```

这也是选择 Python 的优势之一——MCP SDK 原生支持 Python。

## Shell 脚本迁移策略

### 三阶段渐进迁移

```
阶段 1（当前）          阶段 2                  阶段 3（最终）
Python CLI              Python CLI              Python CLI
    │                       │                       │
    ▼                       ▼                       ▼
subprocess.run()        混合模式                 纯 Python
    │                    ┌──┴──┐                    │
    ▼                    ▼     ▼                    ▼
backup.sh           Python  Shell              Python
restore.sh         (pgsql) (k8s)           (pgsql + k8s)
install.sh
```

| 阶段 | pgsql 模块 | k8s 模块 | 说明 |
|------|-----------|---------|------|
| 阶段 1 | subprocess → backup.sh / restore.sh | subprocess → install.sh | 快速上线，验证架构 |
| 阶段 2 | 纯 Python（直接调用 pg_dump） | 继续 subprocess | pgsql 逻辑相对简单，优先纯 Python 化 |
| 阶段 3 | 纯 Python | 评估是否值得纯 Python 化 | k8s 涉及系统级操作，可能长期保持 Shell |

### subprocess 封装

```python
# src/bootstrap/utils/shell.py

import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ScriptResult:
    returncode: int
    stdout: str
    stderr: str


def run_script(
    args: list[str],
    env: dict[str, str] | None = None,
    timeout: int = 600,
) -> ScriptResult:
    """
    执行 Shell 脚本并捕获输出。

    Args:
        args: 命令行参数列表，第一个元素为脚本路径
        env: 额外环境变量（合并到当前环境）
        timeout: 超时时间（秒）

    Returns:
        ScriptResult: 返回码、stdout、stderr
    """
    import os

    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    # Agent 调用时自动注入 AUTO_YES=true
    full_env.setdefault("AUTO_YES", "true")

    proc = subprocess.run(
        ["bash"] + args,
        capture_output=True,
        text=True,
        env=full_env,
        timeout=timeout,
    )

    return ScriptResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
    )


def get_repo_root() -> Path:
    """获取仓库根目录，用于定位现有 Bash 脚本。"""
    return Path(__file__).parent.parent.parent.parent
```

## 输出规范

### Core 层返回值

Core 层始终返回 Pydantic 模型，不做格式化：

```python
# 返回值示例
BackupResult(
    success=True,
    database="mydb",
    file_path="/data/backup/pgsql/daily/mydb_20260405_120000.dump",
    file_size=1048576,
    format="custom",
    elapsed_seconds=3.14,
)
```

### CLI 层输出

CLI 层根据 `--output` 参数决定输出格式：

**text 模式（默认，给人看）：**

```
✓ 备份完成

  数据库:   mydb
  格式:     custom
  文件:     /data/backup/pgsql/daily/mydb_20260405_120000.dump
  大小:     1.0 MB
  耗时:     3.14s
```

**json 模式（给脚本/Agent 看）：**

```json
{
  "success": true,
  "database": "mydb",
  "file_path": "/data/backup/pgsql/daily/mydb_20260405_120000.dump",
  "file_size": 1048576,
  "format": "custom",
  "elapsed_seconds": 3.14
}
```

### Agent Tool 层输出

始终返回 Python dict（由 Pydantic 模型 `.model_dump()` 生成），Agent 框架负责序列化为 JSON。

## 配置管理

### 配置优先级（高 → 低）

```
CLI 参数 / Agent Tool 参数
    ↓
环境变量（PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE）
    ↓
配置文件 ~/.bootstrap/config.toml（可选，未来）
    ↓
代码中的默认值
```

### 环境变量兼容性

保持与现有 Bash 脚本相同的环境变量支持：

| 环境变量 | 用途 | 默认值 |
|----------|------|--------|
| `PGHOST` | 数据库地址 | `127.0.0.1` |
| `PGPORT` | 数据库端口 | `5432` |
| `PGUSER` | 连接用户 | `postgres` |
| `PGDATABASE` | 默认数据库 | (无) |
| `PGPASSWORD` | 密码 | (无) |

## 错误处理

### 错误分类

| 类型 | 处理方式 | 示例 |
|------|---------|------|
| 参数错误 | Pydantic ValidationError → 用户友好提示 | `schema_only + data_only 互斥` |
| 前置检查失败 | Core 层抛出自定义异常 | `数据库不存在`、`pg_dump 未安装` |
| 脚本执行失败 | 返回 `success=False` + stderr 内容 | `pg_dump 连接失败` |
| 超时 | subprocess.TimeoutExpired → 超时异常 | 备份超过 10 分钟 |

### 自定义异常

```python
# src/bootstrap/core/exceptions.py

class BootstrapError(Exception):
    """基础异常。"""
    pass

class PreflightError(BootstrapError):
    """前置检查失败。"""
    pass

class ScriptError(BootstrapError):
    """Shell 脚本执行失败。"""
    def __init__(self, message: str, returncode: int, stderr: str):
        super().__init__(message)
        self.returncode = returncode
        self.stderr = stderr
```

### CLI 层错误展示

```python
# CLI 层捕获异常，格式化为用户友好的输出
try:
    result = run_backup(params)
except PreflightError as e:
    console.print(f"[red]✗ 前置检查失败:[/red] {e}")
    raise typer.Exit(1)
except ScriptError as e:
    console.print(f"[red]✗ 执行失败:[/red] {e}")
    if e.stderr:
        console.print(f"[dim]{e.stderr}[/dim]")
    raise typer.Exit(e.returncode)
```

### Agent Tool 层错误返回

```python
# Agent Tool 层不抛异常，返回错误信息
def tool_pgsql_backup(...) -> dict:
    try:
        ...
        return result.model_dump()
    except BootstrapError as e:
        return {"success": False, "error": str(e)}
```

## 数据模型

### Pydantic 模型定义

```python
# src/bootstrap/models/services/pgsql.py

from pydantic import BaseModel, Field, model_validator
from typing import Literal


class BackupParams(BaseModel):
    """备份参数。"""
    database: str = Field(description="数据库名")
    host: str = Field(default="127.0.0.1", description="数据库地址")
    port: int = Field(default=5432, ge=1, le=65535, description="端口")
    user: str = Field(default="postgres", description="用户名")
    format: Literal["custom", "directory", "tar", "plain"] = Field(
        default="custom", description="备份格式"
    )
    compress: int = Field(default=6, ge=0, le=9, description="压缩级别")
    output_dir: str = Field(default="/data/backup/pgsql", description="备份目录")
    backup_type: Literal["daily", "weekly", "manual"] = Field(
        default="daily", description="备份类型"
    )
    tables: list[str] = Field(default_factory=list, description="只备份指定表")
    exclude_tables: list[str] = Field(default_factory=list, description="排除指定表")
    schemas: list[str] = Field(default_factory=list, description="只备份指定 schema")
    exclude_schemas: list[str] = Field(default_factory=list, description="排除指定 schema")
    schema_only: bool = Field(default=False, description="只备份表结构")
    data_only: bool = Field(default=False, description="只备份数据")

    @model_validator(mode="after")
    def check_constraints(self):
        if self.schema_only and self.data_only:
            raise ValueError("--schema-only 和 --data-only 不能同时使用")
        return self


class BackupResult(BaseModel):
    """备份结果。"""
    success: bool
    database: str
    file_path: str | None = None
    file_size: int | None = None
    format: str
    elapsed_seconds: float
    error: str | None = None
    stdout: str | None = Field(default=None, exclude=True)  # 不序列化到 JSON
    stderr: str | None = Field(default=None, exclude=True)


class RestoreParams(BaseModel):
    """恢复参数。"""
    backup_file: str = Field(description="备份文件路径")
    database: str | None = Field(default=None, description="目标数据库名")
    host: str = Field(default="127.0.0.1", description="目标数据库地址")
    port: int = Field(default=5432, ge=1, le=65535, description="端口")
    user: str = Field(default="postgres", description="用户名")
    jobs: int = Field(default=4, ge=1, description="并行恢复线程数")
    clean: bool = Field(default=True, description="恢复前删除已有对象")


class RestoreResult(BaseModel):
    """恢复结果。"""
    success: bool
    database: str
    backup_file: str
    format: str
    elapsed_seconds: float
    error: str | None = None


class BackupFileInfo(BaseModel):
    """备份文件信息。"""
    file_path: str
    database: str
    format: str
    size: int
    created_at: str  # ISO 8601
```

## 测试策略

### 测试分层

```
┌─────────────────────────────────────────────────┐
│ 集成测试（tests/integration/）                   │
│ 需要真实 PG 实例，验证端到端流程                  │
├─────────────────────────────────────────────────┤
│ Python 单元测试（tests/unit/）                   │
│ 包含 CLI / Tool / Core / Model 各层测试          │
├─────────────────────────────────────────────────┤
│ Bash 兼容测试（tests/bash/）                     │
│ 验证关键脚本入口和迁移期适配行为                  │
├─────────────────────────────────────────────────┤
│ 测试夹具（tests/fixtures/）                      │
│ 样例输出、schema fixture、测试输入数据            │
└─────────────────────────────────────────────────┘
```

### 测试示例

```python
# tests/unit/services/test_pgsql_core.py

import pytest
from unittest.mock import patch
from bootstrap.core.services.pgsql import run_backup
from bootstrap.models.services.pgsql import BackupParams
from bootstrap.utils.shell import ScriptResult


@pytest.fixture
def backup_params():
    return BackupParams(database="testdb")


def test_backup_builds_correct_args(backup_params):
    """验证 Core 层正确拼装 Shell 脚本参数。"""
    with patch("bootstrap.core.services.pgsql.run_script") as mock_run:
        mock_run.return_value = ScriptResult(
            returncode=0,
            stdout="备份完成\n文件: /data/backup/pgsql/daily/testdb_20260405.dump",
            stderr="",
        )
        result = run_backup(backup_params)

        args = mock_run.call_args[0][0]
        assert "-d" in args
        assert "testdb" in args
        assert "-Fc" in args or "-F" in args
        assert result.success is True


def test_backup_schema_only_data_only_exclusive():
    """验证 schema_only 和 data_only 互斥。"""
    with pytest.raises(ValueError, match="不能同时使用"):
        BackupParams(database="testdb", schema_only=True, data_only=True)
```

```python
# tests/unit/services/test_pgsql_tools.py

from bootstrap.tools.services.pgsql import tool_pgsql_backup
from bootstrap.tools.registry import get_schema


def test_tool_schema_has_required_fields():
    """验证 Tool Schema 包含必填字段。"""
    schema = get_schema("pgsql_backup")
    assert "database" in schema["parameters"]["required"]
    assert schema["parameters"]["properties"]["database"]["type"] == "string"


def test_tool_returns_dict():
    """验证 Tool 返回 dict 格式。"""
    with patch("bootstrap.core.services.pgsql.run_backup") as mock:
        mock.return_value = BackupResult(success=True, ...)
        result = tool_pgsql_backup(database="testdb")
        assert isinstance(result, dict)
        assert "success" in result
```

### 运行测试

```bash
# 安装开发依赖
pip install -e ".[dev]"

# 运行全部 Python 单元测试
pytest tests/unit/ -v

# 运行集成测试（需要 PG 实例）
pytest tests/integration/ -v

# 运行特定模块测试
pytest tests/unit/services/test_pgsql_core.py -v

# 查看覆盖率
pytest tests/unit/ tests/integration/ --cov=bootstrap --cov-report=term-missing
```

## 打包与分发

### pyproject.toml

```toml
[project]
name = "bootstrap"
version = "0.1.0"
description = "基础设施初始化工具 — CLI + Agent Tool"
requires-python = ">=3.10"
dependencies = [
    "typer>=0.12",
    "rich>=13.0",
    "pydantic>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov",
]

[project.scripts]
bootstrap = "bootstrap.cli.main:app"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/bootstrap"]
```

### 安装方式

```bash
# 开发模式（可编辑安装）
cd bootstrap
pip install -e .

# 生产安装
pip install .

# 验证
bootstrap --help
bootstrap version
bootstrap pgsql backup --help
```

### 原始 curl | bash 兼容

仓库根目录 `install.sh` 必须保持可用，继续支持：

```bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh | sudo bash -s -- k8s master
```

两种安装方式并存，用户可以选择：
- **快速部署**：`curl | bash`（无需 Python）
- **Agent 集成 / 可编程使用**：`pip install bootstrap`

如后续确实需要整理 Bash 目录结构，应通过根 `install.sh` shim 或兼容跳转保持旧 URL 不失效，而不是先移动再补兼容。

## 分阶段实施计划

### 阶段 1：脚手架 + pgsql 模块（MVP）

**目标：** 在不搬迁现有 Bash 目录的前提下，搭建 Python 项目骨架，并让 `pgsql` 模块可通过 CLI 和 Agent Tool 两种方式调用。

| 任务 | 说明 |
|------|------|
| 1.1 初始化项目结构 | 创建 `pyproject.toml`、`src/bootstrap/` 目录、`__init__.py` |
| 1.2 实现 Models 层 | `BackupParams`、`BackupResult`、`RestoreParams`、`RestoreResult` |
| 1.3 实现 Utils 层 | `shell.py`（subprocess 封装）、`logging.py`（Rich 日志） |
| 1.4 实现 Core 层 (pgsql) | `run_backup`、`run_restore`，通过 subprocess 调用现有 `services/pgsql/*/run.sh` |
| 1.5 实现 CLI 层 (pgsql) | `bootstrap pgsql backup`、`bootstrap pgsql restore` |
| 1.6 实现 Agent Tool 层 (pgsql) | `tool_pgsql_backup`、`tool_pgsql_restore`，Schema 由 Pydantic 模型生成 |
| 1.7 结构化结果兜底方案 | 先允许解析 stdout；如脆弱则补脚本 JSON 输出或结果文件 |
| 1.8 编写测试 | Model/Core/Tool/CLI 的最小闭环测试 |
| 1.9 更新文档 | README、CLAUDE.md、迁移说明 |

### 阶段 2：pgsql 增强 + Tool 注册表

| 任务 | 说明 |
|------|------|
| 2.1 新增查询类 Tool | `pgsql_check_connection`、`pgsql_list_databases`、`pgsql_list_backups` |
| 2.2 完善 Tool 注册表 | `bootstrap tools list`、`bootstrap tools schema` |
| 2.3 丰富返回值 | 增加 `file_size_human`、诊断信息、`next_actions` |
| 2.4 补集成测试 | 以真实 PG 实例覆盖备份/恢复主路径 |

### 阶段 3：k8s 非交互化改造 + 选择性接入

| 任务 | 说明 |
|------|------|
| 3.1 梳理 k8s 子命令边界 | 区分可查询、可执行、必须确认的操作 |
| 3.2 改造底层脚本接口 | 去掉对 `/dev/tty` 粘贴的硬依赖，引入显式参数 |
| 3.3 选择性接入 Python | 优先接入 `label-workers`、`dashboard`，谨慎评估 `init` / `join` |
| 3.4 建立高价值测试 | 以接口测试和少量环境测试为主，不追求全量单测 |

### 阶段 4：pgsql 纯 Python 化（可选）

| 任务 | 说明 |
|------|------|
| 4.1 重写 backup 逻辑 | 直接调用 `pg_dump`，Python 负责参数拼装、文件管理、过期清理 |
| 4.2 重写 restore 逻辑 | 直接调用 `pg_restore` / `psql`，Python 负责格式检测、数据库创建 |
| 4.3 移除对 `services/pgsql/*/run.sh` 的运行时依赖 | 在测试和回退策略成熟后再做 |

### 阶段 5：现有服务评估与扩展

| 任务 | 说明 |
|------|------|
| 5.1 Prometheus 包装层评估 | 判断是否值得为现有 `observability/prometheus/install.sh` 补 Python CLI / Tool |
| 5.2 新服务模块 | 再评估 `docker`、`redis`、`nginx` 是否进入 Python 体系 |
| 5.3 统一迁移规范 | 为所有后续模块复用相同的 CLI/Core/Tool 模板 |

## FAQ

### Q: 为什么不直接全部重写为纯 Python？

**A:** 渐进迁移降低风险。现有 Shell 脚本已经过生产验证，第一阶段通过 subprocess 调用保证功能不退化。逐步替换过程中，如果 Python 实现出问题，可以快速回退到 Shell 版本。

### Q: k8s 模块有必要纯 Python 化吗？

**A:** 可能不需要。k8s 安装涉及大量系统级操作（`modprobe`、`sysctl`、`apt-get`、`kubeadm`），这些操作本质上就是调用系统命令。纯 Python 化只是把 `os.system()` 替换了 Shell 脚本中的直接调用，收益不大。建议 k8s 模块长期保持 Python 壳 + Shell 脚本的方式。

### Q: Agent 调用时如何处理需要 root 权限的操作？

**A:** 与 CLI 模式相同，Agent Tool 层不处理权限问题。如果底层脚本需要 root，Agent 在执行时需以 root 身份运行 Python 进程，或使用 sudo。Tool 的 docstring 中会标注权限要求。

### Q: 如何确保 Tool 返回值的 Schema 与实际一致？

**A:** 通过 Pydantic 模型强制约束。Core 层返回 Pydantic 模型 → Tool 层调用 `.model_dump()` → 返回值的结构始终与模型定义一致。测试中会验证返回值的 key 和类型。

### Q: 是否需要版本化 Tool Schema？

**A:** 第一阶段不需要。Tool Schema 由 Python 函数签名自动生成，随代码版本自然演进。如果未来 Agent 需要稳定的 Schema 契约，可以引入版本化机制（如 `v1/pgsql_backup`）。

## 参考

- [Typer 官方文档](https://typer.tiangolo.com/)
- [Pydantic 官方文档](https://docs.pydantic.dev/)
- [Rich 官方文档](https://rich.readthedocs.io/)
- [Claude Tool Use 文档](https://docs.anthropic.com/en/docs/build-with-claude/tool-use)
- [OpenAI Function Calling](https://platform.openai.com/docs/guides/function-calling)
