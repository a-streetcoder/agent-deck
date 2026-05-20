import AppKit
import SwiftUI

/// Identifier for the custom About window scene (declared in `agent_deckApp`).
enum AboutWindow {
    static let id = "about-agent-deck"
}

/// Open-source, font, asset, and service acknowledgements.
///
/// Shown in Agent Deck's custom About window (`AboutView`), opened from
/// App menu ▸ About Agent Deck. Only things the app actually ships or
/// adapted code from are listed — not loose inspirations.
enum AppCredits {
    struct Entry: Identifiable {
        let title: String
        let detail: String
        var url: String?

        var id: String { title }

        var resolvedURL: URL? {
            guard let url else { return nil }
            return URL(string: url)
        }

        /// The link text without its scheme, e.g. `github.com/markedjs/marked`.
        var displayURL: String? {
            url?
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
        }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    /// A person credited in the About window, rendered with their live
    /// GitHub avatar and a link to their profile.
    struct Author: Identifiable {
        let login: String
        let role: String

        var id: String { login }

        /// GitHub serves a user's avatar at `github.com/<login>.png`.
        var avatarURL: URL? {
            URL(string: "https://github.com/\(login).png?size=144")
        }

        var profileURL: URL? {
            URL(string: "https://github.com/\(login)")
        }
    }

    static let authors: [Author] = [
        Author(login: "acorvi", role: "Creator"),
        Author(login: "almoretti", role: "Contributor")
    ]

    static let sections: [Section] = [
        Section(title: "Assets & Fonts", entries: [
            Entry(
                title: "GitLab SVGs",
                detail: "Toolbar icons sourced from the GitLab SVGs icon collection by GitLab B.V. MIT License. Copyright © 2011–2017 GitLab B.V.",
                url: "https://gitlab.com/gitlab-org/gitlab-svgs"
            ),
            Entry(
                title: "Kemco Pixel Bold",
                detail: "Font created and edited by Jayvee D. Enaguas (Grand Chaos). Licensed under Creative Commons CC-BY-NC-SA 3.0. © GrandChaos9000.",
                url: "https://www.dafont.com/kemco-pixel.font"
            )
        ]),
        Section(title: "Open Source", entries: [
            Entry(
                title: "pi coding agent",
                detail: "Agent Deck is powered by pi, the terminal coding agent by Earendil Works.",
                url: "https://pi.dev"
            ),
            Entry(
                title: "TourKit",
                detail: "SwiftUI onboarding slideshow package by Ram Patra. MIT License.",
                url: "https://github.com/rampatra/TourKit"
            ),
            Entry(
                title: "marked.js",
                detail: "Markdown parser used by the embedded Markdown renderer. MIT License.",
                url: "https://github.com/markedjs/marked"
            ),
            Entry(
                title: "opencode webfetch",
                detail: "The enhanced web_fetch fallback adapts HTML extraction and conversion behavior from opencode's MIT-licensed webfetch tool.",
                url: "https://github.com/anomalyco/opencode"
            ),
            Entry(
                title: "htmlparser2 and Turndown",
                detail: "Optional enhanced web_fetch dependencies installed from npm. Both are MIT licensed; their transitive parser dependencies are BSD-2-Clause.",
                url: "https://www.npmjs.com/package/htmlparser2"
            )
        ]),
        Section(title: "Services", entries: [
            Entry(
                title: "GitHub",
                detail: "GitHub CLI and GitHub APIs power optional issue, comment, commit, and push workflows.",
                url: "https://github.com"
            )
        ])
    ]
}

/// Custom About window — replaces the fixed-size system about panel so the
/// credits have room to breathe and can be styled to match the app.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            creditsList
        }
        .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity,
               minHeight: 440, idealHeight: 560, maxHeight: .infinity)
        .background(AppTheme.windowBackground)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(AppBrand.displayName)
                    .font(.title2.weight(.semibold))
                    .fontWidth(.expanded)
                Text("Version \(AppBrand.marketingVersion)")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 22)
    }

    private var creditsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                authorsSection
                ForEach(AppCredits.sections) { section in
                    sectionView(section)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
        }
    }

    private var authorsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CREATED BY")
                .font(.caption.weight(.semibold))
                .fontWidth(.expanded)
                .kerning(0.7)
                .foregroundStyle(AppTheme.mutedText)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(AppCredits.authors) { author in
                    authorRow(author)
                }
            }
        }
    }

    private func authorRow(_ author: AppCredits.Author) -> some View {
        HStack(spacing: 12) {
            authorAvatar(author)

            VStack(alignment: .leading, spacing: 2) {
                Text(author.login)
                    .font(.callout.weight(.semibold))
                    .fontWidth(.expanded)
                Text(author.role)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }

            Spacer(minLength: 8)

            if let profileURL = author.profileURL {
                Link(destination: profileURL) {
                    HStack(spacing: 3) {
                        Text("github.com/\(author.login)")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.brandAccent)
                .help(profileURL.absoluteString)
            }
        }
    }

    private func authorAvatar(_ author: AppCredits.Author) -> some View {
        AsyncImage(url: author.avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "person.fill")
                    .foregroundStyle(AppTheme.mutedText)
            case .empty:
                ProgressView()
            @unknown default:
                Color.clear
            }
        }
        .frame(width: 32, height: 32)
        .background(AppTheme.contentFill)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(AppTheme.hairlineStroke, lineWidth: 1))
        .accessibilityLabel("\(author.login) on GitHub")
    }

    private func sectionView(_ section: AppCredits.Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title.uppercased())
                .font(.caption.weight(.semibold))
                .fontWidth(.expanded)
                .kerning(0.7)
                .foregroundStyle(AppTheme.mutedText)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(section.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: AppCredits.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title)
                    .font(.callout.weight(.semibold))
                    .fontWidth(.expanded)

                Spacer(minLength: 8)

                if let url = entry.resolvedURL, let display = entry.displayURL {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Text(display)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.brandAccent)
                    .help(url.absoluteString)
                }
            }

            Text(entry.detail)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
