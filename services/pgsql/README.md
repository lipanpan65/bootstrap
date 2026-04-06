# PostgreSQL 服务运维

> PostgreSQL 备份、恢复与测试入口。

## 目录

- `backup/run.sh`：备份脚本入口
- `restore/run.sh`：恢复脚本入口
- `tests/test_pgsql.sh`：mock 单元测试
- `tests/test_integration.sh`：真实 PostgreSQL 集成测试

## 常用命令

```bash
./services/pgsql/backup/run.sh -d mydb --yes
./services/pgsql/backup/run.sh -d mydb -t users -t orders --yes
./services/pgsql/restore/run.sh mydb.dump -d mydb_new --yes

bash services/pgsql/tests/test_pgsql.sh
bash services/pgsql/tests/test_integration.sh
```
