import Darwin
import Foundation

/// 检查和自检用的虚拟串口：应用打开 path，这个对象扮演另一头的设备。
/// 和 DemoDevice 不同，它不会自己说话，也不保持从端打开，所以能看出应用是否真的关掉了串口。
public final class VirtualPort: @unchecked Sendable {
    public let path: String
    private var master: Int32

    public init?() {
        master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else { return nil }
        path = String(cString: name)
    }

    /// 设备发出数据。
    public func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = Darwin.write(master, bytes, bytes.count)
    }

    /// 读走设备收到的数据。
    public func receive() -> Data {
        guard master >= 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &buffer, buffer.count)
        return n > 0 ? Data(buffer[0..<n]) : Data()
    }

    /// 应用这边的串口已经全部关掉：从端打开时没有数据会返回 EAGAIN，全部关掉后是文件结束或 EIO。
    /// 判断时会读走一个字节，只在不关心收到内容的时候用。
    public var isReleasedByApp: Bool {
        guard master >= 0 else { return true }
        var byte: UInt8 = 0
        let n = read(master, &byte, 1)
        if n > 0 { return false }
        return n == 0 || errno != EAGAIN
    }

    /// 当前的数据位。
    public var dataBits: Int? {
        var t = termios()
        guard master >= 0, tcgetattr(master, &t) == 0 else { return nil }
        switch t.c_cflag & tcflag_t(CSIZE) {
        case tcflag_t(CS5): return 5
        case tcflag_t(CS6): return 6
        case tcflag_t(CS7): return 7
        default: return 8
        }
    }

    /// 关闭设备这一头，从应用看就是设备被拔掉了。
    public func unplug() {
        guard master >= 0 else { return }
        Darwin.close(master)
        master = -1
    }

    deinit { unplug() }
}
