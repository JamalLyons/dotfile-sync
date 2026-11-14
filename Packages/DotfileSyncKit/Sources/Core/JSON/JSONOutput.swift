// JSON output matching `serde_json::to_string` / `to_string_pretty` byte for byte for the
// report types: keys in `encode(to:)` order, 2-space indent, `"key": value`, empty containers
// as `[]` / `{}`, `/` and non-ASCII unescaped, control characters escaped like serde_json.
//
// Foundation's `JSONEncoder` sorts or hashes keys and prints `"key" : value`, so this module
// has its own small `Encoder` that records an ordered value tree.

/// An ordered JSON value tree.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Members in insertion order. A repeated key replaces the earlier value in place.
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.uint(a), .uint(b)): return a == b
        case let (.int(a), .uint(b)), let (.uint(b), .int(a)): return a >= 0 && UInt64(a) == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && a.elementsEqual(b) { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

/// Failure encoding a value to JSON.
public enum JSONOutputError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The value's `encode(to:)` threw; carries its description.
    case encoding(String)
    /// A floating-point value was NaN or infinite (serde_json writes `null`; refused here).
    case nonFiniteNumber

    public var description: String {
        switch self {
        case let .encoding(message): return "Failed to encode JSON: \(message)"
        case .nonFiniteNumber: return "Failed to encode JSON: non-finite number"
        }
    }
}

/// Encodes `value` like `serde_json::to_string_pretty` (no trailing newline).
public func jsonStringPretty<T: Encodable>(_ value: T) throws(JSONOutputError) -> String {
    var output = ""
    try writeJSON(try jsonValue(value), pretty: true, indent: 0, into: &output)
    return output
}

/// Encodes `value` like `serde_json::to_string` (compact).
public func jsonStringCompact<T: Encodable>(_ value: T) throws(JSONOutputError) -> String {
    var output = ""
    try writeJSON(try jsonValue(value), pretty: false, indent: 0, into: &output)
    return output
}

/// Encodes `value` into an ordered ``JSONValue`` tree.
public func jsonValue<T: Encodable>(_ value: T) throws(JSONOutputError) -> JSONValue {
    let root = JSONNode()
    do {
        try value.encode(to: TreeEncoder(node: root, codingPath: []))
    } catch {
        throw .encoding(String(describing: error))
    }
    return root.resolve()
}

// MARK: - Writer

private func writeJSON(_ value: JSONValue, pretty: Bool, indent: Int, into out: inout String) throws(JSONOutputError) {
    switch value {
    case .null: out += "null"
    case let .bool(b): out += b ? "true" : "false"
    case let .int(i): out += String(i)
    case let .uint(u): out += String(u)
    case let .double(d):
        guard d.isFinite else { throw .nonFiniteNumber }
        // serde_json (ryu) prints integral floats with a trailing `.0`, as Swift does.
        out += String(d)
    case let .string(s): writeEscaped(s, into: &out)
    case let .array(items):
        if items.isEmpty {
            out += "[]"
            return
        }
        out += "["
        for (index, item) in items.enumerated() {
            if index > 0 { out += "," }
            if pretty { newline(indent + 1, &out) }
            try writeJSON(item, pretty: pretty, indent: indent + 1, into: &out)
        }
        if pretty { newline(indent, &out) }
        out += "]"
    case let .object(members):
        if members.isEmpty {
            out += "{}"
            return
        }
        out += "{"
        for (index, member) in members.enumerated() {
            if index > 0 { out += "," }
            if pretty { newline(indent + 1, &out) }
            writeEscaped(member.0, into: &out)
            out += pretty ? ": " : ":"
            try writeJSON(member.1, pretty: pretty, indent: indent + 1, into: &out)
        }
        if pretty { newline(indent, &out) }
        out += "}"
    }
}

private func newline(_ indent: Int, _ out: inout String) {
    out += "\n"
    out += String(repeating: "  ", count: indent)
}

/// serde_json string escaping: `"`, `\`, and U+0000–U+001F only.
private func writeEscaped(_ string: String, into out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{00}"..."\u{1F}":
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
}

// MARK: - Encoder

/// Mutable tree node filled in by the encoder; resolved into a ``JSONValue`` afterwards.
private final class JSONNode {
    enum Kind {
        case unset
        case value(JSONValue)
        case array([JSONNode])
        case object([(String, JSONNode)])
    }

    var kind: Kind = .unset

    func resolve() -> JSONValue {
        switch kind {
        case .unset: return .object([])
        case let .value(value): return value
        case let .array(nodes): return .array(nodes.map { $0.resolve() })
        case let .object(members): return .object(members.map { ($0.0, $0.1.resolve()) })
        }
    }

    func asObject() {
        if case .object = kind { return }
        kind = .object([])
    }

    func asArray() {
        if case .array = kind { return }
        kind = .array([])
    }

    func child(forKey key: String) -> JSONNode {
        guard case var .object(members) = kind else {
            kind = .object([])
            return child(forKey: key)
        }
        if let existing = members.first(where: { $0.0 == key }) {
            return existing.1
        }
        let node = JSONNode()
        members.append((key, node))
        kind = .object(members)
        return node
    }

    func appendChild() -> JSONNode {
        guard case var .array(nodes) = kind else {
            kind = .array([])
            return appendChild()
        }
        let node = JSONNode()
        nodes.append(node)
        kind = .array(nodes)
        return node
    }

    var count: Int {
        switch kind {
        case let .array(nodes): return nodes.count
        default: return 0
        }
    }
}

private struct TreeEncoder: Encoder {
    let node: JSONNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.asObject()
        return KeyedEncodingContainer(KeyedTreeContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.asArray()
        return UnkeyedTreeContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleTreeContainer(node: node, codingPath: codingPath)
    }
}

private func encodeValue<T: Encodable>(_ value: T, into node: JSONNode, codingPath: [any CodingKey]) throws {
    switch value {
    case let v as String: node.kind = .value(.string(v))
    case let v as Bool: node.kind = .value(.bool(v))
    case let v as Int: node.kind = .value(.int(Int64(v)))
    case let v as Int8: node.kind = .value(.int(Int64(v)))
    case let v as Int16: node.kind = .value(.int(Int64(v)))
    case let v as Int32: node.kind = .value(.int(Int64(v)))
    case let v as Int64: node.kind = .value(.int(v))
    case let v as UInt: node.kind = .value(.uint(UInt64(v)))
    case let v as UInt8: node.kind = .value(.uint(UInt64(v)))
    case let v as UInt16: node.kind = .value(.uint(UInt64(v)))
    case let v as UInt32: node.kind = .value(.uint(UInt64(v)))
    case let v as UInt64: node.kind = .value(.uint(v))
    case let v as Double: node.kind = .value(.double(v))
    case let v as Float: node.kind = .value(.double(Double(v)))
    default: try value.encode(to: TreeEncoder(node: node, codingPath: codingPath))
    }
}

private struct KeyedTreeContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: JSONNode
    let codingPath: [any CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        node.child(forKey: key.stringValue).kind = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try encodeValue(value, into: node.child(forKey: key.stringValue), codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = node.child(forKey: key.stringValue)
        child.asObject()
        return KeyedEncodingContainer(KeyedTreeContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let child = node.child(forKey: key.stringValue)
        child.asArray()
        return UnkeyedTreeContainer(node: child, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> any Encoder {
        TreeEncoder(node: node.child(forKey: "super"), codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        TreeEncoder(node: node.child(forKey: key.stringValue), codingPath: codingPath + [key])
    }
}

private struct IndexKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ index: Int) {
        stringValue = String(index)
        intValue = index
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.init(intValue)
    }
}

private struct UnkeyedTreeContainer: UnkeyedEncodingContainer {
    let node: JSONNode
    let codingPath: [any CodingKey]
    var count: Int { node.count }

    mutating func encodeNil() throws {
        node.appendChild().kind = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let path = codingPath + [IndexKey(count)]
        try encodeValue(value, into: node.appendChild(), codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let path = codingPath + [IndexKey(count)]
        let child = node.appendChild()
        child.asObject()
        return KeyedEncodingContainer(KeyedTreeContainer<NestedKey>(node: child, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = codingPath + [IndexKey(count)]
        let child = node.appendChild()
        child.asArray()
        return UnkeyedTreeContainer(node: child, codingPath: path)
    }

    mutating func superEncoder() -> any Encoder {
        TreeEncoder(node: node.appendChild(), codingPath: codingPath)
    }
}

private struct SingleTreeContainer: SingleValueEncodingContainer {
    let node: JSONNode
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws {
        node.kind = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encodeValue(value, into: node, codingPath: codingPath)
    }
}
