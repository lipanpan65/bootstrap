# PostgreSQL 备份与恢复

> 基于 `pg_dump` / `pg_restore` 的单库逻辑备份恢复工具。

## 快速开始

```bash
# 整库备份（交互模式）
./pgsql/backup.sh -d mydb

# 整库备份（全自动）
./pgsql/backup.sh -H 10.0.0.1 -U postgres -d mydb --yes

# 只备份指定表
./pgsql/backup.sh -d mydb -t users -t orders --yes

# 排除大表
./pgsql/backup.sh -d mydb -T audit_logs --yes

# 恢复
./pgsql/restore.sh mydb_20260402_120000.dump -d mydb --yes

# 恢复到新库（自动创建）
./pgsql/restore.sh mydb.dump -d mydb_new --yes

# 查看帮助
./pgsql/backup.sh --help
./pgsql/restore.sh --help
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `backup.sh` | 数据库备份脚本 |
| `restore.sh` | 数据库恢复脚本 |
| `test_pgsql.sh` | 单元测试（mock，无需数据库） |
| `test_integration.sh` | 集成测试（需要真实 PostgreSQL） |

## 详细文档

- [备份恢复详解](../docs/pgsql-backup-restore.md) — 参数说明、格式对比、注意事项、常见问题
- [测试方案](../docs/pgsql-test-plan.md) — 测试策略、用例清单、覆盖矩阵
