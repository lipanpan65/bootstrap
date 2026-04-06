# PostgreSQL 测试方案

## Bash 单元测试

```bash
bash services/pgsql/tests/test_pgsql.sh
```

覆盖范围：

- 参数解析
- 备份格式映射
- `pg_dump` / `pg_restore` / `psql` 参数传递
- 备份清理与保留策略
- 数据库名校验

## Bash 集成测试

```bash
bash services/pgsql/tests/test_integration.sh
```

前置条件：

- `pg-source`：`127.0.0.1:5434/testdb`
- `pg-target`：`127.0.0.1:5433`
- `PGPASSWORD=postgres`
- 本机可用 `pg_dump`、`pg_restore`、`psql`、`pg_isready`

覆盖范围：

- custom / directory / tar / plain 四种备份格式
- 指定表与排除表
- `--schema-only`
- 自动建库
- 并行恢复
- 过期备份清理
