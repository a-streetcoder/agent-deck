import AppKit
import SwiftUI

struct CreditsScreen: View {
    var body: some View {
        AppPage("Credits", subtitle: "Open source, services, and project acknowledgements") {
            AppCard(title: "App") {
                VStack(alignment: .leading, spacing: 10) {
                    creditRow(
                        title: "\(AppBrand.displayName) icon",
                        detail: "Custom macOS 26 Liquid Glass app icon created with Icon Composer.",
                        url: nil
                    )
                    Divider()
                    creditRow(
                        title: "Kemco Pixel Bold",
                        detail: "Font created and edited by Jayvee D. Enaguas (Grand Chaos). Licensed under Creative Commons CC-BY-NC-SA 3.0. © GrandChaos9000. Some Rights Reserved.",
                        url: "https://www.dafont.com/kemco-pixel.font"
                    )
                }
            }

            AppCard(title: "Open Source") {
                VStack(alignment: .leading, spacing: 10) {
                    creditRow(
                        title: "pi coding agent",
                        detail: "Agent Deck is powered by pi, the terminal coding agent by Earendil Works.",
                        url: "https://pi.dev"
                    )
                    Divider()
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
                    Divider()
                    creditRow(
                        title: "opencode webfetch",
                        detail: "Agent Deck's enhanced web_fetch fallback adapts HTML extraction and conversion behavior from opencode's MIT-licensed webfetch tool.",
                        url: "https://github.com/anomalyco/opencode"
                    )
                    Divider()
                    creditRow(
                        title: "pi-subagents and pi-intercom",
                        detail: "Agent Deck's native subagent design was logically inspired by Nico Bailon's MIT-licensed Pi ecosystem packages. Agent Deck does not bundle or depend on those packages for native subagent execution.",
                        url: "https://github.com/nicobailon/pi-subagents"
                    )
                    Divider()
                    creditRow(
                        title: "htmlparser2 and Turndown",
                        detail: "Optional enhanced web_fetch dependencies installed from npm. htmlparser2 and Turndown are MIT licensed; their current transitive parser dependencies are BSD-2-Clause.",
                        url: "https://www.npmjs.com/package/htmlparser2"
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
