import AppKit

/// Reads and writes `PasteboardSnapshot`s, preserving every useful representation.
public enum PasteboardIO {
    /// Types we always try to keep first when an entry is near the size budget.
    private static let essentialTypes: [String] =
        [PasteboardType.fileURL, PasteboardType.string, PasteboardType.url] + PasteboardType.images + PasteboardType.richText

    /// All types currently on the pasteboard. Cheap: no data is transferred.
    public static func types(of pasteboard: NSPasteboard) -> Set<String> {
        Set((pasteboard.types ?? []).map(\.rawValue))
    }

    /// Copies the pasteboard's contents.
    ///
    /// - Skips file promises, the provenance marker, and opaque `dyn.*` types when real types exist.
    /// - Keeps the total under `maxBytes`, favouring essential types; returns nil if nothing fits.
    public static func read(_ pasteboard: NSPasteboard, maxBytes: Int, includeImages: Bool = true) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var budget = maxBytes
        var snapshots: [PasteboardItemSnapshot] = []

        for item in items {
            let available = item.types.map(\.rawValue)
            let hasRealTypes = available.contains { !$0.hasPrefix("dyn.") }
            var wanted = available.filter { type in
                if PasteboardType.unreplayable.contains(type) || type == PasteboardType.source { return false }
                if PasteboardType.synthesized.contains(type) { return false }
                if hasRealTypes, type.hasPrefix("dyn.") { return false }
                if !includeImages, PasteboardType.images.contains(type) { return false }
                return true
            }
            // Read essentials first so a huge auxiliary type can't starve them of budget,
            // then restore the source app's original ordering (richest first).
            let originalOrder = Dictionary(uniqueKeysWithValues: wanted.enumerated().map { ($1, $0) })
            wanted.sort { lhs, rhs in
                let l = essentialTypes.firstIndex(of: lhs) ?? Int.max
                let r = essentialTypes.firstIndex(of: rhs) ?? Int.max
                return l != r ? l < r : originalOrder[lhs]! < originalOrder[rhs]!
            }

            var representations: [PasteboardRepresentation] = []
            for type in wanted {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                guard data.count <= budget else { continue }
                budget -= data.count
                representations.append(PasteboardRepresentation(type: type, data: data))
            }
            representations.sort { originalOrder[$0.type]! < originalOrder[$1.type]! }
            if !representations.isEmpty {
                snapshots.append(PasteboardItemSnapshot(representations: representations))
            }
        }
        guard !snapshots.isEmpty else { return nil }
        return PasteboardSnapshot(items: snapshots)
    }

    /// Replaces the pasteboard's contents with `snapshot` and returns the new change count.
    @discardableResult
    public static func write(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard, sourceBundleID: String? = nil) -> Int {
        let items = snapshot.items.enumerated().map { index, itemSnapshot in
            let item = NSPasteboardItem()
            for rep in itemSnapshot.representations {
                item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            if index == 0, let sourceBundleID {
                item.setString(sourceBundleID, forType: NSPasteboard.PasteboardType(PasteboardType.source))
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// The bundle identifier a cooperating app declared via `org.nspasteboard.source`.
    public static func declaredSource(of pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardType.source))
    }
}
