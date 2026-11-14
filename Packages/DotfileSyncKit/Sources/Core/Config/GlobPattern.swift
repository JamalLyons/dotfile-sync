// Port of `glob::Pattern::new` + `Pattern::matches` (glob 0.3.4, default `MatchOptions`:
// case-sensitive, no literal separator, no literal leading dot) as used by the inspector.

/// A compiled shell glob pattern with `glob` crate semantics.
struct GlobPattern {
    private enum Token: Equatable {
        case char(Unicode.Scalar)
        case anyChar
        case anySequence
        case anyRecursiveSequence
        case anyWithin([Specifier])
        case anyExcept([Specifier])
    }

    private enum Specifier: Equatable {
        case single(Unicode.Scalar)
        case range(Unicode.Scalar, Unicode.Scalar)
    }

    private enum MatchResult {
        case match
        case subPatternDoesntMatch
        case entirePatternDoesntMatch
    }

    private let tokens: [Token]

    /// Compiles `pattern`, or returns `nil` when `glob::Pattern::new` would reject it.
    init?(_ pattern: String) {
        let chars = Array(pattern.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "?":
                tokens.append(.anyChar)
                i += 1
            case "*":
                let old = i
                while i < chars.count, chars[i] == "*" {
                    i += 1
                }
                let count = i - old
                if count > 2 {
                    return nil
                } else if count == 2 {
                    guard i == 2 || chars[i - count - 1] == "/" else { return nil }
                    if i < chars.count, chars[i] == "/" {
                        i += 1
                    } else if i != chars.count {
                        return nil
                    }
                    if !(tokens.count > 1 && tokens[tokens.count - 1] == .anyRecursiveSequence) {
                        tokens.append(.anyRecursiveSequence)
                    }
                } else {
                    tokens.append(.anySequence)
                }
            case "[":
                if i + 4 <= chars.count, chars[i + 1] == "!" {
                    if let j = chars[(i + 3)...].firstIndex(of: "]") {
                        tokens.append(.anyExcept(Self.parseSpecifiers(Array(chars[(i + 2)..<j]))))
                        i = j + 1
                        continue
                    }
                } else if i + 3 <= chars.count, chars[i + 1] != "!" {
                    if let j = chars[(i + 2)...].firstIndex(of: "]") {
                        tokens.append(.anyWithin(Self.parseSpecifiers(Array(chars[(i + 1)..<j]))))
                        i = j + 1
                        continue
                    }
                }
                return nil
            default:
                tokens.append(.char(chars[i]))
                i += 1
            }
        }
        self.tokens = tokens
    }

    /// `Pattern::matches` with default options.
    func matches(_ string: String) -> Bool {
        if case .match = matchesFrom(followsSeparator: true, Array(string.unicodeScalars)[...], 0) {
            return true
        }
        return false
    }

    private static func parseSpecifiers(_ s: [Unicode.Scalar]) -> [Specifier] {
        var specifiers: [Specifier] = []
        var i = 0
        while i < s.count {
            if i + 3 <= s.count, s[i + 1] == "-" {
                specifiers.append(.range(s[i], s[i + 2]))
                i += 3
            } else {
                specifiers.append(.single(s[i]))
                i += 1
            }
        }
        return specifiers
    }

    private static func inSpecifiers(_ specifiers: [Specifier], _ c: Unicode.Scalar) -> Bool {
        for specifier in specifiers {
            switch specifier {
            case let .single(sc):
                if c == sc { return true }
            case let .range(start, end):
                if c >= start, c <= end { return true }
            }
        }
        return false
    }

    private func matchesFrom(
        followsSeparator initialFollows: Bool,
        _ initialFile: ArraySlice<Unicode.Scalar>,
        _ start: Int
    ) -> MatchResult {
        var followsSeparator = initialFollows
        var file = initialFile
        var ti = start
        while ti < tokens.count {
            let token = tokens[ti]
            switch token {
            case .anySequence, .anyRecursiveSequence:
                switch matchesFrom(followsSeparator: followsSeparator, file, ti + 1) {
                case .subPatternDoesntMatch: break
                case let other: return other
                }
                while let c = file.first {
                    file = file.dropFirst()
                    followsSeparator = c == "/"
                    if token == .anyRecursiveSequence, !followsSeparator {
                        continue
                    }
                    switch matchesFrom(followsSeparator: followsSeparator, file, ti + 1) {
                    case .subPatternDoesntMatch: break
                    case let other: return other
                    }
                }
            default:
                guard let c = file.first else { return .entirePatternDoesntMatch }
                file = file.dropFirst()
                let matched: Bool
                switch token {
                case .anyChar: matched = true
                case let .anyWithin(specifiers): matched = Self.inSpecifiers(specifiers, c)
                case let .anyExcept(specifiers): matched = !Self.inSpecifiers(specifiers, c)
                case let .char(expected): matched = c == expected
                case .anySequence, .anyRecursiveSequence: matched = false
                }
                if !matched {
                    return .subPatternDoesntMatch
                }
                followsSeparator = c == "/"
            }
            ti += 1
        }
        return file.isEmpty ? .match : .subPatternDoesntMatch
    }
}
