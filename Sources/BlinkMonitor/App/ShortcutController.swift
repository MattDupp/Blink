import AppKit
import Carbon.HIToolbox
import Combine
import BlinkCore

/// Whoever can give the app a key combination that works from any app. The real one asks
/// macOS; the tests state the answer.
@MainActor
protocol HotKeys: AnyObject {
    /// Takes the combination. False: macOS refused (another app holds it, most likely).
    func register(_ choice: ShortcutChoice, pressed: @escaping () -> Void) -> Bool
    func unregister()
}

/// The optional shortcut that starts a blink break from any app. Off unless chosen.
///
/// It follows the choice in `Preferences`. Nothing is registered before `start`: the
/// screenshots and the tests build models that must never take a key from this Mac.
/// A refusal by macOS is kept in `refused` and said in Settings, never swallowed.
@MainActor
final class ShortcutController: ObservableObject {

    /// The combination macOS refused, while the choice is still that one.
    @Published private(set) var refused: ShortcutChoice?

    private let preferences: Preferences
    private let keys: HotKeys
    private var pressed: () -> Void = {}
    private var watching: AnyCancellable?

    init(preferences: Preferences, keys: HotKeys? = nil) {
        self.preferences = preferences
        self.keys = keys ?? CarbonHotKeys()
    }

    /// The app runs: take the chosen combination now, and again whenever the choice changes.
    func start(pressed: @escaping () -> Void) {
        self.pressed = pressed
        watching = preferences.$blinkBreakShortcut.removeDuplicates().sink { [weak self] choice in
            self?.use(choice)
        }
    }

    /// The model goes away (the app quits, or enters or leaves the demo): give the key back.
    func stop() {
        watching = nil
        keys.unregister()
    }

    private func use(_ choice: ShortcutChoice?) {
        keys.unregister()
        refused = nil
        guard let choice else { return }
        if keys.register(choice, pressed: { [weak self] in self?.pressed() }) {
            Log.app.notice("Shortcut for the blink break: \(choice.rawValue, privacy: .public)")
        } else {
            Log.app.notice("macOS refused the shortcut \(choice.rawValue, privacy: .public)")
            refused = choice
        }
    }

    /// Puts a refusal in the state, for the screenshots.
    func state(refused: ShortcutChoice?) {
        self.refused = refused
    }
}

/// The words of the shortcut's row in Settings.
enum ShortcutWords {
    static let title = "Shortcut for a blink break"
    static let off = "Off"

    static func detail(chosen: ShortcutChoice?, refused: ShortcutChoice?) -> String {
        if let refused, refused == chosen {
            return "macOS did not give \(refused.symbols) to Blink: another app is probably using it. Choose another one. Nothing is registered now."
        }
        if let chosen {
            return "\(chosen.symbols) starts a blink break from any app. With the camera off, it opens the menu-bar panel instead."
        }
        return "A key combination that starts a blink break from any app. It needs no permission from macOS."
    }
}

/// macOS's own registration of a system-wide key combination (Carbon's
/// `RegisterEventHotKey`). It needs neither Accessibility nor Input Monitoring: the app
/// never sees a key, it is only told that its combination was pressed.
@MainActor
final class CarbonHotKeys: HotKeys {

    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed: () -> Void = {}

    /// "BLNK": how the app recognises its own key in the event.
    private static let signature: OSType = 0x424C_4E4B

    func register(_ choice: ShortcutChoice, pressed: @escaping () -> Void) -> Bool {
        unregister()
        installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        key = reference
        self.pressed = pressed
        return true
    }

    func unregister() {
        if let key { UnregisterEventHotKey(key) }
        key = nil
        pressed = {}
    }

    /// One handler for the "hot key pressed" event, installed at the first registration.
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<CarbonHotKeys>.fromOpaque(context).takeUnretainedValue()
            // Carbon calls on the main thread, where the app's events are dispatched.
            MainActor.assumeIsolated { keys.pressed() }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
