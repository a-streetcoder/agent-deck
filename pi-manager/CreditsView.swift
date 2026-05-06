import AppKit
import SwiftUI

struct CreditsScreen: View {
    var body: some View {
        AppPage("Credits", subtitle: "Open source, services, and project acknowledgements") {
            AppCard(title: "App") {
                VStack(alignment: .leading, spacing: 10) {
                    creditRow(
                        title: "Pi Manager icon",
                        detail: "Custom macOS 26 Liquid Glass app icon created with Icon Composer.",
                        url: nil
                    )
                }
            }

            AppCard(title: "Open Source") {
                VStack(alignment: .leading, spacing: 10) {
                    creditRow(
                        title: "TourKit",
                        detail: "SwiftUI onboarding slideshow package by Ram Patra. MIT License.",
                        url: "https://github.com/rampatra/TourKit"
                    )
                    Divider()
                    creditRow(
                        title: "marked.js",
                        detail: "Markdown parser used by the embedded Markdown renderer. MIT License.",
                        url: "https://github.com/markedjs/marked"
                    )
                }
            }

            AppCard(title: "Services") {
                VStack(alignment: .leading, spacing: 10) {
                    creditRow(
                        title: "GitHub",
                        detail: "GitHub CLI and GitHub APIs power optional issue, comment, commit, and push workflows.",
                        url: "https://github.com"
                    )
                }
            }
        }
    }

    private func creditRow(title: String, detail: String, url: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(detail)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if let url {
                Button {
                    if let resolvedURL = URL(string: url) {
                        NSWorkspace.shared.open(resolvedURL)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(url)
            }
        }
    }
}
