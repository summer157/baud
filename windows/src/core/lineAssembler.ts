/** 把收到的字节流切成行。支持 LF、CR、CRLF，长时间没有换行时可以用 flush 取走残留内容。 */
export class LineAssembler {
  private buffer: Uint8Array;
  private length = 0;
  private pendingCR = false;

  constructor(private readonly maxLineLength = 4096) {
    this.buffer = new Uint8Array(maxLineLength + 2);
  }

  get hasPartial(): boolean {
    return this.length > 0;
  }

  private take(): Uint8Array {
    const line = this.buffer.slice(0, this.length);
    this.length = 0;
    return line;
  }

  feed(data: Uint8Array): Uint8Array[] {
    const lines: Uint8Array[] = [];
    for (let i = 0; i < data.length; i++) {
      const byte = data[i];
      if (this.pendingCR) {
        this.pendingCR = false;
        if (byte === 0x0a) {
          this.buffer[this.length++] = byte;
          lines.push(this.take());
          continue;
        }
        lines.push(this.take());
      }
      this.buffer[this.length++] = byte;
      if (byte === 0x0d) {
        this.pendingCR = true;
      } else if (byte === 0x0a || this.length >= this.maxLineLength) {
        lines.push(this.take());
      }
    }
    return lines;
  }

  flush(): Uint8Array | null {
    this.pendingCR = false;
    return this.length > 0 ? this.take() : null;
  }
}
