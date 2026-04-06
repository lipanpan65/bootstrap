from __future__ import annotations

from pydantic import BaseModel, Field


class KubeadmInitParams(BaseModel):
    yes: bool = Field(default=False, description="跳过确认")


class KubeadmJoinParams(BaseModel):
    join_command: str | None = Field(default=None, description="非交互 join 命令")
    yes: bool = Field(default=False, description="跳过确认")


class KubeadmDashboardParams(BaseModel):
    yes: bool = Field(default=False, description="跳过确认")


class KubeadmCommandResult(BaseModel):
    success: bool = Field(description="命令是否成功")
    returncode: int = Field(description="退出码")
    command: list[str] = Field(description="实际执行的命令参数")
    stdout: str = Field(description="标准输出")
    stderr: str = Field(description="标准错误")
    summary: str = Field(description="面向人类的摘要信息")
    next_actions: list[str] = Field(default_factory=list, description="建议的下一步操作")
    action: str = Field(description="kubeadm 动作名称")


class KindCreateParams(BaseModel):
    name: str = Field(default="learn", description="集群名称")
    workers: int = Field(default=2, ge=0, description="worker 节点数")
    kind_version: str | None = Field(default=None, description="kind 版本")
    mirror: str | None = Field(default=None, description="镜像加速地址")
    yes: bool = Field(default=False, description="跳过确认")


class KindInstallParams(BaseModel):
    kind_version: str | None = Field(default=None, description="kind 版本")
    mirror: str | None = Field(default=None, description="镜像加速地址")
    yes: bool = Field(default=False, description="跳过确认")


class KindDeleteParams(BaseModel):
    name: str = Field(default="learn", description="集群名称")


class KindStatusParams(BaseModel):
    name: str = Field(default="learn", description="集群名称")


class KindCommandResult(BaseModel):
    success: bool = Field(description="命令是否成功")
    returncode: int = Field(description="退出码")
    command: list[str] = Field(description="实际执行的命令参数")
    stdout: str = Field(description="标准输出")
    stderr: str = Field(description="标准错误")
    summary: str = Field(description="面向人类的摘要信息")
    next_actions: list[str] = Field(default_factory=list, description="建议的下一步操作")
    cluster_name: str | None = Field(default=None, description="kind 集群名称")
