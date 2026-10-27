import SwiftUI

/// What a chip's Options reads and does, bound to one suggestion in its task.
struct TaskSuggestionOptionsContext {
    /// What Start starts with now, read each time Options draws: the last choice made here, else
    /// the defaults.
    var choice: () -> TaskSuggestionStartChoice
    /// "As a subtask of ‘…’" when the agent named the task it nests under.
    var parentLabel: String?
    var projects: [Project]
    var harnesses: [HarnessDescriptor]
    var models: NewTaskModelSource?
    /// The accounts the new-task screen offers for a harness, and their check.
    var accounts: (HarnessKind) -> [AccountChoice] = { _ in [] }
    var checkAccounts: (HarnessKind) async -> Void = { _ in }
    var runtimeURL: (HarnessKind) -> URL?
    /// The options a task starts with on another harness: the parent's permission level in its words.
    var defaults: (HarnessKind) -> [String: String]
    /// The account a task starts on with another harness.
    var connection: (HarnessKind) -> ProviderConnection?
    var isRepository: (URL) -> Bool
    /// The agent asked for a worktree (`useWorktree`): a folder outside Git says it starts locally.
    var asksForWorktree = false
    /// A folder chosen from disk becomes a project, as the new-task screen's does.
    var chooseWorkspace: (URL) -> Project?
    /// Keeps a choice for the chip's Start and its quiet summary.
    var save: (TaskSuggestionStartChoice) -> Void
    var start: (TaskSuggestionStartChoice) -> Void
}

/// The chip's Options, as the Claude app's (3.1623.3: a popover from the row with Environment,
/// Worktree, Model and Effort, and Permissions): the harness, the account, where it starts, Local
/// or New worktree, the model, effort and permissions, each a one-level menu of the new-task
/// screen's own choices, then Start. A pick is saved as it is made, for the row's Start and its
/// summary, so nothing waits on the popover staying open, and no control here opens a popover of
/// its own. A harness chosen here starts from the parent's permission level in its words.
struct TaskSuggestionOptionsPopover: View {
    let context: TaskSuggestionOptionsContext
    let dismiss: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    /// A permission the provider asks about first, waiting for that answer.
    @State private var confirming: Confirming?

    private struct Confirming {
        let choice: TaskSuggestionStartChoice
        let confirmation: ComposerPermissionSlot.Confirmation
    }

    /// What the model lists are read for: the harness, the account and the folder.
    private struct ModelListKey: Equatable {
        var harness: HarnessKind
        var connectionID: String?
        var folder: URL?
    }

    var body: some View {
        let choice = context.choice()
        let options = TaskSuggestionStartOptions.sessionOptions(for: choice, catalogs: context.models?.catalogs)
        VStack(alignment: .leading, spacing: 10) {
            if let parentLabel = context.parentLabel {
                Text(parentLabel)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
            }
            row(L10n.string("Harness")) { harnessMenu(choice) }
            let accounts = context.accounts(choice.harness)
            if !accounts.isEmpty {
                row(L10n.string("Account")) { accountMenu(choice, accounts: accounts) }
            }
            row(L10n.string("taskSuggestion.where")) { placeMenu(choice) }
            runRow(choice)
            if let model = options.model {
                ForEach([model.menu.model, model.menu.effort, model.menu.speed].compactMap { $0 }) { selector in
                    row(selector.name) {
                        selectorMenu(selector, isEnabled: model.menu.canChoose) { value in
                            guard let picked = model.apply.choice(id: selector.id, value: value) else { return }
                            pick(picked, in: choice)
                        }
                    }
                }
            }
            if let permission = options.permission {
                row(L10n.string("Permissions")) { permissionMenu(permission, in: choice) }
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("Start")) {
                    context.start(context.choice())
                    dismiss()
                }
                .parityProminentButton()
                .controlSize(.small)
                .parityPointer()
                .disabled(context.runtimeURL(choice.harness) == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13 * interfaceScale))
        .padding(14)
        .frame(width: 400)
        // Opening Options is opening the model menu: a list not read yet is read now, as the
        // new-task screen's menu reads it when it opens.
        .task(id: ModelListKey(harness: choice.harness, connectionID: choice.connection?.id, folder: choice.place.folder)) {
            guard let model = options.model, !model.menu.canChoose || model.menu.isEmpty,
                  let models = context.models, let runtime = context.runtimeURL(choice.harness) else { return }
            await models.load(choice.harness, runtime, choice.connection, choice.place.folder)
        }
        .task(id: choice.harness) { await context.checkAccounts(choice.harness) }
        .alert(confirming?.confirmation.title ?? "", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { request in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(request.confirmation.confirm, role: .destructive) { context.save(request.choice) }
        } message: { request in
            Text(request.confirmation.message)
        }
    }

    private func row<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 6) { control() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28 * interfaceScale)
    }

    @ViewBuilder
    private func item(_ title: String, isChosen: Bool) -> some View {
        if isChosen {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func harnessMenu(_ choice: TaskSuggestionStartChoice) -> some View {
        Menu {
            ForEach(context.harnesses) { descriptor in
                Button {
                    guard let next = TaskSuggestionStartOptions.choosing(
                        harness: descriptor.id, in: choice, options: context.defaults(descriptor.id),
                        connection: context.connection(descriptor.id)) else { return }
                    context.save(next)
                } label: {
                    HarnessIdentityLabel(harness: descriptor.id)
                }
            }
        } label: {
            HarnessIdentityLabel(harness: choice.harness)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Harness"))
        .accessibilityValue(choice.harness.displayName)
    }

    private func accountMenu(_ choice: TaskSuggestionStartChoice, accounts: [AccountChoice]) -> some View {
        let current = accounts.first { $0.connection?.id == choice.connection?.id }
        let title = current?.composerTitle ?? choice.connection?.name ?? L10n.string("Account unavailable")
        return Menu {
            ForEach(accounts) { account in
                Button {
                    var next = choice
                    next.connection = account.connection
                    context.save(next)
                } label: {
                    item(account.composerTitle, isChosen: account.id == current?.id)
                }
                .disabled(!account.canSelect)
            }
        } label: {
            ParityComposerControl(title: title, systemName: "person.crop.circle", showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Account"))
        .accessibilityValue(title)
    }

    private func placeMenu(_ choice: TaskSuggestionStartChoice) -> some View {
        let folder = choice.place.folder
        let current = choice.place.project
            ?? folder.flatMap { ProjectProjection.project(containingRoot: $0, in: context.projects) }
        let name = current?.name ?? folder?.lastPathComponent ?? L10n.string("Chat (no project)")
        return Menu {
            Button(L10n.string("Choose project…")) {
                guard let chosen = NewTaskDestination.askForFolder() else { return }
                let project = context.chooseWorkspace(chosen)
                context.save(context.choice().moving(to: chosen, project: project, isRepository: context.isRepository))
            }
            Button {
                context.save(choice.moving(to: nil, project: nil, isRepository: context.isRepository))
            } label: {
                item(L10n.string("Chat (no project)"), isChosen: folder == nil)
            }
            if !context.projects.isEmpty {
                Divider()
                ForEach(context.projects) { project in
                    Button {
                        context.save(choice.moving(to: project.primaryRoot, project: project, isRepository: context.isRepository))
                    } label: {
                        item(project.name, isChosen: folder != nil && project.id == current?.id)
                    }
                }
            }
        } label: {
            ParityComposerControl(title: name, systemName: folder == nil ? "bubble.left" : "folder", showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("taskSuggestion.where"))
        .accessibilityValue(name)
    }

    /// Local or New worktree, as the new-task screen's control, for a folder in Git. A folder
    /// outside Git has no control there; here it says Local only when the agent asked for a worktree.
    @ViewBuilder
    private func runRow(_ choice: TaskSuggestionStartChoice) -> some View {
        if let folder = choice.place.folder {
            if context.isRepository(folder) {
                let inWorktree = choice.place.startsInNewWorktree
                let title = L10n.string(inWorktree ? "New worktree" : "Local")
                row(L10n.string("Where to run")) {
                    Menu {
                        Button {
                            context.save(choice.startingInNewWorktree(false, isRepository: context.isRepository))
                        } label: {
                            item(L10n.string("Work locally"), isChosen: !inWorktree)
                        }
                        Button {
                            context.save(choice.startingInNewWorktree(true, isRepository: context.isRepository))
                        } label: {
                            item(L10n.string("New worktree"), isChosen: inWorktree)
                        }
                    } label: {
                        ParityComposerControl(title: title, systemName: inWorktree ? "arrow.triangle.branch" : "laptopcomputer",
                                              showsChevron: true)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .parityPointer()
                    .accessibilityLabel(L10n.string("Where to run"))
                    .accessibilityValue(title)
                }
            } else if context.asksForWorktree {
                let reason = L10n.string("The folder isn't in a Git repository, so it can't have a worktree.")
                row(L10n.string("Where to run")) {
                    ParityComposerControl(title: L10n.string("Local"), systemName: "laptopcomputer", isInteractive: false)
                        .fixedSize()
                        .help(reason)
                        .accessibilityHint(reason)
                }
            }
        }
    }

    /// One of the model menu's lists (model, effort, speed) as a menu of its own.
    private func selectorMenu(_ selector: ProviderCapabilitySelector, isEnabled: Bool,
                              onPick: @escaping (String) -> Void) -> some View {
        let title = ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
        return Menu {
            ForEach(selector.choices) { choice in
                Button { onPick(choice.value) } label: {
                    item(choice.name, isChosen: choice.value == selector.currentValue)
                }
            }
        } label: {
            // The menu draws its own chevron; one in the label would be taken for its symbol.
            ParityComposerControl(title: title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .disabled(!isEnabled)
        .accessibilityLabel(selector.name)
        .accessibilityValue(title)
    }

    private func permissionMenu(_ slot: ComposerPermissionSlot, in choice: TaskSuggestionStartChoice) -> some View {
        Menu {
            if let selector = slot.selector {
                ForEach(selector.choices) { option in
                    Button {
                        guard option.value != selector.currentValue,
                              let picked = slot.apply.choice(id: selector.id, value: option.value),
                              let next = TaskSuggestionStartOptions.choosing(picked, in: choice,
                                                                             catalogs: context.models?.catalogs) else { return }
                        if let confirmation = slot.confirmations[option.value] {
                            confirming = Confirming(choice: next, confirmation: confirmation)
                        } else {
                            context.save(next)
                        }
                    } label: {
                        item(option.name, isChosen: option.value == selector.currentValue)
                    }
                }
            }
        } label: {
            ParityComposerControl(title: slot.title, systemName: "checkmark.shield", showsChevron: true,
                                  tint: slot.isElevated ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .disabled(!slot.canChoose || !slot.showsChoices)
        .accessibilityLabel(L10n.string("Permissions"))
        .accessibilityValue(slot.title)
    }

    private func pick(_ picked: ComposerSessionChoice, in choice: TaskSuggestionStartChoice) {
        guard let next = TaskSuggestionStartOptions.choosing(picked, in: choice, catalogs: context.models?.catalogs) else { return }
        context.save(next)
    }
}
