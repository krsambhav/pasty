import AppKit
import Observation
import PastyCore

/// Runs `.clipbookarchive` imports and exports for the Settings window: picks files, reports
/// progress, supports cancelling, and adjusts the history limit so imported items are kept.
@MainActor
@Observable
final class ArchiveController {
    enum State: Equatable {
        case idle
        case running(title: String, completed: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var includeImages = true

    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let model: PanelModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: ClipboardStore, preferences: Preferences, model: PanelModel) {
        self.store = store
        self.preferences = preferences
        self.model = model
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Import

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Clipboard History"
        panel.message = "Choose a .clipbookarchive folder exported from ClipBook or Pasty."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.lastPathComponent == "manifest.json" || url.lastPathComponent == "history.json" {
            url = url.deletingLastPathComponent()
        }
        startImport(from: url)
    }

    func startImport(from url: URL) {
        guard !isRunning else { return }
        state = .running(title: "Importing", completed: 0, total: 0)
        let includeImages = includeImages
        task = Task { [store, weak self] in
            do {
                let summary = try await ArchiveTransfer.importArchive(at: url, into: store, includeImages: includeImages) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.state = .running(title: "Importing", completed: progress.completed, total: progress.total)
                    }
                }
                await self?.finishImport(summary)
            } catch is CancellationError {
                await self?.model.reload()
                self?.state = .finished("Import cancelled. Items imported so far were kept.")
            } catch {
                self?.state = .failed(Self.describe(error))
            }
            self?.task = nil
        }
    }

    private func finishImport(_ summary: ArchiveTransfer.ImportSummary) async {
        // Keep everything that was imported: raise the history limit if the import exceeds it.
        var limitNote = ""
        if let unpinned = try? await store.unpinnedCount(), unpinned > preferences.maxHistory {
            let newLimit = Preferences.historyLimitChoices.first { $0 >= unpinned } ?? Preferences.historyLimitChoices.last!
            if newLimit > preferences.maxHistory {
                preferences.maxHistory = newLimit
                limitNote = " History size raised to \(newLimit.formatted()) to keep it all."
            }
            if unpinned > newLimit {
                limitNote += " Only the newest \(newLimit.formatted()) unpinned items will be kept."
            }
        }
        await model.reload()

        var parts = ["Imported \(summary.inserted.formatted()) item\(summary.inserted == 1 ? "" : "s") from \(summary.sourceApp)."]
        if summary.merged > 0 { parts.append("\(summary.merged.formatted()) were already in Pasty.") }
        if summary.missingAssets > 0 { parts.append("\(summary.missingAssets.formatted()) images were missing from the archive.") }
        if summary.skipped > 0 { parts.append("\(summary.skipped.formatted()) couldn’t be imported.") }
        state = .finished(parts.joined(separator: " ") + limitNote)
    }

    // MARK: Export

    func chooseAndExport() {
        let panel = NSSavePanel()
        panel.title = "Export Clipboard History"
        panel.message = "Pasty writes a .clipbookarchive folder that Pasty and ClipBook can import."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Pasty Export.\(ClipBookArchive.fileExtension)"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ClipBookArchive.fileExtension {
            url = url.appendingPathExtension(ClipBookArchive.fileExtension)
        }
        startExport(to: url)
    }

    func startExport(to url: URL) {
        guard !isRunning else { return }
        state = .running(title: "Exporting", completed: 0, total: 0)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        task = Task { [store, weak self] in
            do {
                let summary = try await ArchiveTransfer.exportArchive(from: store, to: url, appVersion: version) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.state = .running(title: "Exporting", completed: progress.completed, total: progress.total)
                    }
                }
                var message = "Exported \(summary.exported.formatted()) item\(summary.exported == 1 ? "" : "s") to “\(url.lastPathComponent)”."
                if summary.skipped > 0 { message += " \(summary.skipped.formatted()) app-specific items can’t be stored in this format." }
                self?.state = .finished(message)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                self?.state = .finished("Export cancelled. Nothing was written.")
            } catch {
                self?.state = .failed(Self.describe(error))
            }
            self?.task = nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? ClipBookArchive.ArchiveError { return error.description }
        return error.localizedDescription
    }
}
