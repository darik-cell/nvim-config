# Расширения Pi

Этот каталог устанавливается отдельно. `install.sh` в корне репозитория не устанавливает Pi и не копирует эти расширения. Для их переноса не нужно переустанавливать Neovim или Kitty.

## pi-fold — сворачивание в Neovim

Нужны Pi в обычном TUI, `pi-tidy` с включёнными группами и сводками ходов (`groupTools: true`, `collapseTurns: "afterRun"`) и Neovim. Проверено с Pi 1.6.0 и pi-tidy 0.11.1 на Neovim 0.12.5.

Из корня репозитория, если `pi-tidy` ещё не установлен:

```sh
pi install npm:pi-tidy
```

Скопируй расширение. Если одноимённый файл уже есть, сначала сравни его: команда заменит его копией из Git.

```sh
install -Dm644 pi/extensions/pi-fold.ts "$HOME/.pi/agent/extensions/pi-fold.ts"
```

Если используешь профиль `piman`, выполни `piman install npm:pi-tidy`, а расширение скопируй в `~/.pi/profiles/piman/extensions/`. Профили используют один бинарник Pi, но не делят установленные пакеты и файлы расширений.

Часть Neovim лежит отдельно: [`pi-fold.lua`](../.config/nvim/lua/pi-fold.lua) и [`pi-fold-frame.lua`](../.config/nvim/lua/pi-fold-frame.lua). В конфиге из этого репозитория подключение уже есть в [`init.lua`](../.config/nvim/init.lua). Для другого конфига положи оба файла рядом в `lua/` и добавь `require("pi-fold").setup()`.

В уже запущенном Pi выполни `/reload`. В terminal-NORMAL (`Ctrl-\`, `Ctrl-N`), с пустой строкой ввода Pi, проверь `zo`/`zc` на сводке хода или группы инструментов.

`<leader>cp` копирует в системный буфер обмена код или ответ под курсором. Работает в обоих стилях оформления `pi-tidy`: `rail` и `frame`. На заголовке, внутри или на нижней границе блока кода копируется только этот блок. В остальной части рамки ответа копируется весь ответ в Markdown. Текст берётся из Pi, поэтому переносы экрана и рамка не попадают в буфер, а текущий черновик не меняется.

## Убрать значок GPT в pi-tidy — опционально

[Локальный патч](pi-tidy-hide-gpt-icon.patch) убирает значки `openai` и `openai-codex` из заголовка ответа и сводки хода, не меняя имена моделей и остальные значки. Проверено с `pi-tidy` 0.11.1. Обновление npm-пакета может перезаписать правку.

Из корня репозитория после установки или обновления `pi-tidy` (на уже пропатченном профиле команда ничего не меняет):

```sh
(
  set -e
  patch_file="$PWD/pi/pi-tidy-hide-gpt-icon.patch"
  for agent_dir in "$HOME/.pi/agent" "$HOME/.pi/profiles/piman"; do
    tidy_dir="$agent_dir/npm/node_modules/pi-tidy"
    [ -d "$tidy_dir" ] || continue
    (cd "$tidy_dir"
     git apply --unidiff-zero --reverse --check "$patch_file" 2>/dev/null ||
       git apply --unidiff-zero "$patch_file")
  done
)
```

Перезапусти Pi после применения.

## static-working — опционально

Отключает анимацию спиннера, оставляя надпись `Working`. От Neovim и `pi-fold` не зависит.

```sh
install -Dm644 pi/extensions/static-working.ts "$HOME/.pi/agent/extensions/static-working.ts"
```

В уже запущенном Pi тоже нужен `/reload`. После обновления файлов в Git повтори копирование нужных расширений.
