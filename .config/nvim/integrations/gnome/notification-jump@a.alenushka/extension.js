import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {newestNotification} from './selection.js';

const BINDING = 'focus-active-notification';
const MODES = Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW;

export default class NotificationJump extends Extension {
    enable() {
        Main.wm.setCustomKeybindingHandler(BINDING, MODES, () => {
            const notification = newestNotification(Main.messageTray.getSources());
            if (!notification) {
                Main.messageTray._expandActiveNotification();
                return;
            }

            Main.overview.hide();
            Main.panel.closeCalendar();
            // Use the default notification action, exactly as a pointer click does.
            // Kitty focuses its window and reports the target Neovim tab via OSC 99.
            notification.activate();
        });
    }

    disable() {
        Main.wm.setCustomKeybindingHandler(BINDING, MODES,
            Main.messageTray._expandActiveNotification.bind(Main.messageTray));
    }
}
