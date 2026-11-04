import Foundation

/// 把收到的字节流切成行。支持 LF、CR、CRLF，长时间没有换行时可以用 flush 取走残留内容。
public struct LineAssembler: Sendable {
    public let maxLineLength: Int

    private var current = Data()
    private var pendingCR = false

    public init(maxLineLength: Int = 4096) {
        self.maxLineLength = maxLineLength
    }

    public var hasPartial: Bool { !current.isEmpty }

    public mutating func feed(_ data: Data) -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A {
                    current.append(byte)
                    lines.append(current)
                    current = Data()
                    continue
                }
                lines.append(current)
                current = Data()
            }
            current.append(byte)
            if byte == 0x0D {
                pendingCR = true
            } else if byte == 0x0A || current.count >= maxLineLength {
                lines.append(current)
                current = Data()
            }
        }
        return lines
    }

    public mutating func flush() -> Data? {
        pendingCR = false
        guard !current.isEmpty else { return nil }
        defer { current = Data() }
        return current
    }
}
