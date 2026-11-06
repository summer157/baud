import { Channel, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { DemoDevice } from "../core/demoDevice";

export const isNative = "__TAURI_INTERNALS__" in window;

export type PortKind = "demo" | "usb" | "other" | "system";

export interface PortInfo {
  path: string;
  name: string;
  detail: string;
  kind: PortKind;
}

export interface SerialConfig {
  baud: number;
  dataBits: number;
  stopBits: number;
  parity: "none" | "even" | "odd";
  flow: "none" | "rtsCts" | "xonXoff";
}

/**
 * 一次连接尝试。创建时就开始打开，opened 完成后才能确定打开成功，但这之前就可能收到数据。
 * 随时可以 close，打开途中也可以；close 之后这个对象的所有操作都不再影响任何串口。
 */
export interface Transport {
  opened: Promise<void>;
  write(data: Uint8Array): void;
  update(config: SerialConfig): Promise<void>;
  close(): void;
  demo?: DemoDevice;
}

export interface TransportEvents {
  onData(data: Uint8Array): void;
  onLost(): void;
}

export async function listPorts(): Promise<PortInfo[]> {
  return isNative ? invoke<PortInfo[]>("serial_ports") : [];
}

export function watchPorts(onChange: (ports: PortInfo[]) => void) {
  if (isNative) void listen<PortInfo[]>("ports-changed", (event) => onChange(event.payload));
}

const lostHandlers = new Map<number, () => void>();
if (isNative) {
  void listen<number>("serial-lost", (event) => lostHandlers.get(event.payload)?.());
}

/** 连接编号只增不减，后端靠它分辨过期操作。用时间打底，开发时刷新页面也不会倒退。 */
let lastConnectionId = Date.now();

export function openPort(path: string, config: SerialConfig, events: TransportEvents): Transport {
  if (path === DemoDevice.portId) {
    const demo = new DemoDevice((data) => events.onData(data));
    return {
      demo,
      opened: Promise.resolve(),
      write: (data) => demo.write(data),
      update: async () => {},
      close: () => demo.stop(),
    };
  }
  if (!isNative) {
    return {
      opened: Promise.reject(new Error("找不到这个设备，可能已被拔出")),
      write: () => {},
      update: async () => {},
      close: () => {},
    };
  }
  lastConnectionId += 1;
  const id = lastConnectionId;
  const channel = new Channel<ArrayBuffer>();
  channel.onmessage = (message) => events.onData(new Uint8Array(message));
  lostHandlers.set(id, events.onLost);
  let closed = false;
  return {
    opened: invoke<void>("serial_open", { id, path, config, onData: channel }).catch((error) => {
      throw new Error(String(error));
    }),
    write: (data) => {
      if (!closed) void invoke("serial_write", { id, data: Array.from(data) });
    },
    update: (next) => invoke<void>("serial_update", { id, config: next }),
    close: () => {
      if (closed) return;
      closed = true;
      lostHandlers.delete(id);
      void invoke("serial_close", { id });
    },
  };
}

export async function saveTextFile(defaultName: string, text: string): Promise<string | null> {
  if (!isNative) {
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    link.download = defaultName;
    link.click();
    URL.revokeObjectURL(link.href);
    return defaultName;
  }
  const { save } = await import("@tauri-apps/plugin-dialog");
  const path = await save({ defaultPath: defaultName, filters: [{ name: "日志", extensions: ["log", "txt"] }] });
  if (!path) return null;
  await invoke("write_text_file", { path, text });
  return path;
}
