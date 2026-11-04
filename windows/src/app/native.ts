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

export interface Transport {
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

const lostIds = new Set<number>();
const lostHandlers = new Map<number, () => void>();
if (isNative) {
  void listen<number>("serial-lost", (event) => {
    const handler = lostHandlers.get(event.payload);
    if (handler) handler();
    else lostIds.add(event.payload);
  });
}

export async function openPort(path: string, config: SerialConfig, events: TransportEvents): Promise<Transport> {
  if (path === DemoDevice.portId) {
    const demo = new DemoDevice((data) => events.onData(data));
    return {
      demo,
      write: (data) => demo.write(data),
      update: async () => {},
      close: () => demo.stop(),
    };
  }
  if (!isNative) throw new Error("找不到这个设备，可能已被拔出");
  const channel = new Channel<ArrayBuffer>();
  channel.onmessage = (message) => events.onData(new Uint8Array(message));
  let id: number;
  try {
    id = await invoke<number>("serial_open", { path, config, onData: channel });
  } catch (error) {
    throw new Error(String(error));
  }
  if (lostIds.delete(id)) queueMicrotask(events.onLost);
  else lostHandlers.set(id, events.onLost);
  return {
    write: (data) => void invoke("serial_write", { data: Array.from(data) }),
    update: (next) => invoke<void>("serial_update", { config: next }),
    close: () => {
      lostHandlers.delete(id);
      void invoke("serial_close");
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
