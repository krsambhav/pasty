import Foundation

/// Imports and exports `.clipbookarchive` folders in batches, off the main thread, with progress
/// and cancellation. Large histories (tens of thousands of entries, gigabytes of images) stream
/// through in fixed-size chunks rather than being held in memory at once.
public enum ArchiveTransfer {
    public struct Progress: Sendable, Equatable {
        public var completed: Int
        public var total: Int
        public init(completed: Int, total: Int) {
            self.completed = completed
            self.total = total
        }
    }

    public struct ImportSummary: Sendable, Equatable {
        public var total = 0
        public var inserted = 0
        /// Already in Pasty: merged into the existing entry instead of duplicated.
        public var merged = 0
        /// Images whose file wasn't in the archive.
        public var missingAssets = 0
        public var skipped = 0
        public var sourceApp = ""
        public init() {}
    }

    public struct ExportSummary: Sendable, Equatable {
        public var exported = 0
        /// Entries ClipBook's format can't hold (opaque app data).
        public var skipped = 0
        public var archiveURL: URL
    }

    static let chunkSize = 200

    private typealias Conversion = (index: Int, result: Result<ImportedClip, ClipBookArchive.SkipReasonBox>)

    // MARK: Import

    public static func importArchive(
        at root: URL,
        into store: ClipboardStore,
        includeImages: Bool = true,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let contents = try await Task.detached(priority: .userInitiated) { try ClipBookArchive.read(at: root) }.value
        var items = contents.items
        if !includeImages { items.removeAll { $0.kind == "image" } }

        var summary = ImportSummary()
        summary.total = items.count
        summary.sourceApp = contents.manifest.appName
        progress(Progress(completed: 0, total: items.count))

        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var offset = 0
        while offset < items.count {
            try Task.checkCancellation()
            let chunk = Array(items[offset..<min(offset + chunkSize, items.count)])
            let converted = await convert(chunk, root: root, workers: workers)

            var batch: [ImportedClip] = []
            batch.reserveCapacity(converted.count)
            for conversion in converted {
                switch conversion.result {
                case let .success(clip): batch.append(clip)
                case let .failure(box):
                    if box.reason == .missingAsset { summary.missingAssets += 1 } else { summary.skipped += 1 }
                }
            }
            let (inserted, merged) = try await store.importClips(batch)
            summary.inserted += inserted
            summary.merged += merged
            offset += chunk.count
            progress(Progress(completed: offset, total: items.count))
        }
        return summary
    }

    /// Converts a chunk in parallel (image thumbnails dominate the cost), preserving order.
    private static func convert(_ chunk: [ClipBookArchive.Item], root: URL, workers: Int) async -> [Conversion] {
        let sliceSize = max(1, (chunk.count + workers - 1) / workers)
        let results = await withTaskGroup(of: [Conversion].self) { group in
            for start in stride(from: 0, to: chunk.count, by: sliceSize) {
                let part = Array(chunk[start..<min(start + sliceSize, chunk.count)])
                group.addTask {
                    part.enumerated().map { offset, item in
                        (start + offset, ClipBookArchive.importedClip(from: item, archiveRoot: root))
                    }
                }
            }
            var all: [Conversion] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
        return results.sorted { $0.index < $1.index }
    }

    // MARK: Export

    /// Writes the whole history (pinned items included) as a `.clipbookarchive` folder at `root`,
    /// replacing anything already there.
    public static func exportArchive(
        from store: ClipboardStore,
        to root: URL,
        appVersion: String?,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> ExportSummary {
        let fm = FileManager.default
        let staging = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let items = try await store.items(limit: 1_000_000)
            progress(Progress(completed: 0, total: items.count))
            var archived: [ClipBookArchive.Item] = []
            archived.reserveCapacity(items.count)
            var skipped = 0
            for (index, item) in items.enumerated() {
                if index % 50 == 0 {
                    try Task.checkCancellation()
                    progress(Progress(completed: index, total: items.count))
                }
                guard let snapshot = try await store.snapshot(for: item.id),
                      let entry = try ClipBookArchive.archiveItem(for: item, snapshot: snapshot, root: staging) else {
                    skipped += 1
                    continue
                }
                archived.append(entry)
            }
            try ClipBookArchive.writeIndex(items: archived, root: staging, appVersion: appVersion)
            // Swap in atomically, so a cancelled or failed export never leaves half an archive.
            if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            try fm.moveItem(at: staging, to: root)
            progress(Progress(completed: items.count, total: items.count))
            return ExportSummary(exported: archived.count, skipped: skipped, archiveURL: root)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
