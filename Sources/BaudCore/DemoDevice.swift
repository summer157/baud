import Darwin
import Foundation

/// 一个跑在伪终端上的假设备，没有硬件时也能试用完整流程。
public final class DemoDevice: @unchecked Sendable {
    public static let portID = "demo://device"
    public static let info = PortInfo(path: portID, name: "演示设备", detail: "内置模拟，无需硬件", kind: .demo)

    public let path: String

    private let queue = DispatchQueue(label: "baud.demo.device")
    private let master: Int32
    private let heldSlave: Int32
    private var source: DispatchSourceRead?
    private var ticker: DispatchSourceTimer?
    private var flood: DispatchSourceTimer?
    private var command = Data()
    private var floodBacklog = Data()
    private var floodBudget = 0
    private var tick = 0
    private var seq = 128
    private var stopped = false

    public init?() {
        master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else { return nil }
        path = String(cString: name)
        // 保持从端打开，否则应用连接前主端会读到错误
        heldSlave = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard heldSlave >= 0 else { return nil }
    }

    public func start() {
        queue.async { [self] in
            let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            reader.setEventHandler { [weak self] in self?.readCommands() }
            reader.resume()
            source = reader

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.65)
            timer.setEventHandler { [weak self] in self?.emitTelemetry() }
            timer.resume()
            ticker = timer
            send(["boot: firmware v2.4.1", "boot: flash ok, 4096 KB", "wifi: connected, ip 192.168.1.42", "状态: 运行正常"])
        }
    }

    /// 关闭主端，从应用这边看就是设备被拔掉了。
    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            ticker?.cancel()
            flood?.cancel()
            source?.cancel()
            Darwin.close(heldSlave)
            Darwin.close(master)
        }
    }

    /// 打开或关闭高速数据，用来压测界面。
    public func setFlood(bytesPerSecond: Int) {
        queue.async { [self] in
            flood?.cancel()
            flood = nil
            guard bytesPerSecond > 0, !stopped else { return }
            floodBacklog.removeAll()
            floodBudget = 0
            let interval = 0.002
            let perTick = max(1, Int(Double(bytesPerSecond) * interval))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in self?.emitFlood(bytes: perTick) }
            timer.resume()
            flood = timer
        }
    }

    private func emitFlood(bytes: Int) {
        // 额度跨周期累计，低速时才能接近设定的速率
        floodBudget += bytes
        // 伪终端缓冲区很小，积压的数据留到下一次再写，积压过多才丢弃
        while floodBudget > 0, floodBacklog.count < 1 << 20 {
            seq += 1
            let line = Data("data seq=\(seq) adc=[\(seq % 4096), \((seq * 7) % 4096), \((seq * 13) % 4096)] ok\r\n".utf8)
            floodBacklog.append(line)
            floodBudget -= line.count
        }
        floodBudget = min(floodBudget, bytes)
        while !floodBacklog.isEmpty {
            let n = floodBacklog.withUnsafeBytes { Darwin.write(master, $0.baseAddress, min($0.count, 4096)) }
            guard n > 0 else { break }
            floodBacklog.removeFirst(n)
        }
    }

    private func emitTelemetry() {
        tick += 1
        if tick % 13 == 0 {
            send(["状态: 运行正常"])
        } else if tick % 11 == 0 {
            send(["wifi: rssi=-\(52 + tick % 9) dBm"])
        } else if tick % 5 == 0 {
            seq += 1
            send(["heartbeat seq=\(seq)"])
        } else {
            let temp = String(format: "%.1f", 24.4 + Double.random(in: 0...0.6))
            let volt = String(format: "%.2f", 3.69 + Double.random(in: 0...0.03))
            send(["sensor temp=\(temp)C hum=\(47 + Int.random(in: 0...2))% vbat=\(volt)V"])
        }
    }

    private func readCommands() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(master, &buffer, buffer.count)
            guard n > 0 else { return }
            for byte in buffer[0..<n] {
                if byte == 0x0A || byte == 0x0D {
                    if !command.isEmpty { respond(to: String(decoding: command, as: UTF8.self)) }
                    command.removeAll()
                } else {
                    command.append(byte)
                }
            }
        }
    }

    private func respond(to line: String) {
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "at": send(["OK"])
        case "at+gmr": send(["v2.4.1", "OK"])
        case "status": send(["状态: 运行正常", "uptime 01:24:36", "OK"])
        case "reset": send(["rebooting...", "boot: firmware v2.4.1", "boot: flash ok, 4096 KB"])
        default: send(["ERR unknown command"])
        }
    }

    private func send(_ lines: [String]) {
        write(Data(lines.map { $0 + "\r\n" }.joined().utf8))
    }

    private func write(_ data: Data) {
        guard !stopped else { return }
        // 缓冲区满时直接丢弃，真实设备过载时也会这样
        _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    }
}
