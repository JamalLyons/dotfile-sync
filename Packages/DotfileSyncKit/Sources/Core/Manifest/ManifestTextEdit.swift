// Minimal textual edits to `dotfilesync.toml` that keep the user's comments and layout.
//
// Promote appends one base `[[files]]` table; demote removes exactly one. Header detection is
// line-based (a line whose first non-blank character is `[`), so callers must re-parse the
// edited text and compare it with the expected model: ``appendingTrackedFile(_:to:)`` and
// ``removingTrackedFile(at:from:)`` do that and fail closed on any difference.

/// Why a textual manifest edit was refused.
public struct ManifestTextEditError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Returns `content` with a base `[[files]]` table for `file` (source and target only) inserted
/// after the last existing base `[[files]]` table, or appended when there is none.
///
/// The edited text is re-parsed and must equal `parseManifest(content)` plus `file` appended to
/// ``Manifest/files``; otherwise the edit is refused.
func appendingTrackedFile(_ file: TrackedFile, to content: String) throws(ManifestTextEditError) -> String {
    var expected = try parsedForEdit(content)
    expected.files.append(file)

    var lines = splitKeepingTerminators(content)
    let block = [
        "\n",
        "[[files]]\n",
        "source = \(tomlBasicString(file.source))\n",
        "target = \(tomlBasicString(file.target))\n",
    ]
    let insertAt: Int
    if let last = filesBlocks(lines).last {
        insertAt = last.upperBound
    } else {
        insertAt = lines.count
    }
    if insertAt > 0, !lines[insertAt - 1].hasSuffix("\n") {
        lines[insertAt - 1] += "\n"
    }
    lines.insert(contentsOf: block, at: insertAt)
    let edited = lines.joined()
    try verify(edited, equals: expected)
    return edited
}

/// Returns `content` without the base `[[files]]` table that holds ``Manifest/files`[index]`.
///
/// Comments and blank lines that precede the next table stay in place. The edited text is
/// re-parsed and must equal `parseManifest(content)` with that entry removed.
func removingTrackedFile(at index: Int, from content: String) throws(ManifestTextEditError) -> String {
    var expected = try parsedForEdit(content)
    guard expected.files.indices.contains(index) else {
        throw ManifestTextEditError("manifest has no [[files]] entry at index \(index)")
    }
    expected.files.remove(at: index)

    var lines = splitKeepingTerminators(content)
    let blocks = filesBlocks(lines)
    guard blocks.count == expected.files.count + 1 else {
        throw ManifestTextEditError(
            "cannot locate the [[files]] table to remove: found \(blocks.count) [[files]] headers for \(expected.files.count + 1) entries; edit the manifest by hand"
        )
    }
    var range = blocks[index]
    if range.lowerBound > 0, isBlank(lines[range.lowerBound - 1]) {
        range = (range.lowerBound - 1)..<range.upperBound
    }
    lines.removeSubrange(range)
    let edited = lines.joined()
    try verify(edited, equals: expected)
    return edited
}

// MARK: - Helpers

private func parsedForEdit(_ content: String) throws(ManifestTextEditError) -> Manifest {
    do {
        return try parseManifest(content)
    } catch {
        throw ManifestTextEditError("current manifest is invalid: \(error)")
    }
}

private func verify(_ edited: String, equals expected: Manifest) throws(ManifestTextEditError) {
    let reparsed: Manifest
    do {
        reparsed = try parseManifest(edited)
    } catch {
        throw ManifestTextEditError("edited manifest does not parse; edit it by hand: \(error)")
    }
    if reparsed != expected {
        throw ManifestTextEditError(
            "edited manifest does not match the expected change; edit it by hand"
        )
    }
}

/// Line ranges of every base `[[files]]` table: from its header up to the next table header,
/// minus trailing blank and comment-only lines (those introduce the next section).
private func filesBlocks(_ lines: [String]) -> [Range<Int>] {
    var headers: [(index: Int, isFiles: Bool)] = []
    for (index, line) in lines.enumerated() {
        if let header = tableHeader(line) {
            headers.append((index, header.isArray && header.name == "files"))
        }
    }
    var blocks: [Range<Int>] = []
    for (position, header) in headers.enumerated() where header.isFiles {
        var end = position + 1 < headers.count ? headers[position + 1].index : lines.count
        while end - 1 > header.index, isBlank(lines[end - 1]) || isComment(lines[end - 1]) {
            end -= 1
        }
        blocks.append(header.index..<end)
    }
    return blocks
}

/// `[name]` or `[[name]]` with optional surrounding whitespace and a trailing comment.
private func tableHeader(_ line: String) -> (isArray: Bool, name: String)? {
    let trimmed = Substring(rustTrim(line))
    guard trimmed.hasPrefix("[") else { return nil }
    let isArray = trimmed.hasPrefix("[[")
    let open = isArray ? "[[" : "["
    let close = isArray ? "]]" : "]"
    let body = trimmed.dropFirst(open.count)
    guard let closeRange = body.range(of: close) else { return nil }
    let rest = rustTrim(String(body[closeRange.upperBound...]))
    guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
    return (isArray, rustTrim(String(body[..<closeRange.lowerBound])))
}

private func isBlank(_ line: String) -> Bool {
    rustTrim(line).isEmpty
}

private func isComment(_ line: String) -> Bool {
    rustTrim(line).hasPrefix("#")
}

/// Splits on `\n`, keeping each terminator; a final unterminated line is kept as is.
private func splitKeepingTerminators(_ content: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in content {
        current.append(character)
        if character == "\n" || character == "\r\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

/// A TOML basic string (`"..."`) with `\`, `"` and control characters escaped.
func tomlBasicString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
