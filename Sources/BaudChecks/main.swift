import BaudCore
import Darwin
import Foundation

// 核心逻辑自检：swift run BaudChecks
var failures = 0

func check(_ condition: Bool, _ name: String) {
    print((condition ? "  通过  " : "  失败  ") + name)
    if !condition { failures += 1 }
}

func wait(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

print("十六进制")
check(Codec.parseHex("AA 55 01 ff") == Data([0xAA, 0x55, 0x01, 0xFF]), "带空格和小写")
check(Codec.parseHex("0xAA,0x55") == Data([0xAA, 0x55]), "0x 前缀和逗号")
check(Codec.parseHex("ABC") == nil, "奇数位被拒绝")
check(Codec.parseHex("GG") == nil, "非法字符被拒绝")
check(Codec.parseHex("   ") == nil, "空内容被拒绝")
check(Codec.hexString(Data([0x00, 0x0F, 0xA5])) == "00 0F A5", "格式化输出")

print("分行")
var assembler = LineAssembler()
check(assembler.feed(Data("a\nb\r\nc\r".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["a\n", "b\r\n"], "LF 和 CRLF")
check(assembler.feed(Data("\nd".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["c\r\n"], "跨包的 CRLF 不会多分一行")
check(assembler.flush().map { String(decoding: $0, as: UTF8.self) } == "d", "flush 取走残留")
check(assembler.feed(Data("x\ry\r\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["x\r", "y\r\n"], "单独的 CR 也算换行")
_ = assembler.flush()
var short = LineAssembler(maxLineLength: 4)
check(short.feed(Data("abcdefgh".utf8)).count == 2, "超长内容会被切开")

print("编码")
let gbk = Codec.encode("状态", encoding: .gbk, ending: .crlf)
check(gbk == Data([0xD7, 0xB4, 0xCC, 0xAC, 0x0D, 0x0A]), "GBK 编码和行尾")
check(Codec.displayText(gbk, encoding: .gbk) == "状态", "GBK 解码去掉行尾")
check(Codec.displayText(Data("\u{1B}[32mok\u{1B}[0m\r\n".utf8), encoding: .utf8) == "ok", "去掉 ANSI 颜色")
check(Codec.displayText(Data([0x41, 0xFF, 0x42]), encoding: .gbk).contains("A"), "GBK 遇到坏字节不崩溃")

print("校验")
// 各算法的标准校验值，都用 "123456789" 算
let vector = Data("123456789".utf8)
let expected: [(ChecksumKind, UInt32)] = [
    (.modbusCRC16, 0x4B37), (.ccittCRC16, 0x29B1), (.crc32, 0xCBF4_3926),
    (.add8, 0xDD), (.zeroAdd8, 0x23), (.xor8, 0x31), (.add16, 0x01DD),
]
for (kind, value) in expected {
    check(kind.value(of: vector) == value, "\(kind.title) 标准值 \(String(value, radix: 16))")
}

func setting(_ kind: ChecksumKind, start: Int = 1) -> ChecksumSetting {
    var s = ChecksumSetting()
    s.kind = kind
    s.startByte = start
    return s
}
let modbus = Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A])
check(setting(.modbusCRC16).trailer(for: modbus) == Data([0xC5, 0xCD]), "Modbus 帧 01 03 00 00 00 0A 的校验是 C5 CD")
check(setting(.ccittCRC16).trailer(for: vector) == Data([0x29, 0xB1]), "CCITT 默认高字节在前")
check(setting(.crc32).trailer(for: vector) == Data([0xCB, 0xF4, 0x39, 0x26]), "CRC32 占 4 字节")
var swapped = setting(.ccittCRC16)
swapped.lowFirst = true
check(swapped.trailer(for: vector) == Data([0xB1, 0x29]), "字节序可以调换")
swapped.kind = .modbusCRC16
check(swapped.lowFirst, "换算法时字节序回到该算法的默认值")
check(setting(.add8, start: 3).trailer(for: Data([0xAA, 0x55, 0x01, 0x02])) == Data([0x03]), "从第 3 字节算起，跳过帧头")
check(setting(.add8, start: 5).trailer(for: Data([0x01, 0x02])) == nil, "内容够不到起始字节时拒绝")
check(ChecksumSetting().trailer(for: vector) == Data(), "不加校验时没有多余字节")

func frame(_ text: String, hex: Bool, _ kind: ChecksumKind, encoding: TextEncodingChoice = .utf8) -> Result<OutgoingFrame, SendProblem> {
    Codec.frame(text, hex: hex, encoding: encoding, ending: .crlf, checksum: setting(kind))
}
check((try? frame("12", hex: false, .add8).get().bytes) == Data([0x31, 0x32, 0x63, 0x0D, 0x0A]), "文本：校验只算内容，放在行尾之前")
check((try? frame("01 02", hex: true, .add8).get().bytes) == Data([0x01, 0x02, 0x03]), "HEX：不加行尾")
check((try? frame("状", hex: false, .xor8, encoding: .gbk).get().trailer) == Data([0xD7 ^ 0xB4]), "校验按实际发送的 GBK 字节算")
check((try? frame("12", hex: false, .add8).get().trailerRange) == 2..<3, "能定位校验字节的位置")
if case .failure(.badHex) = frame("ABC", hex: true, .add8) { check(true, "HEX 写错时报错") } else { check(false, "HEX 写错时报错") }

print("串口收发（虚拟设备）")
guard let device = DemoDevice() else {
    print("  失败  无法创建虚拟设备")
    exit(1)
}
let received = Box(Data())
let disconnected = Box(false)
var config = SerialConfig()
let port = try SerialPort(path: device.path, config: config)
let counted = Box(0)
port.onData = { data in
    received.mutate { $0.append(data) }
    counted.mutate { $0 += data.count }
}
port.onDisconnect = { disconnected.value = true }
port.start()
device.start()
check(wait { String(decoding: received.value, as: UTF8.self).contains("boot: firmware") }, "收到设备启动信息")

received.value = Data()
port.write(Data("AT+GMR\r\n".utf8))
check(wait { String(decoding: received.value, as: UTF8.self).contains("v2.4.1\r\nOK") }, "发送指令并收到回复")

config.parity = .even
config.dataBits = 7
config.stopBits = 2
let updated = Box<Error?>(nil)
let updateDone = Box(false)
port.update(config: config) { error in
    updated.value = error
    updateDone.value = true
}
check(wait { updateDone.value } && updated.value == nil, "连接中修改数据位、校验位和停止位")
config = SerialConfig()
port.update(config: config) { _ in }

print("高速数据（1 MB/s，持续 2 秒）")
received.value = Data()
counted.value = 0
device.setFlood(bytesPerSecond: 1_000_000)
RunLoop.current.run(until: Date().addingTimeInterval(2))
device.setFlood(bytesPerSecond: 0)
print("  收到 \(counted.value) 字节")
check(counted.value > 500_000, "高速接收吞吐正常")

print("设备拔出")
device.stop()
check(wait { disconnected.value }, "检测到设备断开")

print("主动关闭不应触发断开回调")
if let second = DemoDevice() {
    let flagged = Box(false)
    let p2 = try SerialPort(path: second.path, config: SerialConfig())
    p2.onDisconnect = { flagged.value = true }
    p2.start()
    p2.close()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    second.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    check(!flagged.value, "主动关闭没有误报")
}

print("打开之后、开始接收之前的数据")
if let virtual = VirtualPort() {
    let early = Box(Data())
    let holder = try SerialPort(path: virtual.path, config: SerialConfig())
    holder.onData = { data in early.mutate { $0.append(data) } }
    // 模拟连接时会马上打印启动信息的设备：还没开始接收，数据就已经来了
    virtual.send("boot: early banner\r\n")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    holder.start()
    let bootText = "boot: early banner\r\n"
    check(wait { early.value.count >= bootText.utf8.count }, "start 之前到达的数据没有被清掉")
    virtual.send("later\r\n")
    check(wait { String(decoding: early.value, as: UTF8.self) == bootText + "later\r\n" }, "前后的数据都完整，顺序不变，共 \(early.value.count) 字节")

    holder.write(Data([0x00, 0xFF, 0x41]))
    var echoed = Data()
    _ = wait {
        echoed.append(virtual.receive())
        return echoed.count >= 3
    }
    check(echoed == Data([0x00, 0xFF, 0x41]), "发送的字节原样到达设备")

    print("关闭")
    check(!virtual.isReleasedByApp, "打开时设备这头能看到串口还开着")
    holder.closeAndWait()
    check(virtual.isReleasedByApp, "closeAndWait 返回时串口已经真的关掉")
    holder.closeAndWait()
    holder.close()
    check(true, "重复关闭没事")
    do {
        let again = try SerialPort(path: virtual.path, config: SerialConfig())
        check(true, "关掉后能马上重新打开")
        again.closeAndWait()
    } catch {
        check(false, "关掉后能马上重新打开：\(error.localizedDescription)")
    }
} else {
    check(false, "无法创建虚拟串口")
}

print("打开失败的提示")
do {
    _ = try SerialPort(path: "/dev/cu.does-not-exist", config: SerialConfig())
    check(false, "不存在的端口应当报错")
} catch {
    check(error.localizedDescription.contains("找不到"), "不存在的端口：\(error.localizedDescription)")
}

print("端口列表")
let ports = PortScanner.scan()
print("  " + ports.map(\.menuTitle).joined(separator: " | "))
check(true, "枚举完成，共 \(ports.count) 个")

print(failures == 0 ? "\n全部通过" : "\n有 \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
