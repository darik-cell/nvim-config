const TITLES = new Set(['Ответ готов', 'Дать разрешение']);

export function newestNotification(sources) {
    let newest = null;
    for (const source of sources) {
        const appId = source.app?.get_id();
        if (appId !== 'kitty.desktop' && !(appId == null && source.title?.toLowerCase() === 'kitty'))
            continue;

        for (const notification of source.notifications) {
            if (!TITLES.has(notification.title))
                continue;
            if (!newest || notification.datetime.compare(newest.datetime) >= 0)
                newest = notification;
        }
    }
    return newest;
}
