# PostgreSQL 备份与恢复

> 本文档配合 `pgsql/backup.sh` 和 `pgsql/restore.sh` 脚本使用，详细说明 PostgreSQL 数据库的备份恢复策略、参数配置和注意事项。

## 目录结构

```
pgsql/
├── README.md          # 本文档
├── backup.sh          # 数据库备份脚本
└── restore.sh         # 数据库恢复脚本
```

## 备份工具简介

PostgreSQL 提供了多种备份工具，适用于不同场景：

| 工具 | 用途 | 特点 |
|------|------|------|
| `pg_dump` | 备份单个数据库 | 支持多种输出格式，可选择性备份表/schema |
| `pg_dumpall` | 备份整个集群（所有数据库 + 全局对象） | 包含角色、表空间等全局对象，只支持纯 SQL 输出 |
| `pg_basebackup` | 物理备份（文件级别） | 适用于主从复制和 PITR（时间点恢复） |

**本脚本使用 `pg_dump`**，适用于日常的单库逻辑备份场景。

## 备份格式对比

`pg_dump` 支持四种输出格式，通过 `-F` 参数指定：

| 格式 | 参数 | 后缀 | 压缩 | 并行恢复 | 选择性恢复 | 适用场景 |
|------|------|------|------|----------|------------|----------|
| 自定义格式 | `-Fc` | `.dump` | 默认压缩 | 支持 (`pg_restore -j`) | 支持 | **推荐：生产环境首选** |
| 目录格式 | `-Fd` | 目录 | 默认压缩 | 支持 | 支持 | 大型数据库并行备份 |
| tar 格式 | `-Ft` | `.tar` | 不压缩 | 不支持 | 支持 | 需要查看/编辑备份内容 |
| 纯 SQL | `-Fp` | `.sql` | 不压缩 | 不支持 | 不支持 | 可读性好、跨版本迁移 |

### 为什么推荐自定义格式（`-Fc`）

1. **自动压缩** — 文件体积通常比纯 SQL 小 3-5 倍（取决于数据类型）
2. **并行恢复** — 可通过 `pg_restore -j N` 多线程恢复，大幅缩短恢复时间
3. **选择性恢复** — 可以只恢复指定的表、schema 或数据
4. **数据完整性** — 二进制格式，不存在 SQL 编码问题

## 使用方式

### 备份

```bash
# 整库备份（交互模式，逐步确认）
./pgsql/backup.sh -d mydb

# 整库备份（全自动模式）
./pgsql/backup.sh -d mydb --yes

# 远程数据库备份
./pgsql/backup.sh -H 10.0.0.1 -p 5432 -U postgres -d mydb --yes

# 只备份指定 schema
./pgsql/backup.sh -d mydb -n public -n analytics --yes

# 排除大表（如日志表）
./pgsql/backup.sh -d mydb -T audit_logs -T event_logs --yes

# 只备份指定表
./pgsql/backup.sh -d mydb -t users -t orders -t products --yes

# 只备份表结构（不含数据，用于创建测试环境）
./pgsql/backup.sh -d mydb --schema-only --yes

# 只备份数据（不含表结构，用于数据迁移）
./pgsql/backup.sh -d mydb --data-only --yes

# 组合使用：备份 public schema 中除日志表外的所有表结构
./pgsql/backup.sh -d mydb -n public -T audit_logs --schema-only --yes

# 目录格式并行备份
./pgsql/backup.sh -d mydb -F directory --yes

# 查看帮助（展示所有参数和当前值）
./pgsql/backup.sh --help
```

### 恢复

```bash
# 恢复自定义格式备份
./pgsql/restore.sh mydb_20260402_120000.dump

# 恢复纯 SQL 格式备份
./pgsql/restore.sh mydb_20260402_120000.sql -d mydb

# 恢复到指定数据库（目标库不存在会自动创建）
./pgsql/restore.sh mydb.dump -d mydb_new --yes

# 远程恢复，8 线程并行
./pgsql/restore.sh mydb.dump -H 10.0.0.1 -d mydb -j 8 --yes

# 查看帮助
./pgsql/restore.sh --help
```

## 脚本实际执行的命令

### backup.sh 执行的备份命令

脚本根据配置参数拼装 `pg_dump` 命令，最终执行的等效命令如下：

```bash
# 默认配置（整库备份，自定义格式，压缩级别 6）
pg_dump \
    -h 127.0.0.1 \
    -p 5432 \
    -U postgres \
    -d mydb \
    -Fc \
    -Z 6 \
    -v \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 只备份指定 schema（-n public -n analytics）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    -n public -n analytics \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 排除指定 schema（-N temp -N staging）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    -N temp -N staging \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 只备份指定表（-t users -t orders）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    -t users -t orders \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 排除指定表（-T audit_logs -T event_logs）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    -T audit_logs -T event_logs \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 只备份结构（--schema-only）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    --schema-only \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 只备份数据（--data-only）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fc -Z 6 -v \
    --data-only \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dump

# 目录格式（支持并行备份）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fd -Z 6 -v \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.dir

# 纯 SQL 格式（不支持压缩，不传 -Z）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Fp -v \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.sql

# tar 格式（不支持压缩，不传 -Z）
pg_dump \
    -h 127.0.0.1 -p 5432 -U postgres -d mydb \
    -Ft -v \
    -f /data/backup/pgsql/daily/mydb_20260402_120000.tar
```

**参数来源对照：**

| pg_dump 参数 | 来源（脚本 CLI 参数） | 默认值 |
|-----------|--------------------------|--------|
| `-h` | `-H, --host` | `127.0.0.1` |
| `-p` | `-p, --port` | `5432` |
| `-U` | `-U, --user` | `postgres` |
| `-d` | `-d, --database` | (必填) |
| `-F` | `-F, --format` → 转换为 c/d/t/p | `c`（custom） |
| `-Z` | `-Z, --compress`（仅 -Fc/-Fd 时传入） | `6` |
| `-n` | `-n, --schema`（可多次指定） | (空=全部) |
| `-N` | `-N, --exclude-schema`（可多次指定） | (空=不排除) |
| `-t` | `-t, --table`（可多次指定） | (空=全部) |
| `-T` | `-T, --exclude-table`（可多次指定） | (空=不排除) |
| `--schema-only` | `--schema-only` | 不启用 |
| `--data-only` | `--data-only` | 不启用 |
| `-v` | 固定开启 | — |
| `-f` | `-o, --output-dir` + `--type` + 数据库名_时间戳.后缀 | `/data/backup/pgsql/daily/...` |

### restore.sh 执行的恢复命令

脚本根据备份文件格式自动选择 `pg_restore` 或 `psql`：

```bash
# 自定义格式 / 目录格式（使用 pg_restore，支持并行恢复）
pg_restore \
    -h 127.0.0.1 \
    -p 5432 \
    -U postgres \
    -d mydb \
    -v \
    --clean --if-exists \
    -j 4 \
    mydb_20260402_120000.dump

# tar 格式（使用 pg_restore，不支持并行）
pg_restore \
    -h 127.0.0.1 \
    -p 5432 \
    -U postgres \
    -d mydb \
    -v \
    --clean --if-exists \
    mydb_20260402_120000.tar

# 纯 SQL 格式（使用 psql，非 pg_restore）
psql \
    -h 127.0.0.1 \
    -p 5432 \
    -U postgres \
    -d mydb \
    -f mydb_20260402_120000.sql
```

**参数来源对照：**

| pg_restore 参数 | 来源（脚本 CLI 参数） | 默认值 |
|-----------|--------------------------|--------|
| `-h` | `-H, --host` | `127.0.0.1` |
| `-p` | `-p, --port` | `5432` |
| `-U` | `-U, --user` | `postgres` |
| `-d` | `-d, --database`（未指定则从文件名推断） | — |
| `-j` | `-j, --jobs`（仅 custom/directory 格式） | `4` |
| `--clean --if-exists` | `--clean`（默认开启，`--no-clean` 关闭） | 开启 |
| `-v` | 固定开启 | — |

## 连接参数说明

脚本通过 CLI 参数接收连接信息，**CLI 参数优先级高于环境变量**。如果未指定 CLI 参数，脚本会读取以下 PostgreSQL 标准环境变量作为默认值：

| CLI 参数 | 对应环境变量 | 默认值 | 说明 |
|----------|-------------|--------|------|
| `-H, --host` | `PGHOST` | `127.0.0.1` | 数据库主机地址 |
| `-p, --port` | `PGPORT` | `5432` | 数据库端口 |
| `-U, --user` | `PGUSER` | `postgres` | 连接用户名 |
| `-d, --database` | `PGDATABASE` | (无) | 要备份/恢复的数据库名 |
| — | `PGPASSWORD` | (无) | 密码（建议使用 `.pgpass` 替代） |

> **注意：** 仅以上连接参数支持环境变量。其他参数（如 `-F`, `-Z`, `-t`, `--schema-only` 等）只能通过 CLI 参数指定。

### 密码管理最佳实践

**不推荐** 在命令行或环境变量中直接设置密码：

```bash
# ❌ 不安全：密码会出现在进程列表和 shell 历史中
PGPASSWORD=mypassword pg_dump ...
```

**推荐** 使用 `~/.pgpass` 文件：

```bash
# 创建 .pgpass 文件
cat > ~/.pgpass <<EOF
# hostname:port:database:username:password
10.0.0.1:5432:mydb:postgres:mypassword
# 通配符写法（所有数据库）
10.0.0.1:5432:*:postgres:mypassword
EOF

# 必须设置权限为 600，否则 PostgreSQL 会拒绝读取
chmod 600 ~/.pgpass
```

## 备份脚本参数详解

### `pg_dump` 核心参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `-h, --host` | 数据库服务器地址 | `-h 10.0.0.1` |
| `-p, --port` | 端口号 | `-p 5432` |
| `-U, --username` | 连接用户 | `-U postgres` |
| `-d, --dbname` | 数据库名 | `-d mydb` |
| `-F, --format` | 输出格式（c/d/t/p） | `-Fc`（推荐） |
| `-f, --file` | 输出文件路径 | `-f /backup/mydb.dump` |
| `-Z, --compress` | 压缩级别（0-9，脚本默认 6） | `-Z 6`（平衡速度和体积） |
| `-j, --jobs` | 并行备份线程数（仅目录格式） | `-j 4` |
| `-v, --verbose` | 显示详细进度 | `-v` |

### 数据过滤参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `-n, --schema` | 只备份指定 schema | `-n public` |
| `-N, --exclude-schema` | 排除指定 schema | `-N temp_schema` |
| `-t, --table` | 只备份指定表 | `-t users -t orders` |
| `-T, --exclude-table` | 排除指定表 | `-T logs -T temp_data` |
| `--schema-only` | 只备份结构，不含数据 | `--schema-only` |
| `--data-only` | 只备份数据，不含结构 | `--data-only` |

### 常用参数组合示例

```bash
# 完整备份（推荐日常使用）
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fc -Z 6 -v -f mydb.dump

# 只备份 public schema
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fc -n public -f mydb_public.dump

# 排除大表（如日志表）
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fc -T audit_logs -T event_logs -f mydb_no_logs.dump

# 只备份表结构（用于创建测试环境）
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fc --schema-only -f mydb_schema.dump

# 大库并行备份（目录格式，4 线程）
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fd -j 4 -f mydb_backup_dir/

# 纯 SQL 备份（可读性好，跨版本迁移）
pg_dump -h 10.0.0.1 -U postgres -d mydb -Fp -f mydb.sql
```

## 恢复脚本参数详解

### `pg_restore` 核心参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `-h, --host` | 目标数据库服务器 | `-h 10.0.0.1` |
| `-p, --port` | 端口号 | `-p 5432` |
| `-U, --username` | 连接用户 | `-U postgres` |
| `-d, --dbname` | 目标数据库名 | `-d mydb` |
| `-j, --jobs` | 并行恢复线程数 | `-j 4`（显著加速） |
| `-c, --clean` | 恢复前删除已有对象 | `-c` |
| `--if-exists` | 配合 `-c`，对象不存在时不报错 | `--if-exists` |
| `-C, --create` | 恢复时自动创建数据库 | `-C` |
| `--no-owner` | 不恢复对象的所有者 | `--no-owner` |
| `--no-privileges` | 不恢复权限设置 | `--no-privileges` |
| `-v, --verbose` | 显示详细进度 | `-v` |

### 常用恢复场景

```bash
# 恢复到已有数据库（先清除旧数据）
pg_restore -h 10.0.0.1 -U postgres -d mydb -c --if-exists -v mydb.dump

# 恢复到新数据库
createdb -h 10.0.0.1 -U postgres mydb_new
pg_restore -h 10.0.0.1 -U postgres -d mydb_new -v mydb.dump

# 并行恢复（4 线程，大幅加速）
pg_restore -h 10.0.0.1 -U postgres -d mydb -j 4 -v mydb.dump

# 只恢复指定表
pg_restore -h 10.0.0.1 -U postgres -d mydb -t users -t orders mydb.dump

# 只恢复表结构
pg_restore -h 10.0.0.1 -U postgres -d mydb --schema-only mydb.dump

# 恢复纯 SQL 格式（使用 psql 而非 pg_restore）
psql -h 10.0.0.1 -U postgres -d mydb -f mydb.sql
```

## 备份文件命名与存储

### 命名规则

脚本生成的备份文件遵循以下命名格式：

```
{数据库名}_{日期}_{时间}.{格式后缀}
```

示例：`mydb_20260402_120000.dump`

### 备份存储目录

| 路径 | 说明 |
|------|------|
| `/data/backup/pgsql/` | 默认备份目录（脚本自动创建） |
| `/data/backup/pgsql/daily/` | 每日备份 |
| `/data/backup/pgsql/weekly/` | 每周备份（周日） |
| `/data/backup/pgsql/manual/` | 手动触发的备份 |

### 备份保留策略

| 类型 | 保留周期 | 说明 |
|------|----------|------|
| 每日备份 | 7 天 | 脚本自动清理过期文件 |
| 每周备份 | 4 周 | 每周日自动归档 |
| 手动备份 | 不自动清理 | 需手动管理 |

## 注意事项

### 备份前检查

1. **磁盘空间** — 确保备份目录所在分区有足够空间。经验法则：预留数据库大小 1.5 倍的可用空间
   ```bash
   # 查看数据库大小
   psql -h 10.0.0.1 -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;"
   
   # 查看备份目录可用空间
   df -h /data/backup/pgsql/
   ```

2. **网络连通性** — 确认可以从备份机器连接到数据库
   ```bash
   pg_isready -h 10.0.0.1 -p 5432 -U postgres
   ```

3. **用户权限** — 备份用户需要对目标数据库有 `SELECT` 权限；`pg_dumpall` 需要超级用户权限
   ```bash
   # 检查当前用户权限
   psql -h 10.0.0.1 -U postgres -c "\du"
   ```

### 备份过程中的影响

- **`pg_dump` 不会阻塞读写操作** — 它使用 MVCC 快照，备份期间数据库可以正常读写
- **会增加 I/O 负载** — 大库备份时建议在低峰期执行，或使用 `ionice` 降低 I/O 优先级
  ```bash
  ionice -c2 -n7 pg_dump -Fc -d mydb -f mydb.dump
  ```
- **长时间备份可能导致表膨胀** — 备份期间会持有一个长事务快照，阻止 `VACUUM` 清理该快照仍可见的死元组（dead tuples），导致表体积增长。超大库建议使用物理备份（`pg_basebackup`）替代
- **`pg_dump` 备份的是一致性快照** — 备份开始时刻的数据库状态，备份期间的新写入不会包含在内

### 恢复注意事项

1. **版本兼容性** — `pg_restore` 版本必须 >= 备份时的 `pg_dump` 版本。建议保持工具版本一致
   ```bash
   pg_dump --version
   pg_restore --version
   ```

2. **目标数据库** — 恢复到已有库会追加数据，不会自动清空。如需覆盖，使用 `-c --if-exists` 参数或先手动删库重建

3. **依赖顺序** — 如果只恢复部分表，需注意外键依赖关系。建议先恢复被引用的表

4. **大对象（Large Objects）** — 默认 `pg_dump` 会包含大对象。如果不需要，可使用 `--no-blobs` 排除

5. **编码一致** — 确保源库和目标库的编码（`encoding`）和排序规则（`lc_collate`）一致，否则可能导致恢复失败或数据异常

### 定时备份（crontab）

```bash
# 编辑 crontab
crontab -e

# 每天凌晨 2:00 执行备份
0 2 * * * /opt/workspace/bootstrap/pgsql/backup.sh -H 10.0.0.1 -U postgres -d mydb --yes >> /var/log/pgsql-backup.log 2>&1

# 每周日凌晨 3:00 执行全量备份
0 3 * * 0 /opt/workspace/bootstrap/pgsql/backup.sh -H 10.0.0.1 -U postgres -d mydb --type weekly --yes >> /var/log/pgsql-backup.log 2>&1
```

### 安全建议

- **不要将备份文件存放在数据库同一台机器上** — 机器故障时备份也会丢失
- **定期验证备份可恢复** — 备份不等于可恢复，建议定期在测试环境执行恢复验证
- **加密敏感备份** — 如果备份包含敏感数据，建议使用 GPG 加密后再传输/存储
  ```bash
  # 加密
  gpg --symmetric --cipher-algo AES256 mydb.dump
  # 解密
  gpg -d mydb.dump.gpg > mydb.dump
  ```
- **备份文件权限** — 脚本默认设置备份文件权限为 `600`，仅 owner 可读写

## 常见问题

### 备份文件过大

```bash
# 查看哪些表占用空间最大
psql -h 10.0.0.1 -U postgres -d mydb -c "
SELECT schemaname || '.' || tablename AS table,
       pg_size_pretty(pg_total_relation_size((quote_ident(schemaname) || '.' || quote_ident(tablename))::regclass)) AS size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size((quote_ident(schemaname) || '.' || quote_ident(tablename))::regclass) DESC
LIMIT 20;
"

# 排除大表单独备份
pg_dump -Fc -T big_logs_table -d mydb -f mydb_without_logs.dump
pg_dump -Fc -t big_logs_table --data-only -Z 9 -d mydb -f mydb_logs_only.dump
```

### 备份速度慢

- 使用目录格式 + 并行备份：`pg_dump -Fd -j 4 -d mydb -f mydb_dir/`
- 降低压缩级别：`-Z 1`（牺牲体积换速度）
- 检查网络带宽（远程备份场景）
- 使用 `ionice` 和 `nice` 调整优先级避免影响业务，但不会加速备份本身

### pg_dump: error: connection to server failed

```bash
# 1. 检查数据库是否运行
pg_isready -h 10.0.0.1 -p 5432

# 2. 检查 pg_hba.conf 是否允许远程连接
# 需要在 PostgreSQL 服务器上检查
cat /etc/postgresql/*/main/pg_hba.conf | grep -v '^#'

# 3. 检查防火墙
telnet 10.0.0.1 5432
```

### pg_restore: error: role "xxx" does not exist

目标数据库中缺少源库的用户角色。解决方案：

```bash
# 方案 1：先创建对应的角色
psql -h 10.0.0.1 -U postgres -c "CREATE ROLE xxx WITH LOGIN;"

# 方案 2：恢复时跳过 owner 和权限
pg_restore --no-owner --no-privileges -d mydb mydb.dump
```

## 配置参数说明

### backup.sh 参数

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `-H, --host` | `127.0.0.1` | 数据库地址 |
| `-p, --port` | `5432` | 数据库端口 |
| `-U, --user` | `postgres` | 连接用户 |
| `-d, --database` | (必填) | 目标数据库 |
| `-F, --format` | `custom` | 备份格式：custom / directory / tar / plain |
| `-Z, --compress` | `6` | 压缩级别 0-9 |
| `-o, --output-dir` | `/data/backup/pgsql` | 备份存储根目录 |
| `--type` | `daily` | 备份类型：daily / weekly / manual |
| `--retention-days` | `7` | 每日备份保留天数 |
| `--retention-weeks` | `4` | 每周备份保留周数 |
| `-n, --schema` | (空=全部) | 只备份指定 schema（可多次指定，如 `-n public -n analytics`） |
| `-N, --exclude-schema` | (空=不排除) | 排除指定 schema（可多次指定） |
| `-t, --table` | (空=全部) | 只备份指定表（可多次指定，如 `-t users -t orders`） |
| `-T, --exclude-table` | (空=不排除) | 排除指定表（可多次指定） |
| `--schema-only` | 不启用 | 只备份表结构，不含数据 |
| `--data-only` | 不启用 | 只备份数据，不含表结构 |
| `-y, --yes` | 不启用 | 跳过所有确认提示 |
| `-h, --help` | — | 显示帮助信息（含所有参数及当前值） |

### restore.sh 参数

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `<backup_file>` | (必填) | 备份文件路径（.dump / .sql / .tar / 目录） |
| `-H, --host` | `127.0.0.1` | 目标数据库地址 |
| `-p, --port` | `5432` | 目标数据库端口 |
| `-U, --user` | `postgres` | 连接用户 |
| `-d, --database` | (从文件名推断) | 目标数据库名 |
| `-j, --jobs` | `4` | 并行恢复线程数（仅 custom/directory 格式） |
| `--clean` | 默认开启 | 恢复前删除已有对象 |
| `--no-clean` | — | 不删除已有对象（追加恢复） |
| `-y, --yes` | 不启用 | 跳过所有确认提示 |
| `-h, --help` | — | 显示帮助信息（含所有参数及当前值） |

## 参考

- [PostgreSQL 官方文档 — pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)
- [PostgreSQL 官方文档 — pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html)
- [PostgreSQL 官方文档 — 备份与恢复](https://www.postgresql.org/docs/current/backup.html)
- [PostgreSQL 官方文档 — .pgpass 文件](https://www.postgresql.org/docs/current/libpq-pgpass.html)
