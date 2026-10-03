(() => {
  "use strict";
  let socket;
  let reconnect;
  let leaving = false;
  let connectedOnce = false;
  const currentPath = () => decodeURIComponent(window.location.pathname);

  const connect = () => {
    leaving = false;
    clearTimeout(reconnect);
    const connection = new WebSocket(`ws://${window.location.host}`);
    socket = connection;
    connection.onopen = () => {
      if (connectedOnce) window.location.reload();
      connectedOnce = true;
    };
    connection.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.type === "reload") {
        window.location.reload();
        return;
      }
      if (message.filepath !== currentPath()) {
        return;
      }
      if (message.type === "update" && typeof livepreview_render !== "undefined") {
        livepreview_render(message.content);
        if (typeof livepreview_renderKatex !== "undefined") livepreview_renderKatex();
        if (typeof livepreview_renderMermaid !== "undefined") livepreview_renderMermaid();
      } else if (message.type === "scroll") {
        const elements = [...document.querySelectorAll("[data-source-line]")];
        const line = elements.reduce((best, element) =>
          !best || Math.abs(Number(element.dataset.sourceLine) - message.cursor[0])
            < Math.abs(Number(best.dataset.sourceLine) - message.cursor[0]) ? element : best, null);
        line?.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    };
    connection.onclose = () => {
      if (!leaving && socket === connection) reconnect = setTimeout(connect, 1000);
    };
  };

  window.addEventListener("pagehide", () => {
    leaving = true;
    clearTimeout(reconnect);
    socket?.close();
  });
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) connect();
  });
  connect();
})();
