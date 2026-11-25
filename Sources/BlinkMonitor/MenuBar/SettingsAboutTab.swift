import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The About tab: the version, the project's pages, good to know, and the studies.

private typealias Card = SettingsCard
private typealias Row = SettingsRow

extension SettingsView {

    // MARK: About

    /// The version, what the app is not, where to reach the project, and where its
    /// figures come from. The whole tab scrolls, like the others.
    var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            about
            Card {
                Row("Website and source", detail: "What the app does, how it works, and all of its code.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.home) }
                }
                Divider()
                Row("Report a problem", detail: "A page where problems are listed and answered. It needs a GitHub account.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.problems) }
                }
                Divider()
                Row("Check for a new version", detail: "This is version \(AppInfo.version). The page shows the latest one. The app itself never looks: it makes no network connection.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.newVersion) }
                }
            }
            Text("Each of these opens in your browser.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
            SectionTitle("Good to know")
                .padding(.top, 6)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(GoodToKnow.all, id: \.question) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                            Text(entry.answer)
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            SectionTitle("What studies report")
                .padding(.top, 6)
            Card {
                StudyRangesSection(yours: preferences.reference.map {
                    .init(label: "your usual rate \(Format.rate($0.rate))", rate: $0.rate)
                }, limit: preferences.limit)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            Text("What the app says about blink rates comes from these studies. They describe what is typical, not what is ideal, and none of it is a diagnosis. Each one opens in your browser.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card { SourcesList() }
            Card {
                Row("The whole review", detail: "Every study in one table, what they disagree on, and the limits of this reading.") {
                    Button("Open") { NSWorkspace.shared.open(PublishedRates.review) }
                }
            }
        }
    }

    private var about: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Blink \(AppInfo.version)")
                    .fontWeight(.semibold)
                Text("A personal project, not a medical device: its numbers are not a diagnosis. If your eyes hurt, see an eye-care professional.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
