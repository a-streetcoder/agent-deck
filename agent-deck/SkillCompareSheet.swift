import SwiftUI
import AppKit

/// Identifies two duplicate skill copies to compare side-by-side.
struct SkillCompareContext: Identifiable {
    let id = UUID()
    let left: SkillRecord
    let right: SkillRecord
}

/// Side-by-side comparison of two duplicate skill copies.
struct SkillCompareSheet: View {
    let context: SkillCompareContext
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Skills")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("Review both copies of \"\(context.left.name)\" before choosing which one to keep.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Divider()

            HStack(spacing: 0) {
                skillColumn(
                    title: context.left.filePath,
                    scope: skillLocationLabel(context.left, selectedProjectRoot: nil),
                    body: context.left.body
                )

                Divider()

                skillColumn(
                    title: context.right.filePath,
                    scope: skillLocationLabel(context.right, selectedProjectRoot: nil),
                    body: context.right.body
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 900, height: 560)
    }

    private func skillColumn(title: String, scope: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(scope)
                    .font(AppTheme.Font.micro.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(10)

            Divider()

            ScrollView(showsIndicators: false) {
                MarkdownDocumentView(source: body, minimumHeight: 200)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
