import AppKit

/// ONE QUESTION BEFORE ANYTHING IS ERASED, asked the same way everywhere.
///
/// There were three ways: two rows of Settings turned into "Cancel / Erase" under the
/// pointer, so that a double click on "Erase..." landed on "Erase", and routines used an
/// alert. Now every erasing action asks through this: a system alert, with Cancel as the
/// default button (Return and Escape both cancel) and the erasing button marked as such.
@MainActor
public enum Confirm {

    /// What an erasing action asks: a title, what will be lost, and the word on its button.
    public struct Question: Equatable, Sendable {
        public var title: String
        public var text: String
        public var button: String

        public init(title: String, text: String, button: String) {
            self.title = title
            self.text = text
            self.button = button
        }
    }

    /// True when the erasing button was pressed.
    public static func destructive(_ question: Question) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.text
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let go = alert.addButton(withTitle: question.button)
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }
}
