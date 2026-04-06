from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import subprocess


@dataclass
class CommandResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def resolve_script(*relative_paths: str) -> Path:
    root = repo_root()
    for relative_path in relative_paths:
        candidate = root / relative_path
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"Script not found in candidates: {relative_paths}")


def run_command(args: list[str], input_text: str | None = None) -> CommandResult:
    completed = subprocess.run(
        args,
        check=False,
        text=True,
        input=input_text,
        capture_output=True,
    )
    return CommandResult(
        args=args,
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )
