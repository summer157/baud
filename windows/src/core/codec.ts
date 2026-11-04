import { trailerFor, type ChecksumSetting } from "./checksum";

export type TextEncodingChoice = "utf8" | "gbk";
export type LineEnding = "none" | "cr" | "lf" | "crlf";

export const LINE_ENDINGS: { id: LineEnding; title: string; text: string }[] = [
  { id: "none", title: "无行尾", text: "" },
  { id: "cr", title: "CR", text: "\r" },
  { id: "lf", title: "LF", text: "\n" },
  { id: "crlf", title: "CRLF", text: "\r\n" },
];

const utf8Decoder = new TextDecoder("utf-8");
const gbDecoder = new TextDecoder("gb18030");
const utf8Encoder = new TextEncoder();

/** 解析十六进制文本，允许空格、逗号和 0x 前缀。格式不对时返回 null。 */
export function parseHex(text: string): Uint8Array | null {
  const digits = text.replace(/0x/gi, "").replace(/[\s,]/g, "");
  if (!digits || digits.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(digits)) return null;
  const out = new Uint8Array(digits.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(digits.substr(i * 2, 2), 16);
  return out;
}

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).toUpperCase().padStart(2, "0"));

export function hexString(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += (i ? " " : "") + HEX[bytes[i]];
  return out;
}

let gbTable: Map<number, number[]> | null = null;

/** 浏览器只提供 GB18030 的解码，编码表用解码结果反推出来，第一次用到 GBK 时才生成。 */
function buildGbTable(): Map<number, number[]> {
  const table = new Map<number, number[]>();
  const decoder = new TextDecoder("gb18030", { fatal: true });
  const add = (seq: number[]) => {
    try {
      const text = decoder.decode(Uint8Array.from(seq));
      const cp = text.codePointAt(0);
      if (cp !== undefined && !table.has(cp)) table.set(cp, seq);
    } catch {
      // 这个编码位没有对应的字符
    }
  };
  for (let lead = 0x81; lead <= 0xfe; lead++) {
    for (let trail = 0x40; trail <= 0xfe; trail++) if (trail !== 0x7f) add([lead, trail]);
  }
  for (let a = 0x81; a <= 0x84; a++) {
    for (let b = 0x30; b <= 0x39; b++) {
      for (let c = 0x81; c <= 0xfe; c++) {
        for (let d = 0x30; d <= 0x39; d++) add([a, b, c, d]);
      }
    }
  }
  return table;
}

function encodeGb18030(text: string): Uint8Array {
  gbTable ??= buildGbTable();
  const out: number[] = [];
  for (const char of text) {
    const cp = char.codePointAt(0)!;
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp >= 0x10000) {
      // 增补平面在 GB18030 里是连续排列的
      let n = cp - 0x10000;
      const d = n % 10;
      n = Math.floor(n / 10);
      const c = n % 126;
      n = Math.floor(n / 126);
      const b = n % 10;
      n = Math.floor(n / 10);
      out.push(0x90 + n, 0x30 + b, 0x81 + c, 0x30 + d);
    } else {
      out.push(...(gbTable.get(cp) ?? [0x3f]));
    }
  }
  return Uint8Array.from(out);
}

export function encodeText(text: string, encoding: TextEncodingChoice): Uint8Array {
  return encoding === "utf8" ? utf8Encoder.encode(text) : encodeGb18030(text);
}

/** 把一行字节变成可显示的文字：按编码解码，去掉 ANSI 转义和控制字符。 */
export function displayText(bytes: Uint8Array, encoding: TextEncodingChoice): string {
  const decoded = (encoding === "utf8" ? utf8Decoder : gbDecoder).decode(bytes);
  // eslint-disable-next-line no-control-regex
  if (!/[\x00-\x1f\x7f]/.test(decoded)) return decoded;
  // eslint-disable-next-line no-control-regex
  return decoded.replace(/\x1b(?:\[[^\x40-\x7e]*[\x40-\x7e]?)?/g, "").replace(/[\x00-\x08\x0a-\x1f\x7f]/g, "");
}

/** 一帧要发出去的数据：内容、校验、行尾。校验只覆盖内容，不含行尾。 */
export interface OutgoingFrame {
  body: Uint8Array;
  trailer: Uint8Array;
  ending: Uint8Array;
}

export type SendProblem = { kind: "offline" } | { kind: "badHex" } | { kind: "tooShort"; startByte: number };

export function problemMessage(problem: SendProblem): string {
  switch (problem.kind) {
    case "offline":
      return "还没有连接";
    case "badHex":
      return "HEX 需要成对的 0-9、A-F";
    case "tooShort":
      return `校验从第 ${problem.startByte} 字节算起，内容不够长`;
  }
}

export interface FrameOptions {
  encoding: TextEncodingChoice;
  ending: LineEnding;
  checksum: ChecksumSetting;
}

export function makeFrame(text: string, hex: boolean, options: FrameOptions): OutgoingFrame | SendProblem {
  let body: Uint8Array;
  if (hex) {
    const parsed = parseHex(text);
    if (!parsed) return { kind: "badHex" };
    body = parsed;
  } else {
    body = encodeText(text, options.encoding);
  }
  const trailer = trailerFor(options.checksum, body);
  if (!trailer) return { kind: "tooShort", startByte: options.checksum.startByte };
  const ending = hex ? "" : LINE_ENDINGS.find((e) => e.id === options.ending)!.text;
  return { body, trailer, ending: utf8Encoder.encode(ending) };
}

export function isProblem(result: OutgoingFrame | SendProblem): result is SendProblem {
  return "kind" in result;
}

export function frameBytes(frame: OutgoingFrame): Uint8Array {
  const out = new Uint8Array(frame.body.length + frame.trailer.length + frame.ending.length);
  out.set(frame.body);
  out.set(frame.trailer, frame.body.length);
  out.set(frame.ending, frame.body.length + frame.trailer.length);
  return out;
}
