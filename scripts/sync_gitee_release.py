#!/usr/bin/env python3
"""Synchronize a GitHub Release (metadata and binary assets) to Gitee Releases."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_API_BASE = "https://gitee.com/api/v5"
USER_AGENT = "kazumi-plus-gitee-sync/1.0"
MIB_100 = 100 * 1024 * 1024


class GiteeApiError(RuntimeError):
    """Error returned by Gitee REST API with sanitized diagnostics."""

    def __init__(self, status_code: int, message: str, url: str) -> None:
        self.status_code = status_code
        self.url = url
        super().__init__(f"Gitee API {status_code} for {url}: {message}")


@dataclass(frozen=True)
class SyncResult:
    release_id: int
    action: str
    release_url: str
    uploaded_files: list[str]


def sanitize_text(text: str, token: str) -> str:
    """Redact the secret token from any diagnostic string."""
    if not token:
        return text
    return text.replace(token, "***")


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off", ""}:
        return False
    raise argparse.ArgumentTypeError(f"Invalid boolean value: {value!r}")


def _escape_curl_config(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "")


def api_request(
    method: str,
    url: str,
    token: str,
    payload: dict[str, object] | None = None,
) -> object:
    """Perform a JSON/REST request against Gitee API v5."""
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    data: bytes | None = None
    if payload is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read().decode("utf-8", errors="replace").strip()
            if not raw:
                return None
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw_err = exc.read().decode("utf-8", errors="replace").strip()
        safe_err = sanitize_text(raw_err or exc.reason or "HTTP error", token)
        raise GiteeApiError(exc.code, safe_err, url) from exc
    except urllib.error.URLError as exc:
        safe_reason = sanitize_text(str(exc.reason), token)
        raise RuntimeError(f"Network error requesting {url}: {safe_reason}") from exc


def resolve_release_body(title: str, notes_file: Path | None, body: str | None) -> str:
    """Resolve release notes from file or inline text, falling back to title."""
    content = ""
    if notes_file is not None:
        if not notes_file.is_file():
            raise FileNotFoundError(f"Release notes file not found: {notes_file}")
        content = notes_file.read_text(encoding="utf-8")
    elif body is not None:
        content = body
    if not content.strip():
        return title
    return content


def upsert_release(
    *,
    api_base: str,
    owner: str,
    repo: str,
    tag: str,
    title: str,
    body: str,
    target_commitish: str,
    prerelease: bool,
    token: str,
) -> tuple[int, str]:
    """Create or update the Gitee Release for the given tag."""
    base = api_base.rstrip("/")
    encoded_tag = urllib.parse.quote(tag, safe="")
    tag_url = f"{base}/repos/{owner}/{repo}/releases/tags/{encoded_tag}"
    releases_url = f"{base}/repos/{owner}/{repo}/releases"

    existing: object | None = None
    try:
        existing = api_request("GET", tag_url, token)
    except GiteeApiError as exc:
        if exc.status_code != 404:
            raise

    if isinstance(existing, dict) and isinstance(existing.get("id"), int):
        release_id = existing["id"]
        patch_url = f"{releases_url}/{release_id}"
        patch_payload: dict[str, object] = {
            "access_token": token,
            "tag_name": tag,
            "name": title,
            "body": body,
            "prerelease": prerelease,
        }
        updated = api_request("PATCH", patch_url, token, patch_payload)
        if isinstance(updated, dict) and isinstance(updated.get("id"), int):
            release_id = updated["id"]
        return release_id, "updated"

    create_payload: dict[str, object] = {
        "access_token": token,
        "tag_name": tag,
        "name": title,
        "body": body,
        "target_commitish": target_commitish,
        "prerelease": prerelease,
    }
    created = api_request("POST", releases_url, token, create_payload)
    if not isinstance(created, dict) or not isinstance(created.get("id"), int):
        raise RuntimeError(f"Unexpected Gitee create release response: {created!r}")
    return created["id"], "created"


def list_attachments(
    *,
    api_base: str,
    owner: str,
    repo: str,
    release_id: int,
    token: str,
) -> list[dict[str, object]]:
    base = api_base.rstrip("/")
    url = f"{base}/repos/{owner}/{repo}/releases/{release_id}/attach_files?per_page=100"
    data = api_request("GET", url, token)
    if data is None:
        return []
    if not isinstance(data, list):
        raise RuntimeError(f"Unexpected attach_files response: {data!r}")
    return [item for item in data if isinstance(item, dict)]


def delete_attachment(
    *,
    api_base: str,
    owner: str,
    repo: str,
    release_id: int,
    file_id: int,
    token: str,
) -> None:
    base = api_base.rstrip("/")
    url = f"{base}/repos/{owner}/{repo}/releases/{release_id}/attach_files/{file_id}"
    api_request("DELETE", url, token)


def upload_single_attachment(
    *,
    curl_bin: str,
    upload_url: str,
    asset_path: Path,
    token: str,
) -> None:
    escaped = _escape_curl_config(token)
    curl_config = (
        f'header = "Authorization: token {escaped}"\n'
        f'form = "access_token={escaped}"\n'
    )
    cmd = [
        curl_bin,
        "--silent",
        "--show-error",
        "--retry",
        "3",
        "--retry-delay",
        "5",
        "--retry-all-errors",
        "-X",
        "POST",
        "--config",
        "-",
        "-F",
        f"file=@{asset_path};filename={asset_path.name}",
        "-w",
        "\n%{http_code}",
        upload_url,
    ]
    proc = subprocess.run(
        cmd,
        input=curl_config,
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""
    if proc.returncode != 0:
        detail = sanitize_text(stderr.strip() or stdout.strip(), token)
        raise RuntimeError(
            f"curl failed uploading {asset_path.name} (exit {proc.returncode}): {detail}"
        )

    lines = stdout.rstrip("\r\n").rsplit("\n", 1)
    if len(lines) == 2:
        resp_body, status_raw = lines[0], lines[1].strip()
    else:
        resp_body, status_raw = "", lines[0].strip() if lines else ""

    if not status_raw.isdigit():
        raise RuntimeError(
            f"Unable to parse HTTP status uploading {asset_path.name}: {sanitize_text(stdout, token)}"
        )
    status_code = int(status_raw)
    if not (200 <= status_code < 300):
        raise GiteeApiError(
            status_code,
            sanitize_text(resp_body.strip() or "Upload failed", token),
            upload_url,
        )


def sync_assets(
    *,
    api_base: str,
    owner: str,
    repo: str,
    release_id: int,
    assets_dir: Path,
    token: str,
    curl_bin: str,
) -> list[str]:
    if not assets_dir.is_dir():
        raise FileNotFoundError(f"Assets directory not found: {assets_dir}")

    local_files = sorted(
        (p for p in assets_dir.iterdir() if p.is_file()),
        key=lambda p: p.name,
    )
    if not local_files:
        raise RuntimeError(f"No asset files found in {assets_dir}")

    existing = list_attachments(
        api_base=api_base,
        owner=owner,
        repo=repo,
        release_id=release_id,
        token=token,
    )
    existing_by_name: dict[str, list[int]] = {}
    for item in existing:
        name = item.get("name")
        file_id = item.get("id")
        if isinstance(name, str) and isinstance(file_id, int):
            existing_by_name.setdefault(name, []).append(file_id)

    base = api_base.rstrip("/")
    upload_url = f"{base}/repos/{owner}/{repo}/releases/{release_id}/attach_files"

    uploaded_names: list[str] = []
    for asset_path in local_files:
        for old_id in existing_by_name.get(asset_path.name, []):
            print(f"Removing existing attachment {asset_path.name} (id={old_id})...")
            delete_attachment(
                api_base=api_base,
                owner=owner,
                repo=repo,
                release_id=release_id,
                file_id=old_id,
                token=token,
            )

        size_bytes = asset_path.stat().st_size
        if size_bytes > MIB_100:
            print(
                f"Warning: {asset_path.name} is {size_bytes / (1024 * 1024):.2f} MiB, "
                "which exceeds 100 MiB and may be rejected by Gitee free plans.",
                file=sys.stderr,
            )

        print(f"Uploading {asset_path.name} ({size_bytes} bytes)...")
        upload_single_attachment(
            curl_bin=curl_bin,
            upload_url=upload_url,
            asset_path=asset_path,
            token=token,
        )
        uploaded_names.append(asset_path.name)

    verified = list_attachments(
        api_base=api_base,
        owner=owner,
        repo=repo,
        release_id=release_id,
        token=token,
    )
    remote_names = {
        item.get("name") for item in verified if isinstance(item.get("name"), str)
    }
    missing = [name for name in uploaded_names if name not in remote_names]
    if missing:
        raise RuntimeError(
            f"Uploaded files missing after verification on Gitee: {', '.join(missing)}"
        )

    return uploaded_names


def sync_release(
    *,
    owner: str,
    repo: str,
    tag: str,
    title: str,
    notes_file: Path | None,
    body: str | None,
    target_commitish: str,
    prerelease: bool,
    assets_dir: Path | None,
    token_env: str = "GITEE_TOKEN",
    api_base: str = DEFAULT_API_BASE,
    curl_bin: str = "curl",
) -> SyncResult:
    token = os.environ.get(token_env, "").strip()
    if not token:
        raise RuntimeError(
            f"Environment variable {token_env} is empty or not set. "
            "Configure GITEE_TOKEN with Gitee personal access token (projects scope)."
        )

    resolved_body = resolve_release_body(title, notes_file, body)
    release_id, action = upsert_release(
        api_base=api_base,
        owner=owner,
        repo=repo,
        tag=tag,
        title=title,
        body=resolved_body,
        target_commitish=target_commitish,
        prerelease=prerelease,
        token=token,
    )

    uploaded_files: list[str] = []
    if assets_dir is not None:
        uploaded_files = sync_assets(
            api_base=api_base,
            owner=owner,
            repo=repo,
            release_id=release_id,
            assets_dir=assets_dir,
            token=token,
            curl_bin=curl_bin,
        )

    release_url = f"https://gitee.com/{owner}/{repo}/releases/tag/{tag}"
    return SyncResult(
        release_id=release_id,
        action=action,
        release_url=release_url,
        uploaded_files=uploaded_files,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Synchronize a release and its assets to Gitee Releases (API v5)."
    )
    parser.add_argument("--owner", required=True, help="Gitee repository owner/org.")
    parser.add_argument("--repo", required=True, help="Gitee repository name.")
    parser.add_argument("--tag", required=True, help="Git tag name (e.g. v0.2.4).")
    parser.add_argument(
        "--title",
        default=None,
        help="Release title (defaults to 'Kazumi Plus <tag>').",
    )
    parser.add_argument(
        "--notes-file",
        type=Path,
        default=None,
        help="Path to UTF-8 markdown file containing release notes.",
    )
    parser.add_argument(
        "--body",
        default=None,
        help="Inline release notes text (ignored if --notes-file is given).",
    )
    parser.add_argument(
        "--target-commitish",
        required=True,
        help="Commit SHA or branch targeted by the tag.",
    )
    parser.add_argument(
        "--prerelease",
        type=parse_bool,
        default=False,
        help="Whether the release is a prerelease ('true' or 'false').",
    )
    parser.add_argument(
        "--assets-dir",
        type=Path,
        default=None,
        help="Directory containing release assets to upload.",
    )
    parser.add_argument(
        "--token-env",
        default="GITEE_TOKEN",
        help="Name of the environment variable holding the Gitee token.",
    )
    parser.add_argument(
        "--api-base",
        default=DEFAULT_API_BASE,
        help=f"Gitee API v5 base URL (default: {DEFAULT_API_BASE}).",
    )
    parser.add_argument(
        "--curl-bin",
        default="curl",
        help="Path or name of curl binary used for multipart asset uploads.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    title = args.title or f"Kazumi Plus {args.tag}"

    try:
        result = sync_release(
            owner=args.owner,
            repo=args.repo,
            tag=args.tag,
            title=title,
            notes_file=args.notes_file,
            body=args.body,
            target_commitish=args.target_commitish,
            prerelease=args.prerelease,
            assets_dir=args.assets_dir,
            token_env=args.token_env,
            api_base=args.api_base,
            curl_bin=args.curl_bin,
        )
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(
        f"Successfully {result.action} Gitee release id={result.release_id}: "
        f"{result.release_url} ({len(result.uploaded_files)} assets synced)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
