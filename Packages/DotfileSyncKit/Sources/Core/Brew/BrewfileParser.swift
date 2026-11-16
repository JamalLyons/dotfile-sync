// Port of crates/dotfilesync-core/src/brew/parser.rs.
//
// Rust `&str` operations work on Unicode scalar values (`char`) and UTF-8 bytes, while Swift
// `String` compares and indexes by grapheme cluster with canonical equivalence. To preserve the
// Rust behaviour exactly, all matching here is done on `[Unicode.Scalar]` (or on UTF-8 bytes where
// the Rust code iterates bytes), never on `Character`.

private typealias Scalars = [Unicode.Scalar]

private struct OpenBlock {
    let lineNumber: Int
    let keyword: String
}

/// Statically parses Brewfile content without evaluating any Ruby.
///
/// Unconditional `brew "name"` / `cask "name"` declarations are imported. Everything else
/// (taps, `mas`, bundle extensions, Ruby control flow and anything inside it, malformed or
/// conditional declarations, unrecognized statements) is reported in
/// ``BrewfileParseResult/unsupportedConstructs`` with warnings in
/// ``BrewfileParseResult/diagnostics``. The last diagnostic is always a summary.
///
/// - Parameter content: The full Brewfile text.
/// - Returns: Sorted, de-duplicated formulae and casks plus unsupported constructs and diagnostics.
public func parseBrewfile(_ content: String) -> BrewfileParseResult {
    var formulae: [String] = []
    var casks: [String] = []
    var unsupportedConstructs: [UnsupportedConstruct] = []
    var diagnostics: [Diagnostic] = []
    var blockStack: [OpenBlock] = []

    for (idx, lineScalars) in rustLines(content).enumerated() {
        let lineNumber = idx + 1
        let line = makeString(lineScalars)
        let trimmedScalars = rustTrim(lineScalars)
        let trimmed = makeString(trimmedScalars)

        if trimmedScalars.isEmpty || hasPrefix(trimmedScalars, "#") {
            continue
        }

        let codeScalars = rustTrim(stripTrailingComment(trimmedScalars))
        if codeScalars.isEmpty {
            continue
        }
        let code = makeString(codeScalars)

        func unsupported(_ constructType: String, _ reason: String) {
            unsupportedConstructs.append(
                UnsupportedConstruct(
                    lineNumber: lineNumber,
                    rawLine: line,
                    constructType: constructType,
                    reason: reason
                )
            )
        }

        // 1. Check for block closing: `end`
        if isBlockEnder(codeScalars) {
            if let open = blockStack.popLast() {
                unsupported(
                    "dynamic_ruby",
                    "Ruby control-flow block '\(open.keyword)' (opened at line \(open.lineNumber)) closed with 'end'"
                )
            } else {
                unsupported(
                    "dynamic_ruby",
                    "Unexpected 'end' without matching block opening; scope cannot be safely established"
                )
            }
            continue
        }

        // 2. Check for block continuation: `elsif`, `else`, `when`, `rescue`, `ensure`
        if isBlockContinuation(codeScalars) {
            unsupported(
                "dynamic_ruby",
                "Ruby control-flow branch '\(code)' cannot be evaluated statically"
            )
            continue
        }

        // 3. Check for block opening statements
        if let keyword = isBlockStarter(codeScalars) {
            blockStack.append(OpenBlock(lineNumber: lineNumber, keyword: keyword))
            unsupported(
                "dynamic_ruby",
                "Ruby control-flow block '\(keyword)' cannot be evaluated statically"
            )
            continue
        }

        // 4. Inside an unsupported block: declarations must not enter desired package list
        if let openBlock = blockStack.last {
            if hasPrefix(trimmedScalars, "brew ") || hasPrefix(trimmedScalars, "cask ") {
                unsupported(
                    "dynamic_ruby",
                    "Package declaration inside unsupported Ruby control-flow block '\(openBlock.keyword)' (opened at line \(openBlock.lineNumber)) cannot be evaluated statically and will not be imported"
                )
                diagnostics.append(
                    .warning(
                        "Line \(lineNumber): Conditional package declaration '\(trimmed)' inside '\(openBlock.keyword)' block (line \(openBlock.lineNumber)) will not be imported"
                    )
                )
            } else {
                unsupported(
                    "dynamic_ruby",
                    "Statement inside unsupported Ruby control-flow block '\(openBlock.keyword)' (opened at line \(openBlock.lineNumber))"
                )
            }
            continue
        }

        // 5. Unconditional declarations: `brew` and `cask`
        let declaration: (kindLabel: String, rest: Scalars)? =
            if let rest = stripPrefix(trimmedScalars, "brew ") {
                ("brew", rest)
            } else if let rest = stripPrefix(trimmedScalars, "cask ") {
                ("cask", rest)
            } else {
                nil
            }
        if let (kindLabel, rest) = declaration {
            switch parsePackageDeclaration(rustTrim(rest)) {
            case .success(let name, let hasOptions):
                if kindLabel == "brew" {
                    formulae.append(name)
                } else {
                    casks.append(name)
                }
                if hasOptions {
                    diagnostics.append(
                        .warning(
                            "Line \(lineNumber): \(kindLabel) options on '\(trimmed)' are not tracked by dotfilesync manifest"
                        )
                    )
                }
            case .failure(let constructType, let reason):
                diagnostics.append(
                    .warning(
                        "Line \(lineNumber): Conditional or unsupported package declaration '\(trimmed)' will not be imported: \(reason)"
                    )
                )
                unsupported(constructType, reason)
            }
            continue
        }

        // Check for tap declaration
        if hasPrefix(trimmedScalars, "tap ") || isEqual(trimmedScalars, "tap") {
            unsupported("tap", "Homebrew taps are not currently tracked in dotfilesync.toml")
            continue
        }

        // Check for mas declaration
        if hasPrefix(trimmedScalars, "mas ") || isEqual(trimmedScalars, "mas") {
            unsupported(
                "mas",
                "Mac App Store ('mas') declarations are not supported in this milestone"
            )
            continue
        }

        // Check for whalebrew / vscode bundle extensions
        if hasPrefix(trimmedScalars, "whalebrew ") || hasPrefix(trimmedScalars, "vscode ") {
            unsupported(
                "bundle_extension",
                "Brew bundle extensions (whalebrew, vscode) are not supported"
            )
            continue
        }

        // Check for dynamic Ruby constructs (outside quoted declarations and comments)
        if isDynamicRubyLine(trimmedScalars) {
            unsupported(
                "dynamic_ruby",
                "Dynamic Ruby statement or control flow cannot be evaluated statically"
            )
            continue
        }

        // Anything else is unrecognized
        unsupported("unrecognized", "Unrecognized Brewfile statement or directive")
    }

    // Check for unclosed blocks at EOF
    for open in blockStack {
        let message =
            "Unclosed Ruby control-flow block '\(open.keyword)' opened at line \(open.lineNumber); scope cannot be safely established"
        unsupportedConstructs.append(
            UnsupportedConstruct(
                lineNumber: open.lineNumber,
                rawLine: "Unclosed block '\(open.keyword)'",
                constructType: "dynamic_ruby",
                reason: message
            )
        )
        diagnostics.append(.warning(message))
    }

    formulae = sortedDeduplicated(formulae)
    casks = sortedDeduplicated(casks)

    if unsupportedConstructs.isEmpty {
        diagnostics.append(
            .info("Successfully parsed Brewfile: \(formulae.count) formulae, \(casks.count) casks")
        )
    } else {
        diagnostics.append(
            .warning(
                "Parsed Brewfile with \(formulae.count) formulae, \(casks.count) casks, and \(unsupportedConstructs.count) unsupported/dynamic constructs"
            )
        )
    }

    return BrewfileParseResult(
        formulae: formulae,
        casks: casks,
        unsupportedConstructs: unsupportedConstructs,
        diagnostics: diagnostics
    )
}

// MARK: - Package declarations

private enum PackageDeclaration {
    /// Package name and whether trailing options (`, args: ...`) were present.
    case success(String, Bool)
    /// Construct type and reason.
    case failure(String, String)
}

/// Parses the package expression following `brew ` or `cask `.
/// Expects `"name"` or `'name'`, optionally followed by `, args: [...]` or a comment `# ...`.
/// Rejects trailing conditional expressions (e.g. `if OS.mac?`, `unless OS.linux?`) and
/// unsupported trailing expressions like `+ extra` or string interpolations.
private func parsePackageDeclaration(_ input: Scalars) -> PackageDeclaration {
    let trimmed = rustTrim(input)
    let trimmedText = makeString(trimmed)
    guard let first = trimmed.first, first == "\"" || first == "'" else {
        return .failure(
            "malformed_syntax",
            "Expected opening quote for package name: '\(trimmedText)'"
        )
    }
    let quoteChar = first

    let inner = Scalars(trimmed.dropFirst())
    guard let endQuoteIdx = inner.firstIndex(of: quoteChar) else {
        return .failure(
            "malformed_syntax",
            "Unterminated quote in package declaration: '\(trimmedText)'"
        )
    }

    let nameScalars = Scalars(inner[..<endQuoteIdx])
    if rustTrim(nameScalars).isEmpty {
        return .failure("malformed_syntax", "Package name inside quotes is empty")
    }

    // Dynamic string interpolation check in package name
    if contains(nameScalars, "#{") {
        return .failure("dynamic_ruby", "String interpolation in package name is not supported")
    }
    let name = makeString(nameScalars)

    let remainder = rustTrim(Scalars(inner[(endQuoteIdx + 1)...]))
    let codeRemainder = rustTrim(stripTrailingComment(remainder))

    // Check for trailing conditional expressions (if/unless) even after package options
    if let keyword = hasTrailingConditional(codeRemainder) {
        return .failure(
            "dynamic_ruby",
            "Package declaration has trailing '\(keyword)' conditional modifier and cannot be imported unconditionally"
        )
    }

    if codeRemainder.isEmpty {
        return .success(name, false)
    } else if let optionsPart = stripPrefix(codeRemainder, ",") {
        if contains(rustTrim(optionsPart), "#{") {
            return .failure(
                "dynamic_ruby",
                "Dynamic Ruby interpolation inside options is not supported"
            )
        }
        return .success(name, true)
    } else {
        return .failure(
            "unsupported_expression",
            "Unsupported trailing expression following package declaration: '\(makeString(codeRemainder))'"
        )
    }
}

/// Detects trailing `if` or `unless` statement modifiers outside of quoted string arguments.
///
/// Mirrors the Rust implementation, which walks UTF-8 bytes and treats each byte as a Latin-1
/// `char` (so non-ASCII continuation bytes 0x85 and 0xA0 count as whitespace boundaries).
private func hasTrailingConditional(_ input: Scalars) -> String? {
    let bytes = Array(makeString(input).utf8)
    let len = bytes.count
    var inSingle = false
    var inDouble = false
    var prevChar: UInt8 = 0

    func byteIsBoundary(_ byte: UInt8) -> Bool {
        isWordBoundary(Unicode.Scalar(byte))
    }

    func matches(_ keyword: String, at i: Int) -> Bool {
        let kw = Array(keyword.utf8)
        guard i + kw.count <= len, Array(bytes[i..<(i + kw.count)]) == kw else { return false }
        let isPrevBoundary = i == 0 || byteIsBoundary(bytes[i - 1])
        let next = i + kw.count
        let isNextBoundary =
            next == len || byteIsBoundary(bytes[next]) || bytes[next] == UInt8(ascii: "(")
        return isPrevBoundary && isNextBoundary
    }

    var i = 0
    while i < len {
        let ch = bytes[i]

        if ch == UInt8(ascii: "'") && !inDouble && prevChar != UInt8(ascii: "\\") {
            inSingle.toggle()
            prevChar = ch
            i += 1
            continue
        }
        if ch == UInt8(ascii: "\"") && !inSingle && prevChar != UInt8(ascii: "\\") {
            inDouble.toggle()
            prevChar = ch
            i += 1
            continue
        }

        if !inSingle && !inDouble {
            if matches("if", at: i) {
                return "if"
            }
            if matches("unless", at: i) {
                return "unless"
            }
        }

        prevChar = ch
        i += 1
    }

    return nil
}

private func isWordBoundary(_ c: Unicode.Scalar) -> Bool {
    c.properties.isWhitespace || c == "," || c == "]" || c == "}" || c == ")" || c == ";"
        || c == ":"
}

// MARK: - Ruby block detection

private func isBlockStarter(_ code: Scalars) -> String? {
    let blockKeywords = [
        "if", "unless", "case", "while", "until", "for", "begin", "def", "class", "module",
    ]

    for keyword in blockKeywords {
        guard let rest = stripPrefix(code, keyword) else { continue }
        let isBoundary: Bool
        if let firstChar = rest.first {
            let ws = firstChar.properties.isWhitespace
            switch keyword {
            case "begin":
                isBoundary = ws || firstChar == ";"
            case "if", "unless", "case", "while", "until", "for":
                isBoundary = ws || firstChar == "(" || firstChar == ";"
            case "def":
                isBoundary = ws || firstChar == "("
            case "class":
                isBoundary = ws || firstChar == "<" || firstChar == ";"
            case "module":
                isBoundary = ws || firstChar == ";"
            default:
                isBoundary = false
            }
        } else {
            isBoundary = keyword == "begin" || keyword == "case"
        }

        if isBoundary {
            return keyword
        }
    }

    if hasSuffix(code, " do")
        || contains(code, " do |")
        || hasSuffix(code, " do|")
        || hasSuffix(code, " do;")
    {
        return "do"
    }

    return nil
}

private func isBlockEnder(_ code: Scalars) -> Bool {
    guard let rest = stripPrefix(code, "end") else { return false }
    guard let first = rest.first else { return true }
    return first.properties.isWhitespace || first == ";"
}

private func isBlockContinuation(_ code: Scalars) -> Bool {
    let continuationKeywords = ["else", "elsif", "when", "rescue", "ensure"]
    for keyword in continuationKeywords {
        guard let rest = stripPrefix(code, keyword) else { continue }
        guard let first = rest.first else { return true }
        if first.properties.isWhitespace || first == "(" || first == ";" || first == ":" {
            return true
        }
    }
    return false
}

/// Determines whether a line (with comments stripped) is a dynamic Ruby keyword or control statement.
private func isDynamicRubyLine(_ line: Scalars) -> Bool {
    let code = rustTrim(stripTrailingComment(line))
    if code.isEmpty {
        return false
    }

    if contains(code, "#{") {
        return true
    }

    let rubyKeywords = [
        "if", "unless", "case", "when", "def", "class", "module", "system", "Kernel.", "ENV[",
        "ENV.", "do", "end", "while", "until", "for", "begin", "rescue", "ensure", "lambda",
        "proc",
    ]

    for keyword in rubyKeywords {
        if isEqual(code, keyword)
            || hasPrefix(code, keyword + " ")
            || hasPrefix(code, keyword + "(")
            || hasPrefix(code, keyword + ":")
        {
            return true
        }
    }

    return false
}

private func stripTrailingComment(_ line: Scalars) -> Scalars {
    var inSingle = false
    var inDouble = false
    var prevChar: Unicode.Scalar = "\0"

    for (idx, ch) in line.enumerated() {
        if ch == "'" && !inDouble && prevChar != "\\" {
            inSingle.toggle()
        } else if ch == "\"" && !inSingle && prevChar != "\\" {
            inDouble.toggle()
        } else if ch == "#" && !inSingle && !inDouble {
            return Scalars(line[..<idx])
        }
        prevChar = ch
    }

    return line
}

// MARK: - Rust `str` semantics on Unicode scalars

/// Equivalent of Rust `str::lines()`: splits on `\n`, strips a `\r` preceding each `\n`,
/// and yields no trailing empty line for a final line ending.
private func rustLines(_ content: String) -> [Scalars] {
    var lines: [Scalars] = []
    var current: Scalars = []
    for scalar in content.unicodeScalars {
        if scalar == "\n" {
            if current.last == "\r" {
                current.removeLast()
            }
            lines.append(current)
            current = []
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

/// Equivalent of Rust `str::trim()` (Unicode `White_Space`).
private func rustTrim(_ s: Scalars) -> Scalars {
    guard let start = s.firstIndex(where: { !$0.properties.isWhitespace }),
        let end = s.lastIndex(where: { !$0.properties.isWhitespace })
    else {
        return []
    }
    return Scalars(s[start...end])
}

private func hasPrefix(_ s: Scalars, _ prefix: String) -> Bool {
    s.starts(with: prefix.unicodeScalars)
}

private func stripPrefix(_ s: Scalars, _ prefix: String) -> Scalars? {
    let p = Scalars(prefix.unicodeScalars)
    guard s.starts(with: p) else { return nil }
    return Scalars(s.dropFirst(p.count))
}

private func hasSuffix(_ s: Scalars, _ suffix: String) -> Bool {
    s.reversed().starts(with: Scalars(suffix.unicodeScalars).reversed())
}

private func isEqual(_ s: Scalars, _ other: String) -> Bool {
    s.elementsEqual(other.unicodeScalars)
}

private func contains(_ s: Scalars, _ needle: String) -> Bool {
    let n = Scalars(needle.unicodeScalars)
    guard !n.isEmpty else { return true }
    guard s.count >= n.count else { return false }
    for start in 0...(s.count - n.count) where s[start..<(start + n.count)].elementsEqual(n) {
        return true
    }
    return false
}

private func makeString(_ s: Scalars) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: s)
    return String(view)
}

/// Equivalent of Rust `Vec<String>::sort()` followed by `dedup()`: byte-wise (UTF-8) ordering
/// and exact byte equality, not Swift's canonical-equivalence string comparison.
private func sortedDeduplicated(_ values: [String]) -> [String] {
    let sorted = values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    var result: [String] = []
    for value in sorted where !(result.last.map { $0.utf8.elementsEqual(value.utf8) } ?? false) {
        result.append(value)
    }
    return result
}
