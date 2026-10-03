# Инструкция агенту: чистая установка на Ubuntu 24.04

Цель — не переносить старые runtime/cache, а заново скачать программы и
подключить пользовательские конфиги из этого Git-репозитория.

## Важное допущение

Пользователь разрешил чистую переустановку Nvim и Kitty на целевом host.
`install.sh` удалит только показанные им user-пути: конфиги Nvim/Kitty,
Nvim data/state/cache, user-local Kitty, установленные этим скриптом binaries,
шрифт и mdview venv. Проекты, весь `$HOME`, SSH/Git credentials, shell files,
`.gitconfig`, системные пакеты и `.ideavimrc` не удаляются.

## 1. Сначала проверь host

Ничего не меняя, выполни и покажи пользователю краткое резюме:

```bash
cat /etc/os-release
uname -m
id
printf 'HOME=%s\n' "$HOME"
command -v nvim && nvim --version | head -n 1 || true
command -v kitty && kitty --version || true
git -C ~/configs status --short --branch 2>/dev/null || true
```

Продолжать можно только для Ubuntu 24.04, архитектуры `x86_64` или `aarch64`,
от обычного desktop user. Не запускай install/verify через `sudo`.

Если `~/configs` уже существует и это не чистый checkout данного репозитория,
не удаляй и не перезаписывай его: сообщи конфликт пользователю.

## 2. Получи репозиторий

Если каталога нет:

```bash
git clone https://github.com/darik-cell/configs.git ~/configs
```

Если это уже чистый checkout на `main`, разрешён только обычный fast-forward:

```bash
git -C ~/configs pull --ff-only
```

Перед установкой обязательно проверь:

```bash
git -C ~/configs branch --show-current
git -C ~/configs status --porcelain=v1 --untracked-files=all
```

Ожидаются `main` и пустой status.

## 3. Проверь зависимости без удаления файлов

```bash
cd ~/configs
./install.sh --check
```

`--check` только показывает список будущих удалений и проверяет зависимости.
Он ничего не скачивает и не удаляет. Если скрипт завершился с кодом `20`, он
напечатает точную `sudo apt-get ...` команду.

Агент не должен самовольно расширять эту команду, выполнять `apt upgrade` или
удалять пакеты. Покажи команду пользователю. Выполни её только если пользователь
явно разрешил sudo-действие в этой сессии; иначе попроси пользователя выполнить
команду самостоятельно и прислать полный лог. Затем снова запусти
`./install.sh --check`.

## 4. Выполни чистую установку

После успешной строки `CHECK_OK` запусти реальную установку:

```bash
cd ~/configs
./install.sh --yes
```

Без `--yes` скрипт потребует вручную ввести `DELETE`. Режим `--yes` используй
только после того, как пользователь увидел список из `--check`.

Скрипт:

- скачивает официальные Nvim 0.12.4, Kitty 0.48.2, tree-sitter CLI 0.26.6 и
  FiraCode Nerd Font 3.4.0 для архитектуры host;
- проверяет SHA-256 каждого архива;
- удаляет только заранее напечатанные Nvim/Kitty user-пути;
- устанавливает binaries в `~/.local`, не меняя системные версии;
- делает symlink `~/.config/nvim` и `~/.config/kitty` на `~/configs`;
- создаёт отдельный Python venv для `mdview`;
- заново скачивает Lazy plugins по `lazy-lock.json`, Mason LSP и Tree-sitter
  parsers;
- в конце автоматически запускает `verify.sh`.

Не копируй со старого host `~/.local/share/nvim`, `~/.cache/nvim`,
`~/.local/kitty.app`, Mason, parsers, plugin directories, Python venv или
скачанные архивы: всё это восстанавливается из сети.

## 5. Финальная независимая проверка

После успешной установки открой новый login shell, затем:

```bash
cd ~/configs
./verify.sh
```

Успех заканчивается строкой `VERIFY_OK`. Дополнительно в графической сессии
открой Kitty и Nvim, проверь шрифт, затем в Markdown-файле команды `<leader>m`
(`mdview`) и `<leader>M` (`live-preview.nvim`). Headless verify не открывает
окна и браузер.

`verify.sh` отдельно запускает настоящий login shell и требует, чтобы команды
`nvim`, `kitty`, `tree-sitter` и `mdview` разрешались в `~/.local/bin`. Если
PATH-проверка не прошла, сначала
определи текущий `$SHELL` и его реальный startup-файл. Не заменяя файл целиком,
добавь одну строку `export PATH="$HOME/.local/bin:$PATH"`, открой новый login
shell и повтори `./verify.sh`.

В итоговом отчёте укажи версии Nvim/Kitty/tree-sitter, commit репозитория,
результат `VERIFY_OK`, выполненную apt-команду (или что она не понадобилась) и
любые ошибки. Не включай значения credentials или полный environment.

`.ideavimrc` только хранится в repo. Подключай его отдельно лишь по явной
просьбе пользователя:

```bash
ln -s ~/configs/.ideavimrc ~/.ideavimrc
```

## 6. Уведомления и переход к терминалу агента

Это отдельный набор внутри конфигурации Neovim. Его обработчик и отметки вкладок
уже подключены в `init.lua` и `tabline.lua`. Для интеграции с Codex перенеси
настройки из `.config/nvim/integrations/codex/notifications.toml` в существующую
секцию `[tui]` на целевом host, сохранив остальные настройки Codex.

Глобальный Super+N реализован расширением GNOME Shell 46, исходники которого
лежат в `.config/nvim/integrations/gnome/notification-jump@a.alenushka/`.
Копирование, включение после следующего входа, ограничения и отдельные проверки
описаны в [гайде уведомлений](.config/nvim/docs/notifications.md).

Не запускай чистую переустановку из этой инструкции лишь ради уведомлений.
Для действующего Neovim гайд содержит обновление двух модулей без остановки
терминалов. Личные сессии и полный конфиг Codex остаются локальными и не копируются
в репозиторий.
