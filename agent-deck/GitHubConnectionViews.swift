import AppKit
import SwiftUI

struct GitHubConnectionCard: View {
    var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            GitHubAvatarView(url: avatarURL, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(AppTheme.contentFill, lineWidth: 2))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(accountName)
                    .font(.headline)
                    .fontWidth(.expanded)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedText)
            }

            Spacer()

            VStack(alignment: .center, spacing: 4) {
                Button {
                    viewModel.refreshEverything()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .accessibilityLabel("Refresh GitHub and projects")
                .disabled(viewModel.githubIsRefreshingEverything)

                if let lastCheckedAt = viewModel.githubLastStatusCheckAt {
                    Text(timeFormatter.string(from: lastCheckedAt))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private var accountName: String {
        viewModel.currentGitHubAccount?.login ?? "GitHub"
    }

    private var statusText: String {
        if viewModel.githubIsRefreshingEverything {
            return "Refreshing…"
        }

        switch viewModel.githubConnectionState {
        case .connected:
            return "Connected"
        case .checking:
            return "Connecting…"
        case .failed:
            return "Error"
        case .available:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .disconnected:
            return "Inactive"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var timeFormatter: DateFormatter { Self.timeFormatter }

    private var statusColor: Color {
        switch viewModel.githubConnectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var avatarURL: URL? {
        guard let account = viewModel.currentGitHubAccount else { return nil }
        return GitHubAvatarResolver.url(login: account.login, host: account.host)
    }
}

struct GitHubAvatarView: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(AppTheme.contentSubtleFill)
                    .overlay {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(AppTheme.mutedText)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Decoded NSImages are cached per URL by GitHubAvatarCache, so
        // scrolling a long issue list doesn't re-decode the same PNG on
        // every cell appear. SwiftUI's AsyncImage only caches at the
        // HTTP layer and rebuilds the decoded image per appear.
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }
        let loaded = await GitHubAvatarCache.shared.image(for: url)
        guard url == self.url else { return }
        image = loaded
    }
}

/// Process-wide cache for decoded GitHub avatar NSImages. Each entry is
/// usually <10 KB so 500 cached images is <5 MB; `NSCache` evicts under
/// memory pressure automatically.
actor GitHubAvatarCache {
    static let shared = GitHubAvatarCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

enum GitHubAvatarResolver {
    static func url(login: String, host: String?) -> URL? {
        let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        // `?size=` asks GitHub to resize server-side — crisp at our small avatar
        // sizes and far lighter than the full ~460px source.
        if let normalizedHost, !normalizedHost.isEmpty, normalizedHost.caseInsensitiveCompare("github.com") != .orderedSame {
            return URL(string: "https://\(normalizedHost)/\(login).png?size=160")
        }
        return URL(string: "https://github.com/\(login).png?size=160")
    }
}


struct GitHubConnectionDetails: View {
    var viewModel: AppViewModel

    var body: some View {
        AppCard(title: "GitHub CLI Session") {
            VStack(alignment: .leading, spacing: 12) {
                Text("agent-deck currently reuses the existing `gh` authentication session.")

                switch viewModel.githubConnectionState {
                case let .available(account), let .connected(account):
                    AppKeyValueList(rows: [
                        ("Login", account.login),
                        ("Host", account.host),
                        ("Git Protocol", account.gitProtocol ?? "—"),
                        ("Token Source", account.tokenSource ?? "—"),
                        ("Scopes", account.scopes.isEmpty ? "—" : account.scopes.joined(separator: ", "))
                    ])
                case .unavailable:
                    Text("Install GitHub CLI and run `gh auth login`, then reconnect here.")
                        .foregroundStyle(AppTheme.mutedText)
                default:
                    Text("After connecting, this screen will show the active GitHub CLI account and scopes.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
