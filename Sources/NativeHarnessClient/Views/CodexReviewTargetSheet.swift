import SwiftUI

struct CodexReviewTargetSheet: View {
    let request: CodexReviewRequest
    let onCancel: () -> Void
    let onReview: (CodexReviewTarget) -> Void
    @State private var usesBranch = false
    @State private var branches: [String] = []
    @State private var branch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Review code changes")).font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                targetChoice(L10n.string("Uncommitted changes"), branch: false)
                targetChoice(L10n.string("Base branch"), branch: true)
            }
            if usesBranch {
                Picker(L10n.string("Base branch"), selection: $branch) {
                    ForEach(branches, id: \.self) { Text($0).tag($0) }
                }.disabled(branches.isEmpty)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: onCancel)
                Button(L10n.string("Review")) { onReview(usesBranch ? .baseBranch(branch) : .uncommittedChanges) }
                    .disabled(usesBranch && branch.isEmpty)
            }
        }.padding(20).frame(width: 420)
        .task {
            let service = GitDiffService()
            branches = (try? await service.branches(workspaceURL: request.session.workspaceURL)) ?? []
            if case let .found(base) = try? await service.baseBranch(workspaceURL: request.session.workspaceURL) {
                let candidate = base.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")
                branch = branches.first(where: { $0 == candidate }) ?? branches.first ?? ""
            } else { branch = branches.first ?? "" }
        }
    }

    private func targetChoice(_ title: String, branch: Bool) -> some View {
        Button { usesBranch = branch } label: {
            HStack {
                Text(title)
                Spacer()
                if usesBranch == branch { Image(systemName: "checkmark") }
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(usesBranch == branch ? ParityTheme.subtleFill : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
