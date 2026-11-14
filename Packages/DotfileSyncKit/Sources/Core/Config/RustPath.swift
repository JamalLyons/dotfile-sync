// Rust `std::path::Path` semantics needed by the inspector and comparison engine.
//
// Rust compares, orders, and suffix-matches paths component-wise (`Path::components`), not by
// raw bytes: repeated separators and interior `.` components are ignored, and `Component`
// ordering is `RootDir < CurDir < ParentDir < Normal(bytes)`. These helpers reproduce that on
// native path bytes so non-UTF-8 paths keep their exact bytes.

import System

/// One Rust `std::path::Component` on Unix. Case order matches the Rust derived `Ord`.
enum RustPathComponent: Comparable, Hashable {
    case rootDir
    case curDir
    case parentDir
    case normal([UInt8])

    static func < (lhs: RustPathComponent, rhs: RustPathComponent) -> Bool {
        switch (lhs, rhs) {
        case let (.normal(a), .normal(b)):
            return a.lexicographicallyPrecedes(b)
        default:
            return lhs.rank < rhs.rank
        }
    }

    private var rank: Int {
        switch self {
        case .rootDir: return 0
        case .curDir: return 1
        case .parentDir: return 2
        case .normal: return 3
        }
    }
}

/// `Path::components` for Unix path bytes.
func rustComponents(bytes: [UInt8]) -> [RustPathComponent] {
    let slash = UInt8(ascii: "/")
    let dot = UInt8(ascii: ".")
    var components: [RustPathComponent] = []
    let hasRoot = bytes.first == slash
    if hasRoot {
        components.append(.rootDir)
    } else if bytes == [dot] || (bytes.count >= 2 && bytes[0] == dot && bytes[1] == slash) {
        // A leading `.` is kept only for relative paths (Rust `include_cur_dir`).
        components.append(.curDir)
    }
    for part in bytes.split(separator: slash, omittingEmptySubsequences: true) {
        if part.count == 1, part.first == dot {
            continue
        }
        if part.count == 2, part.allSatisfy({ $0 == dot }) {
            components.append(.parentDir)
        } else {
            components.append(.normal(Array(part)))
        }
    }
    return components
}

func rustComponents(_ path: FilePath) -> [RustPathComponent] {
    rustComponents(bytes: pathBytes(path))
}

/// Rust `Path == Path` (component-wise).
func rustPathEqual(_ lhs: FilePath, _ rhs: FilePath) -> Bool {
    rustComponents(lhs) == rustComponents(rhs)
}

/// Rust `Path::cmp` (component-wise, lexicographic over components).
func rustPathPrecedes(_ lhs: FilePath, _ rhs: FilePath) -> Bool {
    rustComponents(lhs).lexicographicallyPrecedes(rustComponents(rhs))
}

/// Rust `Path::starts_with`.
func rustPathStartsWith(_ path: FilePath, _ base: FilePath) -> Bool {
    let lhs = rustComponents(path)
    let rhs = rustComponents(base)
    return lhs.count >= rhs.count && Array(lhs.prefix(rhs.count)) == rhs
}

/// Rust `Path::ends_with`, where `child` is a raw (undecoded) path string.
func rustPathEndsWith(_ path: FilePath, _ child: String) -> Bool {
    rustPathEndsWith(bytes: pathBytes(path), child)
}

func rustPathEndsWith(bytes: [UInt8], _ child: String) -> Bool {
    let lhs = rustComponents(bytes: bytes)
    let rhs = rustComponents(bytes: Array(child.utf8))
    return lhs.count >= rhs.count && Array(lhs.suffix(rhs.count)) == rhs
}

/// Rust `Path::file_name`: the final component when it is a normal name.
func rustFileName(_ path: FilePath) -> [UInt8]? {
    if case let .normal(bytes) = rustComponents(path).last {
        return bytes
    }
    return nil
}

/// Rust `Path::parent`: `nil` for a root or empty path.
func rustParent(_ path: FilePath) -> FilePath? {
    let components = rustComponents(path)
    guard let last = components.last else { return nil }
    switch last {
    case .normal, .curDir, .parentDir:
        return filePath(fromBytes: joinComponents(components.dropLast()))
    case .rootDir:
        return nil
    }
}

private func joinComponents(_ components: ArraySlice<RustPathComponent>) -> [UInt8] {
    var bytes: [UInt8] = []
    var needsSeparator = false
    for component in components {
        switch component {
        case .rootDir:
            bytes.append(UInt8(ascii: "/"))
            needsSeparator = false
            continue
        case .curDir:
            if needsSeparator { bytes.append(UInt8(ascii: "/")) }
            bytes.append(UInt8(ascii: "."))
        case .parentDir:
            if needsSeparator { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: [UInt8(ascii: "."), UInt8(ascii: ".")])
        case let .normal(name):
            if needsSeparator { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: name)
        }
        needsSeparator = true
    }
    return bytes
}
