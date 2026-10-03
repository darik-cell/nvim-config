# Уведомления и переход к терминалу агента

Весь набор хранится рядом с конфигурацией Neovim: обработчик событий,
отметки вкладок, настройки Codex и расширение GNOME для глобального Super+N.
Расширение в этом репозитории — исходная копия; установленная копия в
`~/.local/share/gnome-shell/extensions/` обновляется из неё.

## Поведение

Терминал агента открывается через `<leader>ga`. У каждой вкладки Neovim
свой терминал и своя отметка, даже если несколько вкладок имеют одинаковый cwd.

| Событие | Отметка вкладки | Текст системного уведомления |
| --- | --- | --- |
| Готов ответ | Зелёная `✓` | `Ответ готов` |
| Нужно разрешение или показан отдельный запрос с вопросом | Жёлтый `?` | `Дать разрешение` |

Уведомление не содержит названия Codex, текста ответа, вопроса или команды.
Нажатие на него возвращает в нужное окно Kitty, вкладку Neovim и её терминал.
При переходе в терминал или вводе в нём отметка снимается. Закрытие вкладки,
терминала или Neovim также убирает относящиеся к ним уведомления.

Опциональное расширение GNOME позволяет делать тот же переход по Super+N
из любого приложения. Выбирается самое свежее сохранённое уведомление;
повторные нажатия открывают оставшиеся. При отсутствии подходящих уведомлений
сохраняется стандартное действие GNOME — фокус на текущем баннере.

## Файлы и границы интеграции

| Файл | Назначение |
| --- | --- |
| [attention.lua](../lua/config/attention.lua) | Приём OSC 9, состояние вкладок, уведомления OSC 99 и переход по клику |
| [tabline.lua](../lua/config/tabline.lua) | Отметки `✓` и `?` |
| [init.lua](../init.lua) | Подключение обработчика |
| [notifications.toml](../integrations/codex/notifications.toml) | Переносимый фрагмент настроек Codex |
| [notification-jump](../integrations/gnome/notification-jump@a.alenushka/README.md) | Расширение GNOME для глобального Super+N |
| [test_attention.lua](../../../tests/test_attention.lua) | Регрессионная проверка настоящего вывода OSC 9 из терминалов |

Проверенный комплект: Neovim 0.12.5, Kitty 0.49.1, Codex CLI 0.160.0;
расширение поддерживает GNOME Shell 46. Другие версии требуют проверки API.

Codex отправляет OSC 9 во встроенный терминал Neovim. Обработчик `TermRequest`
сопоставляет буфер с его вкладкой через `workspace.state_by_tab`, ставит отметку
и отправляет в Kitty новое уведомление OSC 99 с коротким текстом.
При клике Kitty возвращает идентификатор через `TermResponse`; Neovim проверяет
PID и вкладку и открывает её терминал. Настройка remote control Kitty не нужна.

Обрабатываются только буферы терминала агента с меткой
`nvim_alt_agent_terminal`, принадлежащие вкладкам workspace.
Вне Kitty предусмотрен fallback через `notify-send`; переход по клику через
OSC 99 относится к варианту с Kitty.

## Настройки Codex

Перенеси три строки из [notifications.toml](../integrations/codex/notifications.toml)
в существующую секцию `[tui]` файла `~/.codex/config.toml`. Если секции нет,
добавь её вместе с этими строками. Не создавай вторую секцию `[tui]` и не заменяй
полный конфиг фрагментом: в нём могут быть другие настройки и подключения.

`notification_condition = "always"` нужен, потому что переключение между
вкладками Neovim не равно потере фокуса окна Kitty. Настройки начинают действовать
после перезапуска самого Codex; диалог можно продолжить через `codex resume`.

## Установка Super+N на GNOME 46

Эти действия выполняются отдельно от чистой переустановки Nvim/Kitty.
Из корня репозитория скопируй расширение:

```bash
notification_extension_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/notification-jump@a.alenushka"
mkdir -p "$notification_extension_dir"
cp .config/nvim/integrations/gnome/notification-jump@a.alenushka/{extension.js,selection.js,metadata.json,README.md} "$notification_extension_dir/"
```

Новое локальное расширение GNOME 46 обнаружит после следующего выхода и входа
в систему. Затем включи его и проверь сочетание:

```bash
gnome-extensions enable notification-jump@a.alenushka
gsettings get org.gnome.shell.keybindings focus-active-notification
```

Расширение использует существующее действие `focus-active-notification`.
На исходном host оно назначено на `['<Super>n']`. Если на новом host назначение
другое, для Super+N установи:

```bash
gsettings set org.gnome.shell.keybindings focus-active-notification "['<Super>n']"
```

Чтобы отключить расширение и вернуть стандартное действие GNOME:

```bash
gnome-extensions disable notification-jump@a.alenushka
```

Расширение выбирает только уведомления Kitty с точными заголовками
`Ответ готов` и `Дать разрешение`. Другие приложения и уведомления не затрагиваются.
GNOME хранит максимум три уведомления от одного источника. Поэтому Super+N
перебирает сохранённые уведомления, а отметки остальных вкладок Neovim остаются.
После обновления файлов расширения скопируй их снова; работающий GNOME Shell
загрузит обновлённый JavaScript при следующем входе в систему.

## Обновление Neovim без потери вкладок

После изменения обработчика или строки вкладок выполни в открытом Neovim:

```vim
:lua package.loaded['config.attention'] = nil; package.loaded['config.tabline'] = nil; require('config.attention').setup(); require('config.tabline').setup(); vim.cmd.redrawtabline()
```

Это обновляет только два модуля. Не выгружай `config.workspace` и
`config.terminals`: там находится состояние текущих вкладок и терминалов.
Полный повторный `source init.lua` для такого обновления не требуется.

## Снимок вкладок перед настоящим перезапуском

Встроенная сессия сохраняет вкладки, файлы, рабочие папки и расположение окон.
Она не сохраняет работающие процессы, историю терминалов и Lua-таблицу
`workspace.state_by_tab`. Терминалы после перезапуска открываются заново.

Снимок сохраняется локально в state-каталог Neovim:

```vim
:call mkdir(stdpath('state') . '/sessions', 'p')
:let g:nvim_session_saved_options = &sessionoptions
:set sessionoptions-=terminal
:execute 'mksession! ' . fnameescape(stdpath('state') . '/sessions/workspace.vim')
:let &sessionoptions = g:nvim_session_saved_options
:unlet g:nvim_session_saved_options
```

Исключение `terminal` предотвращает повторный запуск сохранённых терминальных
команд при восстановлении. Для стандартного пути state-каталога:

```bash
nvim -S ~/.local/state/nvim/sessions/workspace.vim
```

Личные снимки сессий и полный конфиг Codex не являются частью переносимого набора.

## Проверки и диагностика

Из корня репозитория:

```bash
nvim --headless -u NONE -l tests/test_attention.lua
```

Проверка использует настоящие терминальные буферы и OSC 9 с BEL/ST,
обычные тексты готовых ответов, пять видов запросов, независимые вкладки,
приватность уведомлений и снятие отметок. Она не нажимает системные уведомления
и не проверяет глобальное сочетание GNOME. Клик и Super+N проверяются отдельно
в графической сессии.

Codex передаёт в уведомлении о завершении начало ответа. Фраза
`Agent turn complete` используется только для пустого ответа, поэтому нельзя
распознавать готовность исключительно по ней. Текущий обработчик относит к
запросам пять префиксов: `Approval requested: `, `Codex wants to edit `,
`Approval requested by `, `Plan mode prompt: ` и `Question: `; остальные
сообщения считаются готовым ответом.

OSC 9 не содержит типа события. Ответ, который сам начинается с одного из этих
префиксов, остаётся неоднозначным; при изменении форматов Codex сначала обнови
регрессионные случаи. Обычный вопрос в тексте ответа не равен отдельному запросу
ввода Codex.

Если уведомлений нет, проверь настройки `[tui]`, запуск через `<leader>ga`
и подключение `config.attention` в `init.lua`. Если Super+N только фокусирует
баннер, проверь статус расширения после входа:

```bash
gnome-extensions info notification-jump@a.alenushka
```
