// Codable bridge for Core's ordered `JSONValue` (Rust: `serde_json::Value`), used for the
// free-form `details` of a `ProtocolError`.

import Core

/// A `Codable` wrapper around an arbitrary ``JSONValue``.
///
/// Encoding preserves object member order (so ``jsonStringCompact(_:)`` matches serde_json).
/// Decoding through Foundation's `JSONDecoder` cannot observe member order; decoded object
/// members are sorted by key so equality is deterministic.
public struct AnyJSON: Codable, Sendable, Equatable {
    /// The wrapped value.
    public var value: JSONValue

    /// Wraps `value`.
    public init(_ value: JSONValue) {
        self.value = value
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var members: [(String, JSONValue)] = []
            for key in keyed.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                members.append((key.stringValue, try keyed.decode(AnyJSON.self, forKey: key).value))
            }
            value = .object(members)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd {
                items.append(try unkeyed.decode(AnyJSON.self).value)
            }
            value = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            value = .null
        } else if let b = try? single.decode(Bool.self) {
            value = .bool(b)
        } else if let i = try? single.decode(Int64.self) {
            value = i >= 0 ? .uint(UInt64(i)) : .int(i)
        } else if let u = try? single.decode(UInt64.self) {
            value = .uint(u)
        } else if let d = try? single.decode(Double.self) {
            value = .double(d)
        } else {
            value = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch value {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case let .int(i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case let .uint(u):
            var c = encoder.singleValueContainer()
            try c.encode(u)
        case let .double(d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case let .string(s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case let .array(items):
            var c = encoder.unkeyedContainer()
            for item in items {
                try c.encode(AnyJSON(item))
            }
        case let .object(members):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (key, member) in members {
                try c.encode(AnyJSON(member), forKey: DynamicKey(key))
            }
        }
    }
}
