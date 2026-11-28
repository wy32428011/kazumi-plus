#!/usr/bin/env python3
"""Unit and mock-HTTP tests for scripts/sync_gitee_release.py."""

from __future__ import annotations

from email.parser import BytesParser
from email.policy import default as email_default_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sync_gitee_release as sgr  # noqa: E402


class MockGiteeState:
    def __init__(self, expected_token: str) -> None:
        self.expected_token = expected_token
        self.next_release_id = 100
        self.next_file_id = 500
        self.releases: dict[int, dict[str, object]] = {}
        self.attachments: dict[int, list[dict[str, object]]] = {}
        self.requests: list[tuple[str, str, dict[str, object] | None]] = []
        self.force_500_with_token = False


def make_handler(state: MockGiteeState):
    class MockGiteeHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            return

        def _send_json(self, code: int, payload: object) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _check_auth(self) -> bool:
            auth = self.headers.get("Authorization", "")
            return auth == f"token {state.expected_token}"

        def _read_body(self) -> bytes:
            length = int(self.headers.get("Content-Length", "0") or "0")
            return self.rfile.read(length) if length > 0 else b""

        def do_GET(self) -> None:
            if not self._check_auth():
                self._send_json(401, {"message": "Unauthorized"})
                return

            parsed = urllib.parse.urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]

            if state.force_500_with_token:
                self._send_json(
                    500,
                    {"message": f"Internal error token={state.expected_token}"},
                )
                return

            # /api/v5/repos/{owner}/{repo}/releases/tags/{tag}
            if len(parts) == 8 and parts[5] == "releases" and parts[6] == "tags":
                tag = urllib.parse.unquote(parts[7])
                for rel in state.releases.values():
                    if rel.get("tag_name") == tag:
                        self._send_json(200, rel)
                        return
                self._send_json(404, {"message": "Not Found"})
                return

            # /api/v5/repos/{owner}/{repo}/releases/{id}/attach_files
            if len(parts) == 8 and parts[5] == "releases" and parts[7] == "attach_files":
                rel_id = int(parts[6])
                items = [
                    {"id": att["id"], "name": att["name"], "size": att["size"]}
                    for att in state.attachments.get(rel_id, [])
                ]
                self._send_json(200, items)
                return

            self._send_json(404, {"message": "Unknown GET path"})

        def do_POST(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]
            raw = self._read_body()

            # /api/v5/repos/{owner}/{repo}/releases
            if len(parts) == 6 and parts[5] == "releases":
                if not self._check_auth():
                    self._send_json(401, {"message": "Unauthorized"})
                    return
                payload = json.loads(raw.decode("utf-8"))
                state.requests.append(("POST", parsed.path, payload))
                rel_id = state.next_release_id
                state.next_release_id += 1
                record = {
                    "id": rel_id,
                    "tag_name": payload["tag_name"],
                    "name": payload["name"],
                    "body": payload["body"],
                    "target_commitish": payload["target_commitish"],
                    "prerelease": payload["prerelease"],
                }
                state.releases[rel_id] = record
                state.attachments.setdefault(rel_id, [])
                self._send_json(201, record)
                return

            # /api/v5/repos/{owner}/{repo}/releases/{id}/attach_files
            if len(parts) == 8 and parts[5] == "releases" and parts[7] == "attach_files":
                if not self._check_auth():
                    self._send_json(401, {"message": "Unauthorized"})
                    return
                rel_id = int(parts[6])
                content_type = self.headers.get("Content-Type", "")
                header_bytes = (
                    f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n"
                ).encode("utf-8")
                msg = BytesParser(policy=email_default_policy).parsebytes(
                    header_bytes + raw
                )
                form_token = None
                uploaded_name = None
                uploaded_bytes = b""
                for part in msg.iter_parts():
                    name = part.get_param("name", header="content-disposition")
                    filename = part.get_filename()
                    payload_bytes = part.get_payload(decode=True) or b""
                    if name == "access_token":
                        form_token = payload_bytes.decode("utf-8")
                    elif name == "file":
                        uploaded_name = filename
                        uploaded_bytes = payload_bytes

                if form_token != state.expected_token or not uploaded_name:
                    self._send_json(400, {"message": "Missing access_token or file"})
                    return

                file_id = state.next_file_id
                state.next_file_id += 1
                att = {
                    "id": file_id,
                    "name": uploaded_name,
                    "size": len(uploaded_bytes),
                    "content": uploaded_bytes,
                }
                state.attachments.setdefault(rel_id, []).append(att)
                state.requests.append(
                    ("POST_FILE", parsed.path, {"name": uploaded_name, "size": len(uploaded_bytes)})
                )
                self._send_json(201, {"id": file_id, "name": uploaded_name})
                return

            self._send_json(404, {"message": "Unknown POST path"})

        def do_PATCH(self) -> None:
            if not self._check_auth():
                self._send_json(401, {"message": "Unauthorized"})
                return
            parsed = urllib.parse.urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]
            raw = self._read_body()
            if len(parts) == 7 and parts[5] == "releases":
                rel_id = int(parts[6])
                payload = json.loads(raw.decode("utf-8"))
                state.requests.append(("PATCH", parsed.path, payload))
                if rel_id not in state.releases:
                    self._send_json(404, {"message": "Not Found"})
                    return
                if not payload.get("tag_name"):
                    self._send_json(400, {"message": "tag_name is missing"})
                    return
                state.releases[rel_id].update(
                    {
                        "tag_name": payload["tag_name"],
                        "name": payload["name"],
                        "body": payload["body"],
                        "prerelease": payload["prerelease"],
                    }
                )
                self._send_json(200, state.releases[rel_id])
                return

            self._send_json(404, {"message": "Unknown PATCH path"})

        def do_DELETE(self) -> None:
            if not self._check_auth():
                self._send_json(401, {"message": "Unauthorized"})
                return
            parsed = urllib.parse.urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]
            if len(parts) == 9 and parts[5] == "releases" and parts[7] == "attach_files":
                rel_id = int(parts[6])
                file_id = int(parts[8])
                state.requests.append(("DELETE", parsed.path, {"file_id": file_id}))
                current = state.attachments.get(rel_id, [])
                state.attachments[rel_id] = [
                    att for att in current if att["id"] != file_id
                ]
                self.send_response(204)
                self.end_headers()
                return
            self._send_json(404, {"message": "Unknown DELETE path"})

    return MockGiteeHandler


class SyncGiteeReleaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.token = "secret-gitee-token-12345"
        self.state = MockGiteeState(self.token)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.state))
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.api_base = f"http://127.0.0.1:{self.port}/api/v5"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def test_create_new_release_and_upload_assets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            notes = tmp_path / "v0.2.4.md"
            notes.write_text("# Release v0.2.4\n\nAll good.", encoding="utf-8")
            assets = tmp_path / "assets"
            assets.mkdir()
            (assets / "Kazumi-Plus-v0.2.4-android-tv.apk").write_bytes(b"apk-binary")
            (assets / "SHA256SUMS.txt").write_bytes(b"abc  file\n")

            with mock.patch.dict(os.environ, {"GITEE_TOKEN": self.token}, clear=False):
                result = sgr.sync_release(
                    owner="ZoomEnterprise",
                    repo="kazumi-plus",
                    tag="v0.2.4",
                    title="Kazumi Plus v0.2.4",
                    notes_file=notes,
                    body=None,
                    target_commitish="b9156851f4d2316d61c22b69ea799a7f569ed2e5",
                    prerelease=True,
                    assets_dir=assets,
                    api_base=self.api_base,
                )

            self.assertEqual(result.action, "created")
            self.assertEqual(
                result.uploaded_files,
                ["Kazumi-Plus-v0.2.4-android-tv.apk", "SHA256SUMS.txt"],
            )
            rel = self.state.releases[result.release_id]
            self.assertEqual(rel["tag_name"], "v0.2.4")
            self.assertEqual(
                rel["target_commitish"], "b9156851f4d2316d61c22b69ea799a7f569ed2e5"
            )
            self.assertTrue(rel["prerelease"])
            atts = {a["name"]: a["content"] for a in self.state.attachments[result.release_id]}
            self.assertEqual(atts["Kazumi-Plus-v0.2.4-android-tv.apk"], b"apk-binary")
            self.assertEqual(atts["SHA256SUMS.txt"], b"abc  file\n")

    def test_update_existing_release_replaces_same_name_attachment(self) -> None:
        self.state.releases[10] = {
            "id": 10,
            "tag_name": "v0.2.4",
            "name": "Old Title",
            "body": "Old body",
            "target_commitish": "oldsha",
            "prerelease": False,
        }
        self.state.attachments[10] = [
            {"id": 901, "name": "SHA256SUMS.txt", "size": 3, "content": b"old"},
            {"id": 902, "name": "keep-me.txt", "size": 4, "content": b"keep"},
        ]

        with tempfile.TemporaryDirectory() as tmp:
            assets = Path(tmp) / "assets"
            assets.mkdir()
            (assets / "SHA256SUMS.txt").write_bytes(b"new-checksums")

            with mock.patch.dict(os.environ, {"GITEE_TOKEN": self.token}, clear=False):
                result = sgr.sync_release(
                    owner="ZoomEnterprise",
                    repo="kazumi-plus",
                    tag="v0.2.4",
                    title="Kazumi Plus v0.2.4",
                    notes_file=None,
                    body="Updated notes",
                    target_commitish="newsha",
                    prerelease=False,
                    assets_dir=assets,
                    api_base=self.api_base,
                )

            self.assertEqual(result.action, "updated")
            self.assertEqual(result.release_id, 10)
            self.assertEqual(self.state.releases[10]["name"], "Kazumi Plus v0.2.4")
            self.assertEqual(self.state.releases[10]["body"], "Updated notes")
            patch_reqs = [r for r in self.state.requests if r[0] == "PATCH"]
            self.assertEqual(len(patch_reqs), 1)
            self.assertEqual(patch_reqs[0][2]["tag_name"], "v0.2.4")
            delete_reqs = [r for r in self.state.requests if r[0] == "DELETE"]
            self.assertEqual(len(delete_reqs), 1)
            self.assertEqual(delete_reqs[0][2]["file_id"], 901)
            atts = {a["name"]: a["content"] for a in self.state.attachments[10]}
            self.assertEqual(atts["SHA256SUMS.txt"], b"new-checksums")
            self.assertEqual(atts["keep-me.txt"], b"keep")

    def test_missing_token_fails_clearly(self) -> None:
        with mock.patch.dict(os.environ, {"GITEE_TOKEN": ""}, clear=False):
            with self.assertRaises(RuntimeError) as ctx:
                sgr.sync_release(
                    owner="ZoomEnterprise",
                    repo="kazumi-plus",
                    tag="v0.2.4",
                    title="Kazumi Plus v0.2.4",
                    notes_file=None,
                    body="notes",
                    target_commitish="sha",
                    prerelease=False,
                    assets_dir=None,
                    api_base=self.api_base,
                )
        self.assertIn("GITEE_TOKEN", str(ctx.exception))

    def test_server_500_redacts_token(self) -> None:
        self.state.force_500_with_token = True
        with mock.patch.dict(os.environ, {"GITEE_TOKEN": self.token}, clear=False):
            with self.assertRaises(sgr.GiteeApiError) as ctx:
                sgr.sync_release(
                    owner="ZoomEnterprise",
                    repo="kazumi-plus",
                    tag="v0.2.4",
                    title="Kazumi Plus v0.2.4",
                    notes_file=None,
                    body="notes",
                    target_commitish="sha",
                    prerelease=False,
                    assets_dir=None,
                    api_base=self.api_base,
                )
        msg = str(ctx.exception)
        self.assertNotIn(self.token, msg)
        self.assertIn("***", msg)


if __name__ == "__main__":
    unittest.main()
