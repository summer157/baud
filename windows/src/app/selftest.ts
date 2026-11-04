import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { isNative, model } from "./model";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const PORT = "selftest://pair";

async function waitFor(condition: () => boolean, ms = 3000): Promise<boolean> {
  const end = performance.now() + ms;
  while (performance.now() < end) {
    if (condition()) return true;
    await wait(20);
  }
  return condition();
}

/** 开发用自检：只在设置了环境变量 BAUD_SELFTEST 的 macOS 版里运行，见 src-tauri/src/selftest.rs。 */
export async function runSelfTestIfRequested() {
  if (!isNative) return;
  let path: string | null = null;
  try {
    path = await invoke<string | null>("selftest_path");
  } catch {
    return; // Windows 版没有这个命令
  }
  if (!path) return;

  const lines: string[] = [];
  let failures = 0;
  const check = (ok: boolean, name: string) => {
    lines.push(`${ok ? "通过" : "失败"} ${name}`);
    if (!ok) failures += 1;
  };
  const rows = () => model.log.allEntries;
  const text = (data: Uint8Array) => new TextDecoder().decode(data);
  const read = async () => Uint8Array.from(await invoke<number[]>("selftest_device_read"));

  try {
    await wait(800);
    const image = document.querySelector<HTMLImageElement>(".card");
    check(!!image && image.complete && image.naturalWidth > 0, `正式包里能加载贴纸，宽 ${image?.naturalWidth}`);
    check(getComputedStyle(document.body).backgroundColor !== "rgba(0, 0, 0, 0)", "内容安全策略没有挡住样式");

    // 外观：点界面上的按钮，页面和原生窗口都要跟着变，不受系统设置影响
    const win = getCurrentWindow();
    const pick = (name: string) => document.querySelector<HTMLElement>(`[aria-label="外观：${name}"]`)!.click();
    const paper = () => getComputedStyle(document.documentElement).getPropertyValue("--paper").trim();
    const savedTheme = () => JSON.parse(localStorage.getItem("baud.settings") ?? "{}").theme;
    for (const [name, theme, color] of [["深色", "dark", "#211915"], ["浅色", "light", "#FFF8EC"]] as const) {
      pick(name);
      await wait(300);
      check(document.documentElement.dataset.theme === theme && paper() === color, `选${name}后页面配色正确：${paper()}`);
      check((await win.theme()) === theme, `选${name}后原生窗口也是${name}`);
      check(savedTheme() === theme, `${name}已保存`);
    }
    pick("跟随系统");
    await wait(300);
    const systemTheme = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    check(document.documentElement.dataset.theme === systemTheme && (await win.theme()) === systemTheme, `回到跟随系统：${systemTheme}`);

    const ports = await invoke<{ path: string; name: string; kind: string }[]>("serial_ports");
    check(ports.length >= 0, `能列出系统串口：${ports.map((p) => p.name).join("、") || "无"}`);

    // 不存在的端口
    model.set({ selectedPort: "/dev/cu.baud-does-not-exist" });
    model.toggleLink();
    check(await waitFor(() => model.state.lastError !== null), `打不开时提示：${model.state.lastError}`);
    check(model.state.link === "idle" && (model.state.lastError ?? "").includes("找不到"), "回到未连接，提示能看懂");

    // 通过真实的 Rust 层连接虚拟设备
    model.set({ selectedPort: PORT, sendHex: false, ending: "crlf", encoding: "utf8" });
    model.setChecksumKind("none");
    model.toggleLink();
    check(await waitFor(() => model.state.link === "connected"), "连接虚拟设备成功");
    check(model.state.lastError === null, "错误提示已清除");

    await invoke("selftest_device_write", { data: Array.from(new TextEncoder().encode("boot: ok\r\n状态: 运行正常\r\n")) });
    check(await waitFor(() => rows().some((e) => e.direction === "rx" && text(e.bytes).includes("运行正常"))), "收到设备发来的中文");
    check(model.stats.rx > 0, `RX 统计在工作：${model.stats.rx}`);

    // 全部 256 个字节值，确认通道传的是原始字节
    const all = Uint8Array.from({ length: 256 }, (_, i) => i);
    const before = model.stats.rx;
    await invoke("selftest_device_write", { data: Array.from(all) });
    check(await waitFor(() => model.stats.rx - before >= 256), `二进制数据没有被改动大小：${model.stats.rx - before}`);

    // 发送
    model.set({ input: "AT+GMR" });
    model.submit();
    await wait(150);
    check(text(await read()) === "AT+GMR\r\n", "文本和行尾发到了设备");
    model.setChecksumKind("modbusCRC16");
    model.set({ sendHex: true, input: "01 03 00 00 00 0A" });
    check(model.checksumPreview === "C5 CD", `校验预览：${model.checksumPreview}`);
    model.submit();
    await wait(150);
    check(Array.from(await read()).join() === [1, 3, 0, 0, 0, 10, 0xc5, 0xcd].join(), "带 Modbus 校验的 HEX 帧发到了设备");
    model.setChecksumKind("none");
    model.set({ sendHex: false });

    // 多条发送走同一条通道
    model.multi.items = ["A", "B"].map((t, i) => ({ id: `t${i}`, enabled: true, hex: false, text: t, note: "", delay: "60" }));
    model.multi.start();
    check(await waitFor(() => !model.multi.running), "依次发送结束");
    await wait(100);
    check(text(await read()) === "A\r\nB\r\n", "依次发送的内容和顺序正确");

    // 保存日志
    const logPath = `${path}.log`;
    await invoke("write_text_file", { path: logPath, text: model.log.exportText(true) });
    check(true, "能写入日志文件");

    // 高速接收
    const rx0 = model.stats.rx;
    const payload = Array.from(new TextEncoder().encode("data seq=1 adc=[1, 2, 3] ok\r\n".repeat(150)));
    const started = performance.now();
    for (let i = 0; i < 80; i++) await invoke("selftest_device_write", { data: payload });
    const expected = payload.length * 80;
    check(await waitFor(() => model.stats.rx - rx0 >= expected, 8000), `高速接收不丢数据：${model.stats.rx - rx0} / ${expected}`);
    lines.push(`高速接收速度约 ${Math.round((model.stats.rx - rx0) / ((performance.now() - started) / 1000) / 1024)} KB/s`);

    // 拔线
    await invoke("selftest_unplug");
    check(await waitFor(() => model.state.link === "lost"), `拔出后进入等待状态：${model.state.link}`);
    model.toggleLink();
    await wait(200);
    check(model.state.link === "idle", "可以停止等待");

    // 关闭后能再次打开
    model.toggleLink();
    check(await waitFor(() => model.state.link === "connected"), "关闭后能重新连接");
    model.toggleLink();
    await wait(300);
    check(model.state.link === "idle", "可以主动断开");
  } catch (error) {
    check(false, `中途出错：${String(error)}`);
  }
  lines.push(failures === 0 ? "全部通过" : `有 ${failures} 项失败`);
  await invoke("selftest_finish", { report: lines.join("\n") + "\n", code: failures === 0 ? 0 : 1 });
}
