import Foundation

/// Protocol buffers for the few fixed OMEMO messages, written by hand: proto2 `uint32` and
/// `bytes` fields only.
///
/// The writer emits fields in the order it is called, which the message types keep to field
/// number order, as protobuf serializers do; required fields are always written, zero included.
/// The reader accepts any field order, skips fields it does not know (wire types 0, 1, 2 and 5),
/// and keeps the last value of a field that appears twice, as protobuf parsers do.
struct ProtobufWriter {
    private(set) var data = Data()

    mutating func uint32(_ field: Int, _ value: UInt32) {
        varint(UInt64(field) << 3 | WireType.varint.rawValue)
        varint(UInt64(value))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field) << 3 | WireType.lengthDelimited.rawValue)
        varint(UInt64(value.count))
        data.append(value)
    }

    private mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

enum WireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// The protobuf type of a field a message knows.
enum FieldType {
    case uint32
    case bytes
}

/// The fields of one serialized message, checked against the fields the message knows.
struct ProtobufFields {
    private var integers: [Int: UInt32] = [:]
    private var byteStrings: [Int: Data] = [:]

    /// - Throws: `MessageFormatError.truncated` when the data ends inside a field;
    ///   `.malformed` for a varint over ten bytes, field number 0, a group or unknown wire type,
    ///   a known field with the wrong wire type, or a `uint32` above 2^32 - 1.
    init(_ data: Data, fields: [Int: FieldType]) throws(MessageFormatError) {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let key = try Self.varint(bytes, &index)
            let number = key >> 3
            guard number > 0, number <= 0x1FFF_FFFF else { throw .malformed }
            let field = Int(number)
            let known = fields[field]
            switch WireType(rawValue: key & 0x7) {
            case .varint:
                let value = try Self.varint(bytes, &index)
                guard let known else { continue }
                guard known == .uint32, value <= UInt64(UInt32.max) else { throw .malformed }
                integers[field] = UInt32(value)
            case .lengthDelimited:
                let length = try Self.varint(bytes, &index)
                guard length <= UInt64(Int.max) else { throw .malformed }
                guard length <= UInt64(bytes.count - index) else { throw .truncated }
                let end = index + Int(length)
                if let known {
                    guard known == .bytes else { throw .malformed }
                    byteStrings[field] = Data(bytes[index..<end])
                }
                index = end
            case .fixed64:
                guard known == nil else { throw .malformed }
                guard bytes.count - index >= 8 else { throw .truncated }
                index += 8
            case .fixed32:
                guard known == nil else { throw .malformed }
                guard bytes.count - index >= 4 else { throw .truncated }
                index += 4
            case nil:
                throw .malformed
            }
        }
    }

    func uint32(_ field: Int) throws(MessageFormatError) -> UInt32 {
        guard let value = integers[field] else { throw .missingField }
        return value
    }

    func optionalUInt32(_ field: Int) -> UInt32? {
        integers[field]
    }

    func bytes(_ field: Int) throws(MessageFormatError) -> Data {
        guard let value = byteStrings[field] else { throw .missingField }
        return value
    }

    func optionalBytes(_ field: Int) -> Data? {
        byteStrings[field]
    }

    /// A base 128 varint of at most ten bytes whose value fits 64 bits.
    private static func varint(_ bytes: [UInt8], _ index: inout Int) throws(MessageFormatError)
        -> UInt64
    {
        var value: UInt64 = 0
        for position in 0..<10 {
            guard index < bytes.count else { throw .truncated }
            let byte = bytes[index]
            index += 1
            if position == 9, byte > 1 { throw .malformed }
            value |= UInt64(byte & 0x7F) << (7 * UInt64(position))
            if byte & 0x80 == 0 { return value }
        }
        throw .malformed
    }
}
