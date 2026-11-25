import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The Model tab: the model that reads your eyes, its recordings, and how to add to them or delete them.

private typealias Card = SettingsCard
private typealias Row = SettingsRow

extension SettingsView {

    // MARK: Your model

    var modelTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row(modelTitle, detail: modelDetail) {
                    if !model.isDemo && model.modelSource == .none {
                        Button(preferences.welcomed ? "Continue Setup…" : "Set Up…") { actions.openSetup(.resume) }
                            .mainButton()
                    }
                }
            }
            // With no model there is one thing to do, and it is the button above: adding
            // a recording or deleting what does not exist were two ways in that led nowhere.
            if !model.isDemo, model.modelSource != .none || state.onDisk.sessions > 0 || state.onDisk.captures > 0 || state.onDisk.untested {
                if model.modelSource != .none {
                    Card {
                        Row("Add a recording",
                            detail: "Two minutes in another light, on another day or with other glasses. Then the model is trained again on everything, and tested.") {
                            Button("Add a Recording…") { actions.openSetup(.addSession) }
                        }
                        Divider()
                        Row("Test it again", detail: "\(ProofTest.ticks) ticks, a blink at each: how many does it count where you sit now?") {
                            Button("Test Again") { actions.openSetup(.test) }
                                .disabled(!isTrainedHere)
                        }
                    }
                }
                Card {
                    Row("Recordings", detail: onDiskDetail) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([files.store.base]) }
                    }
                    if isTrainedHere, files.ownSessions {
                        Divider()
                        Row("Start again", detail: "For a model that counts badly: deletes the recordings and the model, then opens setup.") {
                            Button("Start Again…") {
                                if Confirm.destructive(EraseWords.startAgain) { deleteEverything(thenSetUp: true) }
                            }
                        }
                    }
                    Divider()
                    Row("Delete recordings and model", detail: state.deleteProblem ?? "Removes every picture of your eyes and the model trained on them. They are deleted for good, not moved to the Trash.") {
                        Button("Delete…") {
                            if Confirm.destructive(EraseWords.recordingsAndModel(deleteWarning)) { deleteEverything() }
                        }
                        .disabled(state.onDisk.sessions == 0 && state.onDisk.captures == 0 && !isTrainedHere && !state.onDisk.untested)
                    }
                }
            }
        }
        .onAppear { state.refresh(files) }
    }

    private var isTrainedHere: Bool {
        if case .trainedHere = model.modelSource { return true }
        return false
    }

    private var modelTitle: String {
        if model.isDemo { return "The demo has no model" }
        switch model.modelSource {
        case .trainedHere: return "Trained in this app, on your eyes"
        case .builtIn: return "Built into this app"
        case .given: return "Named at launch"
        case .none: return "No model yet"
        }
    }

    private var modelDetail: String {
        if model.isDemo { return "Its blinks are made up. See the Setup, in the panel, trains a real model on painted eyes." }
        switch model.modelSource {
        case .trainedHere(let info):
            var text = "On \(Format.day(info.trainedOn)), from \(Format.count(info.sessions.count, "recording")) "
                + "(\(info.pictures.formatted()) pictures)."
            if let proof = info.proof {
                text += " Its test: \(proof.found) of \(proof.of) blinks counted"
                    + (proof.found >= ProofTest.passMark ? "." : "; you chose to use it anyway.")
            }
            return text
        case .builtIn:
            return "It came with this copy of the app, put there by whoever built it."
                + (state.onDisk.untested ? " A model trained here is waiting for its test: Continue Setup." : "")
        case .given(let url):
            return url.path
        case .none:
            return state.onDisk.untested
                ? "Your model is trained but not tested yet. Until then nothing is counted."
                : "Blink learns your eyes before it can count. \(AppWords.setupLength)"
        }
    }

    private var onDiskDetail: String {
        let disk = state.onDisk
        let captures = disk.captures == 0 ? "" : " Also \(Format.count(disk.captures, "capture")) from Live View"
            + String(format: ", %.0f MB.", disk.captureMegabytes)
        guard disk.sessions > 0 else { return disk.captures == 0 ? "No recording on this Mac." : "No recording on this Mac.\(captures)" }
        return "\(Format.count(disk.sessions, "recording")), \(disk.pictures.formatted()) small pictures of your eyes, "
            + String(format: "%.0f MB.", disk.megabytes) + captures + " "
            + (files.ownSessions ? "In a folder only your account can read." : "In \(files.sessionsRoot.path), named at launch.")
    }

    private var deleteWarning: String {
        var text = files.ownSessions
            ? "Every recording\(state.onDisk.captures > 0 ? ", every capture from Live View," : "") and the model trained on them. This cannot be undone."
            : "The model trained here. The recordings are in a folder named at launch and are left alone."
        if isTrainedHere {
            text += FileManager.default.fileExists(atPath: ModelSource.builtInModel.path)
                ? " Blink goes back to the model built into it."
                : " Blink stops counting until it is set up again."
        }
        return text
    }

    private func deleteEverything(thenSetUp: Bool = false) {
        actions.closeSetup()
        Task {
            do {
                try await model.deleteModelAndRecordings(sessions: files.sessionsRoot, own: files.ownSessions,
                                                         captures: files.capturesRoot)
                state.deleteProblem = nil
            } catch {
                state.deleteProblem = "It could not be deleted: \(error.localizedDescription)"
            }
            state.refresh(files)
            if thenSetUp, state.deleteProblem == nil { actions.openSetup(.resume) }
        }
    }
}
