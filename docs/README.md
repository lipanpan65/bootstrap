# Docs Guide

`docs/` 用于存放项目的正式文档，按“文档角色”而不是按写作者来组织。

## 文档分类

### `docs/architecture/`

放稳定的跨领域架构说明。

适合放这里的内容：

- 系统结构总览
- CLI / Core / Models / Tools 分层说明
- 目录边界说明
- 已稳定下来的跨领域设计说明

不适合放这里的内容：

- 正在推进中的方案
- 版本路线图
- 模块使用手册

### `docs/platforms/`

放平台能力相关文档，例如 Kubernetes、Kind 等。

适合放这里的内容：

- 安装说明
- 平台能力说明
- 平台子模块文档

### `docs/services/`

放服务能力文档，例如 PostgreSQL。

适合放这里的内容：

- 使用与运维说明
- 备份恢复说明
- 测试方案

### `docs/observability/`

放可观测性相关文档，例如 Prometheus。

适合放这里的内容：

- 安装说明
- 组件说明
- 运行与运维说明

### `docs/plans/`

放阶段性计划、路线图、演进方案和待执行设计。

状态目录含义：

- `active/`：当前正在推进或近期准备执行的计划
- `completed/`：已经完成的计划归档
- `backlog/`：暂未进入当前周期的候选计划

## 命名规范

- 文件名统一使用 `kebab-case`
- 文件名描述主题，不描述状态
- 不默认使用日期前缀
- 一个文件只承载一个明确主题

推荐：

- `system-structure.md`
- `backup-restore.md`
- `test-plan.md`
- `mcp-evolution.md`
- `v0.2-roadmap.md`

不推荐：

- `MCP设计.md`
- `pgsql_test_plan.md`
- `active-mcp-plan.md`
- `2026-04-06-mcp-evolution.md`

## 位置判断

可以按下面的顺序判断一份文档该放在哪：

1. 如果它描述稳定的跨领域系统结构，放 `docs/architecture/`
2. 如果它描述某个平台能力，放 `docs/platforms/`
3. 如果它描述某个服务能力，放 `docs/services/`
4. 如果它描述可观测性能力，放 `docs/observability/`
5. 如果它是计划、路线图或演进方案，放 `docs/plans/`

## 当前约定

- `docs/cli-refactor-design.md` 当前继续保留在 `docs/` 根目录，作为跨领域稳定设计说明
- 后续新的稳定架构类文档优先收敛到 `docs/architecture/`
- 后续新的计划类文档统一进入 `docs/plans/`
