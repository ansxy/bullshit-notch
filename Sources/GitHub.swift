import Foundation

/// Talks to GitHub by shelling out to the `gh` CLI.
///
/// ponytail: reusing the user's existing `gh` auth avoids building OAuth and
/// token storage entirely. `gh` runs in a login shell so it inherits PATH.
enum GitHub {
    private static let maxResults = 50

    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func pullRequests(_ list: PRList) async throws -> [PullRequest] {
        let json = try runGH(
            "search prs \(list.filter) --state=open --sort=updated " +
            "--json number,title,url,repository,updatedAt --limit \(maxResults)"
        )
        return try JSONDecoder().decode([PullRequest].self, from: json)
    }

    /// GitHub's merge-readiness for a PR, e.g. CLEAN, BLOCKED, DIRTY, DRAFT, UNSTABLE.
    static func mergeStatus(_ url: String) async throws -> String {
        struct R: Decodable { let mergeStateStatus: String }
        let json = try runGH("pr view \(url) --json mergeStateStatus")
        return try JSONDecoder().decode(R.self, from: json).mergeStateStatus
    }

    /// URLs of open PRs the current user has already reviewed.
    static func reviewedURLs() async throws -> Set<String> {
        struct Item: Decodable { let url: String }
        let json = try runGH("search prs --reviewed-by=@me --state=open --json url --limit \(maxResults)")
        return Set(try JSONDecoder().decode([Item].self, from: json).map(\.url))
    }

    private static func runGH(_ arguments: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "gh \(arguments)"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw Error(message: "gh failed — is it installed and authenticated?")
        }
        return data
    }
}
