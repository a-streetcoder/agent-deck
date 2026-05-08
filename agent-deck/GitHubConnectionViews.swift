import AppKit
import SwiftUI

struct GitHubConnectionCard: View {
    @ObservedObject var viewModel: AppViewModel

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

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

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

    var body: some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(AppTheme.contentSubtleFill)
                .overlay {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

enum GitHubAvatarResolver {
    static func url(login: String, host: String?) -> URL? {
        let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedHost, !normalizedHost.isEmpty, normalizedHost.caseInsensitiveCompare("github.com") != .orderedSame {
            return URL(string: "https://\(normalizedHost)/\(login).png")
        }
        return URL(string: "https://github.com/\(login).png")
    }
}


struct GitHubConnectionDetails: View {
    @ObservedObject var viewModel: AppViewModel

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
