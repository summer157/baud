import Darwin
import Foundation

public enum Parity: String, Codable, CaseIterable, Sendable {
    case none = "N", even = "E", odd = "O"
}

public enum FlowControl: String, Codable, CaseIterable, Sendable {
    case none, rtsCts, xonXoff
}

public struct SerialConfig: Equatable, Codable, Sendable {
    public var baud = 115200
    public var dataBits = 8
    public var stopBits = 1
    public var parity = Parity.none
    public var flow = FlowControl.none

    public init() {}

    public var summary: String { "\(baud) \(dataBits)\(parity.rawValue)\(stopBits)" }
}

public enum SerialError: LocalizedError {
    case open(path: String, code: Int32)
    case configure(code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .open(_, code):
            switch code {
            case EBUSY: return "端口被占用，先关掉正在使用它的程序"
            case ENOENT, ENXIO: return "找不到这个设备，可能已被拔出"
            case EACCES: return "没有访问这个端口的权限"
            default: return String(cString: strerror(code))
            }
        case let .configure(code):
            if code == ENOTTY { return "这个端口不支持所选的波特率" }
            return "无法设置串口参数：\(String(cString: strerror(code)))"
        }
    }
}

/// 一个已打开的串口。读写都在内部串行队列上进行，回调也在该队列上触发。
public final class SerialPort: @unchecked Sendable {
    public let path: String

    // 两个回调都在调用 start() 之前设好，之后不要再改：内部队列会读它们，改动没有同步。

    /// 收到数据。关闭之后，已经在路上的一次调用仍可能发生，调用方要能认出它。
    public var onData: (@Sendable (Data) -> Void)?
    /// 设备消失（拔出或读到文件结束）。主动调用 close() 不会触发，但同样可能迟到。
    public var onDisconnect: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "baud.serial.io", qos: .userInitiated)
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var outgoing = Data()
    private var closed = false

    // IOSSIOSPEED，定义在 IOKit/serial/ioss.h，宏无法导入 Swift
    private static let iossIOSpeed: UInt = 0x8008_5402
    private static let standardBauds: Set<Int> = [
        50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800,
        9600, 19200, 38400, 57600, 115_200, 230_400,
    ]

    public init(path: String, config: SerialConfig) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path: path, code: errno) }
        _ = ioctl(fd, TIOCEXCL)
        do {
            try Self.apply(config, to: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        // 只丢弃打开之前的残留。打开之后到 start 之间收到的内容留在系统缓冲区里，start 后会读到
        tcflush(fd, TCIOFLUSH)
    }

    /// 开始接收。先设好回调再调用。
    public func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drainInput() }
            source.resume()
            readSource = source

            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writer.setEventHandler { [weak self] in self?.drainOutput() }
            writeSource = writer
        }
    }

    public func update(config: SerialConfig, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                try Self.apply(config, to: fd)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    public func write(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            outgoing.append(data)
            drainOutput()
        }
    }

    public func close() {
        queue.async { [self] in teardown() }
    }

    /// 关闭并等到真正关掉。端口是独占的，紧接着重新打开同一个端口时要用它。不能在回调里调用。
    public func closeAndWait() {
        queue.sync { teardown() }
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        if let writer = writeSource {
            if writeSuspended { writer.resume() }
            writer.cancel()
        }
        readSource?.cancel()
        // 丢弃未发完的数据，否则流控卡住时 close 会一直阻塞
        tcflush(fd, TCIOFLUSH)
        Darwin.close(fd)
    }

    private func drainInput() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                onData?(Data(buffer[0..<n]))
                if n < buffer.count { return }
            } else if n == 0 {
                disconnect()
                return
            } else {
                switch errno {
                case EAGAIN, EINTR: return
                default:
                    disconnect()
                    return
                }
            }
        }
    }

    private func drainOutput() {
        guard !closed else { return }
        while !outgoing.isEmpty {
            let n = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outgoing.removeFirst(n)
            } else if errno == EAGAIN || errno == EINTR {
                if writeSuspended {
                    writeSuspended = false
                    writeSource?.resume()
                }
                return
            } else {
                disconnect()
                return
            }
        }
        if !writeSuspended {
            writeSuspended = true
            writeSource?.suspend()
        }
    }

    private func disconnect() {
        guard !closed else { return }
        teardown()
        onDisconnect?()
    }

    private static func apply(_ config: SerialConfig, to fd: Int32) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw SerialError.configure(code: errno) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CREAD | CLOCAL)

        t.c_cflag &= ~tcflag_t(CSIZE)
        switch config.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }

        if config.stopBits == 2 {
            t.c_cflag |= tcflag_t(CSTOPB)
        } else {
            t.c_cflag &= ~tcflag_t(CSTOPB)
        }

        t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        switch config.parity {
        case .none: break
        case .even: t.c_cflag |= tcflag_t(PARENB)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch config.flow {
        case .none: break
        case .rtsCts: t.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        case .xonXoff: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }

        let standard = standardBauds.contains(config.baud)
        let speed = standard ? speed_t(config.baud) : speed_t(9600)
        cfsetspeed(&t, speed)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw SerialError.configure(code: errno) }

        if !standard {
            var custom = speed_t(config.baud)
            guard ioctl(fd, iossIOSpeed, &custom) == 0 else { throw SerialError.configure(code: errno) }
        }
    }
}
