"""Real Neovim process tests; all snapshots and shells use a temporary directory.

Run: python3 -m unittest discover -s tests -p 'test_recovery.py' -v
"""
import json
import os
import pty
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
NVIM = shutil.which("nvim")
SESSION_ID = "12345678-1234-1234-1234-123456789abc"


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.03)
    return False


def topology(node):
    return "leaf" if node["kind"] == "leaf" else (node["kind"], [topology(child) for child in node["children"]])


@unittest.skipUnless(NVIM and Path("/proc").is_dir(), "Linux and Neovim required")
class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.state = self.directory / "sessions"
        self.state.mkdir()
        self.editors = []
        self.requests = 0
        self.pty_fds = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for editor in self.editors:
            if editor[0].poll() is None:
                self.lua(editor, 'vim.schedule(function() vim.cmd("qa!") end); return true')
                editor[0].wait(timeout=8)
            editor[2].close()
        for fd in self.pty_fds:
            os.close(fd)

    def start(self, prompt=False, recovery=True, choice=1, interactive=False):
        index = len(self.editors)
        commands = self.directory / f"editor-{index}.commands"
        init = self.directory / f"editor-{index}.lua"
        init.write_text(f"""
vim.opt.runtimepath:append(vim.env.RECOVERY_CONFIG)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.hidden = true
vim.opt.shell = "/bin/sh"
vim.opt.scrollback = 10000
vim.opt.lines = 45
vim.opt.columns = 140
-- Enumerate real processes in this test workspace, excluding the user's editors.
local original_scan, original_next = vim.uv.fs_scandir, vim.uv.fs_scandir_next
local proc_scans = setmetatable({{}}, {{__mode = "k"}})
vim.uv.fs_scandir = function(path, ...)
  local scan, err = original_scan(path, ...)
  if path == "/proc" and scan then proc_scans[scan] = true end
  return scan, err
end
vim.uv.fs_scandir_next = function(scan)
  while true do
    local name, kind = original_next(scan)
    if not name or not proc_scans[scan] then return name, kind end
    local cwd = vim.uv.fs_readlink("/proc/" .. name .. "/cwd") or ""
    if cwd == vim.env.RECOVERY_WORKSPACE or cwd:sub(1, #vim.env.RECOVERY_WORKSPACE + 1)
        == vim.env.RECOVERY_WORKSPACE .. "/" then return name, kind end
  end
end
vim.fn.confirm = function(message)
  vim.fn.writefile({{message}}, vim.env.RECOVERY_PROMPT)
  return {choice}
end
-- File IPC avoids requiring network/socket permissions just to drive test editors.
local last_request
local timer = vim.uv.new_timer()
timer:start(20, 20, vim.schedule_wrap(function()
  local file = io.open(vim.env.RECOVERY_COMMANDS, "r")
  if not file then return end
  local text = file:read("*a"); file:close()
  local decoded, request = pcall(vim.json.decode, text)
  if not decoded or request.id == last_request then return end
  last_request = request.id
  local fn, compile_error = loadstring("return (function() " .. request.code .. " end)()")
  local ok, result
  if fn then ok, result = pcall(fn) else ok, result = false, compile_error end
  local path = vim.env.RECOVERY_COMMANDS .. ".response"
  vim.fn.writefile({{vim.json.encode({{id = request.id, ok = ok, result = tostring(result)}})}}, path .. ".tmp")
  assert(os.rename(path .. ".tmp", path))
end))
if {str(recovery).lower()} then
  require("config.recovery").setup({{headless = {str(not interactive).lower()}, dir = vim.env.RECOVERY_STATE,
    prompt = {str(prompt).lower()}, interval = 200}})
end
vim.api.nvim_create_autocmd("VimEnter", {{once = true, callback = function()
  vim.defer_fn(function() vim.fn.writefile({{"ready"}}, vim.env.RECOVERY_READY) end, 100)
end}})
""")
        ready = self.directory / f"ready-{index}"
        marker = self.directory / f"prompt-{index}"
        env = dict(os.environ, RECOVERY_CONFIG=str(ROOT / ".config/nvim"),
                   RECOVERY_WORKSPACE=str(self.directory),
                   RECOVERY_COMMANDS=str(commands),
                   RECOVERY_STATE=str(self.state), RECOVERY_READY=str(ready), RECOVERY_PROMPT=str(marker),
                   XDG_STATE_HOME=str(self.directory / "xdg-state"),
                   XDG_CACHE_HOME=str(self.directory / "xdg-cache"),
                   XDG_DATA_HOME=str(self.directory / "xdg-data"))
        log = (self.directory / f"log-{index}").open("w+")
        master, slave = pty.openpty() if interactive else (None, None)
        if interactive:
            self.pty_fds.extend([master, slave])
        proc = subprocess.Popen([NVIM, *([] if interactive else ["--headless"]), "--noplugin", "-i", "NONE", "-u", str(init)],
                                env=env, cwd=self.directory,
                                stdin=slave if interactive else subprocess.DEVNULL,
                                stdout=slave if interactive else log, stderr=log)
        editor = (proc, commands, log, marker)
        self.editors.append(editor)
        if not wait_for(ready.exists):
            log.seek(0)
            self.fail("Editor did not become ready: " + log.read())
        return editor

    def lua(self, editor, code):
        self.requests += 1
        request_id = self.requests
        path = editor[1]
        temporary = Path(str(path) + ".tmp")
        temporary.write_text(json.dumps({"id": request_id, "code": code}))
        temporary.replace(path)
        response = Path(str(path) + ".response")
        self.assertTrue(wait_for(lambda: response.exists()
                                 and json.loads(response.read_text())["id"] == request_id, timeout=15),
                        "No editor response for " + code)
        result = json.loads(response.read_text())
        self.assertTrue(result["ok"], result["result"])
        return result["result"]

    def value(self, editor, code):
        return json.loads(self.lua(editor, "return vim.json.encode(" + code + ")"))

    def snapshot(self, editor):
        self.assertEqual(self.lua(editor, 'return require("config.recovery").save()'), "true")
        pid = self.value(editor, 'vim.uv.os_getpid()')
        return next(path for path in self.state.glob("*.json")
                    if json.loads(path.read_text())["owner"]["pid"] == pid)

    def crash(self, editor):
        pid = self.value(editor, 'vim.uv.os_getpid()')
        os.kill(pid, signal.SIGKILL)
        editor[0].wait(timeout=8)

    def test_multiple_crashes_merge_tabs_splits_cwd_and_contents(self):
        first = self.start()
        one, two = self.directory / "проект один", self.directory / "project-two"
        one.mkdir()
        two.mkdir()
        file = one / "file name.md"
        file.write_text("original\nsecond\nthird\n")
        self.lua(first, f'vim.cmd.tcd({json.dumps(str(one), ensure_ascii=False)}); '
                 f'vim.cmd.edit({json.dumps(str(file), ensure_ascii=False)}); '
                 'vim.api.nvim_win_set_cursor(0, {3, 0}); '
                 'vim.cmd.vsplit(); vim.cmd.split(); vim.cmd.enew(); '
                 'vim.api.nvim_buf_set_lines(0, 0, -1, false, {"unsaved split"}); '
                 'vim.cmd.tabnew(); vim.api.nvim_buf_set_lines(0, 0, -1, false, {"first extra tab"}); return true')
        first_snapshot = self.snapshot(first)
        first_layout = json.loads(first_snapshot.read_text())["tabs"][0]["layout"]
        second = self.start()
        self.lua(second, f'vim.cmd.tcd({json.dumps(str(two))}); '
                 'vim.api.nvim_buf_set_lines(0, 0, -1, false, {"second editor"}); return true')
        second_snapshot = self.snapshot(second)
        self.crash(first)
        self.crash(second)
        recovered = self.start(prompt=True)
        self.assertTrue(recovered[3].exists(), "Recovery prompt was not offered")
        state = self.value(recovered, 'require("config.recovery").capture()')
        self.assertEqual(len(state["tabs"]), 3)
        self.assertEqual([tab["cwd"] for tab in state["tabs"]], [str(one), str(one), str(two)])
        self.assertEqual(state["tabs"][0]["layout"]["kind"], "row")
        self.assertEqual(topology(state["tabs"][0]["layout"]), topology(first_layout))
        contents = [item.get("lines") for item in state["buffers"].values()]
        self.assertIn(["unsaved split"], contents)
        self.assertIn(["first extra tab"], contents)
        self.assertIn(["second editor"], contents)
        self.assertFalse(first_snapshot.exists())
        self.assertFalse(second_snapshot.exists())
        merged = self.snapshot(recovered)
        self.assertEqual(merged.stat().st_mode & 0o777, 0o600)

    def test_interactive_start_enables_recovery(self):
        editor = self.start(interactive=True)
        snapshot = self.snapshot(editor)
        self.assertTrue(snapshot.exists())
        self.crash(editor)
        recovered = self.start(prompt=True, interactive=True)
        self.assertTrue(recovered[3].exists(), "Own TUI frontend must not suppress recovery")
        self.assertFalse(snapshot.exists())

    def test_prompt_draft_and_numbering_survive_crash(self):
        editor = self.start()
        paths = self.value(editor, '(function() '
                           'local w, t = require("config.workspace"), require("config.terminals"); '
                           't.open_agent({normal_mode = true}); local term = w.state().agent_term; '
                           'local ctx = w.terminal_prompt_context(term.bufnr, term.job_id, w.current_cwd()); '
                           'local sent = w.create_prompt(ctx); w.mark_prompt_sent(sent, ctx); '
                           'local draft = w.create_prompt(ctx); w.remember_prompt_context(ctx); '
                           'vim.cmd.edit(draft); '
                           'vim.api.nvim_buf_set_lines(0, 0, -1, false, {"unsaved prompt"}); '
                           'ctx.submission = {path = draft, job_id = term.job_id}; '
                           't.new_terminal(); local shell = w.state().terminals[w.state().last_terminal_slot]; '
                           'local other = w.terminal_prompt_context(shell.bufnr, shell.job_id, w.current_cwd()); '
                           'local other_path = w.create_prompt(other); '
                           'package.loaded["mini.pairs"] = {}; '
                           'local scratch = require("config.markdown").open_scratch(); '
                           'vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {"unsaved tab note"}); '
                           'return {sent, draft, other_path, ctx.id, other.id} end)()')
        self.addCleanup(shutil.rmtree, Path(paths[0]).parent, True)
        self.addCleanup(shutil.rmtree, Path(paths[2]).parent, True)
        saved = json.loads(self.snapshot(editor).read_text())
        self.assertNotIn("submission", saved["prompt_contexts"][paths[3]])
        self.crash(editor)
        restored = self.start(prompt=True)
        state = self.value(restored, '(function() local w = require("config.workspace"); '
                           'local c, s = w.last_prompt_context(), w.state(); '
                           'local scratch = s.scratch_bufnr; '
                           'return {path = c.path, sequence = c.sequence, directory = c.directory, '
                           'bound = w.context_for_terminal(c.terminal_bufnr) == c, queued = c.submission ~= nil, '
                           'scratch_type = vim.bo[scratch].buftype, '
                           'scratch_lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false), '
                           'lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(c.path), 0, -1, false)} end)()')
        self.assertEqual(state["path"], paths[1])
        self.assertEqual(state["sequence"], 2)
        self.assertEqual(state["directory"], str(Path(paths[1]).parent))
        self.assertEqual(state["lines"], ["unsaved prompt"])
        self.assertTrue(state["bound"])
        self.assertFalse(state["queued"])
        self.assertEqual(state["scratch_type"], "nofile")
        self.assertEqual(state["scratch_lines"], ["unsaved tab note"])
        other = self.value(restored, f'(function() local w = require("config.workspace"); '
                           f'local c = w.prompt_contexts[{json.dumps(paths[4])}]; '
                           'return {path = c.path, bound = w.context_for_terminal(c.terminal_bufnr) == c} end)()')
        self.assertEqual(other["path"], paths[2])
        self.assertTrue(other["bound"])
        following = self.lua(restored, 'local w = require("config.workspace"); '
                             'local c = w.last_prompt_context(); '
                             'w.mark_prompt_sent(c.path, c); return w.create_prompt(c)')
        self.assertNotIn(following, paths[:3])
        self.assertEqual(Path(following).parent, Path(paths[1]).parent)
        self.lua(restored, 'local w = require("config.workspace"); '
                 'local c = w.last_prompt_context(); w.mark_prompt_sent(c.path, c); return true')
        snapshot = self.value(restored, 'require("config.recovery").capture()')
        self.assertNotIn("path", snapshot["prompt_contexts"][paths[3]])
        self.assertEqual(snapshot["prompt_contexts"][paths[3]]["sequence"], 3)

    def test_live_unconfigured_editor_suppresses_prompt(self):
        crashed = self.start()
        snapshot = self.snapshot(crashed)
        self.crash(crashed)
        self.start(recovery=False)
        second = self.start(prompt=True)
        self.assertFalse(second[3].exists())
        self.assertTrue(snapshot.exists())

    def test_clean_exit_removes_only_own_snapshot(self):
        first = self.start()
        first_snapshot = self.snapshot(first)
        second = self.start()
        second_snapshot = self.snapshot(second)
        self.lua(second, 'vim.schedule(function() vim.cmd("qa!") end); return true')
        second[0].wait(timeout=8)
        self.assertFalse(second_snapshot.exists())
        self.assertTrue(first_snapshot.exists())

    def test_decline_keeps_snapshot_and_corrupt_snapshot_is_retained(self):
        crashed = self.start()
        snapshot = self.snapshot(crashed)
        self.crash(crashed)
        corrupt = self.state / "corrupt.json"
        corrupt.write_text("{broken")
        recovered = self.start(prompt=True, choice=2)
        self.assertTrue(recovered[3].exists())
        self.assertTrue(snapshot.exists())
        self.assertTrue(corrupt.exists())
        self.assertEqual(self.value(recovered, '#vim.api.nvim_list_tabpages()'), 1)

    def test_terminal_scrollback_resume_commands_and_hidden_slots(self):
        editor = self.start()
        self.lua(editor, 'local t = require("config.terminals"); t.new_terminal(); '
                 f'vim.api.nvim_chan_send(vim.b.terminal_job_id, "printf \'saved terminal text\\ncodex resume {SESSION_ID}\\n\'\\r"); '
                 'return true')
        self.assertTrue(wait_for(lambda: self.value(editor,
            'table.concat(vim.api.nvim_buf_get_lines(require("config.workspace").state().terminals[1].bufnr, 0, -1, false), "\\n")')
            .count("saved terminal text") >= 2))
        self.lua(editor, 'require("config.terminals").new_terminal(); return true')
        snapshot = self.snapshot(editor)
        self.crash(editor)
        data = json.loads(snapshot.read_text())
        terminal = next(item for item in data["buffers"].values()
                        if item.get("kind") == "terminal" and item.get("slot") == 1)
        terminal["lines"].append("touch " + str(self.directory / "should-not-exist"))
        snapshot.write_text(json.dumps(data))
        recovered = self.start(prompt=True)
        self.assertTrue(recovered[3].exists())
        self.assertFalse(snapshot.exists())
        state = self.value(recovered, '(function() local st = require("config.workspace").state(); '
                           'local result = {}; for slot, term in pairs(st.terminals) do '
                           'result[tostring(slot)] = {lines = vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false), '
                           'status = vim.fn.jobwait({term.job_id}, 0)[1], role = vim.b[term.bufnr].nvim_alt_terminal_role}; '
                           'end; return result end)()')
        self.assertEqual(set(state), {"1", "2"})
        self.assertIn("saved terminal text", "\n".join(state["1"]["lines"]))
        self.assertIn("codex resume " + SESSION_ID, "\n".join(state["1"]["lines"]))
        self.assertEqual(state["1"]["status"], -1)
        self.assertEqual(state["2"]["role"], "shell")
        # Historical commands must be displayed, never executed on restoration.
        self.assertFalse((self.directory / "should-not-exist").exists())

    def test_restore_preserves_open_startup_file(self):
        crashed = self.start()
        self.lua(crashed, 'vim.api.nvim_buf_set_lines(0, 0, -1, false, {"crashed content"}); return true')
        self.snapshot(crashed)
        self.crash(crashed)
        editor = self.start()
        file = self.directory / "current.md"
        file.write_text("current file\n")
        self.lua(editor, f'vim.cmd.edit({json.dumps(str(file))}); '
                 'return require("config.recovery").restore(require("config.recovery").pending())')
        self.assertEqual(self.value(editor, '#vim.api.nvim_list_tabpages()'), 2)
        self.assertEqual(self.value(editor, 'vim.api.nvim_buf_get_lines(vim.fn.bufnr(' + json.dumps(str(file)) + '), 0, -1, false)'),
                         ["current file"])

    def test_divergent_unsaved_files_from_two_editors_survive(self):
        file = self.directory / "shared.md"
        file.write_text("on disk\n")
        first, second = self.start(), self.start()
        for editor, text in [(first, "first unsaved copy"), (second, "second unsaved copy")]:
            self.lua(editor, f'vim.cmd.edit({json.dumps(str(file))}); '
                     f'vim.api.nvim_buf_set_lines(0, 0, -1, false, {{{json.dumps(text)}}}); return true')
            self.snapshot(editor)
        self.crash(first)
        self.crash(second)
        editor = self.start(prompt=True)
        snapshot = self.value(editor, 'require("config.recovery").capture()')
        copies = [item for item in snapshot["buffers"].values() if item.get("modified")]
        self.assertEqual({tuple(item["lines"]) for item in copies},
                         {("first unsaved copy",), ("second unsaved copy",)})
        unnamed = next(item for item in copies if item["name"] == "")
        self.assertEqual(unnamed["original_path"], str(file))
        self.assertEqual(file.read_text(), "on disk\n")

    def test_boot_id_and_stale_claim_do_not_block_recovery(self):
        crashed = self.start()
        snapshot = self.snapshot(crashed)
        self.crash(crashed)
        data = json.loads(snapshot.read_text())
        # A reused PID from a different boot must not be considered alive.
        data["owner"] = {"pid": os.getpid(), "boot": "previous-boot", "start": "1"}
        snapshot.write_text(json.dumps(data))
        (self.state / "recovery.lock").write_text(json.dumps(data["owner"]))
        recovered = self.start(prompt=True)
        self.assertTrue(recovered[3].exists())
        self.assertFalse(snapshot.exists())
        self.assertFalse((self.state / "recovery.lock").exists())


if __name__ == "__main__":
    unittest.main()
