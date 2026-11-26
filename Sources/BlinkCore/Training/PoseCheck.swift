import Foundation

/// Was each pose held as the voice asked? Checked before a model learns from it.
///
/// WHY. The pictures are labelled by instruction (`SessionScript`): whatever the eyes do
/// during "Close your eyes", the pictures are saved as closed. Nothing checked that.
/// MEASURED (2026-11-25): one of the author's recordings ends with "Close your eyes. Keep
/// your head tilted." done with the eyes wide open, 60 pictures. The model learned open
/// eyes as closed, then counted 14 to 25 false blinks on six marked captures where the
/// same training without that pose counts 0 to 3.
///
/// THE WITNESS. A pose is shown to a model that did not learn from it, and the model's
/// answers are compared with the pose's label. Which model, measured on six recordings
/// (the author's two and the four of data/raw, with the app's own trainer):
///   - One trained on the OTHER recording, with only two: not usable. A model that has
///     seen the eyes in one light misreads them in another: 14 of 21 pairs of recordings
///     would have had a good pose flagged, some read the other way on every picture.
///   - One trained on every recording except a GROUP of poses, which it then judges
///     (`groups`): it has seen both recordings' light. This is the check with two.
///   - One trained on three or more recordings already checked: none of 95 good poses
///     read the other way on more than 8% of its pictures. This is the check of a
///     recording added later (`checkedForOneWitness`).
///
/// THE RULE. A pose is flagged when its witness reads it the other way WITHOUT DOUBT:
/// the middle of its answers within `sureWithin` of the wrong end. "Most pictures read the
/// other way" is not enough: the witnesses are often unsure of a good pose (a turned head,
/// one eye in view) and that rule flagged a good pose in 29 of 37 trials. Measured with
/// four groups, on 37 trials of two recordings and 16 mistakes (the real one, and 15
/// planted: a pose's pictures replaced by its neighbour's, under the wrong label):
/// mistakes scored 0.000 to 0.023 (the real one 0.010); good poses other than "keyboard"
/// 0.053 and above. With the rule below: no good pose flagged, 14 mistakes of 16 caught.
/// The margin is thin, the rule was chosen on these same numbers, and they come from one
/// person's eyes in two sittings: it is a starting value, to be measured again on new
/// recordings.
public enum PoseCheck {

    /// The poses judged together: an open pose with the closed one that follows it, two
    /// such pairs to a group. With two recordings, four witnesses each learn from twelve
    /// poses of both and judge the four they did not see. Two groups of eight were
    /// measured too: worse (a good turned-head pose scored 0.015).
    public static let groups: [Set<Int>] = [[0, 1, 8, 9], [2, 3, 10, 11], [4, 5, 12, 13], [6, 7, 14, 15]]

    /// A pose is flagged when its score is under this. (Score: the middle of the
    /// witness's answers for the pose's own label; 1 agrees, 0 is sure of the opposite.)
    public static let sureWithin = 0.03

    /// Poses that are never judged. "Look down at the keyboard, without closing your eyes"
    /// was chosen to look almost closed (`SessionScript`), and it does to the witness too:
    /// it read that pose as closed without doubt in two of the six recordings (0.017 and
    /// 0.032), where the pictures show open eyes looking down.
    public static let notJudged: Set<String> = ["keyboard"]

    /// A pose with fewer pictures is not judged: the camera lost the face during it.
    public static let fewestPictures = 10

    /// With this many recordings already checked, a new one is judged by one model trained
    /// on them (measured with three and four).
    public static let checkedForOneWitness = 3

    /// One pose of one recording.
    public struct Pose: Hashable, Comparable {
        public let session: String
        public let phase: Int

        public init(session: String, phase: Int) {
            self.session = session
            self.phase = phase
        }

        public static func < (a: Pose, b: Pose) -> Bool { (a.session, a.phase) < (b.session, b.phase) }
    }

    /// A model to train on some pictures (`train`) and to ask about others (`judge`):
    /// positions in a list of pictures.
    public struct Witness: Equatable {
        public let train: [Int]
        public let judge: [Int]
    }

    // MARK: - The rule

    /// The verdict on one pose, from its label and the witness's answers ("closed", 0...1).
    public static func verdict(label: EyeLabel, closed answers: [Float]) -> (verdict: PoseCheckLine.Verdict, score: Double?) {
        guard answers.count >= fewestPictures else { return (.unjudged, nil) }
        let agreeing = answers.map { label == .closed ? Double($0) : 1 - Double($0) }
        let score = median(agreeing)
        return (score < sureWithin ? .flagged : .kept, score)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - What is on disk

    /// Each pose's last line: what happened to it last.
    public static func latest(_ lines: [PoseCheckLine]) -> [Int: PoseCheckLine] {
        var last: [Int: PoseCheckLine] = [:]
        for line in lines { last[line.phase] = line }
        return last
    }

    /// The pictures of each pose, by position in `entries`.
    public static func pictures(of entries: [TrainingSet.Entry]) -> [Pose: [Int]] {
        var poses: [Pose: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            guard let phase = entry.phase else { continue }
            poses[Pose(session: entry.session, phase: phase), default: []].append(index)
        }
        return poses
    }

    /// The poses that still have pictures and wait for an answer: flagged, and neither left
    /// out nor recorded again since.
    public static func waiting(entries: [TrainingSet.Entry], records: [String: [PoseCheckLine]]) -> [PoseFlag] {
        pictures(of: entries).keys.sorted().compactMap { pose in
            guard let line = latest(records[pose.session] ?? [])[pose.phase], line.verdict == .flagged else { return nil }
            return PoseFlag(session: pose.session, phase: pose.phase, label: line.label, variant: line.variant,
                            pictures: line.pictures, score: line.score ?? 0)
        }
    }

    /// The poses to judge: with pictures, of a kind that is judged, and never judged since
    /// they were recorded (no line, or "recorded again" last).
    public static func toJudge(entries: [TrainingSet.Entry], records: [String: [PoseCheckLine]]) -> Set<Pose> {
        var poses = Set<Pose>()
        for (pose, indices) in pictures(of: entries) where !notJudged.contains(entries[indices[0]].variant) {
            let last = latest(records[pose.session] ?? [])[pose.phase]
            if last == nil || last?.verdict == .again { poses.insert(pose) }
        }
        return poses
    }

    /// The witnesses that judge `poses`. A witness never learns from a picture it judges.
    public static func witnesses(for entries: [TrainingSet.Entry], judging poses: Set<Pose>) -> [Witness] {
        guard !poses.isEmpty else { return [] }
        let judged = entries.indices.filter { index in
            entries[index].phase.map { poses.contains(Pose(session: entries[index].session, phase: $0)) } ?? false
        }
        let checked = Set(entries.map(\.session)).subtracting(poses.map(\.session))
        if checked.count >= checkedForOneWitness {
            return [Witness(train: entries.indices.filter { checked.contains(entries[$0].session) }, judge: judged)]
        }
        // A group is left out of EVERY recording, as it was measured: a pose is then judged
        // by a model that has seen the light of its recording, never the pose itself.
        return groups.compactMap { group in
            let judge = judged.filter { group.contains(entries[$0].phase!) }
            guard !judge.isEmpty else { return nil }
            return Witness(train: entries.indices.filter { entries[$0].phase.map { !group.contains($0) } ?? true }, judge: judge)
        }
    }

    // MARK: - Running it

    /// Judges every pose that needs it, writes each verdict in its recording's
    /// pose-check.csv, and returns the poses flagged: those found now, or those that still
    /// wait for an answer (then nothing is judged). Empty: train.
    ///
    /// Each witness is trained the way the model will be (`EyeTrainer`, the same seed and
    /// passes), in a pool of its own: nothing it made on the graphics processor outlives it.
    public static func run(set: TrainingSet, root: URL, seed: UInt64, passes: Int,
                           report: @escaping (TrainingProgress) -> Void, now: Date = Date()) -> [PoseFlag] {
        var records: [String: [PoseCheckLine]] = [:]
        for session in set.sessions {
            records[session] = RecordFile<PoseCheckLine>(in: root.appendingPathComponent(session, isDirectory: true)).load()
        }
        let waiting = waiting(entries: set.entries, records: records)
        guard waiting.isEmpty else { return waiting }
        let poses = toJudge(entries: set.entries, records: records)
        let plan = witnesses(for: set.entries, judging: poses)
        guard !plan.isEmpty else { return [] }

        let pixels = EyeNetwork.pixels
        func gather(_ positions: [Int]) -> [Float] {
            var out = [Float](repeating: 0, count: positions.count * pixels)
            for (n, position) in positions.enumerated() {
                out.replaceSubrange(n * pixels..<(n + 1) * pixels, with: set.gray[position * pixels..<(position + 1) * pixels])
            }
            return out
        }

        var answers: [Int: Float] = [:]
        let total = plan.count * passes
        report(.checkingPoses(done: 0, of: total))
        for (number, witness) in plan.enumerated() {
            let labels = witness.train.map { set.entries[$0].closed ? Float(1) : 0 }
            let closed = labels.filter { $0 > 0.5 }.count
            // Too few of a kind to learn from: its poses stay unjudged.
            guard closed >= TrainingRun.fewestPicturesOfAKind, labels.count - closed >= TrainingRun.fewestPicturesOfAKind else { continue }
            autoreleasepool {
                guard let trainer = EyeTrainer(seed: seed) else { return }
                let taught = gather(witness.train)
                _ = taught.withUnsafeBufferPointer { pictures in
                    trainer.train(images: pictures.baseAddress!, labels: labels, epochs: passes, seed: seed) { pass, _ in
                        report(.checkingPoses(done: number * passes + pass, of: total))
                    }
                }
                let asked = gather(witness.judge)
                let said = asked.withUnsafeBufferPointer { trainer.predict(images: $0.baseAddress!, count: witness.judge.count) }
                for (position, answer) in zip(witness.judge, said) { answers[position] = answer }
            }
        }

        let all = pictures(of: set.entries)
        var flags: [PoseFlag] = []
        for pose in poses.sorted() {
            guard let indices = all[pose] else { continue }
            let first = set.entries[indices[0]]
            let label: EyeLabel = first.closed ? .closed : .open
            let said = indices.compactMap { answers[$0] }
            let (verdict, score) = said.count == indices.count ? verdict(label: label, closed: said) : (.unjudged, nil)
            let line = PoseCheckLine(at: now, phase: pose.phase, label: label, variant: first.variant,
                                     pictures: indices.count, score: score, verdict: verdict)
            RecordFile<PoseCheckLine>(in: root.appendingPathComponent(pose.session, isDirectory: true)).append(line)
            if verdict == .flagged {
                flags.append(PoseFlag(session: pose.session, phase: pose.phase, label: label, variant: first.variant,
                                      pictures: indices.count, score: score ?? 0))
            }
        }
        return flags
    }

    // MARK: - The person's answer

    /// "Leave It Out" (`again` false) or "Record It Again" (`again` true): the pose's
    /// pictures are set aside in its recording (`SessionStore.setAside`), and the answer is
    /// written. A pose recorded again is judged again at the next training.
    public static func answer(_ flag: PoseFlag, recordAgain again: Bool, root: URL, now: Date = Date()) throws {
        let folder = root.appendingPathComponent(flag.session, isDirectory: true)
        try SessionStore.setAside(phase: flag.phase, of: folder)
        RecordFile<PoseCheckLine>(in: folder).append(PoseCheckLine(at: now, phase: flag.phase, label: flag.label, variant: flag.variant,
                                                                   pictures: flag.pictures, score: flag.score,
                                                                   verdict: again ? .again : .leftOut))
    }
}

/// A pose that its witness read the other way without doubt: open eyes in a pose recorded
/// as "closed", or closed eyes in one recorded as "open".
public struct PoseFlag: Codable, Equatable {
    /// The recording (its folder's name) and the pose (`SessionScript.phases`).
    public let session: String
    public let phase: Int
    public let label: EyeLabel
    public let variant: String
    public let pictures: Int
    /// The middle of the witness's answers for the pose's own label: 1 agrees, 0 is sure
    /// of the opposite.
    public let score: Double

    public init(session: String, phase: Int, label: EyeLabel, variant: String, pictures: Int, score: Double) {
        self.session = session
        self.phase = phase
        self.label = label
        self.variant = variant
        self.pictures = pictures
        self.score = score
    }
}

/// One line of a recording's pose-check.csv: what happened to one of its poses. Lines are
/// only added; a pose's last line is where it stands.
public struct PoseCheckLine: RecordLine, Equatable {

    public enum Verdict: String {
        /// Its witness did not read it the other way without doubt.
        case kept
        /// Its witness read it the other way without doubt: the person is asked.
        case flagged
        /// Not judged: too few pictures, or a witness with too few to learn from.
        case unjudged
        /// Its pictures were set aside to record it again: the new ones are judged next.
        case again
        /// Its pictures were set aside, by the person's choice.
        case leftOut = "left-out"
    }

    public static let fileName = "pose-check.csv"
    public static let header = "at,phase,label,variant,pictures,score,verdict"

    public let at: Date
    public let phase: Int
    public let label: EyeLabel
    public let variant: String
    public let pictures: Int
    public let score: Double?
    public let verdict: Verdict

    public init(at: Date, phase: Int, label: EyeLabel, variant: String, pictures: Int, score: Double?, verdict: Verdict) {
        self.at = at
        self.phase = phase
        self.label = label
        self.variant = variant
        self.pictures = pictures
        self.score = score
        self.verdict = verdict
    }

    public var fields: [String] {
        [RecordDates.string(at), String(phase), label.rawValue, CSVAppender.safe(variant), String(pictures),
         score.map { String(format: "%.4f", $0) } ?? "", verdict.rawValue]
    }

    public init?(fields: [String]) {
        guard fields.count >= 7, let at = RecordDates.date(fields[0]), let phase = Int(fields[1]),
              let label = EyeLabel(rawValue: fields[2]), let pictures = Int(fields[4]),
              let verdict = Verdict(rawValue: fields[6]) else { return nil }
        self.init(at: at, phase: phase, label: label, variant: fields[3], pictures: pictures, score: Double(fields[5]), verdict: verdict)
    }
}
