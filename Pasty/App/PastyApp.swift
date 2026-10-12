import AppKit
import Quartz

@main
enum PastyApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu bar utility: no Dock icon, no app switcher entry. (Also set via LSUIElement.)
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let coordinator = AppCoordinator(launchOptions: LaunchOptions(arguments: CommandLine.arguments))
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Opening Pasty again from Finder/Spotlight shows Settings — the only way back in when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    // Quick Look looks for its controller along the key window's responder chain, which ends at
    // the app delegate. Answering here works whichever window has focus, Quick Look's included.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { coordinator?.panelController.isVisible == true }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { coordinator?.panelController.quickLook.beginControl(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { coordinator?.panelController.quickLook.endControl(panel) }
    }
}

struct LaunchOptions {
    /// `--smoke-test <dir>`: run the automated end-to-end check, write results to `dir`, quit.
    var smokeTestOutput: URL?
    /// Set by the update installer when it relaunches Pasty.
    var afterUpdate = false

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--smoke-test"), arguments.indices.contains(index + 1) {
            smokeTestOutput = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        afterUpdate = arguments.contains("--after-update")
    }
}
