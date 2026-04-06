# PostgreSQL 服务运维

> PostgreSQL 备份、恢复与测试入口。

## 目录

- `backup/run.sh`：备份脚本入口
- `restore/run.sh`：恢复脚本入口
- `tests/`：Bash 测试入口

## 兼容说明

- 当前入口会转发到旧路径 `pgsql/*.sh`。
- 旧路径继续保留，避免打断现有文档、测试和人工执行习惯。
