# MCP Evolution

## 目的

为 `bootstrap` 后续演进为 MCP Server 预留计划文档位置。

## 当前状态

- `platforms/`、`services/`、`observability/` 目录边界已经稳定
- `pgsql`、`k8s kind`、`kubeadm` 已具备 Python Core / Models / CLI 基础
- Tool Registry 已有 canonical namespaced 名称

## 后续可展开的主题

- MCP Server 运行形态
- Tool handler 真实执行层
- 危险操作确认与权限分级
- 结构化输出与错误模型
- Bash 到 Python Core 的进一步收敛

## 备注

这是一个占位计划文档，后续开始 MCP 设计时直接在此基础上展开。
