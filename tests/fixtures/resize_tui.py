import os
import signal
import sys
import time

pending = False

def resize(*_):
    global pending
    pending = True

signal.signal(signal.SIGWINCH, resize)
for i in range(115):
    print(f'{i:03} older code line ' + 'абвгдеёжзийклмнопрстуфхцчшщыэюя' * 3, flush=True)
sys.stdout.write('При открытии и закрытии через контрольную панель')
sys.stdout.flush()
while True:
    time.sleep(0.02)
    if pending:
        pending = False
        time.sleep(0.18)
        width = os.get_terminal_size().columns
        for i in range(34):
            print(f'\r\n438 + return terminals.paste_into_agent redraw-{i:02} width-{width} ' + 'абвгдеёжзийклмнопрстуфхцчшщыэюя' * 2, end='', flush=True)
