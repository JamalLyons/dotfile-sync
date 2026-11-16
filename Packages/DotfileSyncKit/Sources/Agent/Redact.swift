// Port of crates/dotfilesync-daemon/src/redact.rs: best-effort secret redaction for log lines.
//
// Defense in depth: the agent's primary rule is to log only event metadata, never request
// params, reports, config bodies or subprocess output. Works on UTF-8 bytes like Rust.

/// Replacement text for a redacted secret.
public let REDACTED = "[REDACTED]"

private let tokenPrefixes: [[UInt8]] = ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"].map { Array($0.utf8) }
private let sensitiveKeys = [
    "password", "passwd", "secret", "token", "api_key", "apikey", "api-key",
    "access_key", "private_key", "credential", "authorization",
]

private func isAsciiAlnum(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

private func asciiLower(_ bytes: [UInt8]) -> [UInt8] {
    bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
}

private func find(_ hay: ArraySlice<UInt8>, _ needle: [UInt8]) -> Int? {
    guard needle.count <= hay.count else { return nil }
    let start = hay.startIndex
    var i = start
    while i + needle.count <= hay.endIndex {
        if hay[i..<(i + needle.count)].elementsEqual(needle) {
            return i - start
        }
        i += 1
    }
    return nil
}

private func isSensitiveKey(_ key: [UInt8]) -> Bool {
    // `trim_matches(|c| !c.is_ascii_alphanumeric() && c != '_' && c != '-')` on chars; any
    // non-ASCII byte counts as trimmable here, as a non-ASCII char would.
    let keep: (UInt8) -> Bool = { isAsciiAlnum($0) || $0 == 0x5F || $0 == 0x2D }
    guard let first = key.firstIndex(where: keep), let last = key.lastIndex(where: keep) else {
        return false
    }
    let k = String(decoding: asciiLower(Array(key[first...last])), as: UTF8.self)
    return !k.isEmpty && sensitiveKeys.contains { k.contains($0) }
}

private func redactTokenPrefixes(_ word: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var rest = word[...]
    outer: while !rest.isEmpty {
        for prefix in tokenPrefixes {
            if let pos = find(rest, prefix) {
                let afterStart = rest.startIndex + pos + prefix.count
                let after = rest[afterStart...]
                let tailLen = after.firstIndex(where: { !(isAsciiAlnum($0) || $0 == 0x5F) }).map { $0 - afterStart } ?? after.count
                if tailLen >= 4 {
                    out.append(contentsOf: rest[rest.startIndex..<(rest.startIndex + pos)])
                    out.append(contentsOf: Array(REDACTED.utf8))
                    rest = rest[(afterStart + tailLen)...]
                    continue outer
                }
            }
        }
        out.append(contentsOf: rest)
        break
    }
    return out
}

private func redactUrlUserinfo(_ word: [UInt8]) -> [UInt8] {
    if let schemeEnd = find(word[...], Array("://".utf8)) {
        let authStart = schemeEnd + 3
        let rest = word[authStart...]
        let hostEnd = rest.firstIndex(of: 0x2F) ?? rest.endIndex
        if let at = rest[authStart..<hostEnd].lastIndex(of: 0x40) {
            return Array(word[..<authStart]) + Array(REDACTED.utf8) + Array(word[at...])
        }
    }
    return word
}

private func redactKeyValue(_ word: [UInt8]) -> [UInt8]? {
    guard let sep = word.firstIndex(where: { $0 == 0x3D || $0 == 0x3A }) else { return nil }
    let key = Array(word[..<sep])
    let value = word[(sep + 1)...]
    if value.isEmpty || value.starts(with: [0x2F, 0x2F]) || !isSensitiveKey(key) {
        return nil
    }
    return key + [word[sep]] + Array(REDACTED.utf8)
}

/// Redacts secrets from a single log line.
public func redact(_ line: String) -> String {
    var out: [UInt8] = []
    var redactNext = false
    let words = Array(line.utf8).split(separator: 0x20, omittingEmptySubsequences: false)
    for (i, wordSlice) in words.enumerated() {
        if i > 0 {
            out.append(0x20)
        }
        let word = Array(wordSlice)
        if word.isEmpty {
            continue
        }
        var bare = asciiLower(word)
        while bare.last == 0x3A {
            bare.removeLast()
        }
        if bare == Array("bearer".utf8) || bare == Array("basic".utf8) {
            redactNext = true
            out.append(contentsOf: word)
            continue
        }
        if redactNext {
            out.append(contentsOf: Array(REDACTED.utf8))
            redactNext = false
            continue
        }
        if word.last == 0x3A && isSensitiveKey(word) {
            redactNext = true
            out.append(contentsOf: word)
            continue
        }
        var w = redactUrlUserinfo(word)
        if let kv = redactKeyValue(w) {
            w = kv
        }
        out.append(contentsOf: redactTokenPrefixes(w))
    }
    return String(decoding: out, as: UTF8.self)
}
