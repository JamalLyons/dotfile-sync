private let contextLines = 3
private let maxEditDistance = 2_048
private let maxComparisonWork = 8_388_608

private enum LineEdit {
    case context(Int)
    case deletion(Int)
    case addition(Int)
}

private struct DiffLines {
    let bytes: [UInt8]
    let ranges: [Range<Int>]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var ranges: [Range<Int>] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            ranges.append(start..<(index + 1))
            start = index + 1
        }
        if start < bytes.count { ranges.append(start..<bytes.count) }
        self.ranges = ranges
    }

    subscript(index: Int) -> ArraySlice<UInt8> { bytes[ranges[index]] }

    func append(_ index: Int, prefix: String, to lines: inout [String]) {
        let line = self[index]
        let terminated = line.last == 10
        lines.append(prefix + String(decoding: terminated ? line.dropLast() : line, as: UTF8.self))
        if !terminated { lines.append("\\ No newline at end of file") }
    }
}

func lineEdits(from base: [UInt8], to machine: [UInt8]) -> (
    additions: Int, deletions: Int, hunks: [ConfigDiffHunk]
)? {
    let old = DiffLines(base)
    let new = DiffLines(machine)
    let sharedLength = min(old.ranges.count, new.ranges.count)
    var prefix = 0
    while prefix < sharedLength, old[prefix].elementsEqual(new[prefix]) { prefix += 1 }
    var suffix = 0
    while suffix < sharedLength - prefix,
          old[old.ranges.count - suffix - 1].elementsEqual(new[new.ranges.count - suffix - 1]) {
        suffix += 1
    }

    let oldEnd = old.ranges.count - suffix
    let newEnd = new.ranges.count - suffix
    var edits = (0..<prefix).map(LineEdit.context)
    if oldEnd == prefix || newEnd == prefix {
        edits.append(contentsOf: (prefix..<oldEnd).map(LineEdit.deletion))
        edits.append(contentsOf: (prefix..<newEnd).map(LineEdit.addition))
    } else {
        guard let middle = myersEdits(old, new, start: prefix, oldEnd: oldEnd, newEnd: newEnd) else { return nil }
        edits.append(contentsOf: middle)
    }
    edits.append(contentsOf: (oldEnd..<old.ranges.count).map(LineEdit.context))
    return makeHunks(edits, old: old, new: new)
}

/// Myers shortest edit script. Each row stores the furthest old-line index on the reachable
/// diagonals for one edit distance. The caps bound memory and work for highly divergent files.
private func myersEdits(
    _ old: DiffLines, _ new: DiffLines, start: Int, oldEnd: Int, newEnd: Int
) -> [LineEdit]? {
    let limit = min(maxEditDistance, oldEnd - start + newEnd - start)
    var trace: [[Int]] = [[start]]
    var comparisonWork = 0
    for distance in 1...limit {
        let previous = trace[distance - 1]
        var row: [Int] = []
        row.reserveCapacity(distance + 1)
        for slot in 0...distance {
            let diagonal = 2 * slot - distance
            let insert = cameFromInsertion(slot, distance: distance, previous: previous)
            var x = insert ? previous[slot] : previous[slot - 1] + 1
            var y = x - diagonal
            while x < oldEnd, y < newEnd {
                let a = old[x], b = new[y]
                comparisonWork += a.count == b.count ? a.count : 1
                guard comparisonWork <= maxComparisonWork else { return nil }
                guard a.count == b.count, a.elementsEqual(b) else { break }
                x += 1
                y += 1
            }
            if x == oldEnd, y == newEnd {
                return backtrack(trace, oldEnd: x, newEnd: y)
            }
            row.append(x)
        }
        trace.append(row)
    }
    return nil
}

private func cameFromInsertion(_ slot: Int, distance: Int, previous: [Int]) -> Bool {
    slot == 0 || (slot < distance && previous[slot - 1] < previous[slot])
}

private func backtrack(_ trace: [[Int]], oldEnd: Int, newEnd: Int) -> [LineEdit] {
    var x = oldEnd
    var y = newEnd
    var edits: [LineEdit] = []
    for distance in (1...trace.count).reversed() {
        let diagonal = x - y
        let slot = (diagonal + distance) / 2
        let previous = trace[distance - 1]
        let insert = cameFromInsertion(slot, distance: distance, previous: previous)
        let oldBefore = previous[insert ? slot : slot - 1]
        let newBefore = oldBefore - (diagonal + (insert ? 1 : -1))
        while x > oldBefore, y > newBefore {
            x -= 1
            y -= 1
            edits.append(.context(x))
        }
        if insert { edits.append(.addition(newBefore)) }
        else { edits.append(.deletion(oldBefore)) }
        x = oldBefore
        y = newBefore
    }
    return edits.reversed()
}

private func makeHunks(_ edits: [LineEdit], old: DiffLines, new: DiffLines) -> (
    additions: Int, deletions: Int, hunks: [ConfigDiffHunk]
) {
    var spans: [Range<Int>] = []
    for (index, edit) in edits.enumerated() {
        if case .context = edit { continue }
        let start = max(0, index - contextLines)
        let end = min(edits.count, index + contextLines + 1)
        if let last = spans.last, start <= last.upperBound {
            spans[spans.count - 1] = last.lowerBound..<end
        } else {
            spans.append(start..<end)
        }
    }

    var hunks: [ConfigDiffHunk] = []
    var additions = 0, deletions = 0
    var oldPosition = 0, newPosition = 0, previousEnd = 0
    for span in spans {
        let skipped = span.lowerBound - previousEnd
        oldPosition += skipped
        newPosition += skipped
        var oldCount = 0, newCount = 0
        var lines: [String] = []
        for edit in edits[span] {
            switch edit {
            case let .context(index):
                old.append(index, prefix: " ", to: &lines)
                oldCount += 1
                newCount += 1
            case let .deletion(index):
                old.append(index, prefix: "-", to: &lines)
                oldCount += 1
                deletions += 1
            case let .addition(index):
                new.append(index, prefix: "+", to: &lines)
                newCount += 1
                additions += 1
            }
        }
        hunks.append(ConfigDiffHunk(
            oldStart: oldPosition + (oldCount == 0 ? 0 : 1), oldCount: oldCount,
            newStart: newPosition + (newCount == 0 ? 0 : 1), newCount: newCount, lines: lines))
        oldPosition += oldCount
        newPosition += newCount
        previousEnd = span.upperBound
    }
    return (additions, deletions, hunks)
}
