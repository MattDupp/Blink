import Foundation
import BlinkCore

// Runs the app's own trainer on trainings described in a file, and writes its answers:
//
//     BlinkTrain <jobs.json> <results.json> [--only=<prefix>[,<prefix>]]
//
// WHAT IT IS FOR. The app trains its model in Swift (`EyeTrainer`); the project's
// reference is the Python route (training/learning.py). To compare the two on THE SAME
// pictures and THE SAME splits, training/compare.py writes a list of "jobs" (train on
// these pictures, answer on those), runs them in Python, and scores both sets of answers
// with training/evaluate.py's own functions. This tool is the Swift half: `make compare`.

struct Job: Decodable {
    let name: String
    let train: [Int]
    let predict: [Int]
    let seed: UInt64
    let epochs: Int
}

struct Jobs: Decodable {
    let pictures: [String]
    let labels: [Int]
    let jobs: [Job]
}

struct Answer: Encodable {
    let closed: [Float]
    let seconds: Double
    let losses: [Float]
}

setvbuf(stdout, nil, _IONBF, 0)   // every line reaches the terminal at once, even if the run is cut short
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: BlinkTrain <jobs.json> <results.json> [--only=<prefix>[,<prefix>]]")
    exit(2)
}
let only = LaunchArguments.value(of: "only")?.split(separator: ",").map(String.init)

let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
var clock = Date()
let pixels = EyeNetwork.pixels

// Every picture once, as brightness values, read the way the app reads them.
var all = [Float](repeating: 0, count: jobs.pictures.count * pixels)
var unreadable = 0
for (index, path) in jobs.pictures.enumerated() {
    guard let gray = TrainingSet.gray(contentsOf: URL(fileURLWithPath: path)) else { unreadable += 1; continue }
    all.replaceSubrange(index * pixels..<(index + 1) * pixels, with: gray)
}
print(String(format: "%d pictures read in %.1f s", jobs.pictures.count, Date().timeIntervalSince(clock)))
guard unreadable == 0 else {
    // A comparison on pictures that are partly missing would compare nothing.
    print("\(unreadable) pictures could not be read: nothing was trained.")
    exit(1)
}

/// The pictures of a list of positions, one after the other.
func gather(_ positions: [Int]) -> [Float] {
    var out = [Float](repeating: 0, count: positions.count * pixels)
    for (n, position) in positions.enumerated() {
        out.replaceSubrange(n * pixels..<(n + 1) * pixels, with: all[position * pixels..<(position + 1) * pixels])
    }
    return out
}

var results: [String: Answer] = [:]
for job in jobs.jobs where only?.contains(where: { job.name.hasPrefix($0) }) ?? true {
    clock = Date()
    // One training at a time, each in its own pool: nothing a job made on the graphics
    // processor outlives it.
    results[job.name] = autoreleasepool { () -> Answer in
        guard let trainer = EyeTrainer(seed: job.seed) else {
            print("This Mac has no graphics processor that the trainer can use.")
            exit(1)
        }
        let labels = job.train.map { Float(jobs.labels[$0]) }
        let losses = trainer.train(images: gather(job.train), labels: labels, epochs: job.epochs, seed: job.seed)
        let seconds = Date().timeIntervalSince(clock)
        let closed = trainer.predict(images: gather(job.predict), count: job.predict.count)
        return Answer(closed: closed, seconds: seconds, losses: losses)
    }
    if let answer = results[job.name] {
        print(String(format: "  %@  %5d pictures  %5.1f s   loss %.3f -> %.3f", job.name.padding(toLength: 44, withPad: " ", startingAt: 0),
                     job.train.count, answer.seconds, answer.losses.first ?? 0, answer.losses.last ?? 0))
    }
    // Written after every job: a run cut short keeps what it had.
    try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: arguments[2]))
}
