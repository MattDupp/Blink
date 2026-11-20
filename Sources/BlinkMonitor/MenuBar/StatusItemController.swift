import AppKit
import SwiftUI
import Combine
import BlinkCore

/// The app's place in the menu bar: an eye and your blinks per minute. A click opens a
/// small panel under it.
///
/// AppKit names the pieces: an NSStatusItem is the slot in the menu bar, its `button` is
/// what is drawn there, and an NSPopover is the panel with the little arrow. The panel's
/// content is a SwiftUI view, placed inside AppKit by an NSHostingController.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: MonitorModel
    private let panelState = PanelState()
    private var subscription: AnyCancellable?
    private var blinks: AnyCancellable?
    /// The eye is drawn closed until this moment (see `blinkBack`).
    private var eyeClosedUntil = Date.distantPast
    /// What the item currently draws: the status, and whether the rate is written next to it.
    private var shown: (status: MonitorStatus, withRate: Bool)?

    init(model: MonitorModel, actions: PanelActions) {
        self.model = model
        super.init()

        // Each action first closes the panel, then does its work.
        func closing(_ action: @escaping () -> Void) -> () -> Void {
            { [weak self] in self?.popover.performClose(nil); action() }
        }
        let panel = MenuPanelView(
            model: model, history: model.history, reminders: model.reminders, preferences: model.preferences,
            state: panelState,
            actions: PanelActions(startBlinkBreak: closing(actions.startBlinkBreak), openHistory: closing(actions.openHistory),
                                  openSettings: closing(actions.openSettings), openLiveView: closing(actions.openLiveView),
                                  openCameraSettings: closing(actions.openCameraSettings), quit: actions.quit))
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]    // the panel takes its content's size
        popover.contentViewController = host
        popover.behavior = .transient                   // a click anywhere else closes it
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
            // Digits of equal width: the item does not twitch when 9 becomes 10.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Blink Monitor")
        }
        refresh()

        // The status is derived from facts held in three places (the model, the history,
        // the preferences). Each of them announces "I am about to change"; a moment
        // later the status is asked again and the item redrawn if it differs. Nothing has
        // to remember to "update the menu bar".
        subscription = model.objectWillChange
            .merge(with: model.history.objectWillChange, model.preferences.objectWillChange)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refresh() }
        blinks = model.blinked.sink { [weak self] in self?.blinkBack() }
    }

    /// Opens the panel under the item (unless it is open): how the app shows where it lives.
    ///
    /// Right after launch the item is not in the menu bar yet: its window exists but has no
    /// height, and a panel anchored to it does not open (seen in the log of the first demo
    /// run: "frame (0, 0, 81, 0)", then "(3099, 951, 97, 33)" a moment later). So this
    /// waits for the item to be placed, for up to five seconds.
    func showPanel(attemptsLeft: Int = 25) {
        guard !popover.isShown else { return }
        guard let window = item.button?.window, window.frame.height > 0 else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.showPanel(attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        togglePanel()
        Log.app.notice("Panel opened by itself: \(self.popover.isShown, privacy: .public)")
    }

    /// You blinked: the eye in the menu bar closes for a moment too. It costs one small
    /// picture swap, and it answers at once the first question anyone has: does it see me?
    private func blinkBack() {
        guard model.preferences.blinkBack, model.status().isCameraOn,
              let closed = NSImage(systemSymbolName: "eye.half.closed", accessibilityDescription: "Blink Monitor") else { return }
        closed.isTemplate = true
        item.button?.image = closed
        eyeClosedUntil = Date().addingTimeInterval(0.16)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            self?.shown = nil            // draw the item afresh, whatever it shows now
            self?.refresh()
        }
    }

    private func refresh() {
        guard Date() >= eyeClosedUntil else { return }      // mid-blink: `blinkBack` redraws in a moment
        let status = model.status()
        let withRate = model.preferences.showRateInMenuBar
        guard status != shown?.status || withRate != shown?.withRate, let button = item.button else { return }
        shown = (status, withRate)
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "Blink Monitor")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "Blink Monitor")
        // A "template" image is drawn by macOS in the menu bar's own colour: black on a
        // light bar, white on a dark one.
        image?.isTemplate = true
        button.image = image
        let demo = model.isDemo ? " demo" : ""
        button.title = (withRate && !status.menuBarText.isEmpty ? " " + status.menuBarText : "") + demo
        button.toolTip = (model.isDemo ? "Demo, on made-up eyes. " : "") + status.tooltip
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

    /// The panel opens next time as it first was: no pause choices left showing.
    func popoverDidClose(_ notification: Notification) {
        panelState.reset()
    }
}

/// An ordinary window around a SwiftUI view, created the first time it is shown and kept.
/// Closing it leaves the app running in the menu bar.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {

    private let title: String
    private let resizable: Bool
    private let remembersPosition: Bool
    private let makeView: () -> AnyView
    private var window: NSWindow?

    /// Called when the window opens and when it closes.
    var onVisibilityChange: ((Bool) -> Void)?

    init<Content: View>(title: String, resizable: Bool = false, remembersPosition: Bool = true,
                        @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.resizable = resizable
        self.remembersPosition = remembersPosition
        makeView = { AnyView(content()) }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            // A window of fixed size takes its content's size, and follows it when the
            // content changes (another tab of Settings); its title bar stays where it is.
            if !resizable { host.sizingOptions = [.preferredContentSize] }
            let window = NSWindow(contentViewController: host)
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Next time it opens where you left it (macOS keeps the place under this name).
            if remembersPosition { window.setFrameAutosaveName(title) }
            self.window = window
        }
        if window?.isVisible != true { onVisibilityChange?(true) }     // not again for a window already open
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
