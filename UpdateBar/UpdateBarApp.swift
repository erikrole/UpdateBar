import AppKit
import SwiftUI

@main
struct UpdateBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UpdateStore()
    private let launchAtLogin = LaunchAtLoginController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if let index = CommandLine.arguments.firstIndex(of: "--install"),
           CommandLine.arguments.indices.contains(index + 1) {
            let bundleIdentifier = CommandLine.arguments[index + 1]
            Task { await installAndExit(bundleIdentifier) }
            return
        }
        if CommandLine.arguments.contains("--report") {
            Task { await printReportAndExit() }
            return
        }
        configurePopover()
        configureStatusItem()
        configureOutsideClickMonitor()
        observeStore()
        store.start()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusItem = item
        updateStatusItem()
    }

    private func configureOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: UpdateBarView(store: store, launchAtLogin: launchAtLogin)
        )
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.pendingCount
            _ = store.isChecking
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusItem()
                self.observeStore()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = store.pendingCount
        let summary = count == 0 ? "UpdateBar: everything is up to date"
            : "UpdateBar: \(count) update\(count == 1 ? "" : "s") available"
        let symbol = count == 0 ? "arrow.down.app" : "arrow.down.app.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: summary)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.title = count == 0 ? "" : "\(count)"
        button.imagePosition = count == 0 ? .imageOnly : .imageLeading
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    /// `UpdateBar --report` runs one check, prints what it found and exits; handy for
    /// debugging a wrong result without opening the menu.
    private func printReportAndExit() async {
        await store.checkNow()
        var lines = ["\(store.appCount) apps, \(store.pendingCount) updates"]
        for row in store.rows {
            let others = row.alsoReportedBy.isEmpty ? "" : " (also \(row.alsoReportedBy.map(\.label).joined(separator: ", ")))"
            lines.append("UPDATE  \(row.app.name)  \(row.app.displayVersion) -> \(row.update.version)  [\(row.update.source.label)]\(others)")
        }
        for failure in store.failures {
            lines.append("FAILED  \(failure.subject) [\(failure.source.label)]: \(failure.message)")
        }
        print(lines.joined(separator: "\n"))
        exit(0)
    }

    /// `UpdateBar --install <bundle ID>` checks, installs that app's pending update the
    /// way the Update button would (Sparkle or Homebrew only), prints the outcome and exits.
    private func installAndExit(_ bundleIdentifier: String) async {
        await store.checkNow()
        guard let row = store.rows.first(where: { $0.app.bundleIdentifier == bundleIdentifier }) else {
            print("No pending update for \(bundleIdentifier)")
            exit(1)
        }
        let outcome: String
        switch row.update.action {
        case .sparkleInstall:
            switch await SparkleInstaller.install(row.app, progress: { print("  \($0)") }) {
            case .installed: outcome = "INSTALLED \(row.app.name) \(row.update.version)"
            case let .failure(message): outcome = "FAILED \(message)"
            }
        case let .brewUpgrade(token):
            switch await BrewRunner.upgrade(cask: token) {
            case .success: outcome = "INSTALLED \(row.app.name) \(row.update.version)"
            case let .failure(message): outcome = "FAILED \(message)"
            }
        default:
            outcome = "\(row.app.name) doesn't install in place"
        }
        print(outcome)
        exit(outcome.hasPrefix("INSTALLED") ? 0 : 1)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}
