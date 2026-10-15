import Foundation

/// A single open pull request, decoded from `gh search prs --json ...`.
struct PullRequest: Decodable, Identifiable {
    let number: Int
    let title: String
    let url: String
    let repository: Repository
    let updatedAt: String

    var id: String { url }

    struct Repository: Decodable {
        let nameWithOwner: String
    }
}

/// A top-level section in the menu bar panel. Selecting one reveals its sub-tabs.
enum AppSection: String, CaseIterable, Identifiable {
    case git = "Git"
    case work = "Work"
    case agents = "Agents"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .git:  return "arrow.triangle.pull"
        case .work: return "folder"
        case .agents: return "sparkles"
        }
    }
}

/// The two things this app shows: PRs I opened, and PRs waiting on my review.
enum PRList: String, CaseIterable, Identifiable {
    case mine = "Mine"
    case review = "To Review"

    var id: String { rawValue }

    /// The `gh search prs` filter that selects this list.
    var filter: String {
        switch self {
        case .mine:   return "--author=@me"
        case .review: return "--review-requested=@me"
        }
    }
}
