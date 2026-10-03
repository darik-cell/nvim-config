# Notification Jump

On GNOME 46, Super+N invokes the default action of the newest retained Kitty
notification titled `Ответ готов` or `Дать разрешение`. Kitty then focuses the
correct window and Neovim opens the corresponding agent terminal.

Repeated presses open the remaining matching notifications, newest first.
Other applications and other Kitty notifications are ignored. With no matching
notification, the original GNOME banner-focus action is retained.

The extension uses the existing `focus-active-notification` binding, currently
Super+N. A newly installed local extension is discovered at the next login.
GNOME retains at most three notifications per source; older Neovim tab marks
remain visible, but those discarded notifications cannot be activated here.

Disable with:

```sh
gnome-extensions disable notification-jump@a.alenushka
```
