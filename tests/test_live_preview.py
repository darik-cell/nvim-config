"""Integration tests for the actual plugin, detached Neovim and browser sockets.

Run with: python3 -m unittest discover -s tests -p 'test_live_preview.py' -v
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from urllib.parse import quote, urlencode, urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = Path(os.environ.get("LIVE_PREVIEW_TEST_PLUGIN", Path.home() / ".local/share/nvim/lazy/live-preview.nvim"))
NVIM = shutil.which("nvim")


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


@unittest.skipUnless(NVIM and PLUGIN.is_dir(), "Neovim and installed live-preview.nvim required")
class DetachedPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.notes = self.directory / "notes"
        (self.notes / "sub").mkdir(parents=True)
        self.first = self.notes / "1.md"
        self.second = self.notes / "sub" / "2.md"
        self.third = self.notes / "3 Привет?#.markdown"
        self.first.write_text("- [ ] First\n\n[Two](sub/2.md?version=1#second)\n")
        self.second.write_text("- [ ] Second\n\n[Three](<../3 Привет%3F%23.markdown#third>)\n")
        self.third.write_text("# Third\n\n[One](1.md)\n")
        self.ready = self.directory / "ready.json"
        self.editor_socket = self.directory / "editor.sock"
        config_home = self.directory / "config"
        config_home.mkdir()
        (config_home / "nvim").symlink_to(ROOT / ".config/nvim", target_is_directory=True)
        init = self.directory / "editor.lua"
        init.write_text("""
vim.opt.runtimepath:append(vim.env.TEST_CONFIG)
vim.opt.runtimepath:append(vim.env.TEST_PLUGIN)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
dofile(vim.env.TEST_PLUGIN .. "/plugin/livepreview.lua")
local captured_url
require("livepreview.utils").open_browser = function(url) captured_url = url end
require("config.live_preview").setup({ dynamic_root = true })
vim.api.nvim_cmd({cmd = "edit", args = {vim.env.TEST_FIRST}}, {})
vim.api.nvim_cmd({cmd = "LivePreview", args = {"start", vim.env.TEST_FIRST}}, {})
local file = assert(io.open(vim.env.TEST_READY, "w"))
file:write(vim.json.encode({url = captured_url}))
file:close()
""")
        env = dict(os.environ, XDG_CONFIG_HOME=str(config_home), TEST_CONFIG=str(ROOT / ".config/nvim"),
                   TEST_PLUGIN=str(PLUGIN), TEST_FIRST=str(self.first), TEST_READY=str(self.ready))
        self.log = (self.directory / "editor.log").open("w+")
        self.addCleanup(self.log.close)
        self.editor = subprocess.Popen([NVIM, "--headless", "--noplugin", "-i", "NONE", "-u", str(init),
                                        "--listen", str(self.editor_socket)], env=env,
                                       stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)
        self.sockets = []
        self.addCleanup(self.cleanup_processes)
        if not wait_for(self.ready.exists):
            self.log.seek(0)
            self.fail("Editor/worker startup failed: " + self.log.read())
        self.url = json.loads(self.ready.read_text())["url"]
        self.port = urlsplit(self.url).port

    def cleanup_processes(self):
        for client in self.sockets:
            client.close()
        if self.editor.poll() is None:
            try:
                self.editor_lua('require("config.live_preview_process").stop(); return true')
            finally:
                self.editor.terminate()
                self.editor.wait(timeout=8)
        elif hasattr(self, "port"):
            # An editor that exited deliberately leaves a detached worker. Let its
            # normal idle shutdown finish before deleting temporary source files.
            wait_for(lambda: not self.listening(), timeout=8)

    def editor_lua(self, code):
        expression = "luaeval('(function() " + code.replace("'", "''") + " end)()')"
        result = subprocess.run([NVIM, "--server", str(self.editor_socket), "--remote-expr", expression],
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def listening(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                return True
        except OSError:
            return False

    def get(self, url):
        parts = urlsplit(url)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)
        try:
            connection.request("GET", parts.path + ("?" + parts.query if parts.query else ""),
                               headers={"Accept": "text/html"})
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def token(self, url):
        status, body = self.get(url)
        self.assertEqual(status, 200, body)
        return re.search(r'<meta name="live-preview-token" content="([^"]+)">', body)[1]

    def toggle(self, token, source, *, checked=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)
        query = urlencode({"line": 0, "checked": int(checked), "hash": hashlib.sha256(source.encode()).hexdigest()})
        try:
            connection.request("POST", "/__livepreview/task?" + query,
                               headers={"X-LivePreview-Token": token, "Content-Length": "0"})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def websocket(self):
        client = socket.create_connection(("127.0.0.1", self.port), timeout=8)
        client.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                        "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                        "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        self.assertIn(b"101 Switching Protocols", client.recv(4096))
        self.sockets.append(client)
        return client

    def close_page(self, client):
        # Masked browser WebSocket close frame (normal TCP close is tested too).
        client.sendall(bytes([0x88, 0x80, 1, 2, 3, 4]))
        client.close()

    def websocket_update(self, client):
        def read_exact(count):
            result = b""
            while len(result) < count:
                chunk = client.recv(count - len(result))
                self.assertTrue(chunk, "WebSocket closed while receiving a message")
                result += chunk
            return result
        for _ in range(10):
            header = read_exact(2)
            length = header[1] & 127
            if length == 126:
                length = struct.unpack("!H", read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", read_exact(8))[0]
            message = json.loads(read_exact(length))
            if message["type"] == "update":
                return message
        self.fail("No content update received after ten WebSocket messages")

    def test_transitive_links_parent_paths_queries_and_encoded_names(self):
        self.assertEqual(urlsplit(self.url).path, quote(str(self.first), safe="/"))
        second_url = urljoin(self.url, "sub/2.md?version=1#second")
        status, second_html = self.get(second_url)
        self.assertEqual(status, 200)
        self.assertIn("Second", second_html)
        third_url = urljoin(second_url, quote("../" + self.third.name, safe="/") + "#third")
        status, third_html = self.get(third_url)
        self.assertEqual(status, 200)
        self.assertIn("Third", third_html)
        self.assertEqual(self.get(urljoin(third_url, "1.md"))[0], 200)
        self.assertIn("/live-preview-config/task-list.js", second_html)
        self.assertEqual(self.get("/live-preview.nvim/static/markdown/markdown-it.min.js")[0], 200)
        self.assertEqual(self.get("/live-preview-config/light.css")[0], 200)

    def test_eight_previews_keep_earlier_files_and_links_available(self):
        previews = []
        for index in range(8):
            directory = self.notes / f"directory-{index}"
            directory.mkdir()
            document = directory / "note.md"
            document.write_text(f"# Document {index}\n\n[Linked](linked.md)\n")
            (directory / "linked.md").write_text(f"# Linked {index}\n")
            url = self.editor_lua(
                'vim.api.nvim_cmd({cmd="LivePreview", args={"start", ' + json.dumps(str(document)) + '}}, {}); '
                'return require("config.live_preview_process").url(' + json.dumps(str(document)) + ')'
            )
            self.assertEqual(urlsplit(url).port, self.port, "Opening another preview must reuse the same server")
            self.websocket()
            previews.append((url, index))
            for previous_url, previous_index in previews:
                status, body = self.get(previous_url)
                self.assertEqual(status, 200, previous_url)
                self.assertIn(f"Document {previous_index}", body)
                status, linked_body = self.get(urljoin(previous_url, "linked.md"))
                self.assertEqual(status, 200, previous_url)
                self.assertIn(f"Linked {previous_index}", linked_body)
        self.editor_lua('for _, buffer in ipairs(vim.api.nvim_list_bufs()) do '
                        'vim.api.nvim_buf_delete(buffer, {force=true}) end; return true')
        for url, index in previews:
            status, body = self.get(url)
            self.assertEqual(status, 200, url)
            self.assertIn(f"Document {index}", body)

    def test_reload_script_replaces_functions_after_clearing_module_cache(self):
        reload_path = ROOT / ".config/nvim/static/livepreview/reload.lua"
        # The test editor loads the plugin directly, so provide only the lazy
        # load entry point used by the script; all preview modules are real.
        self.editor_lua(
            'package.loaded["lazy"] = {load=function() end}; '
            'package.loaded["config.live_preview"] = nil; '
            'package.loaded["config.live_preview_process"] = nil; '
            'dofile(' + json.dumps(str(reload_path)) + '); return true'
        )
        self.assertEqual(self.editor_lua(
            'assert(package.loaded["config.live_preview"] ~= nil); '
            'assert(package.loaded["config.live_preview_process"] ~= nil); return "loaded"'
        ), "loaded")
        self.url = self.editor_lua(
            'vim.api.nvim_cmd({cmd="LivePreview", args={"start", vim.api.nvim_buf_get_name(0)}}, {}); '
            'return require("config.live_preview_process").url(vim.api.nvim_buf_get_name(0))'
        )
        self.port = urlsplit(self.url).port
        self.assertEqual(self.get(self.url)[0], 200)

    def test_linked_page_checkbox_edits_its_own_file(self):
        first_token = self.token(self.url)
        second_token = self.token(urljoin(self.url, "sub/2.md"))
        self.assertNotEqual(first_token, second_token)
        status, result = self.toggle(second_token, "- [ ] Second")
        self.assertEqual(status, 200, result)
        self.assertTrue(result["saved"])
        self.assertTrue(self.second.read_text().startswith("- [x] Second"))
        self.assertTrue(self.first.read_text().startswith("- [ ] First"))
        self.assertEqual(self.toggle(first_token, "- [ ] Second")[0], 409)
        self.assertEqual(self.toggle("invalid", "- [ ] First")[0], 403)

    def test_unsaved_buffers_and_checkbox_bridge(self):
        self.editor_lua('vim.api.nvim_buf_set_lines(0, 0, 1, false, {"- [ ] Unsaved"}); return true')
        token = self.token(self.url)
        self.assertIn("Unsaved", self.get(self.url)[1])
        status, result = self.toggle(token, "- [ ] Unsaved")
        self.assertEqual(status, 200, result)
        self.assertFalse(result["saved"])
        self.assertEqual(self.editor_lua('return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]'), "- [x] Unsaved")
        self.assertTrue(self.first.read_text().startswith("- [ ] First"))
        client = self.websocket()
        self.editor_lua('vim.api.nvim_buf_set_lines(0, 0, 1, false, {"- [ ] Updated"}); return true')
        message = self.websocket_update(client)
        self.assertEqual(message["filepath"], str(self.first))
        self.assertIn("Updated", message["content"])

    def test_updates_for_linked_disk_file_and_large_websocket_frames(self):
        self.get(urljoin(self.url, "sub/2.md"))
        client = self.websocket()
        content = "# Large linked page\n" + "Привет\n" * 15000
        self.second.write_text(content)
        message = self.websocket_update(client)
        self.assertEqual(message["filepath"], str(self.second))
        self.assertEqual(message["content"], content)

    def test_last_page_shutdown_navigation_grace_and_restart(self):
        first, second = self.websocket(), self.websocket()
        self.close_page(first)
        time.sleep(5.5)
        self.assertTrue(self.listening(), "Second page must keep the server alive")
        self.close_page(second)
        time.sleep(1)
        replacement = self.websocket()
        time.sleep(5.5)
        self.assertTrue(self.listening(), "Reload/navigation must cancel idle shutdown")
        replacement.close()  # Browser crash/EOF without an explicit close frame.
        self.assertTrue(wait_for(lambda: not self.listening()), "Last page must stop the listener")
        self.editor_lua('vim.api.nvim_cmd({cmd="LivePreview", args={"start", vim.api.nvim_buf_get_name(0)}}, {}); return true')
        self.url = self.editor_lua('return require("config.live_preview_process").url(vim.api.nvim_buf_get_name(0))')
        self.port = urlsplit(self.url).port
        self.assertEqual(self.get(self.url)[0], 200)

    def test_hidden_linked_buffer_is_authoritative_and_manual_close_works(self):
        code = ('local buffer = vim.fn.bufadd(' + json.dumps(str(self.second)) + '); '
                'vim.fn.bufload(buffer); '
                'vim.api.nvim_buf_set_lines(buffer, 0, 1, false, {"- [ ] Hidden unsaved"}); return true')
        self.editor_lua(code)
        second_url = urljoin(self.url, "sub/2.md")
        token = self.token(second_url)
        self.assertIn("Hidden unsaved", self.get(second_url)[1])
        status, result = self.toggle(token, "- [ ] Hidden unsaved")
        self.assertEqual(status, 200, result)
        self.assertFalse(result["saved"])
        self.assertTrue(self.second.read_text().startswith("- [ ] Second"))
        self.assertTrue(self.first.read_text().startswith("- [ ] First"))
        self.websocket()
        self.editor_lua('vim.cmd("LivePreview close"); return true')
        self.assertTrue(wait_for(lambda: not self.listening()), "Manual close must stop even an active preview")

    def test_worker_survives_editor_exit_and_uses_disk(self):
        self.token(self.url)
        token = self.token(urljoin(self.url, "sub/2.md"))
        client = self.websocket()
        self.editor_lua('vim.schedule(function() vim.cmd("qa!") end); return true')
        self.editor.wait(timeout=8)
        self.assertEqual(self.get(self.url)[0], 200)
        status, result = self.toggle(token, "- [ ] Second")
        self.assertEqual(status, 200, result)
        self.assertTrue(self.second.read_text().startswith("- [x] Second"))
        self.close_page(client)
        self.assertTrue(wait_for(lambda: not self.listening()), "Worker must exit after editor and last page close")


if __name__ == "__main__":
    unittest.main()
