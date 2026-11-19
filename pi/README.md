# Расширения Pi

Этот каталог устанавливается отдельно. `install.sh` в корне репозитория не устанавливает Pi и не копирует эти расширения. Для их переноса не нужно переустанавливать Neovim или Kitty.

## pi-fold — сворачивание в Neovim

Нужны Pi в обычном TUI, `pi-tidy` с включёнными группами и сводками ходов (`groupTools: true`, `collapseTurns: "afterRun"`) и Neovim. Версии на исходном хосте: Pi 1.5.2, pi-tidy 0.10.0, Neovim 0.12.6.

Из корня репозитория, если `pi-tidy` ещё не установлен:

```sh
pi install npm:pi-tidy@0.10.0
```

Скопируй расширение. Если одноимённый файл уже есть, сначала сравни его: команда заменит его копией из Git.

```sh
install -Dm644 pi/extensions/pi-fold.ts "$HOME/.pi/agent/extensions/pi-fold.ts"
```

Часть Neovim лежит отдельно: [`pi-fold.lua`](../.config/nvim/lua/pi-fold.lua) и [`pi-fold-frame.lua`](../.config/nvim/lua/pi-fold-frame.lua). В конфиге из этого репозитория подключение уже есть в [`init.lua`](../.config/nvim/init.lua). Для другого конфига положи оба файла рядом в `lua/` и добавь `require("pi-fold").setup()`.

В уже запущенном Pi выполни `/reload`. В terminal-NORMAL, с пустой строкой ввода Pi, проверь `zo`/`zc` на сводке хода или группы инструментов.

## static-working — опционально

Отключает анимацию спиннера, оставляя надпись `Working`. От Neovim и `pi-fold` не зависит.

```sh
install -Dm644 pi/extensions/static-working.ts "$HOME/.pi/agent/extensions/static-working.ts"
```

В уже запущенном Pi тоже нужен `/reload`. После обновления файлов в Git повтори копирование нужных расширений.
