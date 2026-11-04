import { displayText, hexString, type TextEncodingChoice } from "../core/codec";

export type Direction = "rx" | "tx" | "sys";
export type ViewMode = "text" | "hex";

export interface LogEntry {
  direction: Direction;
  time: number;
  bytes: Uint8Array;
  note: string;
  error: boolean;
  /** 校验字节的起点和终点。校验值多半不是可显示的文字，文本视图里要单独写出来。 */
  trailer: [number, number] | null;
}

const EMPTY = new Uint8Array();

export const rowEntry = (direction: Direction, bytes: Uint8Array, trailer: [number, number] | null = null, time = Date.now()): LogEntry => ({
  direction, time, bytes, note: "", error: false, trailer,
});

export const noteEntry = (note: string, error = false): LogEntry => ({ direction: "sys", time: Date.now(), bytes: EMPTY, note, error, trailer: null });

const MAX_STORED = 200_000;
const TRIM_STORED = 20_000;
const MAX_SHOWN = 20_000;
const CHUNK = 256;
/** 单次刷新最多追加的行数，超出的部分仍会保存，只是不逐行显示。 */
const MAX_PER_FLUSH = 500;
/** “略过”的提示合并起来，至少隔这么久才显示一条，否则高速时会刷屏。 */
const SKIP_NOTE_EVERY = 2000;

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;" };
const escapeHtml = (text: string) => text.replace(/[&<>]/g, (c) => ESCAPES[c]);
const pad = (n: number, width = 2) => String(n).padStart(width, "0");

export function timestamp(time: number): string {
  const d = new Date(time);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

/** 日志区。保存全部记录，屏幕上只保留最近一部分，按批次追加，高速收数据时也不拖慢界面。 */
export class LogController {
  readonly element = document.createElement("div");
  atBottom = true;
  isEmpty = true;
  pending = 0;
  shownCount = 0;
  paused = false;
  version = 0;

  private entries: LogEntry[] = [];
  private pauseIndex = 0;
  private view: ViewMode = "text";
  private query = "";
  private encoding: TextEncodingChoice = "utf8";
  private chunks: { element: HTMLElement; rows: number }[] = [];
  private lastTop = 0;
  private mouseDown = false;
  private skipped = 0;
  private lastSkipNote = 0;
  private listeners = new Set<() => void>();

  constructor() {
    this.element.className = "log";
    this.element.tabIndex = 0;
    this.element.setAttribute("role", "log");
    this.element.setAttribute("aria-label", "串口日志");
    this.element.addEventListener("scroll", this.onScroll, { passive: true });
    // 滚动事件要等到下一帧才来，高速收数据时会被新数据抢先拉回底部，所以直接按操作判断意图
    this.element.addEventListener("wheel", (event) => {
      if (event.deltaY < 0) this.leaveBottom();
    }, { passive: true });
    this.element.addEventListener("keydown", (event) => {
      if (["ArrowUp", "PageUp", "Home"].includes(event.key)) this.leaveBottom();
    });
    this.element.addEventListener("pointerdown", () => (this.mouseDown = true));
    window.addEventListener("pointerup", this.onPointerUp);
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = () => this.version;

  private changed() {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  private leaveBottom() {
    // 内容不足一屏时没有地方可翻，不算离开
    if (!this.atBottom || this.element.scrollTop <= 0) return;
    this.atBottom = false;
    this.changed();
  }

  private onPointerUp = () => {
    if (!this.mouseDown) return;
    this.mouseDown = false;
    // 选中文字多半是要复制，留在这里，不被新数据带走
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed && this.element.contains(selection.anchorNode) && this.atBottom) {
      this.atBottom = false;
      this.changed();
    }
  };

  private onScroll = () => {
    const el = this.element;
    const distance = el.scrollHeight - el.clientHeight - el.scrollTop;
    const movedUp = el.scrollTop < this.lastTop - 0.5;
    this.lastTop = el.scrollTop;
    if (movedUp && distance > 2 && this.atBottom) {
      this.atBottom = false;
      this.changed();
    } else if (!movedUp && distance < 30 && !this.atBottom && !this.hasLogSelection()) {
      this.atBottom = true;
      this.changed();
    }
  };

  private hasLogSelection(): boolean {
    const selection = window.getSelection();
    return !!selection && !selection.isCollapsed && this.element.contains(selection.anchorNode);
  }

  get allEntries(): LogEntry[] {
    return this.entries;
  }

  append(list: LogEntry[]) {
    if (list.length === 0) return;
    this.entries.push(...(list.length > 50_000 ? list.slice(-50_000) : list));
    if (this.entries.length > MAX_STORED + TRIM_STORED) {
      const drop = this.entries.length - MAX_STORED;
      this.entries.splice(0, drop);
      this.pauseIndex = Math.max(0, this.pauseIndex - drop);
    }
    if (this.paused) {
      this.pending = this.entries.length - this.pauseIndex;
      this.changed();
      return;
    }
    this.render(list);
  }

  private matches(entry: LogEntry): boolean {
    return !this.query || this.bodyOf(entry).toLowerCase().includes(this.query.toLowerCase());
  }

  private render(list: LogEntry[]) {
    let visible = this.query ? list.filter((e) => this.matches(e)) : list;
    const extra: LogEntry[] = [];
    if (visible.length > MAX_PER_FLUSH) {
      this.skipped += visible.length - MAX_PER_FLUSH;
      visible = visible.slice(-MAX_PER_FLUSH);
    }
    const now = performance.now();
    if (this.skipped > 0 && now - this.lastSkipNote > SKIP_NOTE_EVERY) {
      extra.push(noteEntry(`数据太快，这里略过 ${this.skipped} 行显示，保存日志时仍会包含`));
      this.skipped = 0;
      this.lastSkipNote = now;
    }
    if (visible.length === 0) return;
    this.addRows(extra.concat(visible));
    this.trim();
    this.follow();
    this.updateCounts();
  }

  private addRows(list: LogEntry[]) {
    // 分块放进文档，屏幕外的块由 content-visibility 跳过排版，几万行也能流畅滚动
    let index = 0;
    while (index < list.length) {
      let chunk = this.chunks[this.chunks.length - 1];
      if (!chunk || chunk.rows >= CHUNK) {
        const element = document.createElement("div");
        element.className = "chunk";
        this.element.appendChild(element);
        chunk = { element, rows: 0 };
        this.chunks.push(chunk);
      }
      const count = Math.min(CHUNK - chunk.rows, list.length - index);
      let html = "";
      for (let i = index; i < index + count; i++) html += this.rowHtml(list[i]);
      chunk.element.insertAdjacentHTML("beforeend", html);
      chunk.rows += count;
      index += count;
    }
    this.shownCount += list.length;
  }

  private trim() {
    while (this.shownCount > MAX_SHOWN + CHUNK * 8 && this.chunks.length > 1) {
      const first = this.chunks.shift()!;
      first.element.remove();
      this.shownCount -= first.rows;
    }
  }

  private follow() {
    if (!this.atBottom || this.mouseDown) return;
    this.element.scrollTop = this.element.scrollHeight;
    this.lastTop = this.element.scrollTop;
  }

  private updateCounts() {
    this.isEmpty = this.shownCount === 0;
    this.changed();
  }

  private rowHtml(entry: LogEntry): string {
    const arrow = entry.direction === "rx" ? "←" : entry.direction === "tx" ? "→" : entry.error ? "!" : "·";
    const cls = entry.direction === "sys" ? (entry.error ? "r sys err" : "r sys") : `r ${entry.direction}`;
    return `<div class="${cls}"><span class="ts">${timestamp(entry.time)}  </span><span class="ar">${arrow}  </span>${this.highlight(this.bodyOf(entry))}</div>`;
  }

  private highlight(text: string): string {
    if (!this.query) return escapeHtml(text);
    const lower = text.toLowerCase();
    const needle = this.query.toLowerCase();
    let out = "";
    let at = 0;
    for (let found = lower.indexOf(needle); found >= 0; found = lower.indexOf(needle, at)) {
      out += escapeHtml(text.slice(at, found)) + "<mark>" + escapeHtml(text.slice(found, found + needle.length)) + "</mark>";
      at = found + needle.length;
    }
    return out + escapeHtml(text.slice(at));
  }

  bodyOf(entry: LogEntry): string {
    if (entry.direction === "sys") return entry.note;
    if (this.view === "hex") return hexString(entry.bytes);
    const end = entry.trailer ? entry.trailer[0] : entry.bytes.length;
    const content = entry.bytes.subarray(0, end);
    let text = displayText(content, this.encoding);
    // 发出去的全是控制字符时，文本视图不能留一行空白，看不出发了什么
    if (entry.direction === "tx" && text === "") text = hexString(content);
    if (!entry.trailer) return text;
    return `${text}  [校验 ${hexString(entry.bytes.subarray(entry.trailer[0], entry.trailer[1]))}]`;
  }

  /** 选项改变后，从保存的记录重新生成屏幕内容。 */
  private rebuild() {
    const limit = this.paused ? this.pauseIndex : this.entries.length;
    const picked: LogEntry[] = [];
    for (let i = limit - 1; i >= 0 && picked.length < MAX_SHOWN; i--) {
      if (this.matches(this.entries[i])) picked.push(this.entries[i]);
    }
    picked.reverse();
    this.element.replaceChildren();
    this.chunks = [];
    this.shownCount = 0;
    this.addRows(picked);
    this.follow();
    this.updateCounts();
  }

  configure(options: { view?: ViewMode; query?: string; encoding?: TextEncodingChoice }) {
    if (options.view !== undefined) this.view = options.view;
    if (options.query !== undefined) this.query = options.query;
    if (options.encoding !== undefined) this.encoding = options.encoding;
    this.rebuild();
  }

  setShowTime(show: boolean) {
    this.element.classList.toggle("no-time", !show);
    this.follow();
  }

  setPaused(value: boolean) {
    if (value === this.paused) return;
    this.paused = value;
    if (value) {
      this.pauseIndex = this.entries.length;
      this.pending = 0;
      this.changed();
    } else {
      const backlog = this.entries.slice(this.pauseIndex);
      this.pending = 0;
      this.atBottom = true;
      this.render(backlog);
      this.follow();
      this.changed();
    }
  }

  clear() {
    this.entries = [];
    this.pauseIndex = 0;
    this.pending = 0;
    this.paused = false;
    this.atBottom = true;
    this.element.replaceChildren();
    this.chunks = [];
    this.shownCount = 0;
    this.updateCounts();
  }

  jumpToEnd() {
    this.atBottom = true;
    window.getSelection()?.removeAllRanges();
    this.follow();
    this.changed();
  }

  exportText(showTime: boolean): string {
    const lines: string[] = [];
    for (const entry of this.entries) {
      const tag = entry.direction === "rx" ? "RX  " : entry.direction === "tx" ? "TX  " : "--  ";
      lines.push((showTime ? timestamp(entry.time) + "  " : "") + tag + this.bodyOf(entry));
    }
    return lines.join("\n") + "\n";
  }
}
