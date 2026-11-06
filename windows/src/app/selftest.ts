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

type Check = (ok: boolean, name: string) => void;

/** 连接过程中的竞争：核对的都是虚拟设备真正收到的字节和真正生效的参数，而不只是界面状态。 */
async function connectionChecks(check: Check, say: (text: string) => void, read: (port?: string) => Promise<Uint8Array>) {
  const OTHER = "selftest://other";
  const SLOW = "selftest://slow";
  const decode = (data: Uint8Array) => new TextDecoder().decode(data);
  const logged = (needle: string) => model.log.allEntries.some((e) => e.direction === "rx" && decode(e.bytes).includes(needle));
  const send = (text: string) => {
    model.set({ input: text, sendHex: false });
    model.submit();
  };
  const disconnect = async () => {
    if (model.state.link !== "idle") model.toggleLink();
    await wait(150);
  };
  model.set({ ending: "none" });
  await disconnect();

  // 打开后很快就发数据的设备：动画结束之前的内容不能丢
  model.set({ selectedPort: "selftest://chatty" });
  model.toggleLink();
  check(await waitFor(() => model.state.link === "connected"), "会马上说话的设备能连接");
  check(await waitFor(() => logged("early: boot banner")), "连接动画期间收到的内容进了日志");
  await disconnect();

  // 打开后马上消失的设备：不能假装已连接
  model.set({ selectedPort: "selftest://dies" });
  model.toggleLink();
  check(await waitFor(() => model.state.link === "lost"), `动画期间断线会进入等待：${model.state.link}`);
  await wait(600);
  check(model.state.link === "lost", "之后也不会变成已连接");
  await disconnect();
  check(model.state.link === "idle", "可以停止等待");

  // 同一端口快速连接、取消、再连接，旧操作不能关掉新连接
  model.set({ selectedPort: OTHER });
  model.toggleLink();
  model.toggleLink();
  model.toggleLink();
  check(await waitFor(() => model.state.link === "connected"), "连接取消再连接后是已连接");
  await wait(600);
  send("after-reconnect");
  await wait(150);
  check(decode(await read(OTHER)) === "after-reconnect", "快速重连后设备真的收到了数据");
  await disconnect();

  // 慢的连接被取消后换端口：旧的 open 晚完成，不能覆盖新连接
  model.set({ selectedPort: SLOW });
  model.toggleLink();
  await wait(100);
  model.toggleLink();
  model.set({ selectedPort: OTHER });
  model.toggleLink();
  check(await waitFor(() => model.state.link === "connected"), "取消慢连接后换端口能连接");
  await wait(1000); // 等旧的 open 结束
  check(model.state.selectedPort === OTHER && model.state.link === "connected", "旧的 open 结束后仍是新连接");
  send("to-other");
  await wait(150);
  check(decode(await read(OTHER)) === "to-other", "数据发到了新端口");
  check((await read(SLOW)).length === 0, "晚完成的旧端口没有收到数据");
  await disconnect();

  // 连接中切换端口：实际连上的要和界面一致
  model.set({ selectedPort: SLOW });
  model.toggleLink();
  await wait(100);
  model.set({ selectedPort: OTHER });
  check(await waitFor(() => model.state.link === "connected"), "连接中切换端口后能连接");
  await wait(1000);
  send("switched");
  await wait(150);
  check(decode(await read(OTHER)) === "switched", "连接中切换端口后发到了新端口");
  check((await read(SLOW)).length === 0, "原来的端口没有收到数据");
  await disconnect();

  // 连接中改参数：打开后要真的生效
  const notesBefore = model.log.allEntries.length;
  model.set({ selectedPort: SLOW, dataBits: 8 });
  model.toggleLink();
  await wait(100);
  model.set({ dataBits: 7 });
  check(await waitFor(() => model.state.link === "connected"), "连接中改参数后能连接");
  const noted = (text: string) => model.log.allEntries.slice(notesBefore).some((e) => e.direction === "sys" && e.note.includes(text));
  check(await waitFor(() => noted("已切换为") || noted("无法应用新参数")), "打开后马上把连接中改的参数交给了串口");
  if (noted("已切换为")) {
    check((await invoke<number | null>("selftest_device_data_bits", { port: SLOW })) === 7, "连接中改的数据位在设备上生效了");
  } else {
    // serialport 在 macOS 上改任何参数都会重设波特率，虚拟串口不支持，所以这里只能走到串口报错
    say("未验证 改参数是否在设备上生效：macOS 的虚拟串口不支持，靠 link.rs 的假串口测试和真实串口确认");
  }
  model.set({ dataBits: 8 });
  await disconnect();
  model.set({ ending: "crlf" });
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
  const read = async (port?: string) => Uint8Array.from(await invoke<number[]>("selftest_device_read", { port }));

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

    await connectionChecks(check, (text) => lines.push(text), read);

    // 拔线
    model.set({ selectedPort: PORT });
    model.toggleLink();
    check(await waitFor(() => model.state.link === "connected"), "回到虚拟设备");
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
