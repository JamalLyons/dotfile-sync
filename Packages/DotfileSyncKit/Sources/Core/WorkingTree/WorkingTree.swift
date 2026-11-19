import System

/// Builds a sorted HOME-relative tree, including tracked paths absent from discovery.
/// Machine-local files are excluded. Missing or unreadable tracked files are modified.
public func buildWorkingTree(
    report: ConfigDiscoveryReport, resolved: ResolvedManifest, home: FilePath, repoRoot: FilePath
) -> WorkingTree {
    let inspector = ConfigInspector(
        repoRoot: repoRoot, homeDir: home, exclusions: resolved.exclusions, overrides: resolved.overrides)
    let paths = WorkingTreePaths(report: report, resolved: resolved, home: home, repoRoot: repoRoot)
    return makeWorkingTree(report: report, paths: paths, inspect: inspector.inspectFile)
}

func makeWorkingTree(
    report: ConfigDiscoveryReport, paths: WorkingTreePaths, inspect: (TrackedFile) -> ObservedConfigFile
) -> WorkingTree {
    var children: [FilePath: Set<FilePath>] = [:]
    for path in Set(paths.discovered.keys).union(paths.tracked.keys) {
        var child = path
        while !child.isEmpty {
            let parent = child.removingLastComponent()
            guard children[parent, default: []].insert(child).inserted else { break }
            child = parent
        }
    }

    func node(_ path: FilePath) -> WorkingTreeNode {
        let entry = paths.discovered[path]
        let tracked = paths.tracked[path]
        let childNodes = (children[path] ?? []).sorted(by: rustPathPrecedes).map(node)
        let directory = path.isEmpty || entry?.kind == .directory || !childNodes.isEmpty
        let kind = directory ? .directory : entry?.kind ?? .file
        let classification = paths.classification(path)
        var reason = paths.targetExclusion(path, entry: tracked)
        var status: WorkingTreeStatus?
        if reason != nil {
            if tracked != nil || entry.map({ $0.kind != .directory }) == true { status = .excluded }
        } else if let tracked {
            do {
                let source = try paths.sourceLocation(paths.sourceRelativePath(tracked))
                if let source {
                    _ = try paths.targetLocation(path, source: source)
                    switch inspect(tracked).state {
                    case .matching, .symlinkToSource: status = .managed
                    case .excluded, .machineLocal:
                        status = .excluded
                        reason = "Excluded by manifest"
                    default: status = .modified
                    }
                } else {
                    status = .modified
                }
            } catch WorkingTreeError.excluded {
                status = .excluded
                reason = "Repository source or machine file is excluded"
            } catch {
                status = .modified
            }
        } else if let entry, entry.kind != .directory {
            status = .unmanaged
        }

        var aggregate: WorkingTreeCounts?
        if directory {
            var counts = WorkingTreeCounts()
            if let status { counts.count(status) }
            for child in childNodes {
                if let childCounts = child.aggregate { counts.add(childCounts) }
                else if let childStatus = child.status { counts.count(childStatus) }
            }
            aggregate = counts
        }
        let language = directory || classification.class.isExcludedByDefault ? nil : detectConfigLanguage(path)
        return WorkingTreeNode(
            relativePath: path.string, kind: kind, status: status, class: classification.class,
            language: entry?.language ?? language, tool: entry == nil ? ToolRegistry.owner(of: path)?.id : entry?.tool,
            managedSource: tracked?.source,
            excludedReason: reason, aggregate: aggregate, children: directory ? childNodes : nil)
    }

    return WorkingTree(root: node(FilePath()), truncated: report.truncated, diagnostics: report.diagnostics)
}
