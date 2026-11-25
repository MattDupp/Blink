import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The Privacy tab: what is kept and what is not, and every file with its size, Show in Finder and Erase.

private typealias Card = SettingsCard
private typealias Row = SettingsRow

extension SettingsView {

    // MARK: Your data

    var data: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    DataPoint(symbol: "light.beacon.max", text: "The green light beside the camera means Blink is counting. Pause, in the menu-bar panel, turns the camera and the light off.")
                    DataPoint(symbol: "tablecells", text: "Kept: one line per minute, with the seconds counted and the number of blinks.")
                    DataPoint(symbol: "eye", text: "Kept from setup: the small pictures of your eyes it recorded, and the model trained on them. You can see and delete them under Model.")
                    DataPoint(symbol: "checklist", text: "Kept with a routine switched on: one line each time a reminder is shown, done, postponed or missed.")
                    DataPoint(symbol: "eye.slash", text: "Kept about breaks: one line each time a look-away break is taken or skipped, a blink break is finished or a blink reminder is shown.")
                    if state.onDisk.captures > 0 {
                        DataPoint(symbol: "record.circle", text: "Kept from Live View: \(Format.count(state.onDisk.captures, "capture")) of your eyes"
                                  + String(format: ", %.0f MB, ", state.onDisk.captureMegabytes)
                                  + "recorded with its record buttons.")
                    }
                    DataPoint(symbol: "square.and.pencil", text: "Kept with the evening question switched on: your answer, one line a day.")
                    DataPoint(symbol: "photo", text: "Never kept: what the camera sees while it counts. Each picture is read and discarded at once.")
                    DataPoint(symbol: "wifi.slash", text: "Nothing leaves this Mac. The app makes no network connection.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            // Every file the app writes (`KeptRecord`), each with its size, where it is and its own Erase.
            Card {
                let records = model.keptRecords
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider() }
                    recordRow(record)
                }
                if state.onDisk.captures > 0, let captures = files.capturesRoot {
                    Divider()
                    Row("Captures folder", detail: state.capturesProblem ?? ("Small pictures of your eyes, frame by frame, saved from Live View."
                            + String(format: " %.0f MB.", state.onDisk.captureMegabytes))) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([captures]) }
                        Button("Erase…") {
                            guard Confirm.destructive(EraseWords.captures(state.onDisk.captures)) else { return }
                            // Said in the row when it fails, as the model's own Delete does: it
                            // used to fail without a word.
                            do {
                                try FileManager.default.removeItem(at: captures)
                                state.capturesProblem = nil
                            } catch {
                                state.capturesProblem = "They could not be erased: \(error.localizedDescription)"
                            }
                            state.refresh(files)
                        }
                    }
                }
            }
            // Dragging the app to the Trash leaves all of the above behind.
            if let deleteEverything = actions.deleteEverythingAndQuit {
                Card {
                    Row("Remove Blink from this Mac",
                        detail: "Deletes the recordings of your eyes, your model, \(KeptRecord.names(model.keptRecords)) and every setting, "
                            + "then quits. Afterwards, move the app itself to the Trash.") {
                        Button("Delete Everything and Quit…") {
                            if Confirm.destructive(EraseWords.everything(model.keptRecords)) { deleteEverything() }
                        }
                    }
                }
            }
        }
        .onAppear { state.refresh(files) }
    }

    /// One record's row: its size (counted when the window opened), Show in Finder, Erase.
    private func recordRow(_ record: KeptRecord) -> some View {
        let bytes = state.onDisk.recordBytes[record.file]
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "." } ?? "No file yet."
        return Row(record.title, detail: "\(record.detail) \(size)") {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.file]) }
                .disabled(bytes == nil)
            Button("Erase…") {
                guard Confirm.destructive(record.eraseQuestion) else { return }
                record.erase()
                state.refresh(files)
            }
            .disabled(bytes == nil && !record.holdsMore())
        }
    }
}

private struct DataPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
