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

    init(model: MonitorModel, openLiveView: @escaping () -> Void) {
        super.init()

        let panel = MenuPanelView(model: model, openLiveView: { [weak self] in
            self?.popover.performClose(nil)
            openLiveView()
        })
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

/// The live view: the camera, the counters and the curve, in an ordinary window opened
/// from the panel. Closing it leaves the app running in the menu bar.
@MainActor
final class LiveWindowController: NSObject, NSWindowDelegate {

    private let model: MonitorModel
    private var window: NSWindow?

    init(model: MonitorModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MonitorView(model: model)))
            window.title = "Blink Monitor - live view"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.setLiveWindowOpen(true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.setLiveWindowOpen(false)
    }
}
