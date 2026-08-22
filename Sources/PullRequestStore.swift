import Foundation

/// Holds cached PRs for each list and keeps them fresh on a timer.
///
/// Both lists are fetched up front and cached, so switching tabs is instant and
/// never triggers a network call. A background timer refreshes every 10 minutes.
@MainActor
final class PullRequestStore: ObservableObject {
    private static let refreshInterval: TimeInterval = 600  // 10 minutes

    @Published private(set) var cache: [PRList: [PullRequest]] = [:]
    @Published private(set) var mergeStatus: [String: String] = [:]  // PR url -> mergeStateStatus
    @Published private(set) var reviewedURLs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var hasStarted = false

    func pullRequests(for list: PRList) -> [PullRequest] {
        cache[list] ?? []
    }

    /// Starts the initial fetch and the periodic refresh. Safe to call repeatedly.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { await self.refresh() }
        }
    }

    /// Refreshes every list. Keeps existing cache on failure.
    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            for list in PRList.allCases {
                cache[list] = try await GitHub.pullRequests(list)
            }
            reviewedURLs = try await GitHub.reviewedURLs()
            mergeStatus = await mergeStatuses(for: cache[.mine] ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Fetches each PR's merge status concurrently. Failures are simply omitted.
    private func mergeStatuses(for prs: [PullRequest]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for pr in prs {
                group.addTask { (pr.url, try? await GitHub.mergeStatus(pr.url)) }
            }
            var result: [String: String] = [:]
            for await (url, status) in group where status != nil {
                result[url] = status
            }
            return result
        }
    }
}
