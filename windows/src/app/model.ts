import { NO_CHECKSUM, withKind, type ChecksumKind, type ChecksumSetting } from "../core/checksum";
import { frameBytes, hexString, isProblem, makeFrame, type LineEnding, type OutgoingFrame, type SendProblem, type TextEncodingChoice } from "../core/codec";
import { DemoDevice } from "../core/demoDevice";
import { LineAssembler } from "../core/lineAssembler";
import { MultiSendModel, newItem, type SendItem } from "../core/multiSend";
import { normalizeTheme, type ThemeChoice } from "../core/theme";
import { LogController, noteEntry, rowEntry, type LogEntry, type ViewMode } from "./log";
import { MoodModel } from "./mood";
import { isNative, listPorts, openPort, saveTextFile, watchPorts, type PortInfo, type SerialConfig, type Transport } from "./native";
import { applyTheme } from "./theme";

export type LinkState = "idle" | "connecting" | "connected" | "lost";

const DEMO_INFO: PortInfo = { path: DemoDevice.portId, name: "演示设备", detail: "内置模拟，无需硬件", kind: "demo" };

export const portTitle = (port: PortInfo) => (port.detail ? `${port.name}  ·  ${port.detail}` : port.name);

/** 变化频繁的统计数据单独放，避免每次刷新都让整个界面重算。 */
export class StatsModel {
  rx = 0;
  tx = 0;
  rate = 0;
  rxHot = false;
  txHot = false;
  version = 0;

  private listeners = new Set<() => void>();
  private rxOff: ReturnType<typeof setTimeout> | null = null;
  private txOff: ReturnType<typeof setTimeout> | null = null;

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = () => this.version;

  changed() {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  addRx(count: number) {
    this.rx += count;
    this.rxHot = true;
    if (this.rxOff !== null) clearTimeout(this.rxOff);
    this.rxOff = setTimeout(() => {
      this.rxHot = false;
      this.changed();
    }, 90);
    this.changed();
  }

  addTx(count: number) {
    this.tx += count;
    this.txHot = true;
    if (this.txOff !== null) clearTimeout(this.txOff);
    this.txOff = setTimeout(() => {
      this.txHot = false;
      this.changed();
    }, 90);
    this.changed();
  }
}

export interface AppState {
  ports: PortInfo[];
  selectedPort: string;
  link: LinkState;
  lastError: string | null;
  baudChoice: string;
  customBaud: string;
  dataBits: number;
  stopBits: number;
  parity: SerialConfig["parity"];
  flow: SerialConfig["flow"];
  encoding: TextEncodingChoice;
  viewMode: ViewMode;
  showTime: boolean;
  query: string;
  focusMode: boolean;
  theme: ThemeChoice;
  advancedOpen: boolean;
  multiOpen: boolean;
  searchFocusTick: number;
  sendTick: number;
  flooding: boolean;
  demoPlugged: boolean;
  input: string;
  sendHex: boolean;
  ending: LineEnding;
  checksum: ChecksumSetting;
  inputProblem: SendProblem | null;
  timerOn: boolean;
  timerMs: string;
  quick: string[];
}

const SAVED_KEYS = [
  "selectedPort", "baudChoice", "customBaud", "dataBits", "stopBits", "parity", "flow", "encoding", "viewMode",
  "showTime", "focusMode", "theme", "multiOpen", "sendHex", "ending", "checksum", "timerMs", "quick",
] as const;
const STORAGE_KEY = "baud.settings";
const MULTI_KEY = "baud.multiSend";
const CONFIG_KEYS = ["baudChoice", "customBaud", "dataBits", "stopBits", "parity", "flow"];

function readJson<T>(key: string): T | null {
  try {
    const text = localStorage.getItem(key);
    return text ? (JSON.parse(text) as T) : null;
  } catch {
    return null;
  }
}

function writeJson(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // 存不下时这次设置只在本次运行有效
  }
}

export class AppModel {
  readonly log = new LogController();
  readonly stats = new StatsModel();
  readonly mood = new MoodModel();
  readonly multi: MultiSendModel;

  state: AppState = {
    ports: [DEMO_INFO],
    selectedPort: "",
    link: "idle",
    lastError: null,
    baudChoice: "115200",
    customBaud: "250000",
    dataBits: 8,
    stopBits: 1,
    parity: "none",
    flow: "none",
    encoding: "utf8",
    viewMode: "text",
    showTime: true,
    query: "",
    focusMode: false,
    theme: "system",
    advancedOpen: false,
    multiOpen: false,
    searchFocusTick: 0,
    sendTick: 0,
    flooding: false,
    demoPlugged: true,
    input: "",
    sendHex: false,
    ending: "crlf",
    checksum: NO_CHECKSUM,
    inputProblem: null,
    timerOn: false,
    timerMs: "1000",
    quick: ["AT", "AT+GMR", "status", "reset"],
  };
  version = 0;

  private listeners = new Set<() => void>();
  private transport: Transport | null = null;
  private generation = 0;
  private failCount = 0;
  private history: string[] = [];
  private historyIndex: number | null = null;
  private systemPorts: PortInfo[] = [];
  private sendTimer: ReturnType<typeof setInterval> | null = null;
  private queryWork: ReturnType<typeof setTimeout> | null = null;
  private configWork: ReturnType<typeof setTimeout> | null = null;
  private retryWork: ReturnType<typeof setTimeout> | null = null;

  // 接收管线：先分行，定时批量交给日志
  private assembler = new LineAssembler();
  private pipeLines: LogEntry[] = [];
  private pipeBytes = 0;
  private pipeLastData = 0;
  private nextFlush = 0;

  private lastRxTotal = 0;
  private lastRxAt = 0;
  private connectedAt = 0;
  private floodMood = false;

  constructor() {
    const saved = readJson<Partial<AppState>>(STORAGE_KEY);
    if (saved) Object.assign(this.state, saved);
    this.state.checksum = { ...NO_CHECKSUM, ...this.state.checksum };
    this.state.theme = normalizeTheme(this.state.theme);
    applyTheme(this.state.theme);

    const multiSaved = readJson<{ items: SendItem[]; loop: boolean }>(MULTI_KEY);
    this.multi = new MultiSendModel(
      {
        check: (item) => {
          const frame = this.frameFor(item.text, item.hex);
          return isProblem(frame) ? frame : null;
        },
        send: (item) => this.transmit(item.text, item.hex),
        onStart: () => {
          // 和定时发送同时跑，两边的数据会穿插在一起
          this.stopTimer();
          this.bumpSend();
        },
        save: (items, loop) => writeJson(MULTI_KEY, { items, loop }),
      },
      multiSaved?.items ?? ["AT", "AT+GMR", "status"].map((text) => newItem({ text })),
      multiSaved?.loop ?? false,
    );

    this.log.configure({ view: this.state.viewMode, encoding: this.state.encoding });
    this.log.setShowTime(this.state.showTime);
    this.portsChanged([]);
    void listPorts().then((ports) => this.portsChanged(ports));
    watchPorts((ports) => this.portsChanged(ports));

    setInterval(() => this.pipeTick(), 33);
    setInterval(() => this.everySecond(), 1000);
    this.updateMood();
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = () => this.version;

  /** 改状态的唯一入口：保存设置，并处理各项改动带来的副作用。 */
  set(patch: Partial<AppState>) {
    const before = this.state;
    this.state = { ...before, ...patch };
    const changed = (key: keyof AppState) => key in patch && this.state[key] !== before[key];

    if (SAVED_KEYS.some((k) => changed(k))) {
      const out: Record<string, unknown> = {};
      for (const key of SAVED_KEYS) out[key] = this.state[key];
      writeJson(STORAGE_KEY, out);
    }
    if (changed("input") || changed("sendHex") || changed("checksum")) {
      if (!("inputProblem" in patch)) this.state.inputProblem = null;
    }
    if (changed("theme")) applyTheme(this.state.theme);
    if (changed("encoding")) this.log.configure({ encoding: this.state.encoding });
    if (changed("viewMode")) this.log.configure({ view: this.state.viewMode });
    if (changed("showTime")) this.log.setShowTime(this.state.showTime);
    if (changed("query")) {
      if (this.queryWork !== null) clearTimeout(this.queryWork);
      this.queryWork = setTimeout(() => this.log.configure({ query: this.state.query }), 120);
    }
    if (changed("timerMs") && this.state.timerOn) this.startTimer();
    if (CONFIG_KEYS.some((k) => changed(k as keyof AppState))) this.configChanged();
    if (changed("selectedPort") && (this.state.link === "connected" || this.state.link === "lost")) {
      this.closeCurrent();
      this.connect();
    }

    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  get config(): SerialConfig {
    const s = this.state;
    const parsed = parseInt(s.baudChoice === "custom" ? s.customBaud : s.baudChoice, 10);
    return { baud: parsed > 0 ? parsed : 115200, dataBits: s.dataBits, stopBits: s.stopBits, parity: s.parity, flow: s.flow };
  }

  get configSummary(): string {
    const c = this.config;
    return `${c.baud} ${c.dataBits}${c.parity === "none" ? "N" : c.parity === "even" ? "E" : "O"}${c.stopBits}`;
  }

  get isDemoSelected(): boolean {
    return this.state.selectedPort === DemoDevice.portId;
  }

  get selectedName(): string {
    const { ports, selectedPort } = this.state;
    if (this.isDemoSelected) return DEMO_INFO.name;
    return ports.find((p) => p.path === selectedPort)?.name ?? selectedPort.split(/[\\/]/).pop() ?? selectedPort;
  }

  /** 输入框当前内容会带上的校验字节，内容不完整时没有。 */
  get checksumPreview(): string | null {
    const { checksum, input, sendHex } = this.state;
    if (checksum.kind === "none" || input.trim() === "") return null;
    const frame = this.frameFor(input, sendHex);
    return isProblem(frame) ? null : hexString(frame.trailer);
  }

  setChecksumKind(kind: ChecksumKind) {
    this.set({ checksum: withKind(this.state.checksum, kind) });
  }

  // MARK: 设置

  private configChanged() {
    if (this.configWork !== null) clearTimeout(this.configWork);
    if (this.state.link !== "connected") return;
    this.configWork = setTimeout(() => {
      const config = this.config;
      this.transport?.update(config).then(
        () => this.note(`已切换为 ${this.configSummary}`),
        (error) => this.note(`无法应用新参数：${String(error)}`, true),
      );
    }, 400);
  }

  // MARK: 端口列表

  private portsChanged(found: PortInfo[]) {
    this.systemPorts = found;
    const list = [...found];
    if (this.state.demoPlugged) {
      const index = list.findIndex((p) => p.kind === "system");
      list.splice(index < 0 ? list.length : index, 0, DEMO_INFO);
    }
    const hadUsb = new Set(this.state.ports.filter((p) => p.kind === "usb").map((p) => p.path));
    const { link, selectedPort } = this.state;
    const selected = list.find((p) => p.path === selectedPort);
    const newUsb = list.find((p) => p.kind === "usb" && !hadUsb.has(p.path));

    const patch: Partial<AppState> = { ports: list };
    if (link === "idle") {
      if ((!selected || selected.kind === "demo" || selected.kind === "system") && newUsb) {
        patch.selectedPort = newUsb.path;
      } else if (!selected && list[0]) {
        patch.selectedPort = list[0].path;
      }
    }
    this.set(patch);

    if (link === "connected" && !selected) this.deviceLost();
    else if (link === "lost" && selected) this.scheduleReconnect(400);
  }

  // MARK: 连接

  toggleLink() {
    if (this.state.link === "idle") {
      this.connect();
      return;
    }
    const wasConnected = this.state.link === "connected";
    const name = this.selectedName;
    this.generation += 1;
    if (this.retryWork !== null) clearTimeout(this.retryWork);
    this.closeCurrent();
    this.failCount = 0;
    this.set({ link: "idle", lastError: null, demoPlugged: true });
    this.portsChanged(this.systemPorts);
    if (wasConnected) this.note(`已断开 ${name}`);
    this.updateMood();
  }

  private connect(noteText?: string) {
    const { selectedPort, link } = this.state;
    if (!selectedPort) return;
    this.generation += 1;
    const token = this.generation;
    const wasLost = link === "lost";
    const started = performance.now();
    const config = this.config;
    if (!wasLost) this.set({ link: "connecting" });
    this.set({ lastError: null });
    this.updateMood();

    let opened: Transport | null = null;
    const isCurrent = () => token === this.generation && (opened === null || this.transport === opened);
    openPort(selectedPort, config, {
      onData: (data) => {
        if (isCurrent()) this.receive(data);
      },
      onLost: () => {
        if (isCurrent()) this.deviceLost();
      },
    }).then(
      async (transport) => {
        opened = transport;
        // 留一点时间，让开关转圈的动画能被看见
        await new Promise((r) => setTimeout(r, Math.max(0, 420 - (performance.now() - started))));
        if (token !== this.generation) {
          transport.close();
          return;
        }
        this.didOpen(transport, noteText);
      },
      async (error: Error) => {
        await new Promise((r) => setTimeout(r, Math.max(0, 420 - (performance.now() - started))));
        if (token === this.generation) this.didFail(error.message, wasLost);
      },
    );
  }

  private didOpen(opened: Transport, text?: string) {
    this.transport = opened;
    this.failCount = 0;
    this.connectedAt = performance.now();
    this.lastRxAt = 0;
    this.assembler = new LineAssembler();
    this.pipeLines = [];
    this.pipeBytes = 0;
    opened.demo?.start();
    this.set({ link: "connected", lastError: null });
    this.note(`${text ?? "已连接"} ${this.selectedName} · ${this.configSummary}`);
    this.mood.flash("link", 1.8);
  }

  private didFail(message: string, wasLost: boolean) {
    if (wasLost) {
      this.scheduleReconnect(1500);
      return;
    }
    this.failCount += 1;
    this.set({ link: "idle", lastError: message });
    this.note(`连接 ${this.selectedName} 失败：${message}`, true);
    this.mood.flash(this.failCount >= 3 ? "failx" : "fail", 3);
  }

  private deviceLost() {
    const name = this.selectedName;
    this.closeCurrent();
    this.set({ link: "lost", flooding: false });
    this.note(`设备意外断开 ${name}，插回后会自动重连`, true);
    this.mood.flash("unplug", 4);
    this.scheduleReconnect(1000);
  }

  private scheduleReconnect(delay: number) {
    if (this.retryWork !== null) clearTimeout(this.retryWork);
    this.retryWork = setTimeout(() => {
      const { link, ports, selectedPort } = this.state;
      if (link === "lost" && ports.some((p) => p.path === selectedPort)) this.connect("已自动重连");
    }, delay);
  }

  private closeCurrent() {
    this.stopTimer();
    this.multi.stop();
    this.transport?.close();
    this.transport = null;
    if (this.state.flooding) this.set({ flooding: false });
  }

  // MARK: 演示设备

  demoUnplug() {
    const device = this.transport?.demo;
    if (!this.isDemoSelected || this.state.link !== "connected" || !device) return;
    this.set({ demoPlugged: false });
    this.portsChanged(this.systemPorts);
  }

  demoPlugBack() {
    this.set({ demoPlugged: true });
    this.portsChanged(this.systemPorts);
  }

  demoToggleFlood() {
    this.demoSetFlood(this.state.flooding ? 0 : 800_000);
  }

  demoSetFlood(bytesPerSecond: number) {
    const device = this.transport?.demo;
    if (!device) return;
    device.setFlood(bytesPerSecond);
    this.set({ flooding: bytesPerSecond > 0 });
  }

  // MARK: 接收管线

  private receive(data: Uint8Array) {
    this.pipeBytes += data.length;
    this.pipeLastData = performance.now();
    const now = Date.now();
    for (const line of this.assembler.feed(data)) this.pipeLines.push(rowEntry("rx", line, null, now));
  }

  private pipeTick() {
    if (this.assembler.hasPartial && performance.now() - this.pipeLastData > 100) {
      const rest = this.assembler.flush();
      if (rest) this.pipeLines.push(rowEntry("rx", rest));
    }
    if (this.pipeBytes === 0 && this.pipeLines.length === 0) return;
    // 显示最多占用大约五分之一的时间，数据再快界面也不会卡住。多出来的行只保存，不逐行显示
    const started = performance.now();
    if (started < this.nextFlush) return;
    const lines = this.pipeLines;
    const bytes = this.pipeBytes;
    this.pipeLines = [];
    this.pipeBytes = 0;
    if (bytes > 0) {
      this.stats.addRx(bytes);
      this.lastRxAt = performance.now();
    }
    this.log.append(lines);
    const finished = performance.now();
    this.nextFlush = finished + (finished - started) * 4;
  }

  // MARK: 发送

  private frameFor(text: string, hex: boolean): OutgoingFrame | SendProblem {
    const { encoding, ending, checksum } = this.state;
    return makeFrame(text, hex, { encoding, ending, checksum });
  }

  private bumpSend() {
    this.set({ sendTick: this.state.sendTick + 1 });
    this.mood.flash("send", 1.2);
  }

  submit() {
    const text = this.state.input;
    if (text.trim() === "") return;
    if (!this.transmitInput()) return;
    if (this.history[this.history.length - 1] !== text) this.history.push(text);
    this.historyIndex = null;
    if (!this.state.timerOn) this.set({ input: "" });
    this.bumpSend();
  }

  sendQuick(command: string) {
    const problem = this.transmit(command, false);
    if (problem) {
      if (problem.kind !== "offline") this.note(`没有发送 ${command}：${problemText(problem)}`, true);
      return;
    }
    this.bumpSend();
  }

  sendRow(item: SendItem) {
    if (this.multi.sendOne(item)) this.bumpSend();
    else if (this.multi.failure) this.mood.flash("hex", 2);
  }

  /** 发出一帧。返回 null 表示已发出，否则是没能发出的原因。 */
  private transmit(text: string, hex: boolean): SendProblem | null {
    if (this.state.link !== "connected" || !this.transport) return { kind: "offline" };
    const frame = this.frameFor(text, hex);
    if (isProblem(frame)) return frame;
    const data = frameBytes(frame);
    this.transport.write(data);
    this.stats.addTx(data.length);
    const trailer: [number, number] | null = frame.trailer.length ? [frame.body.length, frame.body.length + frame.trailer.length] : null;
    this.log.append([rowEntry("tx", data, trailer)]);
    return null;
  }

  private transmitInput(): boolean {
    const problem = this.transmit(this.state.input, this.state.sendHex);
    if (!problem) return true;
    if (problem.kind !== "offline") {
      this.set({ inputProblem: problem });
      this.mood.flash("hex", 2);
    }
    return false;
  }

  historyUp() {
    if (this.history.length === 0) return;
    const index = this.historyIndex === null ? this.history.length - 1 : Math.max(0, this.historyIndex - 1);
    this.historyIndex = index;
    this.set({ input: this.history[index] });
  }

  historyDown() {
    if (this.historyIndex === null) return;
    if (this.historyIndex + 1 < this.history.length) {
      this.historyIndex += 1;
      this.set({ input: this.history[this.historyIndex] });
    } else {
      this.historyIndex = null;
      this.set({ input: "" });
    }
  }

  toggleTimer() {
    if (this.state.timerOn) {
      this.stopTimer();
      return;
    }
    this.multi.stop();
    if (!this.transmitInput()) return;
    this.set({ timerOn: true });
    this.startTimer();
  }

  private startTimer() {
    if (this.sendTimer !== null) clearInterval(this.sendTimer);
    const parsed = parseInt(this.state.timerMs, 10);
    const ms = Math.max(10, Number.isNaN(parsed) ? 1000 : parsed);
    this.sendTimer = setInterval(() => {
      if (!this.transmitInput()) this.stopTimer();
    }, ms);
  }

  private stopTimer() {
    if (this.sendTimer !== null) clearInterval(this.sendTimer);
    this.sendTimer = null;
    if (this.state.timerOn) this.set({ timerOn: false });
  }

  addQuickFromInput() {
    const command = this.state.input.trim();
    if (!command || this.state.quick.includes(command)) return;
    this.set({ quick: [...this.state.quick, command] });
  }

  removeQuick(command: string) {
    this.set({ quick: this.state.quick.filter((c) => c !== command) });
  }

  // MARK: 工具栏动作

  note(text: string, error = false) {
    this.log.append([noteEntry(text, error)]);
  }

  togglePause() {
    this.log.setPaused(!this.log.paused);
  }

  clearLog() {
    this.log.clear();
    this.stats.rx = 0;
    this.stats.tx = 0;
    this.lastRxTotal = 0;
    this.stats.changed();
  }

  focusSearch() {
    this.set({ searchFocusTick: this.state.searchFocusTick + 1 });
  }

  async saveLog() {
    const d = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    try {
      const path = await saveTextFile(`Baud-${stamp}.log`, this.log.exportText(this.state.showTime));
      if (path) this.note(`日志已保存到 ${path}`);
    } catch (error) {
      this.note(`保存失败：${String(error)}`, true);
    }
  }

  // MARK: 心情

  private everySecond() {
    const total = this.stats.rx;
    const rate = Math.max(0, total - this.lastRxTotal);
    this.lastRxTotal = total;
    if (this.stats.rate !== rate) {
      this.stats.rate = rate;
      this.stats.changed();
    }
    this.updateMood();
  }

  private updateMood() {
    switch (this.state.link) {
      case "idle":
        return this.mood.setAmbient("peek");
      case "connecting":
        return this.mood.setAmbient("wait");
      case "lost":
        return this.mood.setAmbient("unplug");
      case "connected": {
        const quiet = (performance.now() - Math.max(this.lastRxAt, this.connectedAt)) / 1000;
        // 进入和退出用不同的阈值，速率在边界附近时表情不会来回跳
        this.floodMood = this.stats.rate > (this.floodMood ? 20_000 : 30_000);
        if (this.floodMood) this.mood.setAmbient("flood");
        else if (quiet < 2) this.mood.setAmbient("read");
        else if (quiet < 20) this.mood.setAmbient("cool");
        else if (quiet < 180) this.mood.setAmbient("wait");
        else this.mood.setAmbient("doze");
      }
    }
  }
}

function problemText(problem: SendProblem): string {
  return problem.kind === "badHex" ? "HEX 需要成对的 0-9、A-F" : problem.kind === "tooShort" ? `校验从第 ${problem.startByte} 字节算起，内容不够长` : "还没有连接";
}

export const model = new AppModel();
export { isNative };
