import SwiftUI

struct ShellSectionPicker: View {
    @Binding var selection: ShellSection

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ShellSection.allCases) { section in
                Button { selection = section } label: {
                    Text(section.title)
                        .font(.system(size: 12, weight: selection == section ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selection == section ? ParityTheme.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Sidebar section"))
    }
}

struct PersonalAgentsSidebar: View {
    @Bindable var center: PersonalAgentCenter
    let accounts: [AccountChoice]
    @Binding var accountID: String
    let accountMenu: SidebarAccountMenuContext
    let onAccounts: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(accounts) { account in
                        Button(account.title) { accountID = account.id }
                    }
                    Divider()
                    Button(L10n.string("Accounts…"), action: onAccounts)
                } label: {
                    HStack(spacing: 5) {
                        Text(accounts.first { $0.id == accountID }?.title ?? "ChatGPT")
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("ChatGPT account"))
                Spacer(minLength: 0)
                if center.isLoading { ProgressView().controlSize(.mini) }
                else {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help(L10n.string("Refresh"))
                        .accessibilityLabel(L10n.string("Refresh personal agents"))
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(center.agents) { agent in
                        Button { Task { await center.select(agent.id) } } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "circle.dotted").font(.system(size: 22))
                                    .foregroundStyle(ParityTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(agent.isPaused ? L10n.string("Paused") : "Dots")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(center.selectedID == agent.id ? ParityTheme.selectedFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(agent.name)
                        .accessibilityAddTraits(center.selectedID == agent.id ? .isSelected : [])
                    }
                    if center.hasLoaded, center.agents.isEmpty, center.failure == nil {
                        Text(L10n.string("No dots in this account"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            SidebarAccountButton(context: accountMenu).padding(.horizontal, 4).padding(.vertical, 5)
        }
        .background(ParityTheme.sidebar)
    }
}

struct PersonalAgentsContent: View {
    @Bindable var center: PersonalAgentCenter
    let onRetry: () -> Void
    let onAccounts: () -> Void

    var body: some View {
        Group {
            if let agent = center.selected, let conversation = center.conversation {
                PersonalAgentConversationView(agent: agent, conversation: conversation,
                    reconnecting: center.isReconnecting,
                    connectionFailure: center.failure,
                    send: { Task { await center.send() } },
                    download: { try await center.download($0, for: agent.id) },
                    refresh: {
                        if center.failure != nil { onRetry() }
                        else { Task { await center.refreshConversation() } }
                    },
                    loadOlder: { Task { await center.refreshConversation(older: true) } })
                    .id(agent.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "circle.dotted").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("Dots").font(.title2.weight(.medium))
                    if center.isLoading {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Loading your dots…")).foregroundStyle(.secondary)
                    } else if let failure = center.failure {
                        Text(failure.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        if failure == .signInRequired || failure == .runtimeUnavailable {
                            Button(L10n.string("Open Accounts"), action: onAccounts)
                        } else {
                            Button(failure == .accountChanged ? L10n.string("Reconnect") : L10n.string("Try again"),
                                   action: onRetry)
                        }
                    } else if center.hasLoaded {
                        Text(L10n.string("Create your dot in ChatGPT, then refresh here."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .font(.system(size: 13))
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ParityTheme.canvas)
    }
}

struct PersonalAgentConversationView: View {
    let agent: PersonalAgent
    @Bindable var conversation: PersonalAgentConversation
    var reconnecting = false
    var connectionFailure: PersonalAgentFailure?
    let send: () -> Void
    let download: (PersonalAgentAttachment) async throws -> PersonalAgentDownload
    let refresh: () -> Void
    let loadOlder: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @State private var preview: PersonalAgentPreviewFile?
    @State private var attachmentFailure: PersonalAgentFailure?
    @State private var loadingAttachment = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.dotted").font(.system(size: 22)).foregroundStyle(ParityTheme.accent)
                Text(agent.name).font(.system(size: 17 * scale, weight: .semibold)).lineLimit(1)
                if reconnecting { Text(L10n.string("Reconnecting")).font(.caption).foregroundStyle(.secondary) }
                else if agent.isPaused { Text(L10n.string("Paused")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(conversation.isLoading)
                    .help(L10n.string("Refresh")).accessibilityLabel(L10n.string("Refresh conversation"))
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            if let failure = conversation.failure ?? connectionFailure {
                HStack { Text(failure.message); Spacer(); Button(L10n.string("Try again"), action: refresh) }
                    .font(.caption).padding(.horizontal, 28).padding(.bottom, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if conversation.before != nil {
                        Button(L10n.string("Load earlier messages"), action: loadOlder)
                            .buttonStyle(.borderless).disabled(conversation.isLoading)
                            .frame(maxWidth: .infinity)
                    }
                    if conversation.isLoading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    ForEach(conversation.visibleMessages) { message in
                        messageRow(message).id(message.id)
                    }
                    if conversation.loaded, conversation.visibleMessages.isEmpty {
                        Text(L10n.string("No messages yet")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, ParityTheme.conversationInset)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $conversation.anchor)
            if loadingAttachment { ProgressView().controlSize(.small).padding(8) }
            if let attachmentFailure {
                Text(attachmentFailure.message).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            PersonalAgentComposer(draft: conversation.draft, send: send)
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, ParityTheme.conversationInset).padding(.bottom, 16)
        }
        .background(ParityTheme.canvas)
        .sheet(item: $preview) { file in
            PersonalAgentAttachmentPreview(file: file) { preview = nil }
        }
    }

    private func messageRow(_ message: PersonalAgentMessage) -> some View {
        let own = message.author == .person
        return HStack(alignment: .top, spacing: 0) {
            if own { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(author(message.author)).font(.system(size: 11, weight: .medium))
                    if let time = message.createdAt { Text(time, style: .time).font(.system(size: 10)) }
                }
                .foregroundStyle(.secondary)
                if message.isDeleted {
                    Text(L10n.string("Message deleted")).foregroundStyle(.secondary).italic()
                } else {
                    TranscriptMarkdownText(text: message.text)
                        .font(ParityTheme.conversationFont(scale: scale))
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                        if attachment.type == "file", attachment.fileID != nil {
                            Button {
                                loadingAttachment = true
                                attachmentFailure = nil
                                Task {
                                    defer { loadingAttachment = false }
                                    do { preview = try PersonalAgentPreviewFile(download: await download(attachment)) }
                                    catch { attachmentFailure = error as? PersonalAgentFailure ?? .attachmentUnavailable }
                                }
                            } label: { Label(attachment.name, systemImage: "paperclip") }
                                .buttonStyle(.borderless).disabled(loadingAttachment)
                        } else {
                            Label(attachment.name, systemImage: "paperclip").foregroundStyle(.secondary)
                                .help(L10n.string("This attachment cannot be opened here yet."))
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(own ? 12 : 0)
            .frame(maxWidth: own ? 472 : .infinity, alignment: .leading)
            .background(own ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 10))
            if !own { Spacer(minLength: 16) }
        }
        .accessibilityElement(children: .contain)
    }

    private func author(_ value: PersonalAgentMessage.Author) -> String {
        switch value {
        case .person: L10n.string("You")
        case .agent: agent.name
        case let .other(name): name
        case .unknown: L10n.string("Unknown sender")
        }
    }
}

private struct PersonalAgentComposer: View {
    @Bindable var draft: PersonalAgentDraft
    let send: () -> Void
    @FocusState private var focused: Bool
    @State private var confirmsEditing = false
    @State private var confirmsRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.storageFailed {
                HStack {
                    Text(draft.needsRecovery
                         ? L10n.string("The saved draft could not be read. Keep it as a backup to start a new draft.")
                         : PersonalAgentFailure.draftStorage.message)
                    Spacer()
                    if draft.needsRecovery {
                        Button(L10n.string("Start a new draft")) { confirmsRecovery = true }
                    } else {
                        Button(L10n.string("Try again")) { draft.save() }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if let failure = draft.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.message).fixedSize(horizontal: false, vertical: true)
                    if draft.pending != nil, !draft.isSending {
                        HStack {
                            Button(L10n.string("Retry message"), action: submit)
                            Button(L10n.string("Edit message")) { confirmsEditing = true }
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ComposerEditor(draft: draft.editor, placeholder: L10n.string("Message your dot…"),
                accessibilityHint: L10n.string("Press Return to send"), metrics: .task(),
                input: nil, mentionRoots: [], commands: nil, isCommandMenuOpen: false, isMenuOpen: false,
                isFocused: $focused, onSubmit: submit) {
                    EmptyView()
                } chips: {
                    EmptyView()
                } footer: {
                    HStack {
                        Spacer()
                        if draft.isSending { ProgressView().controlSize(.small) }
                        if draft.pending == nil {
                            Button(action: submit) { Image(systemName: "arrow.up").frame(width: 20, height: 20) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.string("Send message"))
                                .disabled(draft.isSending || draft.storageFailed || draft.editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        else { Color.clear.frame(width: 20, height: 20) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
                // A pending result is resolved with the original request and text.
                .disabled(draft.isSending || draft.pending != nil)
        }
        .alert(L10n.string("Return to editing?"), isPresented: $confirmsEditing) {
            Button(L10n.string("Cancel"), role: .cancel) { }
            Button(L10n.string("Edit message")) { if draft.resumeEditing() { focused = true } }
        } message: {
            Text(L10n.string("The earlier message may already have arrived. Check the conversation before sending it again. Your text will stay here."))
        }
        .alert(L10n.string("Start a new draft?"), isPresented: $confirmsRecovery) {
            Button(L10n.string("Cancel"), role: .cancel) { }
            Button(L10n.string("Start a new draft")) { if draft.recoverStorage() { focused = true } }
        } message: {
            Text(L10n.string("The unreadable draft will be kept as a backup. The text currently in this editor will become the new draft."))
        }
    }

    private func submit() {
        guard !draft.isSending, !draft.storageFailed else { return }
        send()
    }
}
