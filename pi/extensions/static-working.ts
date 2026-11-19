// static-working: hides the animated working-indicator spinner; the static "Working" message stays.
// Reapplied on session_start so it persists across /reload, /new, /resume, and restarts.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setWorkingIndicator({ frames: [] });
	});
}
