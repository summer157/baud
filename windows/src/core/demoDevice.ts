const encoder = new TextEncoder();

/** 内置的假设备，没有硬件时也能试用完整流程。 */
export class DemoDevice {
  static readonly portId = "demo://device";

  private ticker: ReturnType<typeof setInterval> | null = null;
  private flood: ReturnType<typeof setInterval> | null = null;
  private command: number[] = [];
  private tick = 0;
  private seq = 128;
  private stopped = false;

  constructor(private readonly emit: (data: Uint8Array) => void) {}

  start() {
    this.ticker = setInterval(() => this.telemetry(), 650);
    this.send(["boot: firmware v2.4.1", "boot: flash ok, 4096 KB", "wifi: connected, ip 192.168.1.42", "状态: 运行正常"]);
  }

  stop() {
    this.stopped = true;
    if (this.ticker !== null) clearInterval(this.ticker);
    if (this.flood !== null) clearInterval(this.flood);
  }

  write(data: Uint8Array) {
    for (const byte of data) {
      if (byte === 0x0a || byte === 0x0d) {
        if (this.command.length) this.respond(new TextDecoder().decode(Uint8Array.from(this.command)));
        this.command = [];
      } else {
        this.command.push(byte);
      }
    }
  }

  /** 打开或关闭高速数据，用来压测界面。 */
  setFlood(bytesPerSecond: number) {
    if (this.flood !== null) clearInterval(this.flood);
    this.flood = null;
    if (bytesPerSecond <= 0 || this.stopped) return;
    const interval = 16;
    const budget = (bytesPerSecond * interval) / 1000;
    this.flood = setInterval(() => {
      let text = "";
      while (text.length < budget) {
        this.seq += 1;
        const s = this.seq;
        text += `data seq=${s} adc=[${s % 4096}, ${(s * 7) % 4096}, ${(s * 13) % 4096}] ok\r\n`;
      }
      this.emit(encoder.encode(text));
    }, interval);
  }

  private telemetry() {
    this.tick += 1;
    const t = this.tick;
    if (t % 13 === 0) {
      this.send(["状态: 运行正常"]);
    } else if (t % 11 === 0) {
      this.send([`wifi: rssi=-${52 + (t % 9)} dBm`]);
    } else if (t % 5 === 0) {
      this.seq += 1;
      this.send([`heartbeat seq=${this.seq}`]);
    } else {
      const temp = (24.4 + Math.random() * 0.6).toFixed(1);
      const volt = (3.69 + Math.random() * 0.03).toFixed(2);
      this.send([`sensor temp=${temp}C hum=${47 + Math.floor(Math.random() * 3)}% vbat=${volt}V`]);
    }
  }

  private respond(line: string) {
    switch (line.trim().toLowerCase()) {
      case "at":
        return this.send(["OK"]);
      case "at+gmr":
        return this.send(["v2.4.1", "OK"]);
      case "status":
        return this.send(["状态: 运行正常", "uptime 01:24:36", "OK"]);
      case "reset":
        return this.send(["rebooting...", "boot: firmware v2.4.1", "boot: flash ok, 4096 KB"]);
      default:
        return this.send(["ERR unknown command"]);
    }
  }

  private send(lines: string[]) {
    if (!this.stopped) this.emit(encoder.encode(lines.map((l) => l + "\r\n").join("")));
  }
}
