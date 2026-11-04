import CoreFoundation
import Foundation

public enum TextEncodingChoice: String, Codable, CaseIterable, Sendable {
    case utf8, gbk

    public var title: String { self == .utf8 ? "UTF-8" : "GBK" }
}

public enum LineEnding: String, Codable, CaseIterable, Sendable {
    case none = "", cr = "\r", lf = "\n", crlf = "\r\n"

    public var title: String {
        switch self {
        case .none: return "无行尾"
        case .cr: return "CR"
        case .lf: return "LF"
        case .crlf: return "CRLF"
        }
    }
}

public enum Codec {
    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// 解析十六进制文本，允许空格、逗号和 0x 前缀。格式不对时返回 nil。
    public static func parseHex(_ text: String) -> Data? {
        var digits = text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
        digits.removeAll { $0.isWhitespace || $0 == "," }
        guard !digits.isEmpty, digits.utf8.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.utf8.count / 2)
        var high: UInt8?
        for char in digits.utf8 {
            let value: UInt8
            switch char {
            case 0x30...0x39: value = char - 0x30
            case 0x41...0x46: value = char - 0x41 + 10
            case 0x61...0x66: value = char - 0x61 + 10
            default: return nil
            }
            if let h = high {
                out.append(h << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return out
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    public static func hexString(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var out = [UInt8]()
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if !out.isEmpty { out.append(0x20) }
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func encode(_ text: String, encoding: TextEncodingChoice, ending: LineEnding) -> Data {
        let full = text + ending.rawValue
        switch encoding {
        case .utf8: return Data(full.utf8)
        case .gbk: return full.data(using: gb18030, allowLossyConversion: true) ?? Data(full.utf8)
        }
    }

    /// 把一行字节变成可显示的文字：按编码解码，去掉 ANSI 转义和控制字符。
    public static func displayText(_ data: Data, encoding: TextEncodingChoice) -> String {
        let decoded: String
        switch encoding {
        case .utf8: decoded = String(decoding: data, as: UTF8.self)
        case .gbk: decoded = decodeGBK(data)
        }
        return sanitize(decoded)
    }

    private static func decodeGBK(_ data: Data) -> String {
        if let whole = String(data: data, encoding: gb18030) { return whole }
        var out = ""
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] < 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(bytes[i]))
                i += 1
            } else if i + 1 < bytes.count, let pair = String(data: Data(bytes[i...(i + 1)]), encoding: gb18030) {
                out += pair
                i += 2
            } else {
                out += "\u{FFFD}"
                i += 1
            }
        }
        return out
    }

    private static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return text }
        var out = String.UnicodeScalarView()
        var iterator = scalars.makeIterator()
        var current = iterator.next()
        while let scalar = current {
            if scalar.value == 0x1B {
                // 跳过 ESC [ ... 终止字符
                current = iterator.next()
                if current?.value == 0x5B {
                    current = iterator.next()
                    while let c = current, !(0x40...0x7E).contains(c.value) { current = iterator.next() }
                    current = iterator.next()
                }
                continue
            }
            if scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7F) { out.append(scalar) }
            current = iterator.next()
        }
        return String(out)
    }
}
