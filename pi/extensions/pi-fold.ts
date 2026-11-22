/**
 * pi-fold — fold turns, groups and tool boxes, and copy code, from the keyboard.
 *
 * Companion to pi-tidy in pi's regular TUI, made for a pi running inside a
 * Neovim terminal buffer (nvim's zo/zc mappings count markers in the buffer
 * and send the commands below). Works without nvim too — just type them.
 *
 *   /zturn T [open|close|toggle]   whole turn: ▸ summary ↔ ▾ rail + groups
 *   /zgroup T I [open|close|toggle]  the tool group that holds the I-th
 *                                    member of turn T: ▸ N calls ↔ ▾ + rows.
 *                                    Opening does NOT expand any member box.
 *   /zbox T I [open|close|toggle]    one tool box: the I-th member of turn T.
 *                                    Opening also opens its group (that is
 *                                    pi-tidy's row-click path); closing folds
 *                                    just that box back to its row, leaving
 *                                    the group and the turn open.
 *   /zbox N [o|c|t]                  absolute ordinal, all boxes this process
 *
 * All state changes go through pi-tidy's own semantic paths, never around
 * them: group and box open are synthetic clicks routed through the captured
 * components' patched handleMouse (exactly what a mouse click on the row
 * runs), box close replicates pi's own setExpanded(false) body so pi-tidy's
 * turn/group bookkeeping is untouched. Ordinals come from the same shared
 * pi-tidy turn store, projected onto the transcript Pi actually renders.
 *
 * Turn/box state is resolved through pi-tidy's own stores (the
 * Symbol.for("pi-toolbox:…") globals both packages share), with ordinals
 * counting visible summaries rather than /tidy's full branch. /zturn bumps the turn's version, which
 * pi-tidy's summary cache keys on — without it a reopened turn keeps drawing
 * its stale ▸ line.
 */
import { createHash } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { AssistantMessageComponent, ToolExecutionComponent, copyToClipboard } from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";

interface FoldClickable {
  render(width: number): string[];
  handleMouse?(event: TuiMouseEvent): unknown;
}

interface FoldBox extends FoldClickable {
  expanded: boolean;
  isPartial: boolean;
  toolName: string;
  toolCallId?: string;
  ui?: { terminal?: { columns: number }; requestRender?(): void };
  updateDisplay(): void;
}

interface AssistantLike extends FoldClickable {
  lastMessage?: unknown;
}

interface TidyMessage {
  role?: string;
  timestamp?: number;
  provider?: string;
  model?: string;
  stopReason?: unknown;
  content?: unknown;
}

interface TidyTurn {
  messages: Map<string, TidyMessage>;
  tools: Map<string, { name: string; args: unknown }>;
  firstAssistant?: string;
  open?: boolean;
  outcome?: string;
  /** Bumped on every mutation; pi-tidy's summary cache keys on it. */
  version?: number;
}

interface FoldRegistry {
  boxes: FoldBox[];
  /** Creation order of `boxes`, entry by entry (shared with the assistants). */
  boxSeqs: number[];
  byId: Map<string, FoldBox>;
  seen: WeakSet<object>;
  assistants: Array<{ comp: AssistantLike; seq: number }>;
  assistantSeen: WeakSet<object>;
  seq: number;
  captureInstalled: boolean;
  assistantCaptureInstalled: boolean;
}

const REGISTRY = Symbol.for("pi-fold:registry");
const TURN_STORE = "pi-toolbox:turn-store";
const TOOL_OPTIONS = "pi-toolbox:tool-frame-options";
/** pi-tidy's per-frame record of where a carrier message's rows landed. */
const CARRIER_CLICK = Symbol.for("pi-toolbox:carrier-click");
/** Outer turn decoration: carrier click maps are relative to its body. */
const TURN_LAYOUT = Symbol.for("pi-tidy:turn-layout");

/** ANSI CSI/OSC sequences, so a probe can read the text a box renders. */
const ANSI = /\x1b(?:\[[0-9;:?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)?)/g;
function foldWidth(box: FoldBox): number {
  const width = box.ui?.terminal?.columns || process.stdout.columns;
  return width > 0 ? width : 117;
}

function registry(): FoldRegistry {
  const g = globalThis as Record<symbol, Partial<FoldRegistry> | undefined>;
  const existing = g[REGISTRY];
  if (existing && Array.isArray(existing.boxes)) {
    // Migrate an older shape in place (a pi still running the previous
    // pi-fold keeps its registry across /reload); the surviving wrapper
    // closures hold this same object, so field additions reach them too.
    existing.boxSeqs ??= [];
    existing.byId ??= new Map();
    existing.seen ??= new WeakSet();
    existing.assistants ??= [];
    existing.assistantSeen ??= new WeakSet();
    existing.seq ??= 0;
    return existing as FoldRegistry;
  }
  const fresh: FoldRegistry = {
    boxes: [],
    boxSeqs: [],
    byId: new Map(),
    seen: new WeakSet(),
    assistants: [],
    assistantSeen: new WeakSet(),
    seq: 0,
    captureInstalled: false,
    assistantCaptureInstalled: false,
  };
  g[REGISTRY] = fresh;
  return fresh;
}

function installCapture(): boolean {
  const reg = registry();
  const proto = (ToolExecutionComponent as unknown as {
    prototype?: Record<string, unknown>;
  }).prototype;
  const update = proto?.updateDisplay as ((this: FoldBox, ...args: unknown[]) => unknown) | undefined;
  if (typeof update !== "function") return false;
  if (!reg.captureInstalled) {
    // The constructor ends with this.updateDisplay(), so every box registers
    // itself here in creation order. pi-tidy's prototype patches wrap the same
    // method independently; both call through. The flag is shared through the
    // global registry, so /reload re-wraps neither its own nor pi-tidy's patch.
    const seen = reg.seen;
    const boxes = reg.boxes;
    const boxSeqs = reg.boxSeqs;
    const byId = reg.byId;
    const wrapper = function (this: FoldBox, ...args: unknown[]): unknown {
      if (!seen.has(this)) {
        seen.add(this);
        reg.seq++;
        boxes.push(this);
        boxSeqs.push(reg.seq);
        if (this.toolCallId) byId.set(this.toolCallId, this);
      }
      return update.apply(this, args);
    };
    proto.updateDisplay = wrapper;
    reg.captureInstalled = true;
  }

  // Assistant message components in creation order too: a group's summary
  // line is drawn by its first member, unless a leading thinking-only step
  // (a "carrier") owns it — then only that component routes the header click.
  // Installed separately from the box capture: a /reload from a build without
  // it installs just this half.
  const assistantProto = (AssistantMessageComponent as unknown as {
    prototype?: Record<string, unknown>;
  }).prototype;
  const updateContent = assistantProto?.updateContent as ((this: AssistantLike, ...args: unknown[]) => unknown) | undefined;
  if (typeof updateContent === "function" && !reg.assistantCaptureInstalled) {
    const seenAssistant = function (this: AssistantLike, ...args: unknown[]): unknown {
      if (!reg.assistantSeen.has(this)) {
        reg.assistantSeen.add(this);
        reg.seq++;
        reg.assistants.push({ comp: this, seq: reg.seq });
      }
      return updateContent.apply(this, args);
    };
    assistantProto.updateContent = seenAssistant;
    reg.assistantCaptureInstalled = true;
  }
  return true;
}

function liveBox<T>(name: string): T | undefined {
  const g = globalThis as Record<symbol, unknown>;
  const slot = g[Symbol.for(name)];
  if (slot && typeof slot === "object" && "value" in (slot as Record<string, unknown>)) {
    return (slot as { value: T }).value;
  }
  return slot as T | undefined;
}

/** Mirror pi-tidy's messageKey for assistant entries (the summary owner). */
function assistantKey(message: TidyMessage | undefined): string | undefined {
  if (message?.role !== "assistant" || !Number.isFinite(message.timestamp)) return undefined;
  return `assistant:${message.timestamp}:${message.provider ?? ""}:${message.model ?? ""}`;
}

function tidyTurns(ctx: ExtensionContext): TidyTurn[] {
  const store = liveBox<{ byMessage?: Map<string, TidyTurn>; current?: TidyTurn }>(TURN_STORE);
  const byMessage = store?.byMessage;
  if (!(byMessage instanceof Map)) return [];

  // Pi replays buildContextEntries(), but pi-tidy restores its store from
  // getBranch(). After compaction a turn can be absent entirely, or retained
  // only from the middle: neither case draws the first assistant's summary.
  const turns: TidyTurn[] = [];
  const seen = new Set<TidyTurn>();
  for (const entry of ctx.sessionManager.buildContextEntries()) {
    if (entry.type !== "message") continue;
    const key = assistantKey(entry.message);
    if (!key) continue;
    const turn = byMessage.get(key);
    if (turn?.firstAssistant === key && !seen.has(turn) && hasProcess(turn)) {
      turns.push(turn);
      seen.add(turn);
    }
  }
  // A streaming first assistant draws before message_end persists it. Only
  // append it if it's not an existing (possibly compacted-away) branch entry.
  const current = store?.current;
  if (current?.firstAssistant && !seen.has(current) && hasProcess(current) &&
      !ctx.sessionManager.getBranch().some((entry) =>
        entry.type === "message" && assistantKey(entry.message) === current.firstAssistant)) {
    turns.push(current);
  }
  return turns;
}

function hasProcess(turn: TidyTurn): boolean {
  if (turn.outcome === "error" || turn.outcome === "interrupted" || turn.outcome === "incomplete") return true;
  if (turn.tools.size > 0) return true;
  let texts = 0;
  for (const message of turn.messages.values()) {
    if (message.role !== "assistant") continue;
    if (message.stopReason === "error" || message.stopReason === "aborted" || message.stopReason === "length") return true;
    if (blocks(message).some((block) => block.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim())) return true;
    if (blocks(message).some((block) => block.type === "text" && typeof block.text === "string" && block.text.trim()) && ++texts > 1) return true;
  }
  return false;
}

interface MessageBlock {
  type?: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
}

function blocks(message: TidyMessage | undefined): MessageBlock[] {
  return Array.isArray(message?.content) ? (message.content as MessageBlock[]) : [];
}

/** pi-tidy's alwaysShowTools: those calls never join a group. */
function pinnedNames(): Set<string> {
  const options = liveBox<{ alwaysShow?: Set<string> }>(TOOL_OPTIONS);
  return options?.alwaysShow instanceof Set ? options.alwaysShow : new Set(["edit", "write"]);
}

/** pi-tidy's classifyAssistant: which assistant steps cut a tool group. */
function classifyAssistant(message: TidyMessage): "boundary" | "carrier" | "plain" {
  if (!message) return "plain";
  const content = message.content;
  if (!Array.isArray(content)) return "boundary";
  let hasToolCall = false;
  for (const block of blocks(message)) {
    if (block?.type === "text" && typeof block.text === "string" && block.text.trim()) return "boundary";
    if (block?.type === "toolCall") hasToolCall = true;
  }
  if (hasToolCall && message.stopReason !== "length") return "carrier";
  return "plain";
}

function thinkingRunCount(message: TidyMessage): number {
  return blocks(message).filter((block) => block.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim()).length;
}

interface TidyGroup {
  /** Tool call ids that render as this group's rows, in order. */
  ids: string[];
  /** The thinking-only step whose summary line can own this group's header. */
  carrierMessage?: TidyMessage;
}

/**
 * The groups of one turn, rebuilt the way pi-tidy cuts them at render time:
 * a step with visible text is a boundary, a pinned (always-shown) call is a
 * boundary, everything else between boundaries is one group.
 */
function groupsOfTurn(turn: TidyTurn): TidyGroup[] {
  const pinned = pinnedNames();
  const groups: TidyGroup[] = [];
  let current: TidyGroup = { ids: [] };
  const cut = () => {
    if (current.ids.length > 0 || current.carrierMessage) groups.push(current);
    current = { ids: [] };
  };
  for (const message of turn.messages.values()) {
    if (message.role !== "assistant") continue;
    const role = classifyAssistant(message);
    if (role === "boundary") cut();
    else if (
      role === "carrier" &&
      current.ids.length === 0 &&
      current.carrierMessage === undefined &&
      thinkingRunCount(message) > 0
    ) {
      // pi-tidy's carrierPlan hands the header to the first thinking step
      // that joins a group before any call does.
      current.carrierMessage = message;
    }
    for (const block of blocks(message)) {
      if (block?.type !== "toolCall" || typeof block.id !== "string") continue;
      const name = block.name ?? turn.tools.get(block.id)?.name ?? "";
      if (pinned.has(name)) cut(); // always-shown: its own box, and a boundary
      else current.ids.push(block.id);
    }
  }
  if (current.ids.length > 0 || current.carrierMessage) groups.push(current);
  return groups;
}

/** The I-th (1-based) group member of a turn, across all its groups. */
function memberOf(turn: TidyTurn, ordinal: number): { id?: string; group?: TidyGroup; index: number } {
  let seen = 0;
  for (const group of groupsOfTurn(turn)) {
    if (ordinal <= seen + group.ids.length) {
      return { id: group.ids[ordinal - seen - 1], group, index: ordinal };
    }
    seen += group.ids.length;
  }
  return { index: ordinal };
}

function boxOf(reg: FoldRegistry, turn: TidyTurn | undefined, ordinal: number): FoldBox | undefined {
  if (!turn) return undefined;
  const { id } = memberOf(turn, ordinal);
  return id !== undefined ? reg.byId.get(id) : undefined;
}

function parseDir(raw: string | undefined): "open" | "close" | "toggle" {
  const d = (raw ?? "toggle").toLowerCase();
  return d.startsWith("o") ? "open" : d.startsWith("c") ? "close" : "toggle";
}

function applyTurn(turn: TidyTurn, dir: "open" | "close" | "toggle"): boolean {
  const target = dir === "toggle" ? turn.open === undefined ? true : !turn.open : dir === "open";
  turn.open = target;
  // Bust pi-tidy's summary cache, which keys on turn.version.
  turn.version = (turn.version ?? 0) + 1;
  return target;
}

/**
 * What the first member currently draws as its first row: the group's `▸`
 * summary (closed), its `▾` summary (open), or neither (open with a carrier
 * step owning the header, or the row hidden inside a folded turn).
 *
 * Probe at the live width so the marker and the click share a layout.
 */
function headerMarkerOf(box: FoldBox, width: number): "closed" | "open" | null {
  if (box.isPartial) return null;
  let rows: string[];
  try {
    rows = box.render(width) ?? [];
  } catch {
    return null;
  }
  const first = (rows[0] ?? "").replace(ANSI, "").replace(/^[│\s]+/, "");
  if (first.startsWith("▸") || first.startsWith("▶")) return "closed";
  if (first.startsWith("▾")) return "open";
  return null;
}

/** A left click at the component's own row `y`, routed the way a real one is. */
function click(component: FoldClickable, y: number, width: number): void {
  if (!component.handleMouse) return;
  const height = component.render(width).length;
  if (y < 0 || y >= height) return;
  // Pi TUI 1.6 routes through cached child layouts keyed by event.width.
  // A partial event with no bounds can select an undefined layout.
  component.handleMouse({
    type: "click", button: "left", x: 0, y, screenX: 0, screenY: y,
    width, height, shift: false, alt: false, ctrl: false, clickCount: 1,
  });
}

/** pi's own setExpanded body, without pi-tidy's turn/group side effects. */
function foldBoxToRow(box: FoldBox): void {
  box.expanded = false;
  box.updateDisplay();
}

/** The carrier step that draws this group's header, if any component for it
 * rendered one (pi-tidy records the row in a per-frame map on the component). */
function carrierHeaderComponent(reg: FoldRegistry, first: FoldBox): { comp: AssistantLike; row: number } | undefined {
  const boxIndex = reg.boxes.indexOf(first);
  const firstSeq = boxIndex >= 0 ? reg.boxSeqs[boxIndex] : undefined;
  let found: { comp: AssistantLike; row: number } | undefined;
  for (const entry of reg.assistants) {
    if (firstSeq !== undefined && entry.seq > firstSeq) break;
    const map = (entry.comp as Record<symbol, { header: number | null } | null | undefined>)[CARRIER_CLICK];
    if (map && typeof map.header === "number") {
      // A turn's FIRST assistant can own both the turn summary and the
      // group's thinking/header rows. The latter's map starts at body row 0,
      // but handleMouse receives OUTER component coordinates: clicking raw
      // row 0 would fold the whole turn and destroy nvim's group anchor.
      const layout = (entry.comp as Record<symbol, { bodyTop?: number } | undefined>)[TURN_LAYOUT];
      found = { comp: entry.comp, row: map.header + (layout?.bodyTop ?? 0) };
    }
  }
  return found;
}

/** Silent render kick: the first box's TUI handle. notify() would print to the
 * terminal — the user asked for silent folds — and mutations alone (turn.open,
 * setExpanded from outside pi's own paths) do not schedule a render. */
function requestRender(reg: FoldRegistry): void {
  const ui = (reg.boxes[0] as { ui?: { requestRender?: () => void } } | undefined)?.ui;
  ui?.requestRender?.();
}

const TURN_CACHE = Symbol.for("pi-tidy:turn-cache");
const CODE_BLOCKS = Symbol.for("pi-tidy:code-blocks");
const COPY_REQUEST = /^\x1bP\+pi-fold-copy;(code|reply);(\d{1,6});([0-9a-f]{64})\x1b\\$/;

type CodeLayout = { bodyTop: number; spans?: Array<{ row: number; index: number }> };

function codeClosingRule(row: string): boolean {
  return /^─+$/.test(row.trim().replace(/^(?:[├│>]\s*){0,3}/, "").replace(/\s*[┤│]$/, ""));
}

function replyBodyBounds(cache: { out: string[]; framed: boolean; layout: CodeLayout }): { start: number; end: number } | undefined {
  if (!cache.framed) return undefined;
  const end = cache.out.length - 1;
  const bottom = cache.out[end]?.replace(ANSI, "").trim();
  if (!bottom || !/^(?:╰─+╯|╰?─+)$/.test(bottom)) return undefined;
  let { bodyTop: start } = cache.layout;
  // Since pi-tidy 0.11 the frame's vertical padding is outside `bodyTop`.
  // Neovim counts all rows between the outer borders, including the padding.
  while (start > 0 && /^│ *│$/.test(cache.out[start - 1]!.replace(ANSI, ""))) start--;
  return { start, end };
}

function frameFingerprint(out: string[], start: number, count: number, lang: string): string {
  const body = out.slice(start, start + count).map((line) => line.replace(ANSI, "").replace(/ +$/, ""));
  return createHash("sha256").update(`${lang}\n${body.join("\n")}`).digest("hex");
}

/** Read text from Pi rather than inferring source line breaks from a TUI render.
 * If two frames look identical but have different source, do not guess. */
function visibleFrameText(reg: FoldRegistry, kind: string, count: number, fingerprint: string): string | undefined {
  let found: string | undefined;
  for (const { comp } of reg.assistants) {
    const symbols = comp as Record<symbol, unknown>;
    const cache = symbols[TURN_CACHE] as { out: string[]; framed: boolean; layout: CodeLayout } | undefined;
    if (!cache || cache.layout !== symbols[TURN_LAYOUT]) continue;
    const { bodyTop, spans } = cache.layout;
    if (kind === "reply") {
      const bounds = replyBodyBounds(cache);
      if (!bounds || bounds.end - bounds.start !== count) continue;
      if (frameFingerprint(cache.out, bounds.start, count, "") !== fingerprint) continue;
      const parts = blocks(comp.lastMessage as TidyMessage | undefined)
        .flatMap((part) => part.type === "text" && part.text?.trim() ? [part.text] : []);
      if (!parts.length) continue;
      const text = parts.join("\n\n");
      if (found !== undefined && found !== text) return undefined;
      found = text;
      continue;
    }
    const code = symbols[CODE_BLOCKS] as { blocks: Array<{ lang: string; text: string }> } | undefined;
    for (const { row, index } of spans ?? []) {
      const block = code?.blocks[index];
      const start = bodyTop + row + 1;
      const close = cache.out[start + count]?.replace(ANSI, "");
      if (!block || !close || !codeClosingRule(close)) continue;
      if (frameFingerprint(cache.out, start, count, block.lang) !== fingerprint) continue;
      if (found !== undefined && found !== block.text) return undefined;
      found = block.text;
    }
  }
  return found;
}

export default function piFold(pi: ExtensionAPI): void {
  if (!installCapture()) {
    // Still consume mapped commands if this Pi build lacks the hooks.
    for (const name of ["zturn", "zgroup", "zbox"]) {
      pi.registerCommand(name, { description: "pi-fold unavailable in this Pi build", handler: async () => {} });
    }
    return;
  }

  let stopCopyInput: (() => void) | undefined;
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui" || !process.env.NVIM) return;
    stopCopyInput = ctx.ui.onTerminalInput((data) => {
      const request = COPY_REQUEST.exec(data);
      if (!request) return;
      const text = visibleFrameText(registry(), request[1]!, Number(request[2]), request[3]!);
      if (text === undefined) ctx.ui.notify("pi-fold: frame no longer matches the transcript", "warning");
      else void copyToClipboard(text).catch(() => ctx.ui.notify("pi-fold: clipboard unavailable", "warning"));
      return { consume: true };
    });
  });
  pi.on("session_shutdown", () => {
    stopCopyInput?.();
    stopCopyInput = undefined;
  });

  // These commands are driven by terminal mappings. A stale or missing
  // target is a quiet no-op, not a transcript entry or a provider prompt.

  pi.registerCommand("zturn", {
    description: "Fold a whole turn by 1-based ordinal: /zturn T [open|close|toggle]",
    handler: async (args, ctx) => {
      const [ordinal, dir] = args.trim().split(/\s+/);
      const turn = tidyTurns(ctx)[Number(ordinal) - 1];
      if (!turn) return;
      applyTurn(turn, parseDir(dir));
      requestRender(registry());
    },
  });

  pi.registerCommand("zgroup", {
    description: "Fold a tool group: /zgroup T I [open|close|toggle] — the group holding member I of turn T",
    handler: async (args, ctx) => {
      const reg = registry();
      const parts = args.trim().split(/\s+/).filter(Boolean);
      const t = Number(parts[0]);
      const i = Number(parts[1]);
      const turn = tidyTurns(ctx)[t - 1];
      if (!turn || !Number.isInteger(i) || i < 1) return;
      const { group } = memberOf(turn, i);
      const firstId = group?.ids[0];
      const first = firstId !== undefined ? reg.byId.get(firstId) : undefined;
      if (!first) return;

      const dir = parseDir(parts[2]);
      const width = foldWidth(first);
      const marker = headerMarkerOf(first, width);
      if (marker === "closed") {
        // The first member carries the ▸ line at its own row 0; pi-tidy's
        // click routing opens the group and touches no member box.
        if (dir !== "close") click(first, 0, width);
      } else if (marker === "open") {
        if (dir !== "open") click(first, 0, width);
      } else {
        // No summary on the first member: either a carrier step owns the
        // header (group is open) or the row is hidden (turn folded).
        const carrier = carrierHeaderComponent(reg, first);
        if (!carrier) return;
        if (dir !== "open") {
          // Fold the members ourselves first: pi-tidy's carrier path folds
          // expanded members outside its pointer guard, which would take the
          // whole turn down with them.
          for (const id of group?.ids ?? []) {
            const member = reg.byId.get(id);
            if (member?.expanded) foldBoxToRow(member);
          }
          click(carrier.comp, carrier.row, width);
        }
      }
      requestRender(reg);
    },
  });

  pi.registerCommand("zbox", {
    description: "Fold one tool box: /zbox T I [open|close|toggle] (I-th member of turn T) or /zbox N [dir] (absolute)",
    handler: async (args, ctx) => {
      const reg = registry();
      const parts = args.trim().split(/\s+/).filter(Boolean);
      let box: FoldBox | undefined;
      let turn: TidyTurn | undefined;
      let memberIndex: number | undefined;

      if (parts.length >= 2 && /^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
        const t = Number(parts[0]);
        const i = Number(parts[1]);
        turn = tidyTurns(ctx)[t - 1];
        box = boxOf(reg, turn, i);
        memberIndex = i;
      } else {
        box = reg.boxes[Number(parts[0]) - 1];
      }
      if (!box) return;

      const word = (parts[2] ?? parts[1] ?? "t").toLowerCase();
      const dir: "open" | "close" | "toggle" = word.startsWith("o") ? "open" : word.startsWith("c") ? "close" : "toggle";
      const want = dir === "toggle" ? !box.expanded : dir === "open";

      if (!want) {
        // Fold this one box back to its row. Deliberately NOT setExpanded():
        // outside pi's pointer paths that is ctrl+o's collapse-all, which
        // also folds the group and the whole turn.
        foldBoxToRow(box);
      } else if (pinnedNames().has(box.toolName)) {
        // Always-shown boxes are not group members; no row to click.
        box.expanded = true;
        box.updateDisplay();
      } else {
        // The row click is pi-tidy's own "open this box" path: it opens the
        // group on the way, exactly like clicking the row under the header.
        const width = foldWidth(box);
        click(box, headerMarkerOf(box, width) ? 1 : 0, width);
        if (!box.expanded && memberIndex !== undefined && turn) {
          // The row was not on screen (group folded): open the group, retry.
          const { group } = memberOf(turn, memberIndex);
          const firstId = group?.ids[0];
          const first = firstId !== undefined ? reg.byId.get(firstId) : undefined;
          if (first && headerMarkerOf(first, width) === "closed") {
            click(first, 0, width);
            click(box, headerMarkerOf(box, width) ? 1 : 0, width);
          }
        }
        if (!box.expanded) return;
      }
      requestRender(reg);
    },
  });
}
