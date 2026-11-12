import Foundation

/// Big-endian byte builder.
public struct ByteWriter {
    public private(set) var data = Data()
    public init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    public mutating func u24(_ v: UInt32) {
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF))
    }
    public mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    public mutating func u32le(_ v: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
    }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    public mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    public mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
}

/// Big-endian reader; throws on truncated input.
public struct ByteReader {
    public enum Error: Swift.Error { case truncated }
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw Error.truncated }
        defer { offset += 1 }
        return data[offset]
    }
    public mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    public mutating func u24() throws -> UInt32 { UInt32(try u8()) << 16 | UInt32(try u8()) << 8 | UInt32(try u8()) }
    public mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
    public mutating func u32le() throws -> UInt32 {
        let a = UInt32(try u8()), b = UInt32(try u8()), c = UInt32(try u8()), d = UInt32(try u8())
        return a | b << 8 | c << 16 | d << 24
    }
    public mutating func f64() throws -> Double {
        Double(bitPattern: UInt64(try u32()) << 32 | UInt64(try u32()))
    }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw Error.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
