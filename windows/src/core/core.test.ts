import { describe, expect, it, vi } from "vitest";
import { checksumValue, NO_CHECKSUM, trailerFor, withKind, type ChecksumKind } from "./checksum";
import { displayText, encodeText, frameBytes, hexString, isProblem, makeFrame, parseHex, type OutgoingFrame } from "./codec";
import { DemoDevice } from "./demoDevice";
import { LineAssembler } from "./lineAssembler";
import { isBlank, MultiSendModel, newItem, type MultiSendHost, type SendItem } from "./multiSend";

const bytes = (...values: number[]) => Uint8Array.from(values);
const utf8 = (text: string) => new TextEncoder().encode(text);
const text = (data: Uint8Array) => new TextDecoder().decode(data);
const setting = (kind: ChecksumKind, startByte = 1) => withKind({ ...NO_CHECKSUM, startByte }, kind);

describe("十六进制", () => {
  it("解析和格式化", () => {
    expect(parseHex("AA 55 01 ff")).toEqual(bytes(0xaa, 0x55, 0x01, 0xff));
    expect(parseHex("0xAA,0x55")).toEqual(bytes(0xaa, 0x55));
    expect(parseHex("ABC")).toBeNull();
    expect(parseHex("GG")).toBeNull();
    expect(parseHex("   ")).toBeNull();
    expect(hexString(bytes(0x00, 0x0f, 0xa5))).toBe("00 0F A5");
  });
});

describe("分行", () => {
  const lines = (a: LineAssembler, input: string) => a.feed(utf8(input)).map(text);

  it("和 Mac 版的切分规则一致", () => {
    const a = new LineAssembler();
    expect(lines(a, "a\nb\r\nc\r")).toEqual(["a\n", "b\r\n"]);
    expect(lines(a, "\nd")).toEqual(["c\r\n"]);
    expect(text(a.flush()!)).toBe("d");
    expect(lines(a, "x\ry\r\n")).toEqual(["x\r", "y\r\n"]);
    a.flush();
    expect(new LineAssembler(4).feed(utf8("abcdefgh")).length).toBe(2);
  });
});

describe("编码", () => {
  it("GBK 和 UTF-8", () => {
    expect(encodeText("状态", "gbk")).toEqual(bytes(0xd7, 0xb4, 0xcc, 0xac));
    expect(displayText(bytes(0xd7, 0xb4, 0xcc, 0xac, 0x0d, 0x0a), "gbk")).toBe("状态");
    expect(displayText(utf8("\u001b[32mok\u001b[0m\r\n"), "utf8")).toBe("ok");
    expect(displayText(bytes(0x41, 0xff, 0x42), "gbk")).toContain("A");
    expect(displayText(encodeText("€𝄞中", "gbk"), "gbk")).toBe("€𝄞中");
  });
});

describe("校验", () => {
  const vector = utf8("123456789");
  it.each<[ChecksumKind, number]>([
    ["modbusCRC16", 0x4b37],
    ["ccittCRC16", 0x29b1],
    ["crc32", 0xcbf43926],
    ["add8", 0xdd],
    ["zeroAdd8", 0x23],
    ["xor8", 0x31],
    ["add16", 0x01dd],
  ])("%s 标准值", (kind, value) => expect(checksumValue(kind, vector)).toBe(value));

  it("00～FF 的 CRC32 和 Mac 版、zlib 一致", () => {
    const all = Uint8Array.from({ length: 256 }, (_, i) => i);
    expect(trailerFor(setting("crc32"), all)).toEqual(bytes(0x29, 0x05, 0x8c, 0x73));
  });

  it("字节序和起始字节", () => {
    expect(trailerFor(setting("modbusCRC16"), bytes(1, 3, 0, 0, 0, 0x0a))).toEqual(bytes(0xc5, 0xcd));
    expect(trailerFor(setting("ccittCRC16"), vector)).toEqual(bytes(0x29, 0xb1));
    expect(trailerFor(setting("crc32"), vector)).toEqual(bytes(0xcb, 0xf4, 0x39, 0x26));
    expect(trailerFor({ ...setting("ccittCRC16"), lowFirst: true }, vector)).toEqual(bytes(0xb1, 0x29));
    expect(withKind({ ...setting("ccittCRC16"), lowFirst: false }, "modbusCRC16").lowFirst).toBe(true);
    expect(trailerFor(setting("add8", 3), bytes(0xaa, 0x55, 1, 2))).toEqual(bytes(3));
    expect(trailerFor(setting("add8", 5), bytes(1, 2))).toBeNull();
    expect(trailerFor(NO_CHECKSUM, vector)).toEqual(bytes());
  });

  it("一帧的组成", () => {
    const options = { encoding: "utf8", ending: "crlf", checksum: setting("add8") } as const;
    expect(frameBytes(makeFrame("12", false, options) as OutgoingFrame)).toEqual(bytes(0x31, 0x32, 0x63, 0x0d, 0x0a));
    expect(frameBytes(makeFrame("01 02", true, options) as OutgoingFrame)).toEqual(bytes(1, 2, 3));
    const gb = makeFrame("状", false, { ...options, encoding: "gbk", checksum: setting("xor8") }) as OutgoingFrame;
    expect(gb.trailer).toEqual(bytes(0xd7 ^ 0xb4));
    const bad = makeFrame("ABC", true, options);
    expect(isProblem(bad) && bad.kind).toBe("badHex");
    const short = makeFrame("1", false, { ...options, checksum: setting("add8", 5) });
    expect(isProblem(short) && short.kind).toBe("tooShort");
  });
});

class Run {
  sent: string[] = [];
  model: MultiSendModel;
  saved = 0;

  constructor(rows: string[], loop = false) {
    const host: MultiSendHost = {
      check: () => null,
      send: (item) => {
        this.sent.push(item.text);
        return null;
      },
      onStart: () => {},
      save: () => {
        this.saved += 1;
      },
    };
    this.model = new MultiSendModel(host, rows.map((t) => newItem({ text: t, delay: "70" })), loop);
  }

  remove(name: string) {
    this.model.items = this.model.items.filter((i) => i.text !== name);
  }

  /** 推进到已发送 count 条。 */
  advanceTo(count: number) {
    for (let i = 0; i < 200 && this.sent.length < count; i++) vi.advanceTimersByTime(10);
  }

  finish() {
    vi.advanceTimersByTime(5000);
  }
}

describe("多条发送：发送途中改列表", () => {
  const add = (name: string): SendItem => newItem({ text: name, delay: "70" });
  const scenarios: [string, string[], string[], (run: Run) => void][] = [
    ["普通顺序", ["A", "B", "C"], ["A", "B", "C"], () => {}],
    ["发完最后一条立刻停", ["A"], ["A"], () => {}],
    ["删掉当前条目，接着发它的后继", ["A", "B", "C"], ["A", "B", "C"], (r) => r.remove("A")],
    ["先删更早的再删当前条目", ["A", "B", "C", "D"], ["A", "B", "C", "D"], (r) => {
      r.advanceTo(3);
      r.remove("A");
      r.remove("C");
    }],
    ["连续删当前条目和它的后继", ["A", "B", "C"], ["A", "C"], (r) => {
      r.remove("A");
      r.remove("B");
    }],
    ["一次赋值删掉当前条目和后继", ["A", "B", "C", "D"], ["A", "C", "D"], (r) => {
      r.model.items = r.model.items.filter((i) => i.text !== "A" && i.text !== "B");
    }],
    ["后继被移走后，游标跟着后继", ["A", "B", "C", "D"], ["A", "B", "C"], (r) => {
      r.remove("A");
      r.model.moveTo(2, 0);
    }],
    ["排序后再删当前条目", ["A", "B", "C", "D"], ["A", "C", "B", "D"], (r) => {
      r.model.moveTo(2, 1);
      r.remove("A");
    }],
    ["删掉当前条目后，末尾新加的会发", ["A", "B", "C"], ["A", "B", "D"], (r) => {
      r.advanceTo(2);
      r.remove("B");
      r.remove("C");
      r.model.items = [...r.model.items, add("D")];
    }],
    ["全部删光后加一条，从新条目继续", ["A", "B"], ["A", "C"], (r) => {
      r.remove("A");
      r.remove("B");
      r.model.items = [...r.model.items, add("C")];
    }],
    ["删光后正常停止", ["A", "B"], ["A"], (r) => {
      r.model.items = [];
    }],
    ["整表换成新条目，从新列表第一条继续", ["A", "B"], ["A", "X", "Y"], (r) => {
      r.model.items = [add("X"), add("Y")];
    }],
    ["取消勾选待发的条目", ["A", "B", "C"], ["A", "C"], (r) => r.model.update(r.model.items[1].id, { enabled: false })],
    ["在当前条目后面插入", ["A", "C"], ["A", "B", "C"], (r) => {
      r.model.items = [r.model.items[0], add("B"), r.model.items[1]];
    }],
    ["发送前改内容，发的是新内容", ["A", "B"], ["A", "B2"], (r) => r.model.update(r.model.items[1].id, { text: "B2" })],
  ];

  it.each(scenarios)("%s", (_name, rows, expected, change) => {
    vi.useFakeTimers();
    const run = new Run(rows);
    run.model.start();
    change(run);
    run.finish();
    expect(run.sent).toEqual(expected);
    expect(run.model.running).toBe(false);
    vi.useRealTimers();
  });
});

describe("多条发送：循环和轮数", () => {
  it("查看下一条不会推进轮数，每回到开头只加一轮", () => {
    vi.useFakeTimers();
    const run = new Run(["A", "B"], true);
    run.model.start();
    run.advanceTo(2);
    expect(run.model.round).toBe(1);
    run.advanceTo(3);
    expect(run.model.round).toBe(2);
    run.advanceTo(5);
    expect(run.model.round).toBe(3);
    run.model.stop();
    expect(run.sent).toEqual(["A", "B", "A", "B", "A"]);

    const single = new Run(["A"], true);
    single.model.start();
    single.advanceTo(3);
    expect(single.model.round).toBe(3);
    single.model.stop();
    vi.useRealTimers();
  });

  it("循环时删掉最后一条或第一条", () => {
    vi.useFakeTimers();
    const tail = new Run(["A", "B", "C"], true);
    tail.model.start();
    tail.advanceTo(3);
    tail.remove("C");
    tail.advanceTo(4);
    expect(tail.model.round).toBe(2);
    tail.advanceTo(5);
    expect(tail.model.round).toBe(2);
    tail.advanceTo(6);
    tail.model.stop();
    expect(tail.sent).toEqual(["A", "B", "C", "A", "B", "A"]);

    const first = new Run(["A", "B", "C"], true);
    first.model.start();
    first.remove("A");
    first.advanceTo(4);
    first.model.stop();
    expect(first.sent).toEqual(["A", "B", "C", "B"]);
    expect(first.model.round).toBe(2);
    vi.useRealTimers();
  });

  it("停止后不再发送；有错的条目不开始；移动到头不动", () => {
    vi.useFakeTimers();
    const stopped = new Run(["A", "B"]);
    stopped.model.start();
    stopped.model.stop();
    stopped.remove("A");
    stopped.finish();
    expect(stopped.sent).toEqual(["A"]);

    const blank = newItem({ text: "  " });
    expect(isBlank(blank)).toBe(true);

    const items = [newItem({ text: "A" }), newItem({ hex: true, text: "ABC" })];
    const sent: string[] = [];
    const strict = new MultiSendModel({
      check: (i) => (i.hex ? { kind: "badHex" } : null),
      send: (i) => {
        sent.push(i.text);
        return null;
      },
      onStart: () => {},
      save: () => {},
    }, items, false);
    strict.start();
    expect(strict.running).toBe(false);
    expect(sent).toEqual([]);
    expect(strict.failure?.id).toBe(items[1].id);
    strict.update(items[1].id, { text: "ABCD" });
    expect(strict.failure).toBeNull();

    strict.moveBy(items[0].id, -1);
    expect(strict.items[0].id).toBe(items[0].id);
    strict.moveBy(items[0].id, 1);
    expect(strict.items[1].id).toBe(items[0].id);
    vi.useRealTimers();
  });
});

describe("演示设备", () => {
  it("回复指令并发送启动信息", () => {
    vi.useFakeTimers();
    let out = "";
    const device = new DemoDevice((d) => (out += text(d)));
    device.start();
    expect(out).toContain("boot: firmware");
    out = "";
    device.write(utf8("AT+GMR\r\n"));
    expect(out).toBe("v2.4.1\r\nOK\r\n");
    out = "";
    device.write(utf8("oops\r\n"));
    expect(out).toContain("ERR");
    device.stop();
    vi.useRealTimers();
  });
});
