import Foundation

/// Walks a watched folder and lists the files worth indexing.
public struct DocumentScanner: Sendable {
    public struct Result: Sendable {
        public var candidates: [DocumentCandidate]
        /// Paths the file system refused to describe — surfaced, never swallowed.
        public var unreadable: [String]
    }

    /// Folders never worth indexing. Source code is indexable, which makes a
    /// checkout of anything a minefield of vendored copies and build output — one
    /// `node_modules` can outweigh a whole library of documents.
    public static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", ".build", ".swiftpm", "build", "dist",
        "target", "out", "Pods", "Carthage", "DerivedData", "vendor", "__pycache__",
        ".venv", "venv", ".tox", ".gradle", ".next", ".nuxt", ".cache", ".terraform",
    ]

    private let extensions: Set<String>
    private let skipped: Set<String>

    public init(extensions: Set<String>, skipping: Set<String> = skippedDirectories) {
        self.extensions = extensions
        self.skipped = skipping
    }

    public func scan(rootID: Int64, at root: URL) -> Result {
        var candidates: [DocumentCandidate] = []
        var unreadable: [String] = []

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                unreadable.append(url.path)
                return true  // keep walking: one bad folder must not stop the scan
            })

        while let url = enumerator?.nextObject() as? URL {
            // Prune whole subtrees rather than filtering their files one by one.
            if skipped.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator?.skipDescendants()
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate
            else {
                unreadable.append(url.path)
                continue
            }
            candidates.append(DocumentCandidate(
                rootID: rootID,
                path: url.standardizedFileURL.path,
                size: Int64(size),
                modifiedAt: modified))
        }

        return Result(candidates: candidates, unreadable: unreadable)
    }
}
