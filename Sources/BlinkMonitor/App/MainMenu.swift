import AppKit

/// The app's menu. Nobody sees it: a menu-bar app shows no menus of its own.
///
/// It exists for the KEYBOARD. macOS does not wire Cmd-W to "close" or Cmd-Q to "quit";
/// it looks for a menu item with that shortcut and performs it. An app without a menu
/// therefore has windows that Cmd-W cannot close - which the first version had.
@MainActor
enum MainMenu {

    /// `settings`: the selector `target` performs for "Settings...".
    static func make(target: AnyObject, settings: Selector) -> NSMenu {
        let app = NSMenu()
        app.addItem(withTitle: "About Blink Monitor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings...", action: settings, keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Blink Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let main = NSMenu()
        for menu in [app, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}
