import Foundation
import Testing
@testable import BlinkMonitor

/// Where the app runs from, and which copy runs when there are two.
@MainActor
@Suite("Where the app is installed")
struct InstallationTests {

    private let applications = URL(fileURLWithPath: "/Applications/Blink.app", isDirectory: true)
    private let ownApplications = URL(fileURLWithPath: "/Users/someone/Applications/BlinkMonitor.app", isDirectory: true)

    @Test("With no other copy running, the app starts")
    func alone() {
        #expect(Installation.start(own: applications, running: []) == .alone)
    }

    @Test("A copy installed elsewhere is already running: it stays, and the new one gives way")
    func anotherCopy() {
        #expect(Installation.start(own: applications, running: [ownApplications]) == .yielding)
        // A bare program has no app around it: it is another copy all the same.
        #expect(Installation.start(own: applications, running: [nil]) == .yielding)
        // One elsewhere is enough, whatever else is running.
        #expect(Installation.start(own: applications, running: [applications, ownApplications]) == .yielding)
    }

    @Test("What runs from this same file is an older build, replaced on disk: the new one takes over")
    func replacedOnDisk() {
        #expect(Installation.start(own: applications, running: [applications]) == .replacing)
        // The same place written another way is the same place.
        let roundabout = URL(fileURLWithPath: "/Applications/../Applications/Blink.app/", isDirectory: true)
        #expect(Installation.start(own: applications, running: [roundabout]) == .replacing)
    }

    @Test("A copy still running from the disk image gives way to the one installed since")
    func diskImageCopyGivesWay() {
        let image = URL(fileURLWithPath: "/Volumes/Blink/Blink.app", isDirectory: true)
        let onImage: (URL) -> Bool = { $0.path.hasPrefix("/Volumes/") }
        // Opened from Applications while the disk image's copy runs: the new one stays.
        #expect(Installation.start(own: applications, running: [image], onReadOnlyDisk: onImage) == .replacing)
        // Opened from the disk image while the installed copy runs: the installed one stays.
        #expect(Installation.start(own: image, running: [applications], onReadOnlyDisk: onImage) == .yielding)
        // An installed copy elsewhere is running too: nothing is taken down.
        #expect(Installation.start(own: applications, running: [image, ownApplications], onReadOnlyDisk: onImage) == .yielding)
        // A bare program is not known to be on a disk image.
        #expect(Installation.start(own: applications, running: [nil], onReadOnlyDisk: onImage) == .yielding)
    }

    @Test("A folder one can write in is not a disk image")
    func ordinaryFolder() {
        #expect(!Installation.isOnReadOnlyVolume(FileManager.default.temporaryDirectory))
    }

    @Test("The demo and the real app do not hear each other's request to show the panel")
    func requestsAreKeptApart() {
        #expect(Installation.showPanelRequest(identifier: "local.blinkmonitor.monitor")
                != Installation.showPanelRequest(identifier: "local.blinkmonitor.demo"))
    }

    @Test("Start at Login is offered to an installed app only, and says why when it is not")
    func loginItem() {
        #expect(LoginItem(demo: true, onDiskImage: false).unavailable == "Not in the demo.")
        // The tests run as a bare program, which cannot be a login item either.
        #expect(!LoginItem(demo: false, onDiskImage: true).available)
    }
}
