#!/usr/bin/env bash
# Apple 构建入口：只在 macOS 执行，详细日志与校验由同目录 Python 脚本统一管理。
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '缺少 Python 3.10+；请先准备固定的 Apple 构建环境。' >&2
  exit 3
fi

# 参数为 macos|ios、--bootstrap-pods、--output-dir PATH；不会自动安装或升级工具。
exec python3 "$script_dir/verify_apple_artifact.py" build \
  --project-root "$project_dir" "$@"
