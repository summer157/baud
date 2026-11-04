import Foundation

public enum ChecksumKind: String, Codable, CaseIterable, Sendable {
    case none, modbusCRC16, ccittCRC16, crc32, zeroAdd8, add8, xor8, add16

    public var title: String {
        switch self {
        case .none: return "不加"
        case .modbusCRC16: return "ModbusCRC16"
        case .ccittCRC16: return "CCITT-CRC16"
        case .crc32: return "CRC32"
        case .zeroAdd8: return "0-ADD8"
        case .add8: return "ADD8"
        case .xor8: return "XOR8"
        case .add16: return "ADD16"
        }
    }

    /// 算法的具体参数。同名算法在不同设备上可能有差异，写明了才好对照。
    public var detail: String {
        switch self {
        case .none: return "发送的内容保持原样"
        case .modbusCRC16: return "多项式 0x8005 反射，初值 0xFFFF"
        case .ccittCRC16: return "CCITT-FALSE：多项式 0x1021，初值 0xFFFF"
        case .crc32: return "IEEE 802.3：多项式 0x04C11DB7 反射，初值和结果异或 0xFFFFFFFF"
        case .zeroAdd8: return "所有字节相加取低 8 位，再用 0 减去它"
        case .add8: return "所有字节相加，取低 8 位"
        case .xor8: return "所有字节依次异或"
        case .add16: return "所有字节相加，取低 16 位"
        }
    }

    /// 校验值占几个字节。
    public var width: Int {
        switch self {
        case .none: return 0
        case .zeroAdd8, .add8, .xor8: return 1
        case .modbusCRC16, .ccittCRC16, .add16: return 2
        case .crc32: return 4
        }
    }

    /// Modbus 规定低字节在前，其余默认高字节在前。
    public var defaultLowFirst: Bool { self == .modbusCRC16 }

    public func value<Bytes: Sequence>(of bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        switch self {
        case .none:
            return 0
        case .modbusCRC16:
            var crc: UInt16 = 0xFFFF
            for byte in bytes {
                crc ^= UInt16(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xA001 : crc >> 1 }
            }
            return UInt32(crc)
        case .ccittCRC16:
            var crc: UInt16 = 0xFFFF
            for byte in bytes {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
            }
            return UInt32(crc)
        case .crc32:
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        case .zeroAdd8:
            return UInt32(0 &- bytes.reduce(UInt8(0), &+))
        case .add8:
            return UInt32(bytes.reduce(UInt8(0), &+))
        case .xor8:
            return UInt32(bytes.reduce(UInt8(0), ^))
        case .add16:
            return UInt32(bytes.reduce(UInt16(0)) { $0 &+ UInt16($1) })
        }
    }
}

public struct ChecksumSetting: Equatable, Codable, Sendable {
    public var kind = ChecksumKind.none {
        didSet { if kind != oldValue { lowFirst = kind.defaultLowFirst } }
    }
    /// 从第几个字节开始算，从 1 起数，用来跳过帧头。
    public var startByte = 1
    public var lowFirst = false

    public init() {}

    public var isOn: Bool { kind != .none }

    /// 要追加在内容后面的校验字节。内容够不到起始字节时返回 nil。
    public func trailer(for body: Data) -> Data? {
        guard isOn else { return Data() }
        guard body.count >= startByte else { return nil }
        let value = kind.value(of: body.dropFirst(startByte - 1))
        let highFirst = (0..<kind.width).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt32($0) * 8)) }
        return Data(lowFirst ? highFirst.reversed() : highFirst)
    }
}

/// 一帧要发出去的数据：内容、校验、行尾。校验只覆盖内容，不含行尾。
public struct OutgoingFrame: Equatable, Sendable {
    public let body: Data
    public let trailer: Data
    public let ending: Data

    public var bytes: Data { body + trailer + ending }
    public var trailerRange: Range<Int>? {
        trailer.isEmpty ? nil : body.count..<(body.count + trailer.count)
    }
}

public enum SendProblem: Error, Equatable, Sendable {
    case offline, badHex
    case tooShort(startByte: Int)

    public var message: String {
        switch self {
        case .offline: return "还没有连接"
        case .badHex: return "HEX 需要成对的 0-9、A-F"
        case let .tooShort(start): return "校验从第 \(start) 字节算起，内容不够长"
        }
    }
}

extension Codec {
    public static func frame(_ text: String, hex: Bool, encoding: TextEncodingChoice, ending: LineEnding,
                             checksum: ChecksumSetting) -> Result<OutgoingFrame, SendProblem> {
        let body: Data
        if hex {
            guard let parsed = parseHex(text) else { return .failure(.badHex) }
            body = parsed
        } else {
            body = encode(text, encoding: encoding, ending: .none)
        }
        guard let trailer = checksum.trailer(for: body) else { return .failure(.tooShort(startByte: checksum.startByte)) }
        return .success(OutgoingFrame(body: body, trailer: trailer, ending: hex ? Data() : Data(ending.rawValue.utf8)))
    }
}
