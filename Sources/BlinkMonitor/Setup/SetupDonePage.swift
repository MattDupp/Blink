import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The last page: where the app lives now, notifications, and Start at login.

struct DonePage: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isDemo ? "That was the whole setup" : Self.title(for: model.monitor.status()))
                        .textStyle(.title, weight: .bold, design: .rounded)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                MenuBarSketch()
                VStack(alignment: .leading, spacing: 2) {
                    Text("From now on, look up").fontWeight(.semibold)
                    Text("Blink has no window and no Dock icon. It lives in the menu bar, at the top right of the screen: click the eye.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                if model.isDemo {
                    WelcomePoint(symbol: "sparkles", title: "Nothing was kept",
                                 text: "The painted recordings and the model trained on them are in a temporary folder, emptied at the next demo.")
                } else {
                    WelcomePoint(symbol: "folder", title: "Your recordings and your model stay on this Mac",
                                 text: String(format: "%.0f MB, in a folder only your account can read.", model.megabytesOnDisk))
                    NotificationPoint(reminders: model.monitor.reminders, actions: actions)
                    WelcomePoint(symbol: "slider.horizontal.3", title: "Also in Settings",
                                 text: """
                                     Look-away breaks (20-20-20): off until you switch them on.
                                     Routines: eye drops, a heated mask, or your own.
                                     Model: add a recording in another light, or delete the recordings and the model.
                                     """)
                    LoginPoint(loginItem: model.monitor.loginItem)
                }
            }

            HStack {
                if !model.isDemo {
                    Button("Show in Finder") { actions.showFiles() }
                    Button("Open Settings") { actions.openSettings() }
                }
                Spacer()
                if !model.isDemo {
                    Button("Watch It Count") { actions.watchItCount() }
                        .controlSize(.large)
                        .help("Opens Live View: the camera's picture, your two eyes, and each blink as it is counted.")
                }
                if model.isDemo, let leaveDemo = actions.leaveDemo {
                    // The demo ends where the real thing begins.
                    Button("Done") { actions.done() }
                        .controlSize(.large)
                    Button("Set Up on My Eyes") { leaveDemo() }
                        .mainButton()
                        .controlSize(.large)
                } else {
                    Button("Done") { actions.done() }
                        .mainButton()
                        .controlSize(.large)
                }
            }
        }
    }

    /// The page reads the app's real state: "counting your blinks" was written there
    /// whether or not counting had started.
    static func title(for status: MonitorStatus) -> String {
        switch status {
        case .watching, .low, .noFace: return "Blink is counting your blinks"
        case .paused: return "Blink is ready, and paused"
        case .cameraRefused, .cameraSilent, .failed: return "Your model is ready, but the camera is not"
        case .starting, .needsSetup, .settingUp: return "Blink is ready"
        }
    }

    private var summary: String {
        guard let info = model.info, let proof = info.proof else { return "Setup is finished." }
        return "Your model was trained on \(info.pictures.formatted()) pictures of your eyes, and counted "
            + "\(proof.found) of \(proof.of) blinks in its test."
    }
}

/// The notification question, said where it can be answered: macOS asks in a small
/// banner at the top right that leaves after a few seconds, and a banner nobody saw
/// counts as a refusal. The line follows what macOS answered.
private struct NotificationPoint: View {
    @ObservedObject var reminders: ReminderController
    let actions: SetupActions

    var body: some View {
        switch reminders.notifications {
        case .unknown:
            WelcomePoint(symbol: "bell", title: "macOS is asking about notifications",
                         text: "Look at the top right of the screen and choose Allow. If the question has gone, it waits in Notification Centre: click the clock in the menu bar. "
                             + "Reminders come as notifications: \(ReminderWords.briefly()). Breaks and routines, if you switch them on, use notifications too.")
        case .allowed:
            WelcomePoint(symbol: "bell", title: "Notifications are allowed",
                         text: "\(ReminderWords.briefly(capital: true)). Breaks and routines, if you switch them on, use notifications too. "
                             + "A reminder's buttons show when the pointer is over it.")
        case .refused:
            VStack(alignment: .leading, spacing: 6) {
                WelcomePoint(symbol: "bell.slash", title: "Notifications are not allowed",
                             text: "Reminders then only show in the menu bar and the panel, and a look-away break is a sound with no words. You can allow them in System Settings > Notifications > Blink.")
                Button("Open Notification Settings") { actions.openNotificationSettings() }
                    .padding(.leading, 42)
            }
        }
    }
}

/// Start at login, offered once at the end of the setup. A menu-bar app has no Dock
/// icon to remind anyone of it: after the first restart it would simply be gone.
private struct LoginPoint: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        if loginItem.available {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                Toggle(isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Blink when I log in").fontWeight(.semibold)
                        Text(loginItem.problem ?? "Without this, it is gone after a restart until you open it again. You can change it in Settings > General.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Shared pieces
