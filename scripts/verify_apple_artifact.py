#!/usr/bin/env python3
"""构建并核验 Apple 产物；结构通过与设备运行通过分别记录。"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
import zipfile


VERSIONS = {
    "flutter": "3.47.7",
    "xcode": "26.3",
    "cocoapods": "1.16.2",
    "xcodeproj": "1.27.0",
    "ruby": "3.3.8",
    "cmake_distribution": "3.31.6",
    "ninja_distribution": "1.11.1.4",
}
TOOL_SOURCES = {
    "cocoapods": "https://github.com/CocoaPods/CocoaPods/releases/tag/1.16.2",
    "cmake": "https://pypi.org/pypi/cmake/3.31.6/json",
    "ninja": "https://pypi.org/pypi/ninja/1.11.1.4/json",
    "ruby": "https://github.com/ruby/ruby/releases/tag/v3_3_8",
}
BUNDLE_ID = "app.kazumiplus.client"
APP_NAME = "Kazumi Plus"
MACHO_MAGICS = {b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"}
FAT_MAGICS = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


class BuildFailure(RuntimeError):
    """退出码保留阶段语义，原命令退出码另存 commands 记录。"""

    def __init__(self, message: str, code: int = 6):
        super().__init__(message)
        self.code = code


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def packed_version(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def version_tuple(value: str) -> tuple[int, ...]:
    parts = [int(item) for item in value.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def macho_slices(path: Path) -> list[dict[str, object]]:
    """直接读取 Mach-O 头，避免只检查主程序而遗漏单架构动态库。"""
    with path.open("rb") as stream:
        magic = stream.read(4)
        if magic not in MACHO_MAGICS | FAT_MAGICS:
            return []
        size = path.stat().st_size
        locations: list[tuple[int, int]] = []
        if magic in FAT_MAGICS:
            endian = ">" if magic[:1] == b"\xca" else "<"
            is_64 = magic in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
            count_data = stream.read(4)
            if len(count_data) != 4:
                raise BuildFailure(f"通用二进制头不完整：{path}", 7)
            count = struct.unpack(endian + "I", count_data)[0]
            if not 1 <= count <= 32:
                raise BuildFailure(f"通用二进制切片数异常：{path}", 7)
            record_size = 32 if is_64 else 20
            for _ in range(count):
                record = stream.read(record_size)
                if len(record) != record_size:
                    raise BuildFailure(f"通用二进制切片表不完整：{path}", 7)
                if is_64:
                    _, _, offset, length, _, _ = struct.unpack(endian + "IIQQII", record)
                else:
                    _, _, offset, length, _ = struct.unpack(endian + "IIIII", record)
                if offset + length > size or length < 28:
                    raise BuildFailure(f"通用二进制切片越界：{path}", 7)
                locations.append((offset, length))
        else:
            locations = [(0, size)]
        slices: list[dict[str, object]] = []
        for offset, length in locations:
            stream.seek(offset)
            header_magic = stream.read(4)
            if header_magic not in MACHO_MAGICS:
                raise BuildFailure(f"切片并非 Mach-O：{path}", 7)
            endian = "<" if header_magic[:1] in {b"\xce", b"\xcf"} else ">"
            is_64 = header_magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
            header = stream.read(28 if is_64 else 24)
            fields = struct.unpack(endian + ("7I" if is_64 else "6I"), header)
            cpu, subtype, filetype, ncmds, command_bytes, _ = fields[:6]
            arch = {0x01000007: "x86_64", 0x0100000C: "arm64", 7: "i386", 12: "arm"}.get(cpu, hex(cpu))
            if ncmds > 10000 or command_bytes > length - (32 if is_64 else 28):
                raise BuildFailure(f"Mach-O 加载命令越界：{path}", 7)
            item: dict[str, object] = {"architecture": arch, "cpu_subtype": subtype, "file_type": filetype, "offset": offset, "size": length, "platform": None, "minimum_os": None}
            for _ in range(ncmds):
                command_start = stream.tell()
                command_header = stream.read(8)
                if len(command_header) != 8:
                    raise BuildFailure(f"Mach-O 加载命令不完整：{path}", 7)
                command, command_size = struct.unpack(endian + "II", command_header)
                if command_size < 8 or command_start + command_size > offset + length:
                    raise BuildFailure(f"Mach-O 命令大小无效：{path}", 7)
                if command == 0x32 and command_size >= 24:
                    target, minimum, sdk, _ = struct.unpack(endian + "4I", stream.read(16))
                    item.update(platform={1: "macos", 2: "ios", 7: "ios-simulator"}.get(target, str(target)), minimum_os=packed_version(minimum), sdk=packed_version(sdk))
                elif command in {0x24, 0x25} and command_size >= 16:
                    minimum, sdk = struct.unpack(endian + "2I", stream.read(8))
                    item.update(platform="macos" if command == 0x24 else "ios", minimum_os=packed_version(minimum), sdk=packed_version(sdk))
                stream.seek(command_start + command_size)
            slices.append(item)
        return slices


def inspect_app(app: Path, target: str) -> dict[str, object]:
    app = app.resolve()
    info_path = app / ("Contents/Info.plist" if target == "macos" else "Info.plist")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise BuildFailure("产物 Bundle ID 与独立版不符", 7)
    if info.get("CFBundleDisplayName", info.get("CFBundleName")) != APP_NAME:
        raise BuildFailure("产物显示名称不是 Kazumi Plus", 7)
    executable_name = info.get("CFBundleExecutable", "")
    if not executable_name or Path(executable_name).name != executable_name:
        raise BuildFailure("产物可执行文件字段无效", 7)
    executable = app / ("Contents/MacOS" if target == "macos" else "") / executable_name
    if not executable.is_file():
        raise BuildFailure("产物主程序不存在", 7)
    minimum_key = "LSMinimumSystemVersion" if target == "macos" else "MinimumOSVersion"
    minimum = "12.0" if target == "macos" else "15.0"
    if version_tuple(str(info.get(minimum_key, "0"))) != version_tuple(minimum):
        raise BuildFailure(f"产物最低系统版本必须为 {minimum}", 7)
    if target == "ios" and info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise BuildFailure("iOS 交付必须为真机包，不能混入模拟器包", 7)
    binaries: list[dict[str, object]] = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            if not path.exists() or not path.resolve().is_relative_to(app):
                raise BuildFailure(f"包内符号链接指向包外：{path}", 7)
            continue
        if not path.is_file():
            continue
        slices = macho_slices(path)
        if not slices:
            continue
        arches = {str(item["architecture"]) for item in slices}
        required = {"arm64", "x86_64"} if target == "macos" else {"arm64"}
        if arches != required:
            raise BuildFailure(f"原生架构不完整：{path.relative_to(app)}，得到 {sorted(arches)}，要求 {sorted(required)}", 7)
        for item in slices:
            if item["platform"] != target:
                raise BuildFailure(f"原生切片目标平台不符：{path.relative_to(app)} {item['platform']}", 7)
            if not item["minimum_os"] or version_tuple(str(item["minimum_os"])) > version_tuple(minimum):
                raise BuildFailure(f"原生库提高了最低系统版本：{path.relative_to(app)} {item['minimum_os']}", 7)
        binaries.append({"path": str(path.relative_to(app)), "sha256": sha256(path), "slices": slices})
    if not binaries or not any(item["path"] == str(executable.relative_to(app)) for item in binaries):
        raise BuildFailure("未发现可核验的 Mach-O 主程序", 7)
    if target == "ios" and any(app.rglob("embedded.mobileprovision")):
        raise BuildFailure("未签名 IPA 不应包含 provisioning profile", 7)
    return {"status": "structural_checks_passed", "platform": target, "bundle_id": BUNDLE_ID, "display_name": APP_NAME, "minimum_os": minimum, "executable": str(executable.relative_to(app)), "macho_count": len(binaries), "binaries": binaries, "device_ui_validation": False}


class Runner:
    def __init__(self, project: Path, output: Path, target: str):
        self.project = project.resolve()
        self.output = output.resolve()
        if self.output == self.project or self.project.is_relative_to(self.output):
            raise BuildFailure("输出目录不能覆盖项目目录或其上级目录", 2)
        if (self.output / "result.json").exists():
            raise BuildFailure("输出目录已有 result.json，请选择新的 --output-dir，避免覆盖验收证据", 2)
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "logs").mkdir(exist_ok=True)
        self.environment = dict(os.environ)
        # 仅作用于本次进程，避免修改用户 Flutter 全局设置。
        self.environment.update(
            FLUTTER_MACOS_ARM64_ONLY="false",
            FLUTTER_XCODE_CODE_SIGNING_ALLOWED="NO",
            FLUTTER_XCODE_CODE_SIGNING_REQUIRED="NO",
            COCOAPODS_DISABLE_STATS="true",
            KAZUMI_APPLE_COCOAPODS_VERSION=VERSIONS["cocoapods"],
            KAZUMI_APPLE_XCODEPROJ_VERSION=VERSIONS["xcodeproj"],
            CI="true",
        )
        # 安装指定 gem 不等于实际激活它；让全部 Ruby 后代进程在加载 CocoaPods 前固定版本。
        self.ruby_activation = self.project / "scripts" / "apple_ruby_toolchain.rb"
        # 库目录经 RUBYLIB 传递，避免带空格的项目路径被 RUBYOPT 拆成多个参数。
        self.environment["RUBYLIB"] = os.pathsep.join(filter(None, [str(self.ruby_activation.parent), self.environment.get("RUBYLIB", "")]))
        self.environment["RUBYOPT"] = " ".join(filter(None, ["-rapple_ruby_toolchain", self.environment.get("RUBYOPT", "")]))
        if target == "macos":
            self.environment.update(FLUTTER_XCODE_ARCHS="arm64 x86_64", FLUTTER_XCODE_ONLY_ACTIVE_ARCH="NO")
        self.result: dict[str, object] = {"schema_version": 1, "platform": target, "status": "running", "started_at": utc_now(), "commands": [], "tool_sources": TOOL_SOURCES, "artifacts": [], "limitations": ["云端结构检查及进程存活检查不代表真机播放验收。"]}
        self.source_files: list[dict[str, object]] = []

    def run(self, label: str, command: list[str], *, cwd: Path | None = None, timeout: int = 600, check: bool = True, echo: bool = True) -> tuple[int, str]:
        """每步独立日志；超时只回收本脚本创建的进程组。"""
        log = self.output / "logs" / f"{len(self.result['commands']) + 1:03d}-{label}.log"
        record = {"label": label, "argv": command, "cwd": str(cwd or self.project), "log": str(log.relative_to(self.output)), "started_at": utc_now()}
        self.result["commands"].append(record)
        chunks: list[str] = []
        with log.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(command, cwd=cwd or self.project, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", start_new_session=True)
            def drain() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    stream.write(line)
                    stream.flush()
                    chunks.append(line)
                    if echo:
                        print(line, end="", flush=True)
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            timed_out = False
            interrupted = False
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
            except KeyboardInterrupt:
                interrupted = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
            finally:
                reader.join(timeout=15)
            code = 130 if interrupted else 124 if timed_out else process.returncode
        record.update(exit_code=code, timed_out=timed_out, finished_at=utc_now())
        if interrupted:
            raise BuildFailure("构建被中断，已回收本步骤启动的进程组。", 130)
        if check and code != 0:
            raise BuildFailure(f"{label} 失败，原命令退出码 {code}，详见 {log.name}")
        return code, "".join(chunks)

    def toolchain(self) -> None:
        if platform.system() != "Darwin":
            raise BuildFailure("Apple 构建只能在 macOS/Xcode 主机执行；本机未开始编译。", 3)
        if sys.version_info < (3, 10):
            raise BuildFailure("需要 Python 3.10 或更高版本", 3)
        if not self.ruby_activation.is_file():
            raise BuildFailure("缺少 Apple Ruby 工具链激活脚本，拒绝回退到默认 gem 版本。", 3)
        paths = {}
        for name in ["flutter", "xcodebuild", "xcode-select", "xcrun", "pod", "ruby", "cmake", "ninja", "codesign", "hdiutil", "ditto", "git", "lipo"]:
            path = shutil.which(name)
            if not path:
                raise BuildFailure(f"缺少工具：{name}；脚本不会自动安装或升级依赖。", 3)
            resolved = Path(path).resolve()
            paths[name] = {"path": str(resolved), "sha256": sha256(resolved)}
        _, text = self.run("flutter-version", ["flutter", "--version", "--machine"], echo=False)
        flutter = json.loads(text[text.index("{"):])
        if flutter.get("frameworkVersion") != VERSIONS["flutter"]:
            raise BuildFailure(f"必须使用 Flutter {VERSIONS['flutter']}", 3)
        _, xcode = self.run("xcode-version", ["xcodebuild", "-version"])
        if xcode.splitlines()[0].strip() != f"Xcode {VERSIONS['xcode']}":
            raise BuildFailure(f"必须选择 Xcode {VERSIONS['xcode']}", 3)
        _, pod = self.run("cocoapods-version", ["pod", "--version"])
        if pod.strip() != VERSIONS["cocoapods"]:
            raise BuildFailure(f"必须使用 CocoaPods {VERSIONS['cocoapods']}", 3)
        # Ruby 的命令行 -r 先于 RUBYOPT 加载；在主程序中 require 才能沿用 pod 的激活顺序。
        _, xcodeproj = self.run("xcodeproj-version", ["ruby", "-e", "require 'xcodeproj'; puts Xcodeproj::VERSION"])
        if xcodeproj.strip() != VERSIONS["xcodeproj"]:
            raise BuildFailure(f"必须使用 xcodeproj {VERSIONS['xcodeproj']}", 3)
        _, ruby = self.run("ruby-version", ["ruby", "--version"])
        if not ruby.startswith(f"ruby {VERSIONS['ruby']} "):
            raise BuildFailure(f"必须使用 Ruby {VERSIONS['ruby']}", 3)
        # 回读实际激活的 gem 及路径，不能只以安装清单或版本字符串作为工具链证据。
        _, activated_text = self.run("ruby-activated-gems", ["ruby", "-e", 'require "cocoapods"; require "xcodeproj"; require "json"; puts JSON.generate(%w[cocoapods xcodeproj].to_h { |name| spec = Gem.loaded_specs.fetch(name); [name, {version: spec.version.to_s, path: spec.full_gem_path}] })'])
        activated_gems = json.loads(activated_text)
        if any(activated_gems.get(name, {}).get("version") != VERSIONS[name] for name in ["cocoapods", "xcodeproj"]):
            raise BuildFailure("Ruby 实际激活的 CocoaPods/xcodeproj 与固定版本不一致", 3)
        for package in ["cmake", "ninja"]:
            try:
                actual = importlib.metadata.version(package)
            except importlib.metadata.PackageNotFoundError as error:
                raise BuildFailure(f"缺少固定的 Python {package} 分发，请使用 CI 同款隔离环境。", 3) from error
            if actual != VERSIONS[f"{package}_distribution"]:
                raise BuildFailure(f"Python {package} 分发版本不符：{actual}", 3)
        _, cmake = self.run("cmake-version", ["cmake", "--version"])
        _, ninja = self.run("ninja-version", ["ninja", "--version"])
        if cmake.splitlines()[0].strip() != "cmake version 3.31.6" or not re.match(r"^1\.11\.1(?:$|[.+-])", ninja.strip()):
            raise BuildFailure("PATH 中 CMake/Ninja 与固定 Python 分发不一致", 3)
        _, selected = self.run("xcode-selection", ["xcode-select", "-p"])
        _, sdk = self.run("sdk-version", ["xcrun", "--sdk", "macosx" if self.result["platform"] == "macos" else "iphoneos", "--show-sdk-version"])
        self.result["tools"] = {"expected_versions": VERSIONS, "paths": paths, "flutter": flutter, "xcode": xcode.strip(), "developer_directory": selected.strip(), "sdk": sdk.strip(), "python": sys.version, "host_architecture": platform.machine(), "ruby_activation": {"path": str(self.ruby_activation), "sha256": sha256(self.ruby_activation), "gems": activated_gems}}

    def source_status(self) -> str:
        command = ["git", "status", "--porcelain", "--untracked-files=normal", "--", "."]
        if self.output.is_relative_to(self.project):
            command.append(f":(exclude){self.output.relative_to(self.project).as_posix()}")
        _, state = self.run("source-state", command, echo=False)
        return state

    def snapshot(self, allow_dirty: bool) -> None:
        _, commit = self.run("source-commit", ["git", "rev-parse", "HEAD"], echo=False)
        state = self.source_status()
        _, difference = self.run("source-diff-fingerprint", ["git", "diff", "--no-ext-diff", "--binary", "HEAD"], echo=False)
        # 差异日志留在本次本地/CI 证据目录，不输出到控制台。
        inputs = ["pubspec.yaml", "pubspec.lock", "scripts/build_apple.sh", "scripts/verify_apple_artifact.py", f"{self.result['platform']}/Podfile", f"{self.result['platform']}/Runner.xcodeproj/project.pbxproj"]
        self.result["source"] = {"commit": commit.strip(), "dirty": bool(state.strip()), "status": state.splitlines(), "diff_sha256": hashlib.sha256(difference.encode()).hexdigest(), "inputs": {name: sha256(self.project / name) for name in inputs if (self.project / name).is_file()}}
        _, entries = self.run("source-inventory", ["git", "ls-files", "--stage", "-z"], echo=False)
        for entry in entries.split("\0"):
            if not entry:
                continue
            metadata, name = entry.split("\t", 1)
            mode, blob, stage = metadata.split()
            path = self.project / name
            item: dict[str, object] = {"path": name, "git_mode": mode, "git_object": blob, "git_stage": stage}
            if mode == "160000":
                item["kind"] = "gitlink"
            elif path.is_symlink():
                item.update(kind="symlink", sha256=hashlib.sha256(os.readlink(path).encode()).hexdigest())
            elif path.is_file():
                item.update(kind="file", sha256=sha256(path), bytes=path.stat().st_size)
            else:
                item["kind"] = "missing"
            self.source_files.append(item)
        manifest = self.output / "source-manifest.json"
        write_json(manifest, {"commit": commit.strip(), "dirty": bool(state.strip()), "files": self.source_files})
        self.result["source"].update(manifest=manifest.name, manifest_sha256=sha256(manifest), tracked_entries=len(self.source_files))
        if state.strip() and not allow_dirty:
            raise BuildFailure("正式 Apple 构建拒绝 dirty 源码；请先冻结提交，避免把工作区修改标记为旧 commit。", 4)

    def verify_source_unchanged(self) -> None:
        changed = []
        for item in self.source_files:
            path = self.project / str(item["path"])
            if item["kind"] == "gitlink":
                continue
            actual = hashlib.sha256(os.readlink(path).encode()).hexdigest() if path.is_symlink() else sha256(path) if path.is_file() else None
            if actual != item.get("sha256"):
                changed.append(item["path"])
        state = self.source_status()
        _, patch = self.run("source-migration-diff", ["git", "diff", "--no-ext-diff", "--binary", "HEAD"], echo=False)
        (self.output / "source-after-build.patch").write_text(patch, encoding="utf-8")
        self.result["source"]["post_build_status"] = state.splitlines()
        self.result["source"]["changed_controlled_files"] = changed
        if changed or state.strip():
            raise BuildFailure("Flutter/CocoaPods 改动了冻结源码；已归档 source-after-build.patch，审核并提交迁移后重建。", 5)

    def archive_source_changes(self, phase: str) -> None:
        """首次 Mac 迁移的真实文件与补丁一起交付，后续可审核并纳入冻结提交。"""
        _, patch = self.run(f"{phase}-source-diff", ["git", "diff", "--no-ext-diff", "--binary", "HEAD"], echo=False)
        patch_path = self.output / f"{phase}-source-changes.patch"
        patch_path.write_text(patch, encoding="utf-8")
        _, changed = self.run(f"{phase}-changed-files", ["git", "diff", "--no-renames", "--name-only", "-z", "HEAD"], echo=False)
        files = []
        for name in changed.split("\0"):
            if not name:
                continue
            path = self.project / name
            destination = self.output / f"{phase}-source" / name
            if path.is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
                files.append({"path": name, "state": "modified", "sha256": sha256(destination)})
            elif path.is_symlink():
                files.append({"path": name, "state": "symlink", "target": os.readlink(path)})
            else:
                files.append({"path": name, "state": "removed_or_submodule"})
        manifest = self.output / f"{phase}-source" / "changes.json"
        write_json(manifest, {"source_commit": self.result["source"]["commit"], "files": files})
        self.result[f"{phase}_source_changes"] = {"patch": patch_path.name, "patch_sha256": sha256(patch_path), "manifest": str(manifest.relative_to(self.output)), "manifest_sha256": sha256(manifest), "files": len(files)}

    def archive_locks(self, paths: list[Path], origin: str) -> dict[str, str]:
        hashes = {}
        for path in paths:
            relative = path.relative_to(self.project)
            destination = self.output / "dependency-locks" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
            hashes[str(relative)] = sha256(path)
        metadata = {"origin": origin, "source_commit": self.result["source"]["commit"], "tools": self.result["tools"]["expected_versions"], "sha256": hashes, "recorded_at": utc_now()}
        write_json(self.output / "dependency-locks" / "provenance.json", metadata)
        self.result["dependency_locks"] = metadata
        return hashes


def lock_paths(project: Path, target: str) -> list[Path]:
    candidates = [project / "pubspec.lock", project / target / "Podfile.lock"]
    for directory in [project / target / "Runner.xcworkspace", project / target / "Runner.xcodeproj/project.xcworkspace"]:
        candidates += list(directory.rglob("Package.resolved"))
    return [path for path in candidates if path.is_file()]


def verify_lock_hashes(project: Path, hashes: dict[str, str]) -> None:
    for name, expected in hashes.items():
        path = project / name
        if not path.is_file() or sha256(path) != expected:
            raise BuildFailure(f"构建修改了冻结依赖锁：{name}；必须重新审核依赖并冻结。", 5)


def sign_macos(runner: Runner, app: Path, inventory: dict[str, object]) -> None:
    binaries = [app / item["path"] for item in inventory["binaries"]]
    bundles = [path for path in app.rglob("*") if path.is_dir() and not path.is_symlink() and path.suffix in {".framework", ".xpc", ".appex", ".app", ".bundle"} and any(file.is_relative_to(path) for file in binaries)]
    # 显式从最深层原生库到外层 bundle 签名，不用 --deep 掩盖嵌套签名遗漏。
    for path in sorted(binaries, key=lambda value: len(value.parts), reverse=True):
        runner.run("adhoc-binary", ["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)], timeout=120)
    for path in sorted(bundles, key=lambda value: len(value.parts), reverse=True):
        runner.run("adhoc-bundle", ["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)], timeout=120)
    runner.run("adhoc-app", ["codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", str(runner.project / "macos/Runner/Release.entitlements"), str(app)], timeout=120)
    runner.run("verify-signature", ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], timeout=180)
    for path in binaries:
        _, signature = runner.run("read-signature", ["codesign", "--display", "--verbose=4", str(path)], timeout=60, echo=False)
        if "Signature=adhoc" not in signature:
            raise BuildFailure(f"原生文件没有 ad-hoc 签名：{path.relative_to(app)}", 7)


def smoke_macos(runner: Runner, app: Path, executable: str, seconds: int) -> dict[str, object]:
    """只核验本次进程存活及动态库加载，结束时有界回收自己启动的进程。"""
    log = runner.output / "logs/macos-startup.log"
    scratch = runner.output / "startup-home"
    scratch.mkdir(exist_ok=True)
    environment = dict(runner.environment, CFFIXED_USER_HOME=str(scratch))
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen([str(app / executable)], cwd=app.parent, env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        early_exit = False
        try:
            process.wait(timeout=seconds)
            early_exit = True
        except subprocess.TimeoutExpired:
            pass
        finally:
            observed = time.monotonic() - started
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=8)
    text = log.read_text(encoding="utf-8", errors="replace")
    fatal_patterns = ["Library not loaded:", "Failed to load dynamic library", "MissingPluginException", "Unhandled Exception", "code signature invalid"]
    found = [pattern for pattern in fatal_patterns if pattern.lower() in text.lower()]
    report = {"status": "failed" if early_exit or found else "process_startup_passed", "host_architecture": platform.machine(), "observed_seconds": round(observed, 3), "exit_code_after_cleanup": process.returncode, "early_exit": early_exit, "fatal_markers": found, "process_terminated_by_script": not early_exit, "log": str(log.relative_to(runner.output)), "ui_validation": False, "playback_validation": False}
    write_json(runner.output / "macos-startup.json", report)
    if early_exit or found:
        raise BuildFailure("macOS 云端启动检查失败，详见 macos-startup.json", 8)
    return report


def check_ipa_layout(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for name in names:
            parts = PurePosixPath(name)
            if parts.is_absolute() or ".." in parts.parts:
                raise BuildFailure("IPA 包含不安全的归档路径", 7)
        expected = "Payload/Kazumi Plus.app/Info.plist"
        if expected not in names:
            raise BuildFailure("IPA 缺少 Payload/Kazumi Plus.app/Info.plist", 7)
        info = plistlib.loads(archive.read(expected))
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise BuildFailure("IPA 内 Bundle ID 不符", 7)


def build(args: argparse.Namespace) -> int:
    project = args.project_root.resolve()
    output = (args.output_dir or project / "dist/apple" / args.platform).resolve()
    runner = Runner(project, output, args.platform)
    exit_code = 0
    try:
        runner.toolchain()
        runner.snapshot(allow_dirty=args.bootstrap_pods)
        podlock = project / args.platform / "Podfile.lock"
        if not args.bootstrap_pods and not podlock.is_file():
            raise BuildFailure("缺少真实 Podfile.lock；请先在 Mac 显式 --bootstrap-pods，提交归档锁后再构建。", 78)
        if not (project / "pubspec.lock").is_file():
            raise BuildFailure("缺少 pubspec.lock，禁止临时解析 Dart 依赖后交付。", 5)
        initial_locks = lock_paths(project, args.platform)
        if not args.bootstrap_pods:
            for path in initial_locks:
                relative = str(path.relative_to(project))
                code, _ = runner.run("lock-tracked", ["git", "ls-files", "--error-unmatch", relative], check=False, echo=False)
                dirty, _ = runner.run("lock-clean", ["git", "diff", "--quiet", "HEAD", "--", relative], check=False, echo=False)
                if code or dirty:
                    raise BuildFailure(f"依赖锁尚未纳入提交或已改动：{relative}", 78)
        hashes = {str(path.relative_to(project)): sha256(path) for path in initial_locks}
        runner.run("dart-dependencies", ["flutter", "pub", "get", "--enforce-lockfile"], timeout=1200)
        config_command = ["flutter", "build", args.platform, "--config-only", "--release"]
        if args.platform == "ios":
            config_command.append("--no-codesign")
        # config-only 会真实调用 CocoaPods；首次锁必须来源于此 Mac 解析，不能伪造。
        runner.run("apple-configure", config_command, timeout=1800)
        if args.bootstrap_pods:
            runner.run("pods-bootstrap", ["pod", "install"], cwd=project / args.platform, timeout=1200)
            if not podlock.is_file():
                raise BuildFailure("CocoaPods 没有生成 Podfile.lock；请检查插件解析日志。", 5)
            runner.archive_locks(lock_paths(project, args.platform), "resolved_on_mac_pending_commit")
            runner.archive_source_changes("bootstrap")
            runner.result["source"]["post_bootstrap_status"] = runner.source_status().splitlines()
            runner.result.update(status="dependency_locks_generated_pending_freeze", next_step="审核并提交 dependency-locks 中的真实锁文件，然后不带 --bootstrap-pods 重跑；本次未编译应用。")
            exit_code = 78
        else:
            if set(hashes) != {str(path.relative_to(project)) for path in lock_paths(project, args.platform)}:
                raise BuildFailure("出现新的依赖锁，需重新 bootstrap 并提交冻结。", 78)
            verify_lock_hashes(project, hashes)
            runner.verify_source_unchanged()
            runner.run("pods-deployment", ["pod", "install", "--deployment"], cwd=project / args.platform, timeout=1200)
            verify_lock_hashes(project, hashes)
            runner.archive_locks(initial_locks, "committed_project_locks")
            command = ["flutter", "build", args.platform, "--release", "--verbose"]
            if args.platform == "ios":
                command.append("--no-codesign")
            runner.run("apple-build", command, timeout=args.build_timeout)
            verify_lock_hashes(project, hashes)
            runner.verify_source_unchanged()
            version_match = re.search(r"^version:\s*([^\s#]+)", (project / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
            if not version_match or not re.fullmatch(r"[A-Za-z0-9.+_-]+", version_match.group(1)):
                raise BuildFailure("pubspec.yaml 版本号不适合构建产物名称", 7)
            version = version_match.group(1)
            if args.platform == "macos":
                built = project / "build/macos/Build/Products/Release/Kazumi Plus.app"
                stage = output / "dmg-root"
                stage.mkdir()
                app = stage / "Kazumi Plus.app"
            else:
                built = project / "build/ios/iphoneos/Kazumi Plus.app"
                stage = output / "ipa-root/Payload"
                stage.mkdir(parents=True)
                app = stage / "Kazumi Plus.app"
            if not built.is_dir():
                raise BuildFailure(f"未找到预期应用包：{built}", 7)
            shutil.copytree(built, app, symlinks=True)
            inventory = inspect_app(app, args.platform)
            if args.platform == "macos":
                sign_macos(runner, app, inventory)
                inventory = inspect_app(app, "macos")
                runner.result["startup"] = smoke_macos(runner, app, inventory["executable"], args.smoke_seconds)
                (stage / "Applications").symlink_to("/Applications")
                artifact = output / f"Kazumi-Plus-{version}-macos-universal-adhoc.dmg"
                runner.run("package-dmg", ["hdiutil", "create", "-volname", "Kazumi Plus", "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(artifact)], timeout=600)
                runner.run("verify-dmg", ["hdiutil", "verify", str(artifact)], timeout=180)
                inventory.update(signature="ad_hoc", notarized=False)
                runner.result["limitations"].append("DMG 使用 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证；云端只启动主机架构。")
            else:
                signed, signature = runner.run("check-ios-unsigned", ["codesign", "--display", "--verbose=4", str(app)], check=False, timeout=60, echo=False)
                if signed == 0 or "not signed at all" not in signature.lower():
                    raise BuildFailure("Runner 仍带代码签名，不能将其标记为 --no-codesign 的未签名交付。", 7)
                inventory.update(signature="unsigned_application", provisioning_profile=False, nested_frameworks_may_have_adhoc_signatures=True)
                artifact = output / f"Kazumi-Plus-{version}-ios-arm64-unsigned.ipa"
                runner.run("package-unsigned-ipa", ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(artifact)], timeout=600)
                check_ipa_layout(artifact)
                runner.result["limitations"].append("IPA 为未签名 iPhone/iPad 真机包，未安装或启动；需用户另行合法签名与设备验收。")
            write_json(output / "artifact-verification.json", inventory)
            runner.result["verification"] = {"path": "artifact-verification.json", "sha256": sha256(output / "artifact-verification.json")}
            runner.result["artifacts"] = [{"path": artifact.name, "bytes": artifact.stat().st_size, "sha256": sha256(artifact), "source_commit": runner.result["source"]["commit"], "source_manifest_sha256": runner.result["source"]["manifest_sha256"]}]
            runner.result["status"] = "artifact_verified"
    except BuildFailure as error:
        exit_code = error.code
        runner.result.update(status="blocked" if error.code in {3, 78} else "failed", error=str(error))
        print(str(error), file=sys.stderr)
    except KeyboardInterrupt:
        exit_code = 130
        runner.result.update(status="cancelled", error="用户中断 Apple 构建。")
    except Exception as error:
        exit_code = 9
        runner.result.update(status="failed", error=f"{type(error).__name__}: {error}")
        print(runner.result["error"], file=sys.stderr)
    finally:
        if "source" in runner.result and runner.result["status"] in {"blocked", "failed"}:
            try:
                runner.archive_source_changes("failure")
                changed_locks = {}
                for lock in lock_paths(project, args.platform):
                    relative = lock.relative_to(project)
                    destination = output / "failure-dependency-locks" / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(lock, destination)
                    changed_locks[str(relative)] = sha256(lock)
                write_json(output / "failure-dependency-locks/provenance.json", {"qualification": "diagnostic_only_not_frozen", "sha256": changed_locks})
            except Exception as error:
                runner.result["evidence_archive_error"] = str(error)
        runner.result.update(exit_code=exit_code, finished_at=utc_now())
        write_json(output / "result.json", runner.result)
        hashes = [f"{item['sha256']}  {item['path']}" for item in runner.result["artifacts"]]
        hashes.append(f"{sha256(output / 'result.json')}  result.json")
        (output / "SHA256SUMS.txt").write_text("\n".join(hashes) + "\n", encoding="utf-8")
    return exit_code


def main() -> int:
    # 中文日志在 Windows 静态检查与 macOS CI 中均使用 UTF-8。
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    if sys.version_info < (3, 10):
        print("Apple 构建和校验脚本需要 Python 3.10 或更高版本。", file=sys.stderr)
        return 3
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    builder = subcommands.add_parser("build", help="在固定 Mac 工具链生成依赖锁或构建交付")
    builder.add_argument("platform", choices=["macos", "ios"])
    builder.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parent.parent)
    builder.add_argument("--output-dir", type=Path)
    builder.add_argument("--bootstrap-pods", action="store_true")
    builder.add_argument("--build-timeout", type=int, default=3600)
    builder.add_argument("--smoke-seconds", type=int, default=25)
    inspector = subcommands.add_parser("verify", help="只读检查已有 .app 的身份、系统版本和全部 Mach-O 架构")
    inspector.add_argument("platform", choices=["macos", "ios"])
    inspector.add_argument("app", type=Path)
    inspector.add_argument("--output-json", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "verify":
        try:
            report = inspect_app(args.app, args.platform)
            write_json(args.output_json, report)
            return 0
        except Exception as error:
            write_json(args.output_json, {"status": "failed", "error": str(error)})
            return 7
    if not 5 <= args.smoke_seconds <= 60 or not 60 <= args.build_timeout <= 7200:
        parser.error("启动观察需为 5–60 秒，构建超时需为 60–7200 秒")
    try:
        return build(args)
    except BuildFailure as error:
        print(str(error), file=sys.stderr)
        return error.code


if __name__ == "__main__":
    raise SystemExit(main())
