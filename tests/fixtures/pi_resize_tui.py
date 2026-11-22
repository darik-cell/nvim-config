"""Pi-like resize: replay scrollback with repeated borders and an empty editor."""
import os
import signal
import sys
import textwrap
import time

pending = False


def resize(*_):
    global pending
    pending = True


signal.signal(signal.SIGWINCH, resize)


def render(clear=False):
    width = os.get_terminal_size().columns
    border = "─" * width
    lines = []
    for i in range(160):
        lines.extend(textwrap.wrap(f"{i:03} transcript line " + "abcdefghijklmnopqrstuvwxyz" * 3, width))
        lines.append(border)
    lines.extend([border, "", border, f"model status width {width}"])
    # Like Pi's fullRender: clear viewport + scrollback, then replay and put
    # the hidden hardware cursor in the empty editor above the footer.
    clear_codes = "\x1b[2J\x1b[H\x1b[3J" if clear else ""
    sys.stdout.write("\x1b[?2026h" + clear_codes + "\r\n".join(lines)
                     + "\x1b[2A\r\x1b[?25l\x1b[?2026l")
    sys.stdout.flush()


render()
while True:
    time.sleep(0.02)
    if pending:
        pending = False
        time.sleep(0.18)
        render(clear=True)
