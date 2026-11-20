import Foundation

// SPIKE:   EyeTrainSpike <jobs.json> <results.json> [--engine=mps|coreml|createml]
//                        [--only=<prefix>[,<prefix>]] [--weights=<folder>] [--template=<.mlmodelc>]
//                        [--cosine] [--fixed-shapes] [--level1]
//          EyeTrainSpike <jobs.json> - --engine=bench       where a training step's time goes
//
// Runs the jobs harness.py exported (train on these pictures, answer on those) with one
// of the candidate engines, and writes the answers in the form harness.py scores.

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

setvbuf(stdout, nil, _IONBF, 0)   // every line reaches the log at once, even if the run is cut short
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: EyeTrainSpike <jobs.json> <results.json> [--engine=mps|coreml|createml] [--only=<prefix>] ...")
    exit(2)
}
func option(_ name: String) -> String? {
    arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
let engine = option("engine") ?? "mps"
let only = option("only")
let weightsFolder = option("weights").map { URL(fileURLWithPath: $0) }

let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
var clock = Date()
let all = engine == "createml" ? [] : Pictures.load(jobs.pictures)
print(String(format: "%d pictures read in %.1f s (engine: %@)", jobs.pictures.count, Date().timeIntervalSince(clock), engine))

/// The pictures of a list of positions, gathered side by side.
func gather(_ positions: [Int]) -> [Float] {
    var out = [Float](repeating: 0, count: positions.count * Pictures.pixels)
    all.withUnsafeBufferPointer { source in
        out.withUnsafeMutableBufferPointer { target in
            for (n, position) in positions.enumerated() {
                (target.baseAddress! + n * Pictures.pixels).update(from: source.baseAddress! + position * Pictures.pixels, count: Pictures.pixels)
            }
        }
    }
    return out
}

if engine == "bench" {
    EyeNetGraph.everythingOnTheGPU = !arguments.contains("--level1")
    EyeNetGraph(seed: 1)!.benchmark()
    exit(0)
}

var results: [String: Answer] = [:]
for job in jobs.jobs where only.map({ $0.split(separator: ",").contains { job.name.hasPrefix($0) } }) ?? true {
    clock = Date()
    let labels = job.train.map { Float(jobs.labels[$0]) }
    var note = ""
    let answer: Answer

    switch engine {
    case "coreml":
        let template = URL(fileURLWithPath: option("template")!)
        let (closed, losses, said) = try CoreMLUpdate.run(
            template: template, images: gather(job.train), labels: labels, asked: gather(job.predict), askedCount: job.predict.count,
            epochs: job.epochs, seed: job.seed, cosineRate: arguments.contains("--cosine"))
        // Training time is not separable from answering here; it is measured apart below.
        answer = Answer(closed: closed, seconds: Date().timeIntervalSince(clock), losses: losses)
        note = said

    case "createml":
        let (closed, seconds, perAnswer, said) = try CreateMLRun.run(pictures: jobs.pictures, labels: jobs.labels, train: job.train, asked: job.predict)
        answer = Answer(closed: closed, seconds: seconds, losses: [])
        note = String(format: "%.2f ms per answer; %@", perAnswer, said)

    default:
        EyeNetGraph.everythingOnTheGPU = !arguments.contains("--level1")
        EyeNetGraph.fixedShapes = arguments.contains("--fixed-shapes")
        guard let network = EyeNetGraph(seed: job.seed) else { fatalError("no Metal device") }
        let images = gather(job.train)
        let losses = network.train(images: images, labels: labels, epochs: job.epochs, seed: job.seed)
        let seconds = Date().timeIntervalSince(clock)
        let closed = network.predict(images: gather(job.predict), count: job.predict.count)
        answer = Answer(closed: closed, seconds: seconds, losses: losses)
        note = String(format: "altering %.1f s, GPU %.1f s", network.secondsAltering, network.secondsOnGPU)

        if let weightsFolder {
            // The trained numbers as one flat file of 32-bit floats, and a list saying what is where.
            try FileManager.default.createDirectory(at: weightsFolder, withIntermediateDirectories: true)
            var blob = Data(), index: [[String: Any]] = []
            for part in network.foldedWeights() {
                index.append(["name": part.name, "shape": part.shape, "offset": blob.count / 4, "count": part.values.count])
                part.values.withUnsafeBufferPointer { blob.append(Data(buffer: $0)) }
            }
            let stem = job.name.replacingOccurrences(of: "/", with: "_")
            try blob.write(to: weightsFolder.appendingPathComponent("\(stem).bin"))
            try JSONSerialization.data(withJSONObject: index).write(to: weightsFolder.appendingPathComponent("\(stem).json"))
        }
    }

    results[job.name] = answer
    print(String(format: "  %@  %5d pictures  %5.1f s   loss %.3f -> %.3f   %@", job.name.padding(toLength: 44, withPad: " ", startingAt: 0),
                 job.train.count, answer.seconds, answer.losses.first ?? 0, answer.losses.last ?? 0, note))
    // Written after every job: a run cut short keeps what it had.
    try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: arguments[2]))
}
