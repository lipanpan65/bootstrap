from __future__ import annotations

from pydantic import BaseModel, Field, model_validator


class PgsqlBackupParams(BaseModel):
    database: str = Field(description="数据库名")
    host: str = Field(default="127.0.0.1", description="数据库地址")
    port: int = Field(default=5432, ge=1, le=65535, description="数据库端口")
    user: str = Field(default="postgres", description="数据库用户名")
    format: str = Field(default="custom", description="备份格式")
    compress: int = Field(default=6, ge=0, le=9, description="压缩级别")
    tables: list[str] = Field(default_factory=list, description="仅备份指定表")
    exclude_tables: list[str] = Field(default_factory=list, description="排除指定表")
    schema_only: bool = Field(default=False, description="只备份结构")
    data_only: bool = Field(default=False, description="只备份数据")
    yes: bool = Field(default=False, description="跳过确认")

    @model_validator(mode="after")
    def validate_modes(self) -> "PgsqlBackupParams":
        if self.schema_only and self.data_only:
            raise ValueError("--schema-only 和 --data-only 不能同时使用")
        return self


class PgsqlRestoreParams(BaseModel):
    backup_file: str = Field(description="备份文件路径")
    database: str | None = Field(default=None, description="目标数据库名")
    host: str = Field(default="127.0.0.1", description="数据库地址")
    port: int = Field(default=5432, ge=1, le=65535, description="数据库端口")
    user: str = Field(default="postgres", description="数据库用户名")
    jobs: int = Field(default=4, ge=1, description="并发恢复线程数")
    clean: bool = Field(default=True, description="恢复前是否清理旧对象")
    yes: bool = Field(default=False, description="跳过确认")


class PgsqlListBackupsParams(BaseModel):
    output_dir: str = Field(default="/data/backup/pgsql", description="备份目录")


class PgsqlBackupFile(BaseModel):
    path: str = Field(description="备份文件路径")
    size_bytes: int = Field(description="文件大小（字节）")


class PgsqlCommandResult(BaseModel):
    success: bool = Field(description="命令是否成功")
    returncode: int = Field(description="退出码")
    command: list[str] = Field(description="实际执行的命令参数")
    stdout: str = Field(description="标准输出")
    stderr: str = Field(description="标准错误")
    summary: str = Field(description="面向人类的摘要信息")
    next_actions: list[str] = Field(default_factory=list, description="建议的下一步操作")


class PgsqlBackupResult(PgsqlCommandResult):
    database: str = Field(description="备份数据库名")
    backup_file: str | None = Field(default=None, description="备份产物路径")


class PgsqlRestoreResult(PgsqlCommandResult):
    database: str | None = Field(default=None, description="恢复目标数据库名")
    backup_file: str = Field(description="输入的备份文件路径")
