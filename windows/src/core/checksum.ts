export type ChecksumKind = "none" | "modbusCRC16" | "ccittCRC16" | "crc32" | "zeroAdd8" | "add8" | "xor8" | "add16";

export const CHECKSUM_KINDS: ChecksumKind[] = ["none", "modbusCRC16", "ccittCRC16", "crc32", "zeroAdd8", "add8", "xor8", "add16"];

export const CHECKSUM_INFO: Record<ChecksumKind, { title: string; detail: string; width: number }> = {
  none: { title: "不加", detail: "发送的内容保持原样", width: 0 },
  modbusCRC16: { title: "ModbusCRC16", detail: "多项式 0x8005 反射，初值 0xFFFF", width: 2 },
  ccittCRC16: { title: "CCITT-CRC16", detail: "CCITT-FALSE：多项式 0x1021，初值 0xFFFF", width: 2 },
  crc32: { title: "CRC32", detail: "IEEE 802.3：多项式 0x04C11DB7 反射，初值和结果异或 0xFFFFFFFF", width: 4 },
  zeroAdd8: { title: "0-ADD8", detail: "所有字节相加取低 8 位，再用 0 减去它", width: 1 },
  add8: { title: "ADD8", detail: "所有字节相加，取低 8 位", width: 1 },
  xor8: { title: "XOR8", detail: "所有字节依次异或", width: 1 },
  add16: { title: "ADD16", detail: "所有字节相加，取低 16 位", width: 2 },
};

export function checksumValue(kind: ChecksumKind, bytes: Uint8Array): number {
  switch (kind) {
    case "none":
      return 0;
    case "modbusCRC16": {
      let crc = 0xffff;
      for (const byte of bytes) {
        crc ^= byte;
        for (let i = 0; i < 8; i++) crc = crc & 1 ? (crc >>> 1) ^ 0xa001 : crc >>> 1;
      }
      return crc;
    }
    case "ccittCRC16": {
      let crc = 0xffff;
      for (const byte of bytes) {
        crc ^= byte << 8;
        for (let i = 0; i < 8; i++) crc = (crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
      }
      return crc;
    }
    case "crc32": {
      let crc = 0xffffffff;
      for (const byte of bytes) {
        crc ^= byte;
        for (let i = 0; i < 8; i++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
      }
      return (~crc) >>> 0;
    }
    case "zeroAdd8":
      return (0x100 - (sum(bytes) & 0xff)) & 0xff;
    case "add8":
      return sum(bytes) & 0xff;
    case "xor8":
      return bytes.reduce((a, b) => a ^ b, 0);
    case "add16":
      return sum(bytes) & 0xffff;
  }
}

function sum(bytes: Uint8Array): number {
  let total = 0;
  for (const byte of bytes) total = (total + byte) & 0xffff;
  return total;
}

export interface ChecksumSetting {
  kind: ChecksumKind;
  /** 从第几个字节开始算，从 1 起数，用来跳过帧头。 */
  startByte: number;
  lowFirst: boolean;
}

export const NO_CHECKSUM: ChecksumSetting = { kind: "none", startByte: 1, lowFirst: false };

/** Modbus 规定低字节在前，其余默认高字节在前。换算法时字节序回到默认值。 */
export function withKind(setting: ChecksumSetting, kind: ChecksumKind): ChecksumSetting {
  return kind === setting.kind ? setting : { ...setting, kind, lowFirst: kind === "modbusCRC16" };
}

/** 要追加在内容后面的校验字节。内容够不到起始字节时返回 null。 */
export function trailerFor(setting: ChecksumSetting, body: Uint8Array): Uint8Array | null {
  if (setting.kind === "none") return new Uint8Array();
  if (body.length < setting.startByte) return null;
  const value = checksumValue(setting.kind, body.subarray(setting.startByte - 1));
  const width = CHECKSUM_INFO[setting.kind].width;
  const out = new Uint8Array(width);
  for (let i = 0; i < width; i++) {
    const byte = Math.floor(value / 2 ** (8 * (width - 1 - i))) & 0xff;
    out[setting.lowFirst ? width - 1 - i : i] = byte;
  }
  return out;
}
