import Foundation

struct RepositoryScanner: Sendable {
    private let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".gradle", ".idea", ".turbo", ".venv", ".worktree", ".worktrees",
        "DerivedData", "Pods", "build", "dist", "node_modules", "vendor"
    ]

    func scan(rootURL: URL, maximumDepth: Int = 6) -> [URL] {
        let fileManager = FileManager.default
        var queue: [(url: URL, depth: Int)] = [(rootURL.standardizedFileURL, 0)]
        var repositories: [URL] = []
        var visited: Set<String> = []

        while !queue.isEmpty {
            let next = queue.removeFirst()
            let path = next.url.resolvingSymlinksInPath().path
            guard visited.insert(path).inserted else { continue }

            let gitMarker = next.url.appendingPathComponent(".git", isDirectory: false)
            if fileManager.fileExists(atPath: gitMarker.path) {
                repositories.append(next.url)
            }

            guard next.depth < maximumDepth else { continue }
            guard let children = try? fileManager.contentsOfDirectory(
                at: next.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                continue
            }

            for child in children {
                guard !shouldIgnoreDirectory(child) else { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                queue.append((child, next.depth + 1))
            }
        }

        return repositories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func shouldIgnoreDirectory(_ url: URL) -> Bool {
        if ignoredDirectoryNames.contains(url.lastPathComponent) {
            return true
        }

        guard url.lastPathComponent == "worktrees" else { return false }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName == ".claude" || parentName == ".codex"
    }
}
