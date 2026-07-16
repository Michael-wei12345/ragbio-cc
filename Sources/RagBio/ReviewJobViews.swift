import SwiftUI

struct ReviewJobConfirmationSheet: View {
    let confirmation: ReviewJobConfirmation
    @ObservedObject var coordinator: ReviewJobCoordinator

    private var manifest: ReviewInputManifest { confirmation.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generate Systematic Review")
                .font(.title2.bold())
            Text(manifest.query)
                .font(.headline)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 10) {
                summary("Use papers", value: manifest.papers.count)
                summary("URLs sent to Review Engine", value: manifest.usableURLCount)
                if manifest.duplicateURLCount > 0 {
                    summary("Duplicate URLs kept in manifest", value: manifest.duplicateURLCount)
                }
                if manifest.missingURLCount > 0 {
                    summary("Papers without a usable URL", value: manifest.missingURLCount)
                }
            }
            .padding(14)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            Text("Only the current search record's Use papers will be included. This fixed list is saved with the review and will not change if you edit Use later.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { coordinator.dismissConfirmation() }
                Button("Start Review") { coordinator.startConfirmedReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manifest.usableURLCount == 0)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func summary(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted()).bold().monospacedDigit()
        }
    }
}

struct ReviewWorkspaceView: View {
    @ObservedObject var coordinator: ReviewJobCoordinator

    private var job: ReviewJob? { coordinator.presentedJob }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back to Paper", systemImage: "chevron.left") {
                    coordinator.closeWorkspace()
                }
                .buttonStyle(.borderless)
                Spacer()
                if let job {
                    Text("Review v\(job.version)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(18)

            Divider()

            if let job {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review Workspace")
                                .font(.largeTitle.bold())
                            Text(job.query)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Label(statusTitle(job.status), systemImage: statusIcon(job.status))
                                .foregroundStyle(statusColor(job.status))
                                .font(.headline)
                        }

                        progressCard(job)

                        if job.status == .completed {
                            deliverablesCard(job)
                        }

                        if let message = job.blockMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }

                        if !job.warningMessages.isEmpty {
                            ForEach(job.warningMessages, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        actionBar(job)

                        Text("Integration preview: the persistent job flow is real, while this foundation build uses deterministic sample Excel and Word content. It does not consume Codex allowance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func progressCard(_ job: ReviewJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.stage.title).font(.headline)
                Spacer()
                Text("\(job.completedPaperCount)/\(job.totalPaperCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(job.completedPaperCount),
                total: Double(max(1, job.totalPaperCount))
            )
            Text(job.stageDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(18)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func deliverablesCard(_ job: ReviewJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review files are ready", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
            HStack {
                Button("Open Excel", systemImage: "tablecells") {
                    coordinator.openWorkbook()
                }
                Button("Open Word", systemImage: "doc.richtext") {
                    coordinator.openManuscript()
                }
                Button("Show in Finder", systemImage: "folder") {
                    coordinator.showInFinder()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func actionBar(_ job: ReviewJob) -> some View {
        HStack {
            if job.status == .running {
                Button("Pause", systemImage: "pause.fill") { coordinator.pause() }
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            } else if job.status == .paused {
                Button("Resume", systemImage: "play.fill") { coordinator.resume() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            }
        }
    }

    private func statusTitle(_ status: ReviewJobStatus) -> String {
        switch status {
        case .confirming: "Waiting for confirmation"
        case .running: "Review is running"
        case .paused: "Review is paused"
        case .blocked: "Review needs attention"
        case .failed: "Review stopped"
        case .completed: "Review completed"
        case .cancelled: "Review cancelled"
        }
    }

    private func statusIcon(_ status: ReviewJobStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed, .blocked: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .cancelled: "xmark.circle"
        default: "circle.dotted.circle"
        }
    }

    private func statusColor(_ status: ReviewJobStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed, .blocked: .orange
        case .paused: .blue
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}
