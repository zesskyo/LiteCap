import Foundation

/// Minimal AMF0 value model used by RTMP commands.
public indirect enum AMF0: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([(String, AMF0)])
    case ecmaArray([(String, AMF0)])
    case strictArray([AMF0])
    case null
    case undefined

    public static func == (lhs: AMF0, rhs: AMF0) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)), let (.ecmaArray(a), .ecmaArray(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.strictArray(a), .strictArray(b)): return a == b
        case (.null, .null), (.undefined, .undefined): return true
        default: return false
        }
    }

    /// Look up a property of an object / ECMA array.
    public subscript(key: String) -> AMF0? {
        switch self {
        case .object(let pairs), .ecmaArray(let pairs): return pairs.first { $0.0 == key }?.1
        default: return nil
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }

    // MARK: Encoding

    public static func encode(_ values: [AMF0]) -> Data {
        var w = ByteWriter()
        values.forEach { $0.write(to: &w) }
        return w.data
    }

    public func write(to w: inout ByteWriter) {
        switch self {
        case .number(let n): w.u8(0x00); w.f64(n)
        case .bool(let b): w.u8(0x01); w.u8(b ? 1 : 0)
        case .string(let s):
            let utf8 = Array(s.utf8)
            if utf8.count > 0xFFFF {
                w.u8(0x0C); w.u32(UInt32(utf8.count))
            } else {
                w.u8(0x02); w.u16(UInt16(utf8.count))
            }
            w.bytes(utf8)
        case .object(let pairs):
            w.u8(0x03)
            Self.writePairs(pairs, to: &w)
        case .ecmaArray(let pairs):
            w.u8(0x08); w.u32(UInt32(pairs.count))
            Self.writePairs(pairs, to: &w)
        case .strictArray(let items):
            w.u8(0x0A); w.u32(UInt32(items.count))
            items.forEach { $0.write(to: &w) }
        case .null: w.u8(0x05)
        case .undefined: w.u8(0x06)
        }
    }

    private static func writePairs(_ pairs: [(String, AMF0)], to w: inout ByteWriter) {
        for (key, value) in pairs {
            let utf8 = Array(key.utf8)
            w.u16(UInt16(utf8.count)); w.bytes(utf8)
            value.write(to: &w)
        }
        w.u16(0); w.u8(0x09)
    }

    // MARK: Decoding

    public enum DecodeError: Error { case unsupportedType(UInt8) }

    public static func decodeAll(_ data: Data) throws -> [AMF0] {
        var r = ByteReader(data)
        var out: [AMF0] = []
        while r.remaining > 0 { out.append(try read(&r)) }
        return out
    }

    static func read(_ r: inout ByteReader) throws -> AMF0 {
        let marker = try r.u8()
        switch marker {
        case 0x00: return .number(try r.f64())
        case 0x01: return .bool(try r.u8() != 0)
        case 0x02: return .string(try readString(&r, length: Int(try r.u16())))
        case 0x0C: return .string(try readString(&r, length: Int(try r.u32())))
        case 0x03: return .object(try readPairs(&r))
        case 0x08: _ = try r.u32(); return .ecmaArray(try readPairs(&r))
        case 0x0A:
            let count = Int(try r.u32())
            var items: [AMF0] = []
            for _ in 0..<count { items.append(try read(&r)) }
            return .strictArray(items)
        case 0x05: return .null
        case 0x06: return .undefined
        default: throw DecodeError.unsupportedType(marker)
        }
    }

    private static func readString(_ r: inout ByteReader, length: Int) throws -> String {
        String(decoding: try r.bytes(length), as: UTF8.self)
    }

    private static func readPairs(_ r: inout ByteReader) throws -> [(String, AMF0)] {
        var pairs: [(String, AMF0)] = []
        while true {
            let keyLength = Int(try r.u16())
            if keyLength == 0 {
                let end = try r.u8()
                if end == 0x09 { return pairs }
                throw DecodeError.unsupportedType(end)
            }
            let key = try readString(&r, length: keyLength)
            pairs.append((key, try read(&r)))
        }
    }
}
