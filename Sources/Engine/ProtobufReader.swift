import Foundation

/// Minimal, crash-safe zero-copy binary protobuf wire decoder for Antigravity SQLite blobs.
public enum ProtobufWire {
    public struct Field {
        public let number: Int
        public let wireType: UInt8
        public let varint: UInt64
        public let slice: Data
    }

    public static func scan(_ data: Data) -> [Field] {
        var fields: [Field] = []
        fields.reserveCapacity(12)
        var i = data.startIndex
        let end = data.endIndex

        while i < end {
            guard let (key, nextIdx) = readVarint(data, from: i) else { break }
            i = nextIdx
            let fieldNum = Int(key >> 3)
            let wireType = UInt8(key & 0x07)
            if fieldNum <= 0 { break }

            switch wireType {
            case 0: // varint
                guard let (val, afterVal) = readVarint(data, from: i) else { return fields }
                i = afterVal
                fields.append(Field(number: fieldNum, wireType: 0, varint: val, slice: Data()))
            case 1: // 64-bit
                guard i + 8 <= end else { return fields }
                let sub = data[i..<(i + 8)]
                i += 8
                fields.append(Field(number: fieldNum, wireType: 1, varint: 0, slice: sub))
            case 2: // length-delimited
                guard let (len, afterLen) = readVarint(data, from: i) else { return fields }
                i = afterLen
                let byteCount = Int(min(len, UInt64(end - i)))
                guard byteCount >= 0, i + byteCount <= end else { return fields }
                let sub = data[i..<(i + byteCount)]
                i += byteCount
                fields.append(Field(number: fieldNum, wireType: 2, varint: 0, slice: sub))
            case 5: // 32-bit
                guard i + 4 <= end else { return fields }
                let sub = data[i..<(i + 4)]
                i += 4
                fields.append(Field(number: fieldNum, wireType: 5, varint: 0, slice: sub))
            default:
                return fields
            }
        }
        return fields
    }

    private static func readVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = start
        let end = data.endIndex
        while idx < end {
            let byte = data[idx]
            idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return (result, idx)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}

public struct AntigravityModelUsage: Sendable {
    public var modelEnum: UInt64 = 0
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheCreateTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var responseId: String = ""
    public var apiRequestId: String = ""

    public var hasTokens: Bool {
        inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheCreateTokens > 0
    }

    public var stableKey: String? {
        if !responseId.isEmpty { return responseId }
        if !apiRequestId.isEmpty { return apiRequestId }
        return nil
    }
}

public struct AntigravityStepDecoded: Sendable {
    public var timestamp: Date?
    public var modelEnum: UInt64 = 0
    public var usage: AntigravityModelUsage?
}

public struct AntigravityGenDecoded: Sendable {
    public var modelEnum: UInt64 = 0
    public var modelSlug: String = ""
    public var lastStepIndex: Int?
    public var usage: AntigravityModelUsage?
}

public enum AntigravityBlobDecoder {
    public static func decodeUsage(_ data: Data) -> AntigravityModelUsage {
        var u = AntigravityModelUsage()
        for f in ProtobufWire.scan(data) {
            switch (f.number, f.wireType) {
            case (1, 0): u.modelEnum = f.varint
            case (2, 0): u.inputTokens = Int64(bitPattern: f.varint)
            case (3, 0): u.outputTokens = Int64(bitPattern: f.varint)
            case (4, 0): u.cacheCreateTokens = Int64(bitPattern: f.varint)
            case (5, 0): u.cacheReadTokens = Int64(bitPattern: f.varint)
            case (7, 2): u.responseId = String(data: f.slice, encoding: .utf8) ?? ""
            case (11, 2): u.apiRequestId = String(data: f.slice, encoding: .utf8) ?? ""
            default: break
            }
        }
        return u
    }

    public static func decodeTimestamp(_ data: Data) -> Date? {
        for f in ProtobufWire.scan(data) where f.number == 1 && f.wireType == 0 {
            let secs = TimeInterval(f.varint)
            if secs > 1_600_000_000 && secs < 2_200_000_000 {
                return Date(timeIntervalSince1970: secs)
            }
        }
        return nil
    }

    public static func decodeStepMetadata(_ data: Data) -> AntigravityStepDecoded {
        var out = AntigravityStepDecoded()
        for f in ProtobufWire.scan(data) {
            switch (f.number, f.wireType) {
            case (1, 2):
                if out.timestamp == nil { out.timestamp = decodeTimestamp(f.slice) }
            case (8, 2):
                if let ts = decodeTimestamp(f.slice) { out.timestamp = ts }
            case (9, 2):
                let u = decodeUsage(f.slice)
                if u.hasTokens { out.usage = u }
            case (11, 0):
                out.modelEnum = f.varint
            default:
                break
            }
        }
        return out
    }

    public static func decodeGenMetadata(_ data: Data) -> AntigravityGenDecoded {
        var out = AntigravityGenDecoded()
        for f in ProtobufWire.scan(data) where f.number == 1 && f.wireType == 2 {
            for sub in ProtobufWire.scan(f.slice) {
                switch (sub.number, sub.wireType) {
                case (3, 0):
                    out.modelEnum = sub.varint
                case (4, 2):
                    let u = decodeUsage(sub.slice)
                    if u.hasTokens { out.usage = u }
                case (19, 2):
                    if let slug = String(data: sub.slice, encoding: .utf8), !slug.isEmpty {
                        out.modelSlug = slug
                    }
                case (20, 2):
                    // Key-value map entry: field 1 = key, field 2 = value
                    var k = "", v = ""
                    for kv in ProtobufWire.scan(sub.slice) where kv.wireType == 2 {
                        if kv.number == 1 { k = String(data: kv.slice, encoding: .utf8) ?? "" }
                        if kv.number == 2 { v = String(data: kv.slice, encoding: .utf8) ?? "" }
                    }
                    if k == "last_step_index", let idx = Int(v) {
                        out.lastStepIndex = idx
                    }
                default:
                    break
                }
            }
        }
        return out
    }
}
