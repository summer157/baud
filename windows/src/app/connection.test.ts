import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DemoDevice } from "../core/demoDevice";
import { appShortcut, isBrowserShortcut } from "./shortcuts";

/**
 * 用真实的 AppModel 和 native.ts，只替换 Tauri。假后端按 link.rs 的规则工作：
 * 编号决定一切，操作的到达顺序和完成时间由测试控制。真实后端的规则在 link.rs 的测试里单独验证。
 */
interface OpenCall {
  id: number;
  path: string;
  config: { baud: number; dataBits: number };
  channel: { onmessage: (data: ArrayBuffer) => void };
  resolve: () => void;
  reject: (message: string) => void;
}

const backend = {
  opens: [] as OpenCall[],
  writes: [] as { id: number; path: string | null; text: string }[],
  updates: [] as { id: number; path: string | null; dataBits: number }[],
  closes: [] as number[],
  ports: [] as { path: string; name: string; detail: string; kind: string }[],
  current: null as number | null,
  floor: 0,
  lost: null as ((event: { payload: number }) => void) | null,
  portsChanged: null as ((event: { payload: unknown }) => void) | null,
  pathOf(id: number | null) {
    return this.opens.find((o) => o.id === id)?.path ?? null;
  },
};

class FakeChannel {
  onmessage: (data: ArrayBuffer) => void = () => {};
}

vi.mock("@tauri-apps/api/core", () => ({
  Channel: FakeChannel,
  invoke: vi.fn(async (command: string, args: Record<string, unknown>) => {
    const id = args?.id as number;
    switch (command) {
      case "serial_ports":
        return backend.ports;
      case "serial_open":
        if (id < backend.floor) throw "这次连接已被取消";
        backend.floor = id;
        backend.current = null;
        return new Promise<void>((resolve, reject) => {
          backend.opens.push({
            id,
            path: args.path as string,
            config: args.config as OpenCall["config"],
            channel: args.onData as OpenCall["channel"],
            resolve: () => {
              if (backend.floor !== id) return reject("这次连接已被取消");
              backend.current = id;
              resolve();
            },
            reject,
          });
        });
      case "serial_write":
        if (backend.current === id) {
          backend.writes.push({ id, path: backend.pathOf(id), text: new TextDecoder().decode(Uint8Array.from(args.data as number[])) });
        }
        return undefined;
      case "serial_update":
        if (backend.current !== id) throw "连接已经关闭";
        backend.updates.push({ id, path: backend.pathOf(id), dataBits: (args.config as OpenCall["config"]).dataBits });
        return undefined;
      case "serial_close":
        backend.closes.push(id);
        backend.floor = Math.max(backend.floor, id + 1);
        if (backend.current !== null && backend.current <= id) backend.current = null;
        return undefined;
      default:
        throw new Error(`没有模拟 ${command}`);
    }
  }),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, handler: (event: { payload: unknown }) => void) => {
    if (name === "serial-lost") backend.lost = handler as (event: { payload: number }) => void;
    if (name === "ports-changed") backend.portsChanged = handler;
    return () => {};
  }),
}));

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ setTheme: async () => {} }),
}));

class FakeLog {
  entries: { direction: string; bytes: Uint8Array; note: string }[] = [];
  paused = false;
  configure() {}
  setShowTime() {}
  append(lines: never[]) {
    this.entries.push(...lines);
  }
  get allEntries() {
    return this.entries;
  }
}

vi.mock("./log", async (original) => ({ ...(await original<typeof import("./log")>()), LogController: FakeLog }));

const usb = (path: string) => ({ path, name: path, detail: "", kind: "usb" });
const encode = (text: string) => new TextEncoder().encode(text).buffer;

function stubBrowser(saved: Record<string, unknown> = {}) {
  const store = new Map<string, string>([["baud.settings", JSON.stringify(saved)]]);
  vi.stubGlobal("window", {
    __TAURI_INTERNALS__: {},
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener() {},
  });
  vi.stubGlobal("document", { documentElement: { dataset: {} } });
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  });
  return store;
}

async function start(saved: Record<string, unknown> = {}, ports = [usb("COM3"), usb("COM4")]) {
  backend.ports = ports;
  const store = stubBrowser(saved);
  const { AppModel } = await import("./model");
  const model = new AppModel();
  await settle(0);
  const rx = () => model.log.allEntries.filter((e) => e.direction === "rx").map((e) => new TextDecoder().decode(e.bytes)).join("");
  const notes = () => model.log.allEntries.filter((e) => e.direction === "sys").map((e) => e.note);
  const send = (text: string) => {
    model.set({ input: text, ending: "none" });
    model.submit();
  };
  return { model, rx, notes, send, store };
}

/** 让时间往前走，同时把 promise 都跑完。 */
async function settle(ms: number) {
  await vi.advanceTimersByTimeAsync(ms);
}

const last = () => backend.opens[backend.opens.length - 1];

beforeEach(() => {
  vi.useFakeTimers();
  vi.resetModules();
  Object.assign(backend, { opens: [], writes: [], updates: [], closes: [], ports: [], current: null, floor: 0, lost: null, portsChanged: null });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("连接：打开前后到达的数据", () => {
  it("打开返回之前到达的数据不丢", async () => {
    const { model, rx } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().channel.onmessage(encode("before-resolve\r\n"));
    await settle(10);
    last().resolve();
    await settle(1000);
    expect(rx()).toContain("before-resolve");
  });

  it("打开之后、动画结束之前到达的数据不丢，也不会多算", async () => {
    const { model, rx } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(50);
    expect(model.state.link).toBe("connecting");
    last().channel.onmessage(encode("boot: ok\r\n"));
    await settle(1000);
    expect(model.state.link).toBe("connected");
    last().channel.onmessage(encode("later\r\n"));
    await settle(100);
    expect(rx()).toBe("boot: ok\r\nlater\r\n");
    expect(model.stats.rx).toBe(17);
  });

  it("跨越动画结束的半行能拼起来", async () => {
    const { model, rx } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(390);
    last().channel.onmessage(encode("hel"));
    await settle(60);
    expect(model.state.link).toBe("connected");
    last().channel.onmessage(encode("lo\r\n"));
    await settle(100);
    expect(rx()).toBe("hello\r\n");
  });

  it("已经取消的连接发来的数据不进日志", async () => {
    const { model, rx } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const old = last();
    model.toggleLink();
    old.channel.onmessage(encode("stale\r\n"));
    await settle(1000);
    expect(rx()).toBe("");
    expect(model.state.link).toBe("idle");
  });

  it("换端口时上一个连接的半行不会接到新连接的内容前面", async () => {
    const { model, rx } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(500);
    last().channel.onmessage(encode("half"));
    await settle(0);
    model.set({ selectedPort: "COM4" });
    await settle(0);
    last().resolve();
    last().channel.onmessage(encode("new\r\n"));
    await settle(500);
    const rows = model.log.allEntries.filter((e) => e.direction === "rx").map((e) => new TextDecoder().decode(e.bytes));
    expect(rows).toEqual(["half", "new\r\n"]);
    expect(rx()).toBe("halfnew\r\n");
  });
});

describe("连接：早期断线", () => {
  it("动画期间断线进入等待，不会变成已连接", async () => {
    const { model, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const opened = last();
    opened.resolve();
    await settle(100);
    backend.lost!({ payload: opened.id });
    await settle(0);
    expect(model.state.link).toBe("lost");
    expect(backend.closes).toContain(opened.id);
    await settle(300);
    expect(model.state.link).not.toBe("connected");
    expect(notes().some((n) => n.includes("设备意外断开"))).toBe(true);
  });

  it("打开返回之前的断线事件也不会丢", async () => {
    const { model } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const opened = last();
    backend.lost!({ payload: opened.id });
    await settle(0);
    expect(model.state.link).toBe("lost");
    opened.resolve();
    await settle(400);
    expect(model.state.link).toBe("lost");
  });

  it("动画期间端口从列表消失也算断线", async () => {
    const { model } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(100);
    backend.portsChanged!({ payload: [usb("COM4")] });
    await settle(0);
    expect(model.state.link).toBe("lost");
  });

  it("过期连接的断线事件不影响当前连接", async () => {
    const { model } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const old = last();
    old.resolve();
    await settle(500);
    model.set({ selectedPort: "COM4" });
    await settle(0);
    last().resolve();
    await settle(500);
    backend.lost!({ payload: old.id });
    await settle(0);
    expect(model.state.link).toBe("connected");
  });

  it("断线后设备回来会自动重连，重连期间不会重复打开", async () => {
    const { model, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(500);
    backend.lost!({ payload: last().id });
    await settle(1000);
    expect(backend.opens).toHaveLength(2);
    backend.portsChanged!({ payload: [usb("COM3"), usb("COM5")] });
    await settle(600);
    expect(backend.opens).toHaveLength(2);
    last().resolve();
    await settle(500);
    expect(model.state.link).toBe("connected");
    expect(notes().some((n) => n.startsWith("已自动重连"))).toBe(true);
  });
});

describe("连接：旧操作不能影响新连接", () => {
  it("同一端口快速连接、取消、再连接，发送到达新连接", async () => {
    const { model, send } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const first = last();
    first.resolve();
    await settle(100);
    model.toggleLink();
    await settle(100);
    model.toggleLink();
    await settle(0);
    const second = last();
    expect(second.id).toBeGreaterThan(first.id);
    second.resolve();
    await settle(1000);
    expect(model.state.link).toBe("connected");
    expect(backend.closes).not.toContain(second.id);
    send("hello");
    expect(backend.writes).toEqual([{ id: second.id, path: "COM3", text: "hello" }]);
  });

  it("慢的 open 被取消后换端口，旧 open 晚完成也不覆盖", async () => {
    const { model, send } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const slow = last();
    model.toggleLink();
    expect(backend.closes).toContain(slow.id);
    model.set({ selectedPort: "COM4" });
    model.toggleLink();
    await settle(0);
    const fresh = last();
    fresh.resolve();
    await settle(500);
    slow.resolve();
    await settle(500);
    expect(model.state.link).toBe("connected");
    send("data");
    expect(backend.writes).toEqual([{ id: fresh.id, path: "COM4", text: "data" }]);
  });

  it("取消后打开才失败，不显示错误也不改变状态", async () => {
    const { model, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const slow = last();
    model.toggleLink();
    slow.reject("端口被占用，先关掉正在使用它的程序");
    await settle(1000);
    expect(model.state.link).toBe("idle");
    expect(model.state.lastError).toBeNull();
    expect(notes().some((n) => n.includes("失败"))).toBe(false);
  });

  it("重复关闭只发一次，关闭后写入不再发出", async () => {
    const { openPort } = await (stubBrowser(), import("./native"));
    const transport = openPort("COM3", { baud: 9600, dataBits: 8, stopBits: 1, parity: "none", flow: "none" }, { onData() {}, onLost() {} });
    await settle(0);
    last().resolve();
    await transport.opened;
    transport.close();
    transport.close();
    transport.write(new Uint8Array([1]));
    await settle(0);
    expect(backend.closes).toHaveLength(1);
    expect(backend.writes).toHaveLength(0);
  });

  it("等待改参数期间切换端口，不会把提示算到新连接上", async () => {
    const { model, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(500);
    model.set({ dataBits: 7 });
    await settle(100);
    model.set({ selectedPort: "COM4" });
    await settle(1000);
    expect(backend.updates).toHaveLength(0);
    expect(notes().some((n) => n.includes("已切换为"))).toBe(false);
    expect(last().path).toBe("COM4");
    expect(last().config.dataBits).toBe(7);
  });
});

describe("连接：连接期间切换端口和改参数", () => {
  it("连接中切换端口：旧尝试作废，数据只发到新端口", async () => {
    const { model, send, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    const old = last();
    model.set({ selectedPort: "COM4" });
    await settle(0);
    expect(backend.closes).toContain(old.id);
    expect(last().path).toBe("COM4");
    old.resolve();
    last().resolve();
    await settle(1000);
    expect(model.state.link).toBe("connected");
    send("x");
    expect(backend.writes).toEqual([{ id: last().id, path: "COM4", text: "x" }]);
    expect(notes().filter((n) => n.startsWith("已连接"))).toHaveLength(1);
    expect(notes().find((n) => n.startsWith("已连接"))).toContain("COM4");
  });

  it("打开途中改参数：打开后立刻应用到串口", async () => {
    const { model } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    expect(last().config.dataBits).toBe(8);
    model.set({ dataBits: 7 });
    await settle(50);
    expect(backend.updates).toHaveLength(0);
    last().resolve();
    await settle(0);
    expect(backend.updates).toEqual([{ id: last().id, path: "COM3", dataBits: 7 }]);
    await settle(1000);
    expect(backend.updates).toHaveLength(1);
  });

  it("打开之后、动画结束之前改参数也会生效", async () => {
    const { model } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(100);
    expect(model.state.link).toBe("connecting");
    model.set({ dataBits: 6 });
    await settle(1000);
    expect(backend.updates).toEqual([{ id: last().id, path: "COM3", dataBits: 6 }]);
  });

  it("打开失败时回到未连接并提示", async () => {
    const { model, notes } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().reject("端口被占用，先关掉正在使用它的程序");
    await settle(1000);
    expect(model.state.link).toBe("idle");
    expect(model.state.lastError).toContain("端口被占用");
    expect(notes().some((n) => n.includes("连接 COM3 失败"))).toBe(true);
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(500);
    expect(model.state.link).toBe("connected");
  });
});

describe("连接：收发保持原样", () => {
  it("发送和接收的字节原样，统计正确", async () => {
    const { model, rx, send } = await start({ selectedPort: "COM3" });
    model.toggleLink();
    await settle(0);
    last().resolve();
    await settle(500);
    send("AT");
    last().channel.onmessage(encode("OK\r\n"));
    await settle(100);
    expect(backend.writes[0].text).toBe("AT");
    expect(rx()).toBe("OK\r\n");
    expect(model.stats.tx).toBe(2);
    expect(model.stats.rx).toBe(4);
  });

  it("没有连接时不发送", async () => {
    const { send, model } = await start({ selectedPort: "COM3" });
    send("AT");
    await settle(0);
    expect(backend.writes).toHaveLength(0);
    expect(model.stats.tx).toBe(0);
  });
});

describe("端口记忆", () => {
  const savedPort = (store: Map<string, string>) => JSON.parse(store.get("baud.settings")!).selectedPort;

  it("保存的端口还在时，启动后仍选它，存储也不变", async () => {
    const { model, store } = await start({ selectedPort: "COM4", baudChoice: "9600" });
    expect(model.state.selectedPort).toBe("COM4");
    expect(savedPort(store)).toBe("COM4");
  });

  it("枚举返回之前不会改掉保存的端口", async () => {
    backend.ports = [usb("COM3"), usb("COM4")];
    const store = stubBrowser({ selectedPort: "COM4" });
    const { AppModel } = await import("./model");
    const model = new AppModel();
    expect(model.state.selectedPort).toBe("COM4");
    expect(savedPort(store)).toBe("COM4");
  });

  it("枚举返回之前连接又取消，也不会改掉保存的端口", async () => {
    backend.ports = [usb("COM3"), usb("COM4")];
    const store = stubBrowser({ selectedPort: "COM4" });
    const { AppModel } = await import("./model");
    const model = new AppModel();
    model.toggleLink();
    model.toggleLink();
    expect(model.state.selectedPort).toBe("COM4");
    await settle(0);
    expect(model.state.selectedPort).toBe("COM4");
    expect(savedPort(store)).toBe("COM4");
  });

  it("保存的端口不在了，选第一个 USB 串口", async () => {
    const { model } = await start({ selectedPort: "COM9" });
    expect(model.state.selectedPort).toBe("COM3");
  });

  it("保存的端口不在且没有 USB 串口，选演示设备", async () => {
    const { model } = await start({ selectedPort: "COM9" }, []);
    expect(model.state.selectedPort).toBe(DemoDevice.portId);
  });

  it("后来插入的 USB 串口不会抢走保存的端口", async () => {
    const { model } = await start({ selectedPort: "COM4" });
    backend.portsChanged!({ payload: [usb("COM3"), usb("COM4"), usb("COM7")] });
    await settle(0);
    expect(model.state.selectedPort).toBe("COM4");
  });

  it("首次启动没有硬件：立刻选中演示设备，连上后能收到数据", async () => {
    backend.ports = [];
    stubBrowser();
    const { AppModel } = await import("./model");
    const model = new AppModel();
    expect(model.state.selectedPort).toBe(DemoDevice.portId);
    model.toggleLink();
    await settle(1500);
    expect(model.state.link).toBe("connected");
    expect(model.stats.rx).toBeGreaterThan(0);
    model.toggleLink();
    await settle(0);
    expect(model.state.selectedPort).toBe(DemoDevice.portId);
    expect(backend.opens).toHaveLength(0);
  });

  it("首次启动有 USB 串口时优先选它", async () => {
    const { model } = await start({}, [usb("COM3")]);
    expect(model.state.selectedPort).toBe("COM3");
  });
});

describe("快捷键", () => {
  const press = (key: string, modifiers: { ctrl?: boolean; shift?: boolean; meta?: boolean } = {}) => ({
    key,
    ctrlKey: !!modifiers.ctrl,
    metaKey: !!modifiers.meta,
    shiftKey: !!modifiers.shift,
  });

  it("Ctrl+Shift+P 是暂停，不会先被当成打印拦下", () => {
    // Shift 按住时 key 是大写的 P，正式版里曾被打印的拦截规则吃掉
    expect(appShortcut(press("P", { ctrl: true, shift: true }))).toBe("togglePause");
  });

  it("Ctrl+P 仍然拦下，不触发暂停", () => {
    expect(appShortcut(press("p", { ctrl: true }))).toBeNull();
    expect(isBrowserShortcut(press("p", { ctrl: true }))).toBe(true);
  });

  it("其他快捷键不变", () => {
    expect(appShortcut(press("F", { ctrl: true, shift: true }))).toBe("toggleFocus");
    expect(appShortcut(press("M", { ctrl: true, shift: true }))).toBe("toggleMulti");
    expect(appShortcut(press("k", { ctrl: true }))).toBe("toggleLink");
    expect(appShortcut(press("f", { ctrl: true }))).toBe("focusSearch");
    expect(appShortcut(press("l", { ctrl: true }))).toBe("clearLog");
    expect(appShortcut(press("s", { ctrl: true }))).toBe("saveLog");
    expect(appShortcut(press("k"))).toBeNull();
    expect(isBrowserShortcut(press("F5"))).toBe(true);
    expect(isBrowserShortcut(press("r", { ctrl: true }))).toBe(true);
    expect(isBrowserShortcut(press("a", { ctrl: true }))).toBe(false);
  });
});
