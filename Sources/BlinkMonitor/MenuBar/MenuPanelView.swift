import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the panel's buttons do. The panel itself only draws; whoever shows it decides.
struct PanelActions {
    var startBlinkBreak: () -> Void = {}
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var openLiveView: () -> Void = {}
    var openCameraSettings: () -> Void = {}
    /// Opens the setup window, where it stands.
    var openSetup: () -> Void = {}
    /// Leaves a demo that was entered from the setup window. Nil when there is no way
    /// back: the app that `make demo` builds is a demo for good.
    var leaveDemo: (() -> Void)?
    /// "Try the Demo", beside the setup button. Nil in the demo itself.
    var tryDemo: (() -> Void)?
    var quit: () -> Void = {}
}

/// What the panel remembers while it is open (SwiftUI's own `@State` needs Xcode's
/// macros, which this project builds without).
@MainActor
final class PanelState: ObservableObject {
    /// The pause choices are showing.
    @Published var choosingPause = false
    /// The bar of the last-hour chart under the pointer: how many minutes ago it was.
    @Published var hoveredMinute: Int?

    func reset() {
        choosingPause = false
        hoveredMinute = nil
    }
}

/// The panel under the menu-bar item, read from top to bottom: how you blink NOW, how
/// TODAY went, then what you can do. Settings live in their own window.
struct MenuPanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: PanelState
    /// The moment the panel describes: the present, except in the screenshots.
    var moment = Moment()
    /// The app runs from its disk image and not from Applications.
    var onDiskImage = Installation.isOnDiskImage
    let actions: PanelActions

    var body: some View {
        AtPresent(moment: moment) { now in panel(now: now) }
    }

    /// The title of the routine whose timer is running.
    private var timerRoutine: String? {
        guard let session = model.routines.session.session else { return nil }
        return model.routines.routines.first { $0.id == session.routine }?.title
    }

    private func panel(now: Date) -> some View {
        let status = model.status(now: now)
        let bare = status == .needsSetup
        return VStack(alignment: .leading, spacing: 0) {
          // Everything above the buttons scrolls when the screen is too small for it (many
          // routines, a low screen). The last row stays put. 60: that row and the panel's
          // own arrow.
          ScrollsWhenTall(reserved: 60) {
           VStack(alignment: .leading, spacing: 0) {
            if onDiskImage { DiskImageBanner() }
            if model.isDemo { DemoBanner(actions: actions) }
            VStack(alignment: .leading, spacing: 10) {
                NowSection(status: status, blinks: model.live.counters.totalBlinks, begun: preferences.welcomed,
                           limit: preferences.limit, offersSetup: model.failure?.offersSetup ?? false,
                           timer: timerRoutine, energy: model.energyHold,
                           // Asked only when it is said: finding the cameras is not free.
                           camera: status == .cameraSilent ? model.cameraPlace : .lid,
                           tryAgain: { Task { await model.tryAgain() } }, actions: actions)
                // The four actions sit directly under the rate, at the same place each time
                // the panel opens: at the bottom they moved with every routine and note.
                if !bare {
                    ActionTiles(model: model, state: state, status: status, actions: actions)
                        .padding(.top, 4)
                    Notes(status: status, history: history, reminders: reminders, preferences: preferences, now: now,
                      cameraMovedTo: model.cameraMovedTo, whileAway: model.whileAway)
                }
            }
            .padding(16)
            // Before the setup there is nothing to show: dashes, "0 min" and an empty
            // chart around the one useful button said less than the sentence alone.
            if !bare {
                Divider()
                RoutineBlock(routines: model.routines, now: now)
                TodaySection(history: history, state: state, limit: preferences.limit, now: now)
                    .padding(16)
            }
           }
          }
            Divider()
            FooterRow(model: model, bare: bare, cameraOn: status.isCameraOn, actions: actions)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .windowWidth(340)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Now

/// Said at the top of the panel for as long as the app runs on made-up eyes: because it
/// was asked to, or because this copy has no model (the one the disk image installs).
private struct DemoBanner: View {
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(actions.leaveDemo == nil
                    ? "Demo: the blinks are made up and the camera is off. To use it on your own eyes, open Blink itself."
                    : "Demo: the blinks are made up and the camera is off.",
                  systemImage: "sparkles")
                .textStyle(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("See the Setup") { actions.openSetup() }
                    .help("The whole setup on painted eyes: recorded, trained and tested for real")
                if let leaveDemo = actions.leaveDemo {
                    Button("Set Up on My Eyes") { leaveDemo() }
                }
            }
            .smallControl()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.16))
    }
}

/// Said for as long as the app runs from its disk image: opened in the image's window
/// without being dragged to Applications first (see `Installation.isOnDiskImage`).
private struct DiskImageBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // At the size of the panel's other sentences: it was the smallest text on it,
            // and it is the one a new user most needs to read.
            Label("Running from the disk image. To keep Blink: quit it, drag it onto Applications, and open it from there.",
                  systemImage: "externaldrive")
                .textStyle(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .smallControl()
                .help("Shows Blink in the disk image's window, beside the Applications folder to drag it onto")
        }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18))
    }
}

private struct NowSection: View {
    let status: MonitorStatus
    /// Blinks counted so far: when it changes, the status dot pulses.
    let blinks: Int
    /// The setup has been started before (its welcome page was passed).
    let begun: Bool
    /// The limit in force, in blinks a minute.
    var limit = 10
    /// The failure is one the setup can mend (no readable model).
    var offersSetup = false
    /// The routine whose timer holds the pause, if one runs.
    var timer: String?
    /// Counting rests to save energy.
    var energy: EnergyPause.Reason?
    /// Where the camera in use sits: said when it sends no picture.
    var camera = CameraPlace.lid
    var tryAgain: () -> Void = {}
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                if let headline = status.headline {
                    // No rate to write: the state takes its place, in the same large type.
                    Text(headline)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: 62)
                } else {
                    RateReadout(rate: status.rate, tint: status.isLow ? .orange : .primary)
                }
                Spacer(minLength: 8)
                // Beside a headline the pill would say the same word twice. It stays
                // while the eyes are read, for its dot: it pulses at each blink.
                if status.headline == nil || status == .watching(rate: nil) {
                    StatusPill(text: status.label, color: status.tint, pulse: blinks)
                }
            }
            Text(status.explanation(limit: limit, timer: timer, energy: energy, camera: camera))
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status == .cameraRefused {
                HStack(spacing: 8) {
                    Button("Open Camera Settings") { actions.openCameraSettings() }
                    Button("Check Again") { tryAgain() }
                }
                .padding(.top, 2)
            }
            if case .failed = status {
                HStack(spacing: 8) {
                    Button("Try Again") { tryAgain() }
                    if offersSetup { Button("Open Setup…") { actions.openSetup() } }
                }
                .padding(.top, 2)
            }
            // "Does it see me?" is answered by Live View, which was a small grey word
            // beside Quit.
            if status == .noFace || status == .cameraSilent {
                Button("See What the Camera Sees") { actions.openLiveView() }
                    .padding(.top, 2)
            }
            // An app that cannot count yet says what to do about it, here where you look.
            if status == .needsSetup {
                HStack(spacing: 8) {
                    Button(begun ? "Continue Setup…" : "Set Up Blink…") { actions.openSetup() }
                        .mainButton()
                    // Once the setup was begun, its first page and the demo on it were out of reach.
                    if let tryDemo = actions.tryDemo {
                        Button("Try the Demo") { tryDemo() }
                            .help("The whole app on made-up eyes: no camera, nothing recorded")
                    }
                }
                .padding(.top, 2)
            } else if case .settingUp = status {
                Button("Show Setup") { actions.openSetup() }
                    .padding(.top, 2)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    /// The dot swells for a moment each time this changes: one pulse per blink.
    let pulse: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            // With Reduce Motion the dot does not swell: the count beside it still moves.
            Circle().fill(color).frame(width: 7, height: 7)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.9, 1.0], trigger: pulse) { dot, scale in
                    dot.scaleEffect(scale)
                } animation: { _ in .easeOut(duration: 0.14) }
            Text(text).textStyle(.caption, weight: .medium)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// The lines under the rate that are only there when they have something to say: time at
/// the screen, snoozed reminders, how you compare with your reference.
private struct Notes: View {
    let status: MonitorStatus
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var preferences: Preferences
    let now: Date
    /// Automatic moved to this camera (`CameraChoice`): said until a camera is chosen.
    var cameraMovedTo: String?
    /// What ended while the Mac slept: said here until the panel is closed.
    var whileAway = WhileAway()

    var body: some View {
        let lines = self.lines
        if !lines.isEmpty || showsNextBreak || reminders.quietReason(now: now) != nil || reminders.breaks.current != nil || preferences.offersOwnRate {
            VStack(alignment: .leading, spacing: 6) {
                if preferences.offersOwnRate, let reference = preferences.reference { ownRateOffer(reference) }
                if let current = reminders.breaks.current {
                    // A look-away break is running. Its banner has the same button.
                    HStack(spacing: 6) {
                        NoteLine(symbol: "eye", text: BreakWords.running(current), tint: .primary)
                        Spacer(minLength: 4)
                        // The banner's two buttons, for someone who missed the banner.
                        if current.canPostpone {
                            Button("Later (5 min)") { reminders.breaks.postpone() }
                                .smallControl()
                        }
                        Button("Skip") { reminders.breaks.skip() }
                            .smallControl()
                    }
                }
                if let quiet = reminders.quietReason(now: now) {
                    HStack(spacing: 6) {
                        NoteLine(symbol: "bell.slash", text: QuietWords.line(quiet, now: now))
                        Spacer(minLength: 4)
                        // Only the Quiet somebody chose can be ended here. The working
                        // hours are a setting: the sentence says where.
                        if case .chosen = quiet {
                            Button("End Quiet") { reminders.setQuiet(until: nil) }
                                .smallControl()
                        }
                    }
                }
                if showsNextBreak {
                    HStack(spacing: 6) {
                        NoteLine(symbol: "clock", text: BreakWords.atTheScreen(minutes: reminders.screenMinutes,
                                                                               next: reminders.breaks.minutesUntilNext,
                                                                               nextIsLong: reminders.breaks.nextIsLong))
                        Spacer(minLength: 4)
                        Button("Now") { reminders.breaks.startNow() }
                            .smallControl()
                            .help("Start the look-away break now")
                    }
                }
                ForEach(lines, id: \.text) { line in
                    NoteLine(symbol: line.symbol, text: line.text, tint: line.tint)
                }
            }
        }
    }

    /// Said once, when the usual rate turns out to be under the limit. The starting limit
    /// of 10 comes from a study; many people sit under it all day, and for them the app
    /// would say "Low" and remind without end. Their own rate is the better yardstick.
    private func ownRateOffer(_ reference: Reference) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteLine(symbol: "info.circle",
                     text: String(format: "Your usual rate is %.0f blinks a minute, under the limit of %d. "
                                  + "With that limit the app would say Low most of the time. "
                                  + "Following your own rate puts the limit at %d: it then tells you when you blink less than you usually do.",
                                  reference.rate, preferences.limit, Baseline.floorFollowing(reference: reference)),
                     tint: .primary)
            HStack(spacing: 8) {
                Button("Follow My Own Rate") { preferences.followOwnRate() }
                Button("Keep \(preferences.limit)") { preferences.ownRateOfferAnswered = true }
            }
            .smallControl()
            .padding(.leading, 20)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Time at the screen and the next break, with its Now button.
    private var showsNextBreak: Bool {
        preferences.breakNudgesOn && status.isCameraOn && reminders.breaks.current == nil && reminders.screenMinutes >= 1
    }

    private var lines: [(symbol: String, text: String, tint: Color)] {
        var lines: [(String, String, Color)] = []
        // Before the app can count, there is no rate to learn and nothing to compare.
        if status == .needsSetup { return lines }
        if case .settingUp = status { return lines }
        if let cameraMovedTo { lines.append(("camera", CameraWords.moved(to: cameraMovedTo), .primary)) }
        for sentence in whileAway.sentences { lines.append(("moon.zzz", sentence, .primary)) }
        if preferences.breakNudgesOn, let tally = BreakWords.takenToday(reminders.breaks.tally(now: now)) {
            lines.append(("checkmark.circle", tally, .secondary))
        }
        if reminders.notificationsRefused, preferences.remindersOn || preferences.breakNudgesOn {
            lines.append(("bell.slash", "Notifications are off for Blink: reminders only show here and in the menu bar. Settings says how to allow them.", .warningText))
        }
        guard preferences.automaticLimit else { return lines }
        if let reference = preferences.reference {
            // A decline is SHOWN against the reference; the reference does not follow it.
            if let drift = Baseline.drift(reference: reference, recent: history.minutes),
               drift >= Baseline.driftWorthSaying {
                lines.append(("arrow.down.right",
                              String(format: "This week you blink %.0f%% less than your usual rate (%@ a minute, measured %@)",
                                     drift * 100, Format.rate(reference.rate), Format.day(reference.measuredOn)), .warningText))
            }
        } else {
            lines.append(("gauge.with.needle",
                          CalibrationWords.line(Baseline.calibration(records: history.minutes), limit: preferences.limit),
                          .secondary))
        }
        return lines
    }
}

private struct NoteLine: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.caption)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today

private struct TodaySection: View {
    @ObservedObject var history: HistoryController
    @ObservedObject var state: PanelState
    let limit: Int
    let now: Date

    var body: some View {
        let today = history.summary(of: now, threshold: Double(limit))
        let hour = LastHour(minutes: history.minutes, current: history.currentMinute, now: now)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Today")
            HStack(spacing: 8) {
                StatTile(value: Format.duration(today.observedSeconds), caption: "at the screen")
                StatTile(value: today.ratePerMinute.map(Format.rate) ?? Format.none, caption: "blinks a minute")
                    .help("Today's average. \(today.blinks.formatted()) blinks counted today.")
                StatTile(value: today.lowShare.map { "\(Int(((1 - $0) * 100).rounded()))%" } ?? Format.none, caption: "above your limit")
                    .help("The share of today's minutes at or above your limit of \(limit) blinks a minute")
            }
            // One height for the three, the tallest's: a caption may take two lines.
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Last hour").textStyle(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(caption(today: today, hour: hour))
                        .textStyle(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                MinuteBars(hour: hour, limit: Double(limit), hovered: state.hoveredMinute) { state.hoveredMinute = $0 }
                    .frame(height: 54)
                HStack(spacing: 4) {
                    Text("60 min ago")
                    Spacer()
                    HStack(spacing: 5) {
                        DashedLine().frame(width: 18, height: 1)
                        Text("your limit, \(limit) a minute")
                    }
                    Spacer()
                    Text("now")
                }
                .textStyle(.caption2)
                .foregroundStyle(.secondary)       // it says what the chart is: not the faintest grey
            }
        }
    }

    /// The minute under the pointer, when there is one.
    private func caption(today: DaySummary, hour: LastHour) -> String {
        if let ago = state.hoveredMinute {
            let time = Format.time(hour.start(minutesAgo: ago))
            guard let rate = hour.rate(minutesAgo: ago) else { return "\(time): not counted" }
            return String(format: "%@: %.0f a minute", time, rate) + (ago == 0 ? " so far" : "")
        }
        // A figure for the whole day captioned the chart of the last hour: it is a tile now.
        return ""
    }
}

/// A short piece of the chart's dashed line, for its legend.
private struct DashedLine: View {
    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityHidden(true)
    }
}

/// The last 60 minutes, one bar per minute: its height is that minute's blink rate.
/// Orange = under the limit (the dashed line). The minute in progress is drawn lighter:
/// its rate is not final.
private struct MinuteBars: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour
    let hour: LastHour
    let limit: Double
    let hovered: Int?
    /// The pointer is over the bar of that many minutes ago (nil: it left the chart).
    let onHover: (Int?) -> Void

    var body: some View {
        Canvas { context, size in
            let slot = size.width / 60
            // The rate drawn at full height: room above the tallest bar and above the line.
            let top = max(limit * 1.6, (hour.rates.compactMap { $0 }.max() ?? 0) * 1.1)

            if let hovered {
                let column = CGRect(x: CGFloat(59 - hovered) * slot, y: 0, width: slot, height: size.height)
                context.fill(Path(column), with: .color(.primary.opacity(0.12)))
            }
            for (ago, rate) in hour.rates.enumerated() {
                guard let rate else { continue }
                let height = max(2, CGFloat(min(rate, top) / top) * size.height)
                let bar = CGRect(x: CGFloat(59 - ago) * slot + 0.5, y: size.height - height,
                                 width: max(slot - 1.2, 1), height: height)
                let colour: Color = rate < limit ? .orange : .green
                if withoutColour && rate < limit {
                    // "Differentiate without colour": a minute under the limit is hollow.
                    context.stroke(Path(roundedRect: bar.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 1.5),
                                   with: .color(colour.opacity(ago == 0 ? 0.45 : 1)), lineWidth: 1.2)
                } else {
                    context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(colour.opacity(ago == 0 ? 0.45 : 1)))
                }
            }

            guard !hour.isEmpty else { return }       // nothing to compare with the limit yet
            let y = size.height - CGFloat(limit / top) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // The line carries its number: the chart had no scale at all.
            let number = context.resolve(Text("\(Int(limit))").font(.system(size: 9, weight: .semibold)).foregroundColor(.primary))
            let measured = number.measure(in: size)
            let plate = CGRect(x: 2, y: y - measured.height / 2 - 1, width: measured.width + 6, height: measured.height + 2)
            // On a plate of its own, at the left end: over the bars it could not be read.
            context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
            context.draw(number, at: CGPoint(x: plate.midX, y: plate.midY), anchor: .center)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if hour.isEmpty {
                Text("Nothing recorded in the last hour yet")
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): onHover(LastHour.minutesAgo(atX: point.x, width: geometry.size.width))
                        case .ended: onHover(nil)
                        }
                    }
            }
        }
        .help("One bar per minute. Green: at or above your limit. Orange: under it. A gap: not counted. The pale bar is the minute in progress.")
        .accessibilityLabel("Blink rate, minute by minute, over the last hour")
        .accessibilityValue(hour.summary(limit: limit))
    }
}

// MARK: - Actions

private struct ActionTiles: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: PanelState
    let status: MonitorStatus
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActionTile(symbol: "eye", title: "Blink Break", tint: status.isLow ? .orange : nil) {
                    actions.startBlinkBreak()
                }
                .disabled(!status.isCameraOn)
                // A greyed tile says why.
                .help(status.isCameraOn ? "Ten slow, full blinks, counted by the camera (B)"
                                        : "The camera counts the blinks of a blink break, and it is off now.")
                .keyboardShortcut("b", modifiers: [])

                if model.showsResume {
                    // During a timer, Resume is there but not the thing to press: the
                    // camera comes back by itself when the timer ends.
                    let timed = model.routines.session.session != nil
                    ActionTile(symbol: "play.fill", title: "Resume", tint: timed ? nil : .accentColor) { model.resume() }
                        .help(timed ? "Turn the camera back on now, before the timer ends (P)" : "Turn the camera back on (P)")
                        .keyboardShortcut("p", modifiers: [])
                } else {
                    ActionTile(symbol: "pause.fill", title: "Pause", tint: state.choosingPause ? .accentColor : nil) {
                        state.choosingPause.toggle()
                    }
                    .disabled(model.lifecycle != .running)
                    .help(model.lifecycle == .running ? "Turn the camera off: its green light goes out (P)"
                                                      : "The camera is not running, so there is nothing to pause.")
                    .keyboardShortcut("p", modifiers: [])
                }

                // A letter for each tile, said in its tooltip: the panel had no keyboard path.
                ActionTile(symbol: "chart.bar.fill", title: "History") { actions.openHistory() }
                    .help("Your last seven days, hour by hour (H)")
                    .keyboardShortcut("h", modifiers: [])
                ActionTile(symbol: "gearshape.fill", title: "Settings") { actions.openSettings() }
                    .help("Every choice the app remembers (S, or Command-comma)")
                    .keyboardShortcut("s", modifiers: [])
            }
            .fixedSize(horizontal: false, vertical: true)

            if state.choosingPause && !model.showsResume {
                PauseChoices { duration in
                    model.pause(for: duration)
                    state.choosingPause = false
                }
            }

        }
    }
}

/// "Camera on", with a small green dot like the light it speaks of.
private struct CameraOnStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.green)
            configuration.title
        }
    }
}

/// The last row of the panel: the version, Quiet, Live View and Quit. Before the setup,
/// Settings and Quit only.
private struct FooterRow: View {
    @ObservedObject var model: MonitorModel
    let bare: Bool
    /// The camera is running (asked of the panel's own moment, not of the clock).
    let cameraOn: Bool
    let actions: PanelActions

    var body: some View {
            HStack(spacing: 14) {
                // The green light is explained in the setup, then seen every day: three days
                // later the panel is where someone looks to learn whose it is.
                if cameraOn && !model.isDemo {
                    Label("Camera on", systemImage: "circle.fill")
                        .labelStyle(CameraOnStyle())
                        .help("The green light beside the camera means Blink is counting your blinks. Pause turns it off.")
                } else {
                    // The app's name is on the Quit button's tooltip and in Settings:
                    // here it took the room that sets Quit apart.
                    Text("Version \(AppInfo.version)")
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if bare {
                    Button("Settings") { actions.openSettings() }
                } else {
                // "Leave me alone for an hour": every banner and sound is held, counting
                // goes on. Pause is something else: it turns the camera off.
                Menu {
                    Button("For 30 Minutes") { model.reminders.setQuiet(.thirtyMinutes) }
                    Button("For 1 Hour") { model.reminders.setQuiet(.oneHour) }
                    Button("Until Tomorrow") { model.reminders.setQuiet(.untilTomorrow) }
                } label: {
                    Text("Quiet")
                }
                .menuStyle(.button)
                .smallControl()
                .fixedSize()
                .help("No reminder, no look-away break and no sound for a while. Blinks are still counted.")
                Button("Live View") { actions.openLiveView() }
                    .help("The camera with your eyes framed, and each blink as it is counted")
                }
                // Quit sat 14 points from Live View: twice the room now sets it apart. Its
                // whole name is said where there is room for it, and in its tooltip.
                Button(bare ? "Quit Blink" : "Quit") { actions.quit() }
                    .help("Quit Blink: counting and every reminder stop until you open it again")
                    .accessibilityLabel("Quit Blink")
                    .padding(.leading, bare ? 0 : 14)
            }
            // Drawn as buttons, at a size one can read: they were three grey words.
            .textStyle(.callout)
            .smallControl()
            .foregroundStyle(.secondary)
    }
}

/// A pause says when it ends: the four choices.
private struct PauseChoices: View {
    let choose: (PauseDuration) -> Void

    private static let labels: [(PauseDuration, String)] = [
        (.fifteenMinutes, "For 15 minutes"), (.oneHour, "For 1 hour"),
        (.untilTomorrow, "Until tomorrow"), (.untilResumed, "Until I resume"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause the camera")
                .textStyle(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(Self.labels, id: \.1) { duration, label in
                    Button { choose(duration) } label: {
                        Text(label).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One of the panel's four actions: a symbol over a word. `tint`: drawn as the one to press.
private struct ActionTile: View {
    let symbol: String
    let title: String
    var tint: Color?
    let action: () -> Void
    /// The keyboard is on this tile (with keyboard navigation switched on in macOS).
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                // The word of an orange tile is written in the orange made for text.
                // A word too long for its tile goes onto a second line. It was shrunk to
                // fit, and small text was made smaller for the people who enlarge it.
                Text(title)
                    .textStyle(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(tint == .orange ? Color.warningText : (tint ?? .primary))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(TileStyle(tint: tint))
        .focused($focused)
        // The tile draws itself, so it draws its own focus ring too.
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

private struct TileStyle: ButtonStyle {
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint ?? .primary)
            .background((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: 8))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.6 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shared pieces

struct SectionTitle: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .textStyle(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

struct StatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // The caption wraps instead of shrinking; the number above is a display
            // figure, and may still be drawn smaller to stay on its line.
            Text(caption)
                .textStyle(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// How the app writes durations, times and days: once, so every window says them alike.
enum Format {
    /// Where a number is missing: one dash, the same everywhere (`RateReadout.none`).
    static let none = RateReadout.none

    /// "42 min", "2 h 5 min", "3 h".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes) min" }
        // "5 h 10" is not an English duration, and "3 h 00" says nothing more than "3 h".
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// A rate with one decimal, written the way this Mac writes numbers ("13.2", "13,2").
    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// An hour of the day as this Mac writes times: "14:00", or "2:00 PM".
    static func hour(_ hour: Int, calendar: Calendar = .current) -> String {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0)).map(time) ?? "\(hour):00"
    }

    /// The same, short, for an axis: "14", or "2 PM".
    static func hourLabel(_ hour: Int, calendar: Calendar = .current) -> String {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
            .map { $0.formatted(.dateTime.hour()) } ?? "\(hour)"
    }

    /// "70%": a share as this Mac writes a percentage.
    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "two", "ten": a small count as a sentence says it; digits above ten.
    static func word(_ number: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(number) ? words[number] : number.formatted()
    }

    /// "1 minute", "3 minutes": a number with its noun, so that no sentence says "1 minutes".
    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number.formatted()) \(noun)s"
    }

    /// "16:30".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "18 Nov".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A moment ahead, as short as it can be said without doubt: "09:00" within the next
    /// 24 hours, "Mon 09:00" further away.
    static func ahead(_ date: Date, from now: Date) -> String {
        date.timeIntervalSince(now) < 86_400 ? time(date) : "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time(date))"
    }

    /// When a pause ends: "16:30", or "tomorrow" for the pause that lasts until midnight.
    static func pauseEnd(_ date: Date, calendar: Calendar = .current) -> String {
        calendar.startOfDay(for: date) == date ? "tomorrow" : time(date)
    }
}
