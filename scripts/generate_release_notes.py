#!/usr/bin/env python3
"""根据上一个 v* 标签到当前 HEAD 的提交记录生成 Kazumi Plus 版本更新文档草稿。"""

from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path
import re
import subprocess
import sys


TAG_PATTERN = re.compile(r"^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
TYPE_GROUPS = (
    ("新增功能", ("feat",)),
    ("修复与优化", ("fix", "perf", "refactor", "style")),
    ("构建、发布与文档", ("build", "ci", "docs", "chore", "test")),
)


def run_git(project_root: Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(project_root), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def find_previous_tag(project_root: Path, target_tag: str) -> str | None:
    raw = run_git(project_root, ["tag", "--list", "v*", "--sort=-creatordate"])
    for line in raw.splitlines():
        tag = line.strip()
        if tag and tag != target_tag:
            return tag
    return None


def collect_commits(project_root: Path, previous_tag: str | None) -> list[tuple[str, str]]:
    rev_range = f"{previous_tag}..HEAD" if previous_tag else "HEAD"
    raw = run_git(
        project_root,
        ["log", rev_range, "--no-merges", "--pretty=format:%h%x09%s"],
    )
    commits: list[tuple[str, str]] = []
    for line in raw.splitlines():
        if "\t" not in line:
            continue
        sha, subject = line.split("\t", 1)
        commits.append((sha.strip(), subject.strip()))
    return commits


def classify_commits(commits: list[tuple[str, str]]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {title: [] for title, _ in TYPE_GROUPS}
    grouped["其他变更"] = []
    prefix_re = re.compile(r"^([a-zA-Z]+)(?:\([^)]*\))?!?:\s*(.+)$")

    for sha, subject in commits:
        match = prefix_re.match(subject)
        entry = f"- {subject} (`{sha}`)"
        placed = False
        if match:
            commit_type = match.group(1).lower()
            message = match.group(2).strip()
            entry = f"- {message} (`{sha}`)"
            for title, prefixes in TYPE_GROUPS:
                if commit_type in prefixes:
                    grouped[title].append(entry)
                    placed = True
                    break
        if not placed:
            grouped["其他变更"].append(entry)
    return grouped


def render_release_notes(
    tag: str,
    previous_tag: str | None,
    grouped: dict[str, list[str]],
) -> str:
    today = date.today().isoformat()
    lines = [
        f"# Kazumi Plus {tag}",
        "",
        f"发布日期：{today}",
    ]
    if previous_tag:
        lines.append(f"对比基线：`{previous_tag}`..`{tag}`")
    lines.append("")

    for section in ("新增功能", "修复与优化", "构建、发布与文档", "其他变更"):
        items = grouped.get(section) or []
        if not items and section in ("构建、发布与文档", "其他变更"):
            continue
        lines.append(f"## {section}")
        lines.append("")
        if items:
            lines.extend(items)
        else:
            lines.append("- 暂无条目（请在发布前补充面向用户的说明）。")
        lines.append("")

    lines.extend(
        [
            "## 已知限制与说明",
            "",
            "- Windows 安装包（`.exe`）支持每用户覆盖安装并保留 `%APPDATA%\\KazumiPlus` 用户数据；绿色版（`.zip`）需解压后手动替换。",
            "- Android 手机版（`android-mobile`）与 Android TV 版（`android-tv`）为独立包名与签名，请按设备选择对应安装包。",
            "- macOS 打包产物（`.dmg`）为 ad-hoc 签名，未公证，首次打开可能需要在系统设置中允许运行。",
            "- iOS 打包产物（`.ipa`）为未签名包，需自行合法签名后安装，不支持应用内自动更新。",
            "",
            "## 安装包清单",
            "",
            f"- `Kazumi-Plus-{tag}-windows-x64-setup.exe`（Windows 安装版，推荐）",
            f"- `Kazumi-Plus-{tag}-windows-x64.zip`（Windows 绿色版）",
            f"- `Kazumi-Plus-{tag}-android-mobile-arm64.apk`（Android 手机版）",
            f"- `Kazumi-Plus-{tag}-android-tv.apk`（Android TV 版）",
            f"- `Kazumi-Plus-{tag}-macos.dmg`（macOS 通用包）",
            f"- `Kazumi-Plus-{tag}-ios.ipa`（iOS 未签名包）",
            "- `SHA256SUMS.txt`（全部安装包校验和）",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="发布标签，例如 v0.2.0")
    parser.add_argument(
        "--since",
        default="",
        help="显式指定对比起始标签或提交（默认自动查找最近一个 v* 标签）",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="目标文档已存在时允许覆盖",
    )
    args = parser.parse_args()

    tag = args.tag.strip()
    if not TAG_PATTERN.fullmatch(tag):
        print(f"错误：标签 '{tag}' 格式不合法，需符合 v<major>.<minor>.<patch>（可选 -prerelease）。", file=sys.stderr)
        return 2

    project_root = Path(__file__).resolve().parent.parent
    output_dir = project_root / "docs" / "releases"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{tag}.md"
    if output_path.exists() and not args.force:
        print(f"错误：{output_path} 已存在；如需覆盖请传入 --force。", file=sys.stderr)
        return 1

    previous_tag = args.since.strip() or find_previous_tag(project_root, tag)
    commits = collect_commits(project_root, previous_tag)
    grouped = classify_commits(commits)
    content = render_release_notes(tag, previous_tag, grouped)
    output_path.write_text(content, encoding="utf-8")
    print(f"已生成版本更新文档草稿：{output_path}（汇总 {len(commits)} 条提交）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
