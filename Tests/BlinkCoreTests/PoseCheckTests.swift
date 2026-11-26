import CoreGraphics
import Foundation
import Testing
@testable import BlinkCore

/// The check that each pose was held as the voice asked (`PoseCheck`): its rule on answers
/// written by hand, which pictures each witness learns from, what is kept on disk, and one
/// whole check on painted eyes.
@Suite("Each pose is checked before learning")
struct PoseCheckTests {

    // MARK: The rule

    @Test("A pose is flagged only when read the other way without doubt")
    func rule() {
        func closed(_ value: Float, _ count: Int = 60) -> [Float] { Array(repeating: value, count: count) }
        // The real mistake: "Close your eyes. Keep your head tilted." held with open eyes,
        // read at 0.010 by the witness (measured 2026-11-25).
        let real = PoseCheck.verdict(label: .closed, closed: closed(0.010))
        #expect(real.verdict == .flagged && abs((real.score ?? 1) - 0.010) < 1e-6)
        // The highest mistake that was caught, and the lowest good pose that was kept.
        #expect(PoseCheck.verdict(label: .closed, closed: closed(0.023)).verdict == .flagged)
        #expect(PoseCheck.verdict(label: .closed, closed: closed(0.053)).verdict == .kept)
        // A good pose the witness is unsure of (a turned head, one eye in view): kept, even
        // though every picture is on the wrong side of 0.5.
        #expect(PoseCheck.verdict(label: .closed, closed: closed(0.25)).verdict == .kept)
        // The other way: closed eyes in an open pose.
        #expect(PoseCheck.verdict(label: .open, closed: closed(0.99)).verdict == .flagged)
        #expect(PoseCheck.verdict(label: .open, closed: closed(0.01)).verdict == .kept)
        // The middle answer decides: a third of the pictures read the other way is not a pose
        // held the wrong way.
        #expect(PoseCheck.verdict(label: .closed, closed: closed(0.0, 20) + closed(0.95, 40)).verdict == .kept)
        // Too few pictures to say.
        #expect(PoseCheck.verdict(label: .closed, closed: closed(0.0, 9)) == (.unjudged, nil))
    }

    // MARK: The witnesses

    /// `sessions` recordings of every pose, two pictures each (one per eye).
    private func entries(_ sessions: [String]) -> [TrainingSet.Entry] {
        sessions.flatMap { session in
            SessionScript.phases.enumerated().flatMap { index, phase in
                (0..<2).map { eye in
                    TrainingSet.Entry(file: URL(fileURLWithPath: "/\(session)/\(index)-\(eye).png"), session: session,
                                      closed: phase.label == .closed, phase: index, variant: phase.variant)
                }
            }
        }
    }

    @Test("With two recordings, four witnesses each judge a group of poses they never learned from")
    func fourGroups() {
        let all = entries(["a", "b"])
        let poses = PoseCheck.toJudge(entries: all, records: [:])
        #expect(poses.count == 2 * (SessionScript.phases.count - 1))                // every pose but "keyboard"
        #expect(!poses.contains(PoseCheck.Pose(session: "a", phase: 4)))
        let witnesses = PoseCheck.witnesses(for: all, judging: poses)
        #expect(witnesses.count == 4)
        var judged: [Int] = []
        for (witness, group) in zip(witnesses, PoseCheck.groups) {
            #expect(Set(witness.train).isDisjoint(with: witness.judge))
            // A group is left out of BOTH recordings, as it was measured.
            #expect(witness.train.allSatisfy { !group.contains(all[$0].phase!) })
            #expect(witness.judge.allSatisfy { group.contains(all[$0].phase!) })
            #expect(Set(witness.train.map { all[$0].session }) == ["a", "b"])        // it has seen both lights
            judged += witness.judge
        }
        #expect(judged.count == poses.count * 2)
        // Every pose is in one group exactly.
        #expect(PoseCheck.groups.reduce(Set<Int>()) { $0.union($1) } == Set(SessionScript.phases.indices))
        #expect(PoseCheck.groups.map(\.count).reduce(0, +) == SessionScript.phases.count)
    }

    @Test("A recording added to three checked ones is judged by one witness that learned from those three")
    func oneWitness() {
        let all = entries(["a", "b", "c", "d"])
        let poses = Set(PoseCheck.pictures(of: all).keys.filter { $0.session == "d" })
        let witnesses = PoseCheck.witnesses(for: all, judging: poses)
        #expect(witnesses.count == 1)
        #expect(Set(witnesses[0].train.map { all[$0].session }) == ["a", "b", "c"])
        #expect(Set(witnesses[0].judge.map { all[$0].session }) == ["d"])
        // With two checked, it is groups again (one witness was measured with three and four).
        let fewer = Array(all.filter { $0.session != "c" })
        #expect(PoseCheck.witnesses(for: fewer, judging: poses).count == 4)
    }

    @Test("A pose recorded again is judged alone, by the one witness of its group")
    func oneGroup() {
        let all = entries(["a", "b"])
        let witnesses = PoseCheck.witnesses(for: all, judging: [PoseCheck.Pose(session: "b", phase: 15)])
        #expect(witnesses.count == 1)
        #expect(witnesses[0].judge.count == 2 && witnesses[0].judge.allSatisfy { all[$0].phase == 15 && all[$0].session == "b" })
        #expect(witnesses[0].train.allSatisfy { ![6, 7, 14, 15].contains(all[$0].phase!) })
    }

    // MARK: What is on disk

    @Test("A pose's last line is where it stands: flagged waits, recorded again is judged, left out is done")
    func standing() {
        let all = entries(["a", "b"])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ phase: Int, _ verdict: PoseCheckLine.Verdict) -> PoseCheckLine {
            PoseCheckLine(at: at, phase: phase, label: SessionScript.phases[phase].label, variant: SessionScript.phases[phase].variant,
                          pictures: 60, score: verdict == .flagged ? 0.01 : 0.9, verdict: verdict)
        }
        let judgedOnce = (0..<16).map { line($0, $0 == 15 ? .flagged : .kept) }
        var records = ["a": (0..<16).map { line($0, .kept) }, "b": judgedOnce]
        #expect(PoseCheck.toJudge(entries: all, records: records).isEmpty)
        #expect(PoseCheck.waiting(entries: all, records: records)
                == [PoseFlag(session: "b", phase: 15, label: .closed, variant: "tilt", pictures: 60, score: 0.01)])

        records["b"] = judgedOnce + [line(15, .again)]
        #expect(PoseCheck.waiting(entries: all, records: records).isEmpty)
        #expect(PoseCheck.toJudge(entries: all, records: records) == [PoseCheck.Pose(session: "b", phase: 15)])

        records["b"] = judgedOnce + [line(15, .leftOut)]
        #expect(PoseCheck.waiting(entries: all, records: records).isEmpty)
        #expect(PoseCheck.toJudge(entries: all, records: records).isEmpty)

        // A flagged pose whose pictures are gone waits for nothing.
        #expect(PoseCheck.waiting(entries: all.filter { !($0.session == "b" && $0.phase == 15) }, records: ["b": judgedOnce]).isEmpty)
    }

    @Test("A line of pose-check.csv reads back as it was written; the progress words survive a pipe")
    func lines() throws {
        let line = PoseCheckLine(at: Date(timeIntervalSince1970: 1_800_000_000), phase: 15, label: .closed, variant: "tilt",
                                 pictures: 60, score: 0.0104, verdict: .leftOut)
        #expect(PoseCheckLine(fields: line.fields) == line)
        #expect(line.fields.last == "left-out")
        let unjudged = PoseCheckLine(at: line.at, phase: 3, label: .closed, variant: "tight", pictures: 4, score: nil, verdict: .unjudged)
        #expect(PoseCheckLine(fields: unjudged.fields) == unjudged)
        #expect(PoseCheckLine(fields: ["nonsense"]) == nil)

        let flag = PoseFlag(session: "20261122-215811", phase: 15, label: .closed, variant: "tilt", pictures: 60, score: 0.01)
        for word in [TrainingProgress.flagged([flag]), .checkingPoses(done: 12, of: 120)] {
            #expect(TrainingProgress(line: word.line) == word)
        }
    }

    @Test("Leaving a pose out moves its pictures and lines aside: nothing is deleted, and no trainer reads them")
    func setAside() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var writer = try SessionWriter(root: root, session: "20270101-090000", condition: "")
        let eye = EyeRegion(side: .imageLeft, cropRect: CGRect(x: 0, y: 0, width: 128, height: 128), center: .zero)
        let located = LocatedEyes(faceRect: .zero, left: eye, right: eye, interocularDistance: 180, roll: 0, yaw: nil)
        let image = try #require(PaintedEye(openness: 1).image())
        func save(phase: Int, frames: Range<Int>) {
            for frame in frames {
                writer.save(EyeSample(image: image, label: SessionScript.phases[phase].label, variant: SessionScript.phases[phase].variant,
                                      phaseIndex: phase, frameIndex: frame, time: 0, eye: eye, located: located,
                                      frameSize: CGSize(width: 1920, height: 1080)))
            }
        }
        save(phase: 14, frames: 0..<4)
        save(phase: 15, frames: 4..<10)
        let session = writer.folder
        #expect(TrainingSet.list(root: root).count == 10)

        #expect(try SessionStore.setAside(phase: 15, of: session) == 6)
        let left = TrainingSet.list(root: root)
        #expect(left.count == 4 && left.allSatisfy { $0.phase == 14 })
        #expect(SessionStore.sessions(in: root).first?.closed == 0)
        let aside = session.appendingPathComponent(SessionStore.asideFolder)
        let asideLines = try String(contentsOf: aside.appendingPathComponent("manifest.csv"), encoding: .utf8).split(separator: "\n")
        #expect(asideLines.count == 1 + 6 && asideLines.first.map(String.init) == SessionWriter.header)
        #expect(try FileManager.default.contentsOfDirectory(atPath: aside.appendingPathComponent("closed").path).count == 6)
        // Set aside as a recording of its own would be: the same layout, the same reader.
        #expect(TrainingSet.list(root: session).count == 6)

        // The same pose recorded again with the same frame numbers, and set aside again:
        // the newcomers get a number, nothing is overwritten. (A writer is opened after the
        // manifest was rewritten, as the setup does: one opened before writes to the old file.)
        writer = try SessionWriter(root: root, session: "20270101-090000", condition: "")
        save(phase: 15, frames: 4..<10)
        #expect(try SessionStore.setAside(phase: 15, of: session) == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: aside.appendingPathComponent("closed").path).count == 12)
        #expect(try SessionStore.setAside(phase: 15, of: session) == 0)              // nothing left to move

        // The person's answer is written after the pictures move.
        let flag = PoseFlag(session: "20270101-090000", phase: 14, label: .open, variant: "tilt", pictures: 4, score: 0.99)
        try PoseCheck.answer(flag, recordAgain: true, root: root)
        #expect(TrainingSet.list(root: root).isEmpty)
        #expect(RecordFile<PoseCheckLine>(in: session).load().map(\.verdict) == [.again])
    }

    // MARK: On painted eyes

    @Test("Painted recordings: a closed pose held with open eyes is flagged, nothing else is, and once it is left out the training ends",
          .enabled(if: Fixture.canTrain, "no graphics processor to train on, or a machine it was not tried on"))
    func paintedMistake() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        // Two recordings of every pose in two lights; the second ends with its last pose
        // held with the eyes open, as the author's did.
        for (number, light) in [0.72, 0.5].enumerated() {
            let writer = try SessionWriter(root: sessions, session: "2027010\(number + 1)-090000", condition: "painted")
            var random = SeededRandom(seed: UInt64(number + 1))
            let eye = EyeRegion(side: .imageLeft, cropRect: CGRect(x: 800, y: 400, width: 128, height: 128), center: .zero)
            let located = LocatedEyes(faceRect: .zero, left: eye, right: eye, interocularDistance: 260, roll: 0, yaw: nil)
            for (index, phase) in SessionScript.phases.enumerated() {
                let heldOpen = phase.label == .open || (number == 1 && index == 15)
                for frame in 0..<20 {
                    var painted = PaintedEye.random(open: heldOpen, using: &random)
                    painted.light = light + Double(random.uniform(-0.05, 0.05))
                    guard let image = painted.image() else { continue }
                    writer.save(EyeSample(image: image, label: phase.label, variant: phase.variant, phaseIndex: index,
                                          frameIndex: index * 100 + frame, time: 0, eye: eye, located: located,
                                          frameSize: CGSize(width: 1920, height: 1080)))
                }
            }
        }
        let store = ModelStore(base: root)
        try store.prepareStaging()

        var said: [TrainingProgress] = []
        #expect(TrainingRun.run(sessions: sessions, into: store.staging, passes: 8) { said.append($0) } == nil)
        let flag = PoseFlag(session: "20270102-090000", phase: 15, label: .closed, variant: "tilt", pictures: 20, score: 0)
        guard case .flagged(let flags) = said.last, flags.count == 1, let found = flags.first else {
            Issue.record("expected the one pose held open, heard \(String(describing: said.last))")
            return
        }
        #expect(found.session == flag.session && found.phase == 15 && found.pictures == 20 && found.score < PoseCheck.sureWithin)
        #expect(said.contains(.checkingPoses(done: 32, of: 32)))                  // four witnesses, eight passes each
        #expect(!said.contains { if case .learning = $0 { return true } else { return false } })   // nothing learned
        // Every pose but "keyboard" has its verdict on disk.
        let second = RecordFile<PoseCheckLine>(in: sessions.appendingPathComponent(flag.session)).load()
        #expect(second.count == SessionScript.phases.count - 1)
        #expect(second.filter { $0.verdict == .flagged }.map(\.phase) == [15])

        // Asked again before an answer: the same flag, and nothing is judged again.
        said = []
        #expect(TrainingRun.run(sessions: sessions, into: store.staging, passes: 8) { said.append($0) } == nil)
        guard case .flagged(let again) = said.last else {
            Issue.record("expected the same flag, heard \(String(describing: said.last))")
            return
        }
        #expect(again.map(\.session) == [found.session] && again.map(\.phase) == [15])
        #expect(!said.contains { if case .checkingPoses = $0 { return true } else { return false } })

        try PoseCheck.answer(found, recordAgain: false, root: sessions)
        said = []
        let info = try #require(TrainingRun.run(sessions: sessions, into: store.staging, passes: 8) { said.append($0) })
        #expect(info.closedPictures == 2 * 8 * 20 - 20)                            // the pose held open is not learned
        #expect(!said.contains { if case .checkingPoses = $0 { return true } else { return false } })
    }
}
