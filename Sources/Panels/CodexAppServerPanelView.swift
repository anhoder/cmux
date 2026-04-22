import SwiftUI

struct CodexAppServerPanelView: View {
    @ObservedObject var panel: CodexAppServerPanel
    let isFocused: Bool

    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if isFocused {
                promptFocused = true
            }
        }
        .task {
            await panel.start()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                promptFocused = true
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(
                String(localized: "codexAppServer.header.title", defaultValue: "Codex App Server"),
                systemImage: "sparkles"
            )
            .font(.headline)

            Text(panel.status.localizedTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusBackground, in: Capsule())

            Spacer(minLength: 12)

            Label(
                String(localized: "codexAppServer.cwd.label", defaultValue: "Working directory"),
                systemImage: "folder"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)

            TextField(
                String(localized: "codexAppServer.cwd.placeholder", defaultValue: "Working directory"),
                text: $panel.cwd
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 220, maxWidth: 360)

            Button {
                if showsStartButton {
                    if !isStopped {
                        panel.stop()
                    }
                    Task { await panel.start() }
                } else {
                    panel.stop()
                }
            } label: {
                Image(systemName: showsStartButton ? "play.fill" : "stop.fill")
            }
            .help(showsStartButton
                ? String(localized: "codexAppServer.button.start", defaultValue: "Start")
                : String(localized: "codexAppServer.button.stop", defaultValue: "Stop")
            )
            .disabled(panel.status == .starting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ZStack {
                CodexTrajectoryTranscriptView(items: panel.transcriptItems)
                    .opacity(panel.transcriptItems.isEmpty ? 0 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panel.transcriptItems.isEmpty && panel.pendingRequests.isEmpty {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !panel.pendingRequests.isEmpty {
                Divider()
                pendingRequests
            }
        }
    }

    private var pendingRequests: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(panel.pendingRequests) { request in
                    CodexAppServerPendingRequestView(
                        request: request,
                        onAccept: {
                            panel.resolvePendingRequest(request, decision: .accept)
                        },
                        onDecline: {
                            panel.resolvePendingRequest(request, decision: .decline)
                        },
                        onCancel: {
                            panel.resolvePendingRequest(request, decision: .cancel)
                        }
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(String(localized: "codexAppServer.emptyTranscript", defaultValue: "No messages yet"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                String(localized: "codexAppServer.prompt.placeholder", defaultValue: "Ask Codex about this workspace"),
                text: $panel.promptText,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .focused($promptFocused)
            .onSubmit {
                Task { await panel.sendPrompt() }
            }

            Button {
                Task { await panel.sendPrompt() }
            } label: {
                Label(
                    String(localized: "codexAppServer.button.send", defaultValue: "Send"),
                    systemImage: "paperplane.fill"
                )
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!panel.canSendPrompt)
        }
        .padding(12)
    }

    private var isStopped: Bool {
        if case .stopped = panel.status {
            return true
        }
        return false
    }

    private var showsStartButton: Bool {
        switch panel.status {
        case .stopped, .failed:
            return true
        case .starting, .ready, .running:
            return false
        }
    }

    private var statusForeground: Color {
        switch panel.status {
        case .ready:
            return .green
        case .running, .starting:
            return .blue
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private var statusBackground: Color {
        statusForeground.opacity(0.14)
    }

}

private struct CodexAppServerPendingRequestView: View {
    let request: CodexAppServerPendingRequest
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(localized: "codexAppServer.request.title", defaultValue: "Approval requested"),
                systemImage: "hand.raised.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text(request.method)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(request.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if request.supportsDecisionResponse {
                    Button {
                        onAccept()
                    } label: {
                        Label(
                            String(localized: "codexAppServer.button.approve", defaultValue: "Approve"),
                            systemImage: "checkmark"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onDecline()
                    } label: {
                        Label(
                            String(localized: "codexAppServer.button.deny", defaultValue: "Deny"),
                            systemImage: "xmark"
                        )
                    }
                }

                Button {
                    onCancel()
                } label: {
                    Label(
                        String(localized: "codexAppServer.button.cancel", defaultValue: "Cancel"),
                        systemImage: "slash.circle"
                    )
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
