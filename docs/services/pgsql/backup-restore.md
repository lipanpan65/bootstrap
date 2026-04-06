# PostgreSQL 备份恢复

## 入口

- 备份：`./services/pgsql/backup/run.sh`
- 恢复：`./services/pgsql/restore/run.sh`

## 常用示例

```bash
# 整库备份
./services/pgsql/backup/run.sh -d mydb --yes

# 指定表
./services/pgsql/backup/run.sh -d mydb -t users -t orders --yes

# 排除表
./services/pgsql/backup/run.sh -d mydb -T audit_logs --yes

# 只备份结构
./services/pgsql/backup/run.sh -d mydb --schema-only --yes

# 恢复到指定数据库
./services/pgsql/restore/run.sh mydb_20260402_120000.dump -d mydb --yes

# 恢复到新库
./services/pgsql/restore/run.sh mydb.dump -d mydb_new --yes
```

## 格式说明

- `custom`：默认格式，适合 `pg_restore`
- `directory`：目录格式，适合较大库与并行恢复
- `tar`：单文件 tar 格式
- `plain`：纯 SQL 文本格式

## 测试

```bash
bash services/pgsql/tests/test_pgsql.sh
bash services/pgsql/tests/test_integration.sh
```
