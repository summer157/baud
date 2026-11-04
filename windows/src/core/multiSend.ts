import type { SendProblem } from "./codec";

export interface SendItem {
  id: string;
  /** 是否参与“依次发送”。没勾上的条目仍然可以单独点发送。 */
  enabled: boolean;
  hex: boolean;
  text: string;
  note: string;
  /** 发完这条后等多久再发下一条，单位毫秒。 */
  delay: string;
}

export const MIN_DELAY = 10;

let nextId = 0;
export function newItem(fields: Partial<SendItem> = {}): SendItem {
  nextId += 1;
  return { id: `${Date.now().toString(36)}-${nextId}`, enabled: true, hex: false, text: "", note: "", delay: "1000", ...fields };
}

export function isBlank(item: SendItem): boolean {
  return item.text.trim() === "";
}

function delayMs(item: SendItem): number {
  const parsed = parseInt(item.delay, 10);
  return Math.max(MIN_DELAY, Number.isNaN(parsed) ? 1000 : parsed);
}

type Cursor = { at: "beginning" } | { at: "after"; id: string } | { at: "before"; id: string };

export interface MultiSendHost {
  /** 只检查不发送，返回 null 表示没问题。 */
  check(item: SendItem): SendProblem | null;
  /** 真正发出去，返回 null 表示已发出。 */
  send(item: SendItem): SendProblem | null;
  onStart(): void;
  save(items: SendItem[], loop: boolean): void;
}

/** 多条发送。依次发送途中可以改列表，游标按 ID 记录，排序和增删条目时不会错位。 */
export class MultiSendModel {
  private itemsValue: SendItem[];
  private loopValue: boolean;
  running = false;
  currentId: string | null = null;
  round = 1;
  failure: { id: string; problem: SendProblem } | null = null;

  private timer: ReturnType<typeof setTimeout> | null = null;
  private cursor: Cursor = { at: "beginning" };
  private rounds = 1;
  private lastShown = 0;
  private listeners = new Set<() => void>();
  version = 0;

  constructor(private readonly host: MultiSendHost, items: SendItem[], loop: boolean) {
    this.itemsValue = items;
    this.loopValue = loop;
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

  get items(): SendItem[] {
    return this.itemsValue;
  }

  set items(next: SendItem[]) {
    const old = this.itemsValue;
    this.itemsValue = next;
    this.failure = null;
    if (this.running) this.relocateCursor(old);
    this.host.save(next, this.loopValue);
    this.changed();
  }

  get loop(): boolean {
    return this.loopValue;
  }

  set loop(value: boolean) {
    this.loopValue = value;
    this.host.save(this.itemsValue, value);
    this.changed();
  }

  /** 会参与依次发送的条目。 */
  get queue(): SendItem[] {
    return this.itemsValue.filter((i) => i.enabled && !isBlank(i));
  }

  get progress(): { index: number; total: number } | null {
    if (!this.running || !this.currentId) return null;
    const list = this.queue;
    const index = list.findIndex((i) => i.id === this.currentId);
    return index < 0 ? null : { index: index + 1, total: list.length };
  }

  update(id: string, fields: Partial<SendItem>) {
    this.items = this.itemsValue.map((i) => (i.id === id ? { ...i, ...fields } : i));
  }

  add(): string {
    const item = newItem({ delay: this.itemsValue[this.itemsValue.length - 1]?.delay ?? "1000" });
    this.items = [...this.itemsValue, item];
    return item.id;
  }

  remove(id: string) {
    this.items = this.itemsValue.filter((i) => i.id !== id);
  }

  /** 把 from 位置的条目移到 to 位置。 */
  moveTo(from: number, to: number) {
    if (from === to || from < 0 || from >= this.itemsValue.length) return;
    const next = [...this.itemsValue];
    const [item] = next.splice(from, 1);
    next.splice(Math.max(0, Math.min(to, next.length)), 0, item);
    this.items = next;
  }

  /** 上移或下移一位，到头了就不动。 */
  moveBy(id: string, offset: number) {
    const index = this.itemsValue.findIndex((i) => i.id === id);
    const target = index + offset;
    if (index < 0 || target < 0 || target >= this.itemsValue.length) return;
    this.moveTo(index, target);
  }

  /** 单独发一条，返回是否发出。 */
  sendOne(item: SendItem): boolean {
    if (isBlank(item)) return false;
    this.failure = null;
    const problem = this.host.send(item);
    if (problem) {
      if (problem.kind !== "offline") this.failure = { id: item.id, problem };
      this.changed();
      return false;
    }
    this.changed();
    return true;
  }

  toggleRun() {
    if (this.running) this.stop();
    else this.start();
  }

  start() {
    if (this.running) return;
    // 先把要发的都检查一遍，不要发到一半才发现后面有一条写错了
    const list = this.queue;
    this.failure = null;
    for (const item of list) {
      const problem = this.host.check(item);
      if (problem) {
        this.failure = { id: item.id, problem };
        this.changed();
        return;
      }
    }
    if (list.length === 0) {
      this.changed();
      return;
    }
    this.host.onStart();
    this.running = true;
    this.cursor = { at: "beginning" };
    this.rounds = 1;
    this.round = 1;
    this.lastShown = 0;
    this.tick();
    this.changed();
  }

  stop() {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    if (!this.running) return;
    this.running = false;
    this.currentId = null;
    this.changed();
  }

  private tick() {
    this.timer = null;
    // 发送途中可以改列表，所以每一步都按当前的列表找下一条
    const step = this.running ? this.next(this.loopValue) : null;
    if (!step) {
      this.stop();
      return;
    }
    const problem = this.host.send(step.item);
    if (problem) {
      this.stop();
      if (problem.kind !== "offline") {
        this.failure = { id: step.item.id, problem };
        this.changed();
      }
      return;
    }
    this.cursor = { at: "after", id: step.item.id };
    if (step.wrapped) this.rounds += 1;

    // 间隔很短时高亮不必每条都刷新，眼睛也跟不上
    const now = performance.now();
    if (now - this.lastShown > 60) {
      this.lastShown = now;
      this.currentId = step.item.id;
      this.round = this.rounds;
      this.changed();
    }

    if (!this.loopValue && !this.next(false)) {
      this.stop();
      return;
    }
    this.timer = setTimeout(() => this.tick(), delayMs(step.item));
  }

  /** 只查看下一条，不改变任何状态。wrapped 表示这一条是回到开头开始新的一轮。 */
  private next(wrapping: boolean): { item: SendItem; wrapped: boolean } | null {
    const items = this.itemsValue;
    let start = 0;
    if (this.cursor.at !== "beginning") {
      const { id, at } = this.cursor;
      const index = items.findIndex((i) => i.id === id);
      start = index < 0 ? 0 : at === "after" ? index + 1 : index;
    }
    for (let i = start; i < items.length; i++) {
      if (items[i].enabled && !isBlank(items[i])) return { item: items[i], wrapped: false };
    }
    const first = wrapping ? this.queue[0] : undefined;
    return first ? { item: first, wrapped: true } : null;
  }

  /** 游标指向的条目被删了：接着发它后面还在的那条；后面没有了就贴到前面还在的那条之后，这样新加到末尾的条目不会被漏掉。 */
  private relocateCursor(old: SendItem[]) {
    if (this.cursor.at === "beginning") return;
    const { id } = this.cursor;
    const alive = new Set(this.itemsValue.map((i) => i.id));
    if (alive.has(id)) return;
    const index = old.findIndex((i) => i.id === id);
    if (index < 0) return;
    const successor = old.slice(index + 1).find((i) => alive.has(i.id));
    if (successor) {
      this.cursor = { at: "before", id: successor.id };
      return;
    }
    const predecessor = old.slice(0, index).reverse().find((i) => alive.has(i.id));
    this.cursor = predecessor ? { at: "after", id: predecessor.id } : { at: "beginning" };
  }
}
