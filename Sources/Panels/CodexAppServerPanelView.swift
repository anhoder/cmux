import SwiftUI

struct CodexAppServerPanelView: View {
    @ObservedObject var panel: CodexAppServerPanel
    let isFocused: Bool

    @FocusState private var promptFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(alignment: .center, spacing: 8) {
            TextField(
                String(localized: "codexAppServer.prompt.placeholder", defaultValue: "Ask Codex about this workspace"),
                text: $panel.promptText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .lineLimit(1...5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 28, alignment: .center)
            .focused($promptFocused)
            .onSubmit {
                Task { await panel.sendPrompt() }
            }

            Button {
                Task { await panel.sendPrompt() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!panel.canSendPrompt)
            .foregroundStyle(panel.canSendPrompt ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(panel.canSendPrompt ? 0.75 : 0.35), in: Circle())
            .accessibilityLabel(String(localized: "codexAppServer.button.send", defaultValue: "Send"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 17))
        .frame(maxWidth: 740)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
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
