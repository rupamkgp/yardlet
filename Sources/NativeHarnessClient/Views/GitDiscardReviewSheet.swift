import SwiftUI

struct GitDiscardReviewSheet: View {
    let request: GitDiscardRequest
    let onCancel: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Discard changes")).font(.title3.weight(.semibold))
            Text(request.workspaceURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.snapshot.files) { file in Text(file.path).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            Text(L10n.string("Unstaged changes and new files in this list will be discarded."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: onCancel)
                Button(L10n.string("Discard changes"), role: .destructive, action: onDiscard)
            }
        }.padding(20).frame(width: 440)
    }
}
