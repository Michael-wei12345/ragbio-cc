import SwiftUI

struct ReviewJobConfirmationSheet: View {
    let confirmation: ReviewJobConfirmation
    @ObservedObject var coordinator: ReviewJobCoordinator

    private var manifest: ReviewInputManifest { confirmation.manifest }
    private var authorizationStage: ReviewAuthorizationStage {
        guard coordinator.confirmation?.id == confirmation.id else {
            return confirmation.authorizationStage
        }
        return coordinator.confirmation?.authorizationStage ?? confirmation.authorizationStage
    }
    private var outputLanguage: Binding<ReviewOutputLanguage> {
        Binding(
            get: {
                coordinator.confirmation?.manifest.resolvedOutputLanguage
                    ?? manifest.resolvedOutputLanguage
            },
            set: coordinator.setOutputLanguage
        )
    }

    var body: some View {
        Group {
            switch authorizationStage {
            case .checking:
                authorizationProgress(
                    title: "Connecting Review Engine",
                    detail: "Checking your ChatGPT sign-in…"
                )
            case .signingIn:
                authorizationProgress(
                    title: "Sign in to ChatGPT",
                    detail: "Complete sign-in in your browser. RagBio will continue automatically."
                )
            case .ready:
                confirmationContent
            case let .failed(message):
                authorizationFailure(message: message)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(authorizationStage.isBusy)
    }

    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generate Systematic Review")
                .font(.title2.bold())
            Text(manifest.query)
                .font(.headline)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 10) {
                summary("Use papers", value: manifest.papers.count)
                summary("URLs sent to Review Engine", value: manifest.usableURLCount)
                Divider()
                HStack {
                    Text("Review language")
                    Spacer()
                    Picker("Review language", selection: outputLanguage) {
                        ForEach(ReviewOutputLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
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

            Label(
                "This review uses your signed-in Codex allowance.",
                systemImage: "person.crop.circle.badge.checkmark"
            )
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
    }

    private func authorizationProgress(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.bold())
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { coordinator.dismissConfirmation() }
            }
        }
    }

    private func authorizationFailure(message: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ChatGPT sign-in needed")
                .font(.title2.bold())
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Retry will open ChatGPT sign-in in your browser and return here automatically when it finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { coordinator.dismissConfirmation() }
                Button("Retry Sign-in") { coordinator.retryAuthorization() }
                    .buttonStyle(.borderedProminent)
            }
        }
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
                            VStack(alignment: .leading, spacing: 8) {
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text(recoveryGuidance(job.failureCategory))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
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

                        Text("The Review Engine uses your signed-in Codex allowance. Results are generated only from the fixed Use manifest and should be reviewed before publication.")
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
                Text(job.status == .completed
                     ? "\(job.completedPaperCount)/\(job.totalPaperCount)"
                     : "\(job.totalPaperCount) selected sources")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if job.status == .completed {
                ProgressView(value: 1, total: 1)
            } else {
                ProgressView()
            }
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
            } else if job.status == .blocked || job.status == .failed {
                Button(recoveryButtonTitle(job.failureCategory), systemImage: "arrow.clockwise") {
                    recover(job.failureCategory)
                }
                    .buttonStyle(.borderedProminent)
                if job.status == .blocked {
                    Button("Cancel", role: .destructive) { coordinator.cancel() }
                }
            }
        }
    }

    private func recover(_ category: ReviewHelperFailureCategory?) {
        switch category {
        case .authentication:
            coordinator.signInAndResume()
        case .runtime:
            coordinator.restartApplication()
        default:
            coordinator.resume()
        }
    }

    private func recoveryButtonTitle(_ category: ReviewHelperFailureCategory?) -> String {
        switch category {
        case .authentication: "Sign in again"
        case .network: "Retry connection"
        case .sourceAccess: "Retry sources"
        case .generation: "Retry generation"
        case .outputValidation: "Regenerate files"
        case .fileSave: "Retry saving"
        case .runtime: "Restart RagBio"
        default: "Retry"
        }
    }

    private func recoveryGuidance(_ category: ReviewHelperFailureCategory?) -> String {
        switch category {
        case .authentication:
            "Your task is saved. Sign in again, then RagBio will continue from the saved review."
        case .allowance:
            "Your task is saved. Retry later or check the allowance for the signed-in ChatGPT account."
        case .network:
            "Your task is saved. Check the internet connection, then retry."
        case .sourceAccess:
            "The fixed Use list is unchanged. Retry to read the unavailable sources again."
        case .generation:
            "Completed work is kept. Retry to continue AI generation from the saved review."
        case .outputValidation:
            "The source work is kept. RagBio can regenerate and validate the Excel and Word files."
        case .fileSave:
            "Free some disk space or check folder permissions, then retry saving the files."
        case .runtime:
            "Restart RagBio first. If this repeats, replace the app with the latest build; saved searches and reviews remain on this Mac."
        case .protocol:
            "Your task is saved. Retry to reconnect the app and its local Review Engine."
        case nil:
            "Your task is saved. Retry to continue from the latest saved point."
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
