# Plans

`docs/plans/` 用于存放阶段性计划、路线图、演进方案和待执行设计。

更上层的文档分类与命名规则见 `docs/README.md`。

## 放什么

- MCP Server 演进方案
- Tool 层真实可调用实现计划
- 版本路线图
- 大型重构拆分方案
- 风险评估与迁移步骤

## 不放什么

- 模块使用手册
- 最终定稿后的稳定架构说明
- 纯测试说明
- 面向用户的快速开始

这些内容仍应放在：

- `docs/platforms/`
- `docs/services/`
- `docs/observability/`

## 当前约定

- `docs/cli-refactor-design.md` 继续保留在 `docs/` 根目录，作为当前稳定的跨领域设计说明
- 新的计划文档优先放在 `docs/plans/active/`
- 文件名统一使用 kebab-case

## 目录状态约定

- `active/`：当前正在推进或近期准备执行的计划
- `completed/`：已经完成的计划归档，用于回溯设计背景与决策
- `backlog/`：暂未进入当前周期、但值得保留的候选计划

## 命名规范

- 文件名统一使用 `kebab-case`
- 文件名描述主题，不描述状态
- 状态优先由目录表达，例如 `active/`、`completed/`、`backlog/`
- 不默认使用日期前缀
- 一个文件只承载一个明确主题

示例：

- `mcp-evolution.md`
- `tool-runtime-plan.md`
- `prometheus-pythonization.md`
- `v0.2-roadmap.md`

不推荐：

- `MCP设计.md`
- `mcp_plan.md`
- `active-mcp-plan.md`
- `2026-04-06-mcp-evolution.md`

## 推荐目录

```text
docs/plans/
├── README.md
├── active/
├── completed/
└── backlog/
```
