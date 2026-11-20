import AppKit
import SwiftUI
import Combine

/// The app's place in the menu bar: an eye and your blinks per minute. A click opens a
/// small panel under it.
///
/// AppKit names the pieces: an NSStatusItem is the slot in the menu bar, its `button` is
/// what is drawn there, and an NSPopover is the panel with the little arrow. The panel's
/// content is a SwiftUI view, placed inside AppKit by an NSHostingController.
@MainActor
final class StatusItemController: NSObject {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscription: AnyCancellable?

    init(model: MonitorModel, actions: PanelActions) {
        super.init()

        // Each action first closes the panel, then does its work.
        var closing = PanelActions()
        closing.openHistory = { [weak self] in self?.popover.performClose(nil); actions.openHistory() }
        closing.openDiagnostics = { [weak self] in self?.popover.performClose(nil); actions.openDiagnostics() }
        closing.quit = actions.quit

        let panel = MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                  loginItem: model.loginItem, actions: closing)
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]    // the panel takes its content's size
        popover.contentViewController = host
        popover.behavior = .transient                   // a click anywhere else closes it

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
            // Digits of equal width: the item does not twitch when 9 becomes 10.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Blink Monitor")
        }
        show(model.statusSummary)

        // `$statusSummary` is a stream of the property's values: every time the model
        // changes it, this block runs and redraws the menu-bar item.
        subscription = model.$statusSummary
            .removeDuplicates()
            .sink { [weak self] summary in self?.show(summary) }
    }

    private func show(_ summary: StatusSummary) {
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: summary.symbol, accessibilityDescription: "Blink Monitor")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "Blink Monitor")
        // A "template" image is drawn by macOS in the menu bar's own colour: black on a
        // light bar, white on a dark one.
        image?.isTemplate = true
        button.image = image
        button.title = summary.text.isEmpty ? "" : " " + summary.text
        button.toolTip = summary.tooltip
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // An accessory app is never "in front" by itself; without this the panel's
            // controls would not take the first click.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// An ordinary window around a SwiftUI view, created the first time it is shown and kept.
/// Closing it leaves the app running in the menu bar.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {

    private let title: String
    private let resizable: Bool
    private let makeView: () -> AnyView
    private var window: NSWindow?

    /// Called when the window appears and when it closes.
    var onVisibilityChange: ((Bool) -> Void)?

    init<Content: View>(title: String, resizable: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.resizable = resizable
        makeView = { AnyView(content()) }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeView()))
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        onVisibilityChange?(true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}
