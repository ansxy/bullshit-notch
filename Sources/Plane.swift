import AppKit
import Foundation
import SwiftUI

// MARK: - Plane.so Data Models (Self-Hosted & Cloud API v1)

enum PlanePriority: String, CaseIterable, Identifiable, Codable {
    case urgent = "urgent"
    case high = "high"
    case medium = "medium"
    case low = "low"
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .urgent: return "Urgent"
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Low"
        case .none:   return "None"
        }
    }

    var icon: String {
        switch self {
        case .urgent: return "exclamationmark.triangle.fill"
        case .high:   return "chevron.up.2"
        case .medium: return "equal"
        case .low:    return "chevron.down"
        case .none:   return "minus"
        }
    }

    var color: Color {
        switch self {
        case .urgent: return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .high:   return Color(red: 1.0, green: 0.62, blue: 0.22)
        case .medium: return Color(red: 0.96, green: 0.80, blue: 0.28)
        case .low:    return Color(red: 0.38, green: 0.78, blue: 1.0)
        case .none:   return Color.white.opacity(0.42)
        }
    }

    var sortRank: Int {
        switch self {
        case .urgent: return 0
        case .high:   return 1
        case .medium: return 2
        case .low:    return 3
        case .none:   return 4
        }
    }
}

enum PlaneStateGroup: String, CaseIterable, Identifiable, Codable {
    case started = "started"
    case unstarted = "unstarted"
    case backlog = "backlog"
    case completed = "completed"
    case cancelled = "cancelled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .started:   return "In Progress"
        case .unstarted: return "Todo"
        case .backlog:   return "Backlog"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .started:   return "circle.lefthalf.filled"
        case .unstarted: return "circle"
        case .backlog:   return "circle.dashed"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .started:   return Color(red: 0.98, green: 0.68, blue: 0.22)
        case .unstarted: return Color(red: 0.35, green: 0.80, blue: 1.0)
        case .backlog:   return Color.white.opacity(0.48)
        case .completed: return Color(red: 0.30, green: 0.88, blue: 0.54)
        case .cancelled: return Color(red: 0.95, green: 0.42, blue: 0.42).opacity(0.75)
        }
    }

    var sortOrder: Int {
        switch self {
        case .started:   return 0
        case .unstarted: return 1
        case .backlog:   return 2
        case .completed: return 3
        case .cancelled: return 4
        }
    }
}

struct PlaneProject: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let identifier: String
    let description: String?
}

struct PlaneStateItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let group: PlaneStateGroup
    let colorHex: String
    let projectId: String
    let sequence: Double
}

struct PlaneCycleItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let projectId: String
    let status: String
    let startDate: String?
    let endDate: String?
    let isActive: Bool
}

struct PlaneMember: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let email: String?
}

struct PlaneWorkFolder: Identifiable, Hashable {
    var id: String { expandedPath }
    let name: String
    let expandedPath: String
    let displayPath: String
    let agentCommand: String?
}

enum PlaneFolderScope: String, CaseIterable, Identifiable {
    case ticket = "This Ticket"
    case project = "Project"

    var id: String { rawValue }
}

struct PlaneAssignedFolder: Equatable {
    let expandedPath: String
    let name: String
    let displayPath: String
    let isTicketSpecific: Bool
    let isExplicit: Bool
}

struct PlaneIssue: Identifiable, Equatable, Hashable {
    let id: String
    let sequenceId: Int
    let projectId: String
    let projectIdentifier: String
    let projectName: String
    var name: String
    var descriptionText: String
    var priority: PlanePriority
    var stateId: String
    var stateName: String
    var stateGroup: PlaneStateGroup
    var stateColorHex: String
    var assigneeIds: [String]
    var isAssignedToMe: Bool
    var cycleIds: Set<String>
    var cycleName: String?
    var inActiveCycle: Bool
    var targetDate: String?
    var updatedAt: String?

    var issueKey: String {
        "\(projectIdentifier)-\(sequenceId)"
    }

    var suggestedBranchName: String {
        let slugTitle = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let trimmed = String(slugTitle.prefix(38)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let keyLower = issueKey.lowercased()
        return trimmed.isEmpty ? "feat/\(keyLower)" : "feat/\(keyLower)-\(trimmed)"
    }

    static func == (lhs: PlaneIssue, rhs: PlaneIssue) -> Bool {
        lhs.id == rhs.id &&
        lhs.stateId == rhs.stateId &&
        lhs.priority == rhs.priority &&
        lhs.name == rhs.name &&
        lhs.isAssignedToMe == rhs.isAssignedToMe &&
        lhs.inActiveCycle == rhs.inActiveCycle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(stateId)
        hasher.combine(priority)
        hasher.combine(isAssignedToMe)
        hasher.combine(inActiveCycle)
    }
}

// MARK: - Plane.so Self-Hosted Store

@MainActor
final class PlaneStore: ObservableObject {
    static let shared = PlaneStore()

    enum StateFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case started = "In Progress"
        case todo = "Todo"
        case done = "Done"
        case all = "All"

        var id: String { rawValue }
    }

    @Published private(set) var projects: [PlaneProject] = []
    @Published private(set) var statesByProject: [String: [PlaneStateItem]] = [:]
    @Published private(set) var cyclesByProject: [String: [PlaneCycleItem]] = [:]
    @Published private(set) var members: [PlaneMember] = []
    @Published private(set) var issues: [PlaneIssue] = [] {
        didSet { recomputeFiltered() }
    }
    @Published private(set) var filteredIssues: [PlaneIssue] = []
    @Published private(set) var inProgressCount: Int = 0
    @Published private(set) var todoCount: Int = 0

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusToast: String?
    @Published var currentUserId: String? = UserDefaults.standard.string(forKey: "planeCurrentUserID") {
        didSet {
            if let currentUserId {
                UserDefaults.standard.set(currentUserId, forKey: "planeCurrentUserID")
            }
            recomputeFiltered()
        }
    }
    @Published private(set) var currentUserDisplayName: String?

    /// Primary quick filters requested by user: Active Cycle & Assigned to Me
    @Published var onlyActiveCycle: Bool = UserDefaults.standard.object(forKey: "planeOnlyActiveCycle") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(onlyActiveCycle, forKey: "planeOnlyActiveCycle")
            recomputeFiltered()
        }
    }
    @Published var onlyAssignedToMe: Bool = UserDefaults.standard.object(forKey: "planeOnlyAssignedToMe") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(onlyAssignedToMe, forKey: "planeOnlyAssignedToMe")
            recomputeFiltered()
        }
    }
    @Published var selectedCycleId: String = "" {
        didSet { recomputeFiltered() }
    }
    @Published var stateFilter: StateFilter = .active {
        didSet { recomputeFiltered() }
    }
    @Published var searchText: String = "" {
        didSet { recomputeFiltered() }
    }
    @Published var selectedProjectId: String = UserDefaults.standard.string(forKey: Pref.planeSelectedProjectID) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedProjectId, forKey: Pref.planeSelectedProjectID)
            recomputeFiltered()
        }
    }

    /// Per-Ticket and Per-Project local folder mappings (persisted in UserDefaults)
    @Published private(set) var ticketFolders: [String: String] = [:] {
        didSet { saveFolderMaps() }
    }
    @Published private(set) var projectFolders: [String: String] = [:] {
        didSet { saveFolderMaps() }
    }
    @Published private(set) var ticketAgents: [String: String] = [:] {
        didSet { saveFolderMaps() }
    }
    @Published private(set) var availableFolders: [PlaneWorkFolder] = []

    private let ticketFoldersKey = "planeTicketFolderMap"
    private let projectFoldersKey = "planeProjectFolderMap"
    private let ticketAgentsKey = "planeTicketAgentMap"
    private var toastTask: Task<Void, Never>?
    private var isDemo = false

    private init() {
        loadFolderMaps()
        refreshAvailableFolders()
        if CommandLine.arguments.contains("--demo") {
            loadDemoData()
            return
        }
    }

    var isConfigured: Bool {
        if isDemo { return true }
        let url = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        let key = apiKey
        return !url.isEmpty && !slug.isEmpty && !key.isEmpty
    }

    var normalizedBaseURL: String {
        let raw = (UserDefaults.standard.string(forKey: Pref.planeBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        var cleaned = raw
        if !cleaned.lowercased().hasPrefix("http://") && !cleaned.lowercased().hasPrefix("https://") {
            cleaned = "https://\(cleaned)"
        }
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        if cleaned.lowercased().hasSuffix("/api/v1") {
            cleaned = String(cleaned.dropLast("/api/v1".count))
        }
        if let components = URLComponents(string: cleaned),
           let scheme = components.scheme,
           let host = components.host {
            var base = "\(scheme)://\(host)"
            if let port = components.port {
                base += ":\(port)"
            }
            return base
        }
        return cleaned
    }

    var normalizedWorkspaceSlug: String {
        let raw = (UserDefaults.standard.string(forKey: Pref.planeWorkspaceSlug) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !raw.isEmpty {
            return raw.split(separator: "/").first.map(String.init) ?? raw
        }
        let rawURL = (UserDefaults.standard.string(forKey: Pref.planeBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: rawURL) {
            let parts = comps.path.split(separator: "/").map(String.init)
            if let first = parts.first, first != "api" && first != "spaces" && !first.isEmpty {
                return first
            }
        }
        return ""
    }

    private var apiKey: String {
        var raw = (UserDefaults.standard.string(forKey: Pref.planeApiKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("x-api-key:") {
            raw = String(raw.dropFirst("x-api-key:".count)).trimmingCharacters(in: .whitespaces)
        } else if raw.lowercased().hasPrefix("bearer ") {
            raw = String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: - Demo Mode

    func loadDemoData() {
        isDemo = true
        currentUserId = "demo-user-1"
        currentUserDisplayName = "Ansar"
        let p1 = PlaneProject(id: "proj-1", name: "BullshitNotch", identifier: "NOTCH", description: "Native macOS Notch Studio")
        let p2 = PlaneProject(id: "proj-2", name: "Hyperdrive API", identifier: "API", description: "Core Rust & Python backend")
        projects = [p1, p2]

        let s1 = PlaneStateItem(id: "st-1", name: "In Progress", group: .started, colorHex: "#f59e0b", projectId: "proj-1", sequence: 1)
        let s2 = PlaneStateItem(id: "st-2", name: "Todo", group: .unstarted, colorHex: "#38bdf8", projectId: "proj-1", sequence: 2)
        let s3 = PlaneStateItem(id: "st-3", name: "Done", group: .completed, colorHex: "#22c55e", projectId: "proj-1", sequence: 3)
        statesByProject["proj-1"] = [s1, s2, s3]
        statesByProject["proj-2"] = [s1, s2, s3]

        let c1 = PlaneCycleItem(id: "cyc-1", name: "Sprint 14", projectId: "proj-1", status: "current", startDate: "2026-11-01", endDate: "2026-11-15", isActive: true)
        cyclesByProject["proj-1"] = [c1]

        issues = [
            PlaneIssue(
                id: "iss-101", sequenceId: 101, projectId: "proj-1", projectIdentifier: "NOTCH", projectName: "BullshitNotch",
                name: "Add Self-Hosted Plane.so ticket workspace section with Active Cycle & Assigned to Me filters",
                descriptionText: "Integrate Plane API v1 issues with quick state toggles and coding agent hand-off.",
                priority: .urgent, stateId: "st-1", stateName: "In Progress", stateGroup: .started, stateColorHex: "#f59e0b",
                assigneeIds: ["demo-user-1"], isAssignedToMe: true, cycleIds: ["cyc-1"], cycleName: "Sprint 14", inActiveCycle: true,
                targetDate: "2026-11-06", updatedAt: "2m"
            ),
            PlaneIssue(
                id: "iss-104", sequenceId: 104, projectId: "proj-2", projectIdentifier: "API", projectName: "Hyperdrive API",
                name: "Fix Redis connection pool timeout on worker restart when idle sockets drop",
                descriptionText: "Worker nodes drop idle connections after 300s without TCP keepalive.",
                priority: .high, stateId: "st-1", stateName: "In Progress", stateGroup: .started, stateColorHex: "#f59e0b",
                assigneeIds: ["demo-user-1"], isAssignedToMe: true, cycleIds: ["cyc-1"], cycleName: "Sprint 14", inActiveCycle: true,
                targetDate: "2026-11-08", updatedAt: "18m"
            ),
            PlaneIssue(
                id: "iss-98", sequenceId: 98, projectId: "proj-1", projectIdentifier: "NOTCH", projectName: "BullshitNotch",
                name: "Support one-click git branch slug copy from Plane ticket row",
                descriptionText: "Allow copying feat/notch-98-... directly from the ticket row.",
                priority: .medium, stateId: "st-2", stateName: "Todo", stateGroup: .unstarted, stateColorHex: "#38bdf8",
                assigneeIds: ["demo-user-1"], isAssignedToMe: true, cycleIds: ["cyc-1"], cycleName: "Sprint 14", inActiveCycle: true,
                targetDate: nil, updatedAt: "1h"
            )
        ]
    }

    // MARK: - Cached Filtering & Counts

    var availableCycles: [PlaneCycleItem] {
        if !selectedProjectId.isEmpty {
            return cyclesByProject[selectedProjectId] ?? []
        }
        return cyclesByProject.values.flatMap { $0 }
    }

    var activeCycleLabel: String {
        if !selectedCycleId.isEmpty, let c = availableCycles.first(where: { $0.id == selectedCycleId }) {
            return c.name
        }
        let actives = availableCycles.filter(\.isActive)
        if actives.count == 1, let first = actives.first {
            return first.name
        }
        return "Active Cycle"
    }

    private func recomputeFiltered() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let me = currentUserId

        var startedCounter = 0
        var todoCounter = 0

        let matching = issues.filter { issue in
            if !selectedProjectId.isEmpty && issue.projectId != selectedProjectId {
                return false
            }

            // 1. Cycle filter
            if !selectedCycleId.isEmpty {
                if !issue.cycleIds.contains(selectedCycleId) { return false }
            } else if onlyActiveCycle {
                if !issue.inActiveCycle { return false }
            }

            // 2. Assigned to Me filter
            if onlyAssignedToMe {
                let assignedToCurrentUser: Bool = {
                    if issue.isAssignedToMe { return true }
                    if let me, !me.isEmpty, issue.assigneeIds.contains(me) { return true }
                    return false
                }()
                if !assignedToCurrentUser { return false }
            }

            // Tally active/todo counts before state sub-filter
            if issue.stateGroup == .started {
                startedCounter += 1
            } else if issue.stateGroup == .unstarted || issue.stateGroup == .backlog {
                todoCounter += 1
            }

            // 3. State group filter
            switch stateFilter {
            case .active:
                if issue.stateGroup == .completed || issue.stateGroup == .cancelled { return false }
            case .started:
                if issue.stateGroup != .started { return false }
            case .todo:
                if issue.stateGroup != .unstarted && issue.stateGroup != .backlog { return false }
            case .done:
                if issue.stateGroup != .completed { return false }
            case .all:
                break
            }

            // 4. Text search
            guard !q.isEmpty else { return true }
            if issue.issueKey.lowercased().contains(q) { return true }
            if issue.name.lowercased().contains(q) { return true }
            if issue.projectName.lowercased().contains(q) { return true }
            if issue.stateName.lowercased().contains(q) { return true }
            if let cyc = issue.cycleName?.lowercased(), cyc.contains(q) { return true }
            if issue.priority.label.lowercased().contains(q) { return true }
            return false
        }
        .sorted { a, b in
            if a.stateGroup.sortOrder != b.stateGroup.sortOrder {
                return a.stateGroup.sortOrder < b.stateGroup.sortOrder
            }
            if a.priority.sortRank != b.priority.sortRank {
                return a.priority.sortRank < b.priority.sortRank
            }
            return a.sequenceId > b.sequenceId
        }

        inProgressCount = startedCounter
        todoCount = todoCounter
        filteredIssues = matching
    }

    func states(for projectId: String) -> [PlaneStateItem] {
        statesByProject[projectId] ?? []
    }

    func selectCurrentUser(_ member: PlaneMember) {
        currentUserId = member.id
        currentUserDisplayName = member.displayName
        var updated = issues
        for idx in updated.indices {
            updated[idx].isAssignedToMe = updated[idx].assigneeIds.contains(member.id)
        }
        issues = updated
        showToast("Filtering @me as \(member.displayName)")
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        statusToast = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self.statusToast = nil
        }
    }

    // MARK: - Plane REST API v1 Networking

    func refresh() async {
        if isDemo { return }
        guard isConfigured else {
            errorMessage = nil
            return
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let base = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        let key = apiKey

        do {
            // 1. Fetch current user profile (/api/v1/users/me/) or workspace members so we know who @me is
            if let meJSON = try? await Self.requestJSON(base: base, path: "/api/v1/users/me/", apiKey: key) as? [String: Any] {
                if let uid = meJSON["id"] as? String, !uid.isEmpty {
                    currentUserId = uid
                }
                let disp = (meJSON["display_name"] as? String) ?? (meJSON["first_name"] as? String) ?? (meJSON["email"] as? String)
                if let disp, !disp.isEmpty {
                    currentUserDisplayName = disp
                }
            }

            if let membersAny = try? await Self.requestJSON(base: base, path: "/api/v1/workspaces/\(slug)/members/", apiKey: key) {
                let rawMembers = Self.extractResultsArray(from: membersAny)
                let parsedMembers: [PlaneMember] = rawMembers.compactMap { mDict in
                    if let memberObj = mDict["member"] as? [String: Any],
                       let uid = memberObj["id"] as? String {
                        let name = (memberObj["display_name"] as? String)
                            ?? (memberObj["first_name"] as? String)
                            ?? (memberObj["email"] as? String)
                            ?? uid
                        return PlaneMember(id: uid, displayName: name, email: memberObj["email"] as? String)
                    }
                    guard let uid = (mDict["member"] as? String) ?? (mDict["id"] as? String) else { return nil }
                    let name = (mDict["display_name"] as? String) ?? (mDict["email"] as? String) ?? uid
                    return PlaneMember(id: uid, displayName: name, email: mDict["email"] as? String)
                }
                if !parsedMembers.isEmpty {
                    members = parsedMembers
                    if currentUserId == nil, parsedMembers.count == 1, let sole = parsedMembers.first {
                        currentUserId = sole.id
                        currentUserDisplayName = sole.displayName
                    } else if let me = currentUserId, let matched = parsedMembers.first(where: { $0.id == me }) {
                        currentUserDisplayName = matched.displayName
                    }
                }
            }

            // 2. Fetch Workspace Projects (/api/v1/workspaces/{slug}/projects/)
            let projAny = try await Self.requestJSON(
                base: base,
                path: "/api/v1/workspaces/\(slug)/projects/",
                apiKey: key
            )
            let rawProjects = Self.extractResultsArray(from: projAny)
            let decodedProjects: [PlaneProject] = rawProjects.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let identifier = (dict["identifier"] as? String) ?? String(name.prefix(4)).uppercased()
                let desc = dict["description"] as? String
                return PlaneProject(id: id, name: name, identifier: identifier, description: desc)
            }
            projects = decodedProjects

            if !selectedProjectId.isEmpty && !decodedProjects.contains(where: { $0.id == selectedProjectId }) {
                selectedProjectId = ""
            }

            let targetProjects: [PlaneProject]
            if !selectedProjectId.isEmpty, let match = decodedProjects.first(where: { $0.id == selectedProjectId }) {
                targetProjects = [match]
            } else {
                targetProjects = Array(decodedProjects.prefix(4))
            }

            let meId = currentUserId
            var newStatesByProject = statesByProject
            var newCyclesByProject = cyclesByProject
            var allFetchedIssues: [PlaneIssue] = []

            // 3. Fetch States, Cycles + Active Cycle Issues, and Project Issues sequentially per project to keep memory low
            for proj in targetProjects {
                // 3a. Fetch states for project
                var stateItems: [PlaneStateItem] = []
                if let statesAny = try? await Self.requestJSON(
                    base: base,
                    path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/states/",
                    apiKey: key
                ) {
                    let stateDicts = Self.extractResultsArray(from: statesAny)
                    stateItems = stateDicts.enumerated().compactMap { idx, sDict in
                        guard let sid = sDict["id"] as? String,
                              let sname = sDict["name"] as? String else { return nil }
                        let grpRaw = (sDict["group"] as? String) ?? "unstarted"
                        let grp = PlaneStateGroup(rawValue: grpRaw) ?? .unstarted
                        let color = (sDict["color"] as? String) ?? "#38bdf8"
                        let seq = (sDict["sequence"] as? Double) ?? Double(idx)
                        return PlaneStateItem(
                            id: sid,
                            name: sname,
                            group: grp,
                            colorHex: color,
                            projectId: proj.id,
                            sequence: seq
                        )
                    }
                    .sorted { $0.sequence < $1.sequence }
                }
                let stateMap = Dictionary(uniqueKeysWithValues: stateItems.map { ($0.id, $0) })

                // 3b. Fetch cycles for project & identify active cycle(s)
                var cycleItems: [PlaneCycleItem] = []
                var activeCycleIds = Set<String>()
                var issueIdsByCycle: [String: Set<String>] = [:]
                var cycleExtraIssueDicts: [(String, String, [String: Any])] = []

                if let currentCycAny = try? await Self.requestJSON(
                    base: base,
                    path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/cycles/?cycle_view=current",
                    apiKey: key
                ) {
                    for cDict in Self.extractResultsArray(from: currentCycAny) {
                        if let cid = cDict["id"] as? String {
                            activeCycleIds.insert(cid)
                        }
                    }
                }

                if let cyclesAny = try? await Self.requestJSON(
                    base: base,
                    path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/cycles/",
                    apiKey: key
                ) {
                    let cycleDicts = Self.extractResultsArray(from: cyclesAny)
                    cycleItems = cycleDicts.compactMap { cDict in
                        guard let cid = cDict["id"] as? String,
                              let cname = cDict["name"] as? String else { return nil }
                        let statusRaw = ((cDict["status"] as? String) ?? "").lowercased()
                        let startStr = cDict["start_date"] as? String
                        let endStr = cDict["end_date"] as? String
                        let active = activeCycleIds.contains(cid)
                            || Self.isCycleActive(status: statusRaw, startDate: startStr, endDate: endStr)
                        if active {
                            activeCycleIds.insert(cid)
                        }
                        return PlaneCycleItem(
                            id: cid,
                            name: cname,
                            projectId: proj.id,
                            status: statusRaw,
                            startDate: startStr,
                            endDate: endStr,
                            isActive: active
                        )
                    }

                    if activeCycleIds.isEmpty,
                       let fallback = cycleItems.first(where: { $0.status != "completed" && $0.status != "draft" && $0.status != "cancelled" }) {
                        activeCycleIds.insert(fallback.id)
                        cycleItems = cycleItems.map { c in
                            c.id == fallback.id
                                ? PlaneCycleItem(id: c.id, name: c.name, projectId: c.projectId, status: c.status, startDate: c.startDate, endDate: c.endDate, isActive: true)
                                : c
                        }
                    }

                    // Only inspect active cycles (or selected cycle) to avoid downloading huge historical cycle payloads
                    let cyclesToInspect = cycleItems.filter { $0.isActive || $0.id == selectedCycleId }.prefix(2)
                    for cyc in cyclesToInspect {
                        if let cycIssuesAny = try? await Self.requestJSON(
                            base: base,
                            path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/cycles/\(cyc.id)/cycle-issues/",
                            apiKey: key
                        ) {
                            let rows = Self.extractResultsArray(from: cycIssuesAny)
                            for row in rows {
                                if let issueId = row["issue"] as? String {
                                    issueIdsByCycle[cyc.id, default: []].insert(issueId)
                                    if let detail = row["issue_detail"] as? [String: Any] {
                                        cycleExtraIssueDicts.append((cyc.id, cyc.name, detail))
                                    }
                                } else if let issueObj = row["issue"] as? [String: Any],
                                          let issueId = issueObj["id"] as? String {
                                    issueIdsByCycle[cyc.id, default: []].insert(issueId)
                                    cycleExtraIssueDicts.append((cyc.id, cyc.name, issueObj))
                                } else if let workItemId = row["work_item"] as? String {
                                    issueIdsByCycle[cyc.id, default: []].insert(workItemId)
                                } else if row["sequence_id"] != nil, row["name"] != nil,
                                          let directId = row["id"] as? String {
                                    issueIdsByCycle[cyc.id, default: []].insert(directId)
                                    cycleExtraIssueDicts.append((cyc.id, cyc.name, row))
                                }
                            }
                        }
                    }
                }

                let cycleMap = Dictionary(uniqueKeysWithValues: cycleItems.map { ($0.id, $0) })

                // 3c. Fetch issues for project (try /issues/ first, fallback to /work-items/)
                let issuesAny: Any
                if let primary = try? await Self.requestJSON(
                    base: base,
                    path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/issues/",
                    apiKey: key
                ) {
                    issuesAny = primary
                } else {
                    issuesAny = try await Self.requestJSON(
                        base: base,
                        path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/work-items/",
                        apiKey: key
                    )
                }

                let issueDicts = Self.extractResultsArray(from: issuesAny)
                var seenIssueIds = Set<String>()
                var projectIssues: [PlaneIssue] = []

                for dict in issueDicts {
                    if let parsed = Self.parseIssue(
                        dict: dict,
                        project: proj,
                        stateMap: stateMap,
                        cycleMap: cycleMap,
                        activeCycleIds: activeCycleIds,
                        issueIdsByCycle: issueIdsByCycle,
                        currentUserId: meId
                    ) {
                        seenIssueIds.insert(parsed.id)
                        projectIssues.append(parsed)
                    }
                }

                for (cid, _, extraDict) in cycleExtraIssueDicts {
                    if let eid = extraDict["id"] as? String, !seenIssueIds.contains(eid) {
                        issueIdsByCycle[cid, default: []].insert(eid)
                        if let parsed = Self.parseIssue(
                            dict: extraDict,
                            project: proj,
                            stateMap: stateMap,
                            cycleMap: cycleMap,
                            activeCycleIds: activeCycleIds,
                            issueIdsByCycle: issueIdsByCycle,
                            currentUserId: meId
                        ) {
                            seenIssueIds.insert(parsed.id)
                            projectIssues.append(parsed)
                        }
                    }
                }

                if !stateItems.isEmpty {
                    newStatesByProject[proj.id] = stateItems
                }
                if !cycleItems.isEmpty {
                    newCyclesByProject[proj.id] = cycleItems
                }
                allFetchedIssues.append(contentsOf: projectIssues)
            }

            statesByProject = newStatesByProject
            cyclesByProject = newCyclesByProject
            issues = allFetchedIssues

            let anyCyclesExist = newCyclesByProject.values.contains { !$0.isEmpty }
            if !anyCyclesExist && onlyActiveCycle {
                onlyActiveCycle = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mutations: Update State, Update Priority, Create Issue

    func updateIssueState(_ issue: PlaneIssue, to newState: PlaneStateItem) async {
        guard issue.stateId != newState.id else { return }

        if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
            var copy = issues
            copy[idx].stateId = newState.id
            copy[idx].stateName = newState.name
            copy[idx].stateGroup = newState.group
            copy[idx].stateColorHex = newState.colorHex
            issues = copy
        }
        showToast("\(issue.issueKey) → \(newState.name)")

        guard !isDemo else { return }
        let base = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        let key = apiKey
        let payload: [String: Any] = ["state": newState.id]

        do {
            _ = try await Self.sendMutation(
                base: base,
                path: "/api/v1/workspaces/\(slug)/projects/\(issue.projectId)/issues/\(issue.id)/",
                fallbackPath: "/api/v1/workspaces/\(slug)/projects/\(issue.projectId)/work-items/\(issue.id)/",
                method: "PATCH",
                body: payload,
                apiKey: key
            )
        } catch {
            showToast("Failed: \(error.localizedDescription)")
        }
    }

    func updateIssuePriority(_ issue: PlaneIssue, to newPriority: PlanePriority) async {
        guard issue.priority != newPriority else { return }

        if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
            var copy = issues
            copy[idx].priority = newPriority
            issues = copy
        }
        showToast("\(issue.issueKey) → \(newPriority.label)")

        guard !isDemo else { return }
        let base = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        let key = apiKey
        let payload: [String: Any] = ["priority": newPriority.rawValue]

        do {
            _ = try await Self.sendMutation(
                base: base,
                path: "/api/v1/workspaces/\(slug)/projects/\(issue.projectId)/issues/\(issue.id)/",
                fallbackPath: "/api/v1/workspaces/\(slug)/projects/\(issue.projectId)/work-items/\(issue.id)/",
                method: "PATCH",
                body: payload,
                apiKey: key
            )
        } catch {
            showToast("Failed: \(error.localizedDescription)")
        }
    }

    func createIssue(title: String, projectId: String, priority: PlanePriority) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }

        guard let proj = projects.first(where: { $0.id == projectId }) ?? projects.first else {
            showToast("Select a Plane project first")
            return false
        }

        if isDemo {
            let nextSeq = (issues.map(\.sequenceId).max() ?? 100) + 1
            let defaultState = states(for: proj.id).first ?? PlaneStateItem(
                id: "st-2", name: "Todo", group: .unstarted, colorHex: "#38bdf8", projectId: proj.id, sequence: 1
            )
            let activeCyc = cyclesByProject[proj.id]?.first(where: \.isActive)
            let newIssue = PlaneIssue(
                id: UUID().uuidString,
                sequenceId: nextSeq,
                projectId: proj.id,
                projectIdentifier: proj.identifier,
                projectName: proj.name,
                name: cleanTitle,
                descriptionText: "",
                priority: priority,
                stateId: defaultState.id,
                stateName: defaultState.name,
                stateGroup: defaultState.group,
                stateColorHex: defaultState.colorHex,
                assigneeIds: currentUserId.map { [$0] } ?? [],
                isAssignedToMe: true,
                cycleIds: activeCyc.map { [$0.id] } ?? [],
                cycleName: activeCyc?.name,
                inActiveCycle: activeCyc != nil,
                targetDate: nil,
                updatedAt: "now"
            )
            issues.insert(newIssue, at: 0)
            showToast("Created \(newIssue.issueKey)")
            return true
        }

        let base = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        let key = apiKey

        var payload: [String: Any] = [
            "name": cleanTitle,
            "priority": priority.rawValue
        ]
        if let me = currentUserId {
            payload["assignees"] = [me]
        }

        do {
            _ = try await Self.sendMutation(
                base: base,
                path: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/issues/",
                fallbackPath: "/api/v1/workspaces/\(slug)/projects/\(proj.id)/work-items/",
                method: "POST",
                body: payload,
                apiKey: key
            )
            showToast("Created ticket in \(proj.identifier)")
            await refresh()
            return true
        } catch {
            showToast("Create failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Browser, Clipboard & Coding Agent Actions

    func openInBrowser(_ issue: PlaneIssue) {
        let base = normalizedBaseURL.isEmpty ? "https://app.plane.so" : normalizedBaseURL
        let slug = normalizedWorkspaceSlug.isEmpty ? "workspace" : normalizedWorkspaceSlug
        if let url = URL(string: "\(base)/\(slug)/projects/\(issue.projectId)/issues/\(issue.id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openWorkspaceInBrowser() {
        let base = normalizedBaseURL
        let slug = normalizedWorkspaceSlug
        guard !base.isEmpty else { return }
        let urlString = slug.isEmpty ? base : "\(base)/\(slug)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyIssueKey(_ issue: PlaneIssue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.issueKey, forType: .string)
        showToast("Copied \(issue.issueKey)")
    }

    func copyBranchSlug(_ issue: PlaneIssue) {
        let branch = issue.suggestedBranchName
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
        showToast("Copied \(branch)")
    }

    // MARK: - Folder & Agent Assignment per Ticket / Plane Project

    private func loadFolderMaps() {
        if let tData = UserDefaults.standard.dictionary(forKey: ticketFoldersKey) as? [String: String] {
            ticketFolders = tData
        }
        if let pData = UserDefaults.standard.dictionary(forKey: projectFoldersKey) as? [String: String] {
            projectFolders = pData
        }
        if let aData = UserDefaults.standard.dictionary(forKey: ticketAgentsKey) as? [String: String] {
            ticketAgents = aData
        }
    }

    private func saveFolderMaps() {
        if isDemo { return }
        UserDefaults.standard.set(ticketFolders, forKey: ticketFoldersKey)
        UserDefaults.standard.set(projectFolders, forKey: projectFoldersKey)
        UserDefaults.standard.set(ticketAgents, forKey: ticketAgentsKey)
    }

    func refreshAvailableFolders() {
        var seen = Set<String>()
        var result: [PlaneWorkFolder] = []

        func appendFolder(path: String, preferredName: String? = nil, agentCmd: String? = nil) {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty, !seen.contains(expanded) else { return }
            seen.insert(expanded)
            let name = preferredName ?? URL(fileURLWithPath: expanded).lastPathComponent
            let display = (expanded as NSString).abbreviatingWithTildeInPath
            result.append(
                PlaneWorkFolder(
                    name: name.isEmpty ? display : name,
                    expandedPath: expanded,
                    displayPath: display,
                    agentCommand: agentCmd
                )
            )
        }

        // 1. Saved projects in ProjectStore
        for p in ProjectStore.shared.projects {
            appendFolder(path: p.expandedPath, preferredName: p.name, agentCmd: p.agentCommand)
        }

        // 2. Any already-assigned ticket or project folders
        for path in projectFolders.values.sorted() {
            appendFolder(path: path)
        }
        for path in ticketFolders.values.sorted() {
            appendFolder(path: path)
        }

        // 3. Common workspace roots: ~/project, ~/work, ~/projects, ~/code, ~/dev
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["project", "work", "projects", "code", "dev"].map { home.appendingPathComponent($0) }
        for root in roots {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let subdirs = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for dir in subdirs {
                appendFolder(path: dir.path)
            }
        }

        availableFolders = result
    }

    func assignedFolder(for issue: PlaneIssue) -> PlaneAssignedFolder? {
        // 1. Explicit ticket-level folder assignment
        if let tPath = ticketFolders[issue.id], !tPath.isEmpty {
            let expanded = (tPath as NSString).expandingTildeInPath
            let name = URL(fileURLWithPath: expanded).lastPathComponent
            let display = (expanded as NSString).abbreviatingWithTildeInPath
            return PlaneAssignedFolder(
                expandedPath: expanded,
                name: name.isEmpty ? display : name,
                displayPath: display,
                isTicketSpecific: true,
                isExplicit: true
            )
        }
        // 2. Explicit Plane-project-level folder assignment
        if let pPath = projectFolders[issue.projectId], !pPath.isEmpty {
            let expanded = (pPath as NSString).expandingTildeInPath
            let name = URL(fileURLWithPath: expanded).lastPathComponent
            let display = (expanded as NSString).abbreviatingWithTildeInPath
            return PlaneAssignedFolder(
                expandedPath: expanded,
                name: name.isEmpty ? display : name,
                displayPath: display,
                isTicketSpecific: false,
                isExplicit: true
            )
        }
        // 3. Auto-match against saved ProjectStore projects or discovered folders by Plane project name/identifier
        let planeProj = issue.projectName.lowercased()
        let planeId = issue.projectIdentifier.lowercased()
        if let matched = availableFolders.first(where: { f in
            let fName = f.name.lowercased()
            return (!planeProj.isEmpty && (fName == planeProj || fName.contains(planeProj) || planeProj.contains(fName)))
                || (!planeId.isEmpty && fName == planeId)
        }) {
            return PlaneAssignedFolder(
                expandedPath: matched.expandedPath,
                name: matched.name,
                displayPath: matched.displayPath,
                isTicketSpecific: false,
                isExplicit: false
            )
        }
        return nil
    }

    func assignedProjectFolder(for projectId: String) -> PlaneAssignedFolder? {
        guard let pPath = projectFolders[projectId], !pPath.isEmpty else { return nil }
        let expanded = (pPath as NSString).expandingTildeInPath
        let name = URL(fileURLWithPath: expanded).lastPathComponent
        let display = (expanded as NSString).abbreviatingWithTildeInPath
        return PlaneAssignedFolder(
            expandedPath: expanded,
            name: name.isEmpty ? display : name,
            displayPath: display,
            isTicketSpecific: false,
            isExplicit: true
        )
    }

    func assignFolder(_ rawPath: String?, to issue: PlaneIssue, scope: PlaneFolderScope) {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            switch scope {
            case .ticket:
                ticketFolders.removeValue(forKey: issue.id)
                showToast("Cleared folder for \(issue.issueKey)")
            case .project:
                projectFolders.removeValue(forKey: issue.projectId)
                showToast("Cleared default folder for \(issue.projectIdentifier)")
            }
            return
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        let folderURL = URL(fileURLWithPath: expanded)
        ProjectStore.shared.addFolder(folderURL)

        switch scope {
        case .ticket:
            ticketFolders[issue.id] = expanded
            showToast("\(issue.issueKey) → \(folderURL.lastPathComponent)")
        case .project:
            projectFolders[issue.projectId] = expanded
            // If ticket had a stale override, remove it so the newly set project folder applies
            ticketFolders.removeValue(forKey: issue.id)
            showToast("\(issue.projectIdentifier) project → \(folderURL.lastPathComponent)")
        }
        refreshAvailableFolders()
    }

    func assignFolderToProject(projectId: String, projectIdentifier: String, rawPath: String?) {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            projectFolders.removeValue(forKey: projectId)
            showToast("Cleared folder for \(projectIdentifier)")
            return
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let folderURL = URL(fileURLWithPath: expanded)
        ProjectStore.shared.addFolder(folderURL)
        projectFolders[projectId] = expanded
        refreshAvailableFolders()
        showToast("\(projectIdentifier) → \(folderURL.lastPathComponent)")
    }

    func pickFolderWithDialog(for issue: PlaneIssue, scope: PlaneFolderScope) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Assign Working Folder for \(scope == .ticket ? issue.issueKey : issue.projectName)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            assignFolder(url.path, to: issue, scope: scope)
        }
    }

    func assignedAgent(for issue: PlaneIssue, folderPath: String? = nil) -> String {
        if let custom = ticketAgents[issue.id], !custom.isEmpty {
            return custom
        }
        if let customProj = ticketAgents["proj:\(issue.projectId)"], !customProj.isEmpty {
            return customProj
        }
        let resolvedPath = folderPath ?? assignedFolder(for: issue)?.expandedPath
        if let resolvedPath,
           let matchedProj = ProjectStore.shared.projects.first(where: { $0.expandedPath == resolvedPath }),
           !matchedProj.agentCommand.isEmpty {
            return matchedProj.agentCommand
        }
        return UserDefaults.standard.string(forKey: Pref.defaultAgentCommand) ?? "claude"
    }

    func setAgent(_ agentCmd: String, for issue: PlaneIssue, scope: PlaneFolderScope) {
        let trimmed = agentCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch scope {
        case .ticket:
            ticketAgents[issue.id] = trimmed
        case .project:
            ticketAgents["proj:\(issue.projectId)"] = trimmed
            ticketAgents.removeValue(forKey: issue.id)
        }
    }

    func sendToAgent(_ issue: PlaneIssue, folderPathOverride: String? = nil, agentCommandOverride: String? = nil) {
        let resolvedFolder = folderPathOverride
            ?? assignedFolder(for: issue)?.expandedPath
            ?? ProjectStore.shared.projects.first?.expandedPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        let agentCmd = agentCommandOverride ?? assignedAgent(for: issue, folderPath: resolvedFolder)
        let folderName = URL(fileURLWithPath: resolvedFolder).lastPathComponent

        var promptParts = ["Work on Plane ticket \(issue.issueKey): \(issue.name)"]
        if !issue.descriptionText.isEmpty {
            let cleanDesc = issue.descriptionText
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(240)
            promptParts.append("Details: \(cleanDesc)")
        }
        let prompt = promptParts.joined(separator: " — ")
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        ProjectStore.shared.launchInTerminal(directory: resolvedFolder, command: "\(agentCmd) \"\(escapedPrompt)\"")
        showToast("Launched \(agentCmd) in \(folderName)")
    }

    func openAssignedFolderInFinder(_ issue: PlaneIssue) {
        guard let assigned = assignedFolder(for: issue) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: assigned.expandedPath))
    }

    // MARK: - JSON Parsing Helpers

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated private static func isCycleActive(status: String, startDate: String?, endDate: String?) -> Bool {
        let s = status.lowercased()
        if s == "current" || s == "active" || s == "started" || s == "in_progress" {
            return true
        }
        if s == "completed" || s == "draft" || s == "cancelled" || s == "upcoming" {
            return false
        }
        guard let startStr = startDate?.prefix(10),
              let endStr = endDate?.prefix(10),
              startStr.count == 10, endStr.count == 10 else {
            return false
        }
        let today = dayFormatter.string(from: Date())
        return String(startStr) <= today && today <= String(endStr)
    }

    nonisolated private static func requestJSON(base: String, path: String, apiKey: String) async throws -> Any {
        guard let url = URL(string: base + path) else {
            throw NSError(domain: "PlaneAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Plane URL: \(base)\(path)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BullshitNotch/1.2", forHTTPHeaderField: "User-Agent")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "PlaneAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]
            )
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func sendMutation(
        base: String,
        path: String,
        fallbackPath: String,
        method: String,
        body: [String: Any],
        apiKey: String
    ) async throws -> Any {
        do {
            return try await performMutation(base: base, path: path, method: method, body: body, apiKey: apiKey)
        } catch let err as NSError where err.code == 404 {
            return try await performMutation(base: base, path: fallbackPath, method: method, body: body, apiKey: apiKey)
        }
    }

    nonisolated private static func performMutation(
        base: String,
        path: String,
        method: String,
        body: [String: Any],
        apiKey: String
    ) async throws -> Any {
        guard let url = URL(string: base + path) else {
            throw NSError(domain: "PlaneAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Plane URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BullshitNotch/1.2", forHTTPHeaderField: "User-Agent")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "PlaneAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]
            )
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    nonisolated private static func extractResultsArray(from json: Any) -> [[String: Any]] {
        if let arr = json as? [[String: Any]] {
            return arr
        }
        if let dict = json as? [String: Any] {
            if let results = dict["results"] as? [[String: Any]] {
                return results
            }
            if let data = dict["data"] as? [[String: Any]] {
                return data
            }
        }
        return []
    }

    nonisolated private static func parseIssue(
        dict: [String: Any],
        project: PlaneProject,
        stateMap: [String: PlaneStateItem],
        cycleMap: [String: PlaneCycleItem],
        activeCycleIds: Set<String>,
        issueIdsByCycle: [String: Set<String>],
        currentUserId: String?
    ) -> PlaneIssue? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else { return nil }

        let seqId = (dict["sequence_id"] as? Int) ?? 0
        let priorityRaw = (dict["priority"] as? String)?.lowercased() ?? "none"
        let priority = PlanePriority(rawValue: priorityRaw) ?? .none

        let rawDesc = (dict["description_stripped"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let descStripped = String(rawDesc.prefix(240))

        // State resolution
        var stateId = ""
        var stateName = "Todo"
        var stateGroup: PlaneStateGroup = .unstarted
        var stateColor = "#38bdf8"

        if let sId = dict["state"] as? String {
            stateId = sId
            if let mapped = stateMap[sId] {
                stateName = mapped.name
                stateGroup = mapped.group
                stateColor = mapped.colorHex
            }
        } else if let sObj = dict["state"] as? [String: Any] {
            stateId = (sObj["id"] as? String) ?? ""
            stateName = (sObj["name"] as? String) ?? "Todo"
            if let grpRaw = sObj["group"] as? String, let grp = PlaneStateGroup(rawValue: grpRaw) {
                stateGroup = grp
            } else if let mapped = stateMap[stateId] {
                stateGroup = mapped.group
            }
            stateColor = (sObj["color"] as? String) ?? "#38bdf8"
        }

        // Assignees resolution
        var assigneeIds: [String] = []
        if let strArr = dict["assignees"] as? [String] {
            assigneeIds = strArr
        } else if let idsArr = dict["assignee_ids"] as? [String] {
            assigneeIds = idsArr
        } else if let objArr = dict["assignees"] as? [[String: Any]] {
            assigneeIds = objArr.compactMap { ($0["id"] as? String) ?? ($0["member"] as? String) }
        } else if let detailArr = dict["assignee_details"] as? [[String: Any]] {
            assigneeIds = detailArr.compactMap { $0["id"] as? String }
        }

        let isMine: Bool = {
            guard let me = currentUserId, !me.isEmpty else { return false }
            return assigneeIds.contains(me)
        }()

        // Cycle resolution
        var matchedCycleIds = Set<String>()
        if let cid = dict["cycle"] as? String, !cid.isEmpty {
            matchedCycleIds.insert(cid)
        }
        if let cid = dict["cycle_id"] as? String, !cid.isEmpty {
            matchedCycleIds.insert(cid)
        }
        if let cObj = dict["cycle"] as? [String: Any], let cid = cObj["id"] as? String {
            matchedCycleIds.insert(cid)
        }
        if let cObj = dict["issue_cycle"] as? [String: Any] {
            if let cid = (cObj["cycle"] as? String) ?? (cObj["id"] as? String) {
                matchedCycleIds.insert(cid)
            }
        }
        if let cArr = dict["cycles"] as? [String] {
            matchedCycleIds.formUnion(cArr)
        }
        for (cid, setOfIssueIds) in issueIdsByCycle where setOfIssueIds.contains(id) {
            matchedCycleIds.insert(cid)
        }

        let isInActiveCycle = !matchedCycleIds.isDisjoint(with: activeCycleIds)
        let resolvedCycleName: String? = {
            if let activeId = matchedCycleIds.first(where: { activeCycleIds.contains($0) }),
               let cyc = cycleMap[activeId] {
                return cyc.name
            }
            if let anyId = matchedCycleIds.first, let cyc = cycleMap[anyId] {
                return cyc.name
            }
            return nil
        }()

        let targetDate = dict["target_date"] as? String

        return PlaneIssue(
            id: id,
            sequenceId: seqId,
            projectId: project.id,
            projectIdentifier: project.identifier,
            projectName: project.name,
            name: name,
            descriptionText: descStripped,
            priority: priority,
            stateId: stateId,
            stateName: stateName,
            stateGroup: stateGroup,
            stateColorHex: stateColor,
            assigneeIds: assigneeIds,
            isAssignedToMe: isMine,
            cycleIds: matchedCycleIds,
            cycleName: resolvedCycleName,
            inActiveCycle: isInActiveCycle,
            targetDate: targetDate,
            updatedAt: nil
        )
    }
}

// MARK: - Plane.so Workspace View (Inside Expanded Notch)

struct PlaneView: View {
    @ObservedObject private var store = PlaneStore.shared
    @ObservedObject private var music = NowPlaying.shared
    @AppStorage(Pref.musicAmbient) private var musicAmbient = true
    @AppStorage(Pref.planeBaseURL) private var planeBaseURL = ""
    @AppStorage(Pref.planeWorkspaceSlug) private var planeWorkspaceSlug = ""
    @AppStorage(Pref.planeApiKey) private var planeApiKey = ""

    @State private var showConnectionForm = false
    @State private var showNewIssueForm = false
    @State private var showProjectPicker = false
    @State private var showProjectFolderPicker = false
    @State private var activeIssuePickerId: String? = nil
    @State private var activeFolderIssueId: String? = nil
    @State private var folderScope: PlaneFolderScope = .ticket
    @State private var newIssueTitle = ""
    @State private var newIssuePriority: PlanePriority = .medium
    @State private var newIssueProjectId = ""
    @State private var isCreatingIssue = false

    private var palette: NowPlaying.Palette? {
        musicAmbient ? music.activePalette : nil
    }

    private var accentColor: Color {
        palette?.primaryColor ?? Color(red: 0.35, green: 0.78, blue: 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerBar

            if !store.isConfigured || showConnectionForm {
                connectionSetupCard
            } else {
                if showProjectPicker && store.projects.count > 1 {
                    projectPickerInlineBar
                } else if showProjectFolderPicker,
                          let selectedProj = store.projects.first(where: { $0.id == store.selectedProjectId }) {
                    projectFolderInlineBar(for: selectedProj)
                } else if showNewIssueForm {
                    newIssueInlineBar
                } else {
                    filterAndSearchBar
                }

                if store.isLoading && store.issues.isEmpty {
                    ProgressView("Syncing Plane.so tickets…")
                        .font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = store.errorMessage, store.issues.isEmpty {
                    errorStateView(err)
                } else if store.filteredIssues.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.filteredIssues) { issue in
                                PlaneIssueRow(
                                    issue: issue,
                                    projectStates: store.states(for: issue.projectId),
                                    assignedFolder: store.assignedFolder(for: issue),
                                    assignedAgent: store.assignedAgent(for: issue),
                                    availableFolders: store.availableFolders,
                                    agentPresets: ProjectStore.shared.agentPresets,
                                    isPickerOpen: activeIssuePickerId == issue.id,
                                    isFolderPickerOpen: activeFolderIssueId == issue.id,
                                    folderScope: folderScope,
                                    accentColor: accentColor,
                                    onTogglePicker: {
                                        activeFolderIssueId = nil
                                        activeIssuePickerId = (activeIssuePickerId == issue.id) ? nil : issue.id
                                    },
                                    onToggleFolderPicker: {
                                        activeIssuePickerId = nil
                                        if activeFolderIssueId == issue.id {
                                            activeFolderIssueId = nil
                                        } else {
                                            store.refreshAvailableFolders()
                                            activeFolderIssueId = issue.id
                                        }
                                    },
                                    onSelectFolderScope: { newScope in
                                        folderScope = newScope
                                    },
                                    onAssignFolder: { path in
                                        store.assignFolder(path, to: issue, scope: folderScope)
                                    },
                                    onBrowseFolder: {
                                        store.pickFolderWithDialog(for: issue, scope: folderScope)
                                    },
                                    onSelectAgent: { cmd in
                                        store.setAgent(cmd, for: issue, scope: folderScope)
                                    },
                                    onLaunchAgent: {
                                        if store.assignedFolder(for: issue) != nil {
                                            activeFolderIssueId = nil
                                            store.sendToAgent(issue)
                                        } else {
                                            activeIssuePickerId = nil
                                            store.refreshAvailableFolders()
                                            activeFolderIssueId = issue.id
                                            store.showToast("Select a folder for \(issue.issueKey) first")
                                        }
                                    },
                                    onForceLaunchAgent: {
                                        activeFolderIssueId = nil
                                        store.sendToAgent(issue)
                                    },
                                    onSelectState: { st in
                                        activeIssuePickerId = nil
                                        Task { await store.updateIssueState(issue, to: st) }
                                    },
                                    onSelectPriority: { p in
                                        activeIssuePickerId = nil
                                        Task { await store.updateIssuePriority(issue, to: p) }
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .onAppear {
            store.refreshAvailableFolders()
            if newIssueProjectId.isEmpty {
                newIssueProjectId = store.selectedProjectId.isEmpty ? (store.projects.first?.id ?? "") : store.selectedProjectId
            }
            if store.isConfigured && store.issues.isEmpty && !store.isLoading {
                Task { await store.refresh() }
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text("Plane")
                    .font(.subheadline.bold())
            }

            if store.isConfigured {
                // Inline Project Switcher Pill (No NSMenu so hover tracking never breaks)
                Button {
                    showProjectPicker.toggle()
                    showProjectFolderPicker = false
                    showNewIssueForm = false
                } label: {
                    HStack(spacing: 3) {
                        let selectedProj = store.projects.first(where: { $0.id == store.selectedProjectId })
                        Text(selectedProj?.identifier ?? "All Projects")
                            .font(.caption2.bold())
                        if store.projects.count > 1 {
                            Image(systemName: showProjectPicker ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7.5, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(showProjectPicker ? 0.16 : 0.09), in: Capsule())
                }
                .buttonStyle(.plain)

                // If a specific Plane project is selected, allow assigning its default local folder right in the header
                if let selectedProj = store.projects.first(where: { $0.id == store.selectedProjectId }) {
                    let projFolder = store.assignedProjectFolder(for: selectedProj.id)
                    Button {
                        store.refreshAvailableFolders()
                        showProjectFolderPicker.toggle()
                        showProjectPicker = false
                        showNewIssueForm = false
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(projFolder?.name ?? "Set Folder")
                                .font(.system(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: showProjectFolderPicker ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(projFolder != nil ? accentColor : .white.opacity(0.68))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(projFolder != nil ? accentColor.opacity(0.15) : Color.white.opacity(0.08))
                                .overlay(
                                    Capsule().strokeBorder(projFolder != nil ? accentColor.opacity(0.4) : Color.clear, lineWidth: 0.7)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(projFolder.map { "Default folder for \(selectedProj.identifier): \($0.displayPath)" } ?? "Assign a default local folder for \(selectedProj.identifier)")
                }

                // Compact Counts
                HStack(spacing: 3) {
                    Circle().fill(PlaneStateGroup.started.color).frame(width: 5.5, height: 5.5)
                    Text("\(store.inProgressCount) active")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PlaneStateGroup.started.color.opacity(0.14), in: Capsule())
                .foregroundStyle(PlaneStateGroup.started.color)

                HStack(spacing: 3) {
                    Circle().fill(PlaneStateGroup.unstarted.color).frame(width: 5.5, height: 5.5)
                    Text("\(store.todoCount) todo")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PlaneStateGroup.unstarted.color.opacity(0.14), in: Capsule())
                .foregroundStyle(PlaneStateGroup.unstarted.color)
            }

            if let toast = store.statusToast {
                Text(toast)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if store.isConfigured {
                Button {
                    if newIssueProjectId.isEmpty {
                        newIssueProjectId = store.selectedProjectId.isEmpty ? (store.projects.first?.id ?? "") : store.selectedProjectId
                    }
                    showNewIssueForm.toggle()
                    showProjectPicker = false
                    showConnectionForm = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showNewIssueForm ? "xmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(showNewIssueForm ? "Cancel" : "New")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(showNewIssueForm ? .white.opacity(0.75) : accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(showNewIssueForm ? Color.white.opacity(0.08) : accentColor.opacity(0.16))
                            .overlay(Capsule().strokeBorder(showNewIssueForm ? Color.clear : accentColor.opacity(0.42), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .help("Create a new Plane ticket right from the notch")

                Button {
                    store.openWorkspaceInBrowser()
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open self-hosted Plane workspace in browser")
            }

            Button {
                showConnectionForm.toggle()
                showNewIssueForm = false
                showProjectPicker = false
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(showConnectionForm ? accentColor : .white.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .background(showConnectionForm ? accentColor.opacity(0.2) : .white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Configure self-hosted Plane URL, Workspace Slug & API Token")

            if store.isConfigured {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isLoading {
                        ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh Plane tickets")
            }
        }
    }

    // MARK: - Inline Project Picker Bar

    private var projectPickerInlineBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button {
                    store.selectedProjectId = ""
                    showProjectPicker = false
                } label: {
                    Text("All Projects")
                        .font(.system(size: 10, weight: store.selectedProjectId.isEmpty ? .bold : .medium))
                        .foregroundStyle(store.selectedProjectId.isEmpty ? .white : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(store.selectedProjectId.isEmpty ? accentColor.opacity(0.3) : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                ForEach(store.projects) { proj in
                    let isSel = store.selectedProjectId == proj.id
                    let projFolder = store.assignedProjectFolder(for: proj.id)
                    Button {
                        store.selectedProjectId = proj.id
                        showProjectPicker = false
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(proj.identifier) · \(proj.name)")
                                .font(.system(size: 10, weight: isSel ? .bold : .medium))
                            if let projFolder {
                                Text("(\(projFolder.name))")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(isSel ? .white : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(isSel ? accentColor.opacity(0.3) : Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Inline Project Default Folder Picker Bar

    private func projectFolderInlineBar(for proj: PlaneProject) -> some View {
        let currentFolder = store.assignedProjectFolder(for: proj.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text("Default Folder for \(proj.identifier) (\(proj.name)):")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))

                if let currentFolder {
                    Text(currentFolder.displayPath)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    let panel = NSOpenPanel()
                    panel.title = "Select Default Folder for \(proj.name)"
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        store.assignFolderToProject(projectId: proj.id, projectIdentifier: proj.identifier, rawPath: url.path)
                        showProjectFolderPicker = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Browse…")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)

                if currentFolder != nil {
                    Button {
                        store.assignFolderToProject(projectId: proj.id, projectIdentifier: proj.identifier, rawPath: nil)
                        showProjectFolderPicker = false
                    } label: {
                        Text("Clear")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.availableFolders) { folder in
                        let isSelected = currentFolder?.expandedPath == folder.expandedPath
                        Button {
                            store.assignFolderToProject(projectId: proj.id, projectIdentifier: proj.identifier, rawPath: folder.expandedPath)
                            showProjectFolderPicker = false
                        } label: {
                            HStack(spacing: 3.5) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "folder.fill")
                                    .font(.system(size: 8.5))
                                Text(folder.name)
                                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
                            }
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(isSelected ? accentColor.opacity(0.35) : Color.white.opacity(0.07))
                                    .overlay(
                                        Capsule().strokeBorder(isSelected ? accentColor : Color.white.opacity(0.1), lineWidth: 0.7)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(folder.displayPath)
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.32), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Filter & Search Bar (Active Cycle + Assigned to Me + State Filters)

    private var filterAndSearchBar: some View {
        HStack(spacing: 4) {
            // 1. Active Cycle Toggle Pill
            let cycleFilterOn = store.onlyActiveCycle || !store.selectedCycleId.isEmpty
            Button {
                if !store.selectedCycleId.isEmpty {
                    store.selectedCycleId = ""
                    store.onlyActiveCycle = false
                } else {
                    store.onlyActiveCycle.toggle()
                }
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(store.activeCycleLabel)
                        .font(.system(size: 10.5, weight: cycleFilterOn ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(cycleFilterOn ? Color(red: 1.0, green: 0.78, blue: 0.32) : .secondary)
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(cycleFilterOn ? Color.orange.opacity(0.22) : Color.white.opacity(0.06))
                        .overlay(
                            Capsule().strokeBorder(cycleFilterOn ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Toggle Active Cycle filter")

            // 2. Assigned to Me Toggle Pill
            Button {
                store.onlyAssignedToMe.toggle()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("Assigned to Me")
                        .font(.system(size: 10.5, weight: store.onlyAssignedToMe ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(store.onlyAssignedToMe ? Color.cyan : .secondary)
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(store.onlyAssignedToMe ? Color.cyan.opacity(0.20) : Color.white.opacity(0.06))
                        .overlay(
                            Capsule().strokeBorder(store.onlyAssignedToMe ? Color.cyan.opacity(0.55) : Color.clear, lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .help(store.currentUserDisplayName.map { "Filter tickets assigned to \($0)" } ?? "Filter tickets assigned to me")

            Divider()
                .frame(height: 12)
                .overlay(Color.white.opacity(0.14))

            // 3. Compact State Filter Pills (Active, In Progress, Todo, Done)
            ForEach([PlaneStore.StateFilter.active, .started, .todo, .done]) { sf in
                let selected = store.stateFilter == sf
                Button {
                    store.stateFilter = sf
                } label: {
                    Text(sf.rawValue)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(selected ? accentColor.opacity(0.26) : Color.white.opacity(0.05))
                                .overlay(
                                    Capsule().strokeBorder(selected ? accentColor.opacity(0.50) : Color.clear, lineWidth: 0.8)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            // 4. Compact Search Field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                TextField("Search…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(.white.opacity(0.06), in: Capsule())
        }
    }

    // MARK: - Inline Quick New Ticket Bar

    private var newIssueInlineBar: some View {
        HStack(spacing: 6) {
            TextField("New ticket title… (Press Return to create)", text: $newIssueTitle)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onSubmit {
                    submitNewIssue()
                }

            ForEach([PlanePriority.urgent, .high, .medium, .low]) { p in
                let sel = newIssuePriority == p
                Button {
                    newIssuePriority = p
                } label: {
                    Text(p.label)
                        .font(.system(size: 9.5, weight: sel ? .bold : .regular))
                        .foregroundStyle(sel ? p.color : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(sel ? p.color.opacity(0.18) : Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }

            Button {
                submitNewIssue()
            } label: {
                if isCreatingIssue {
                    ProgressView().controlSize(.mini).frame(width: 52, height: 22)
                } else {
                    Text("Create")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.85), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(newIssueTitle.trimmingCharacters(in: .whitespaces).isEmpty || isCreatingIssue)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func submitNewIssue() {
        let title = newIssueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isCreatingIssue else { return }
        isCreatingIssue = true
        let targetProj = newIssueProjectId.isEmpty
            ? (store.selectedProjectId.isEmpty ? (store.projects.first?.id ?? "") : store.selectedProjectId)
            : newIssueProjectId
        Task {
            let ok = await store.createIssue(title: title, projectId: targetProj, priority: newIssuePriority)
            isCreatingIssue = false
            if ok {
                newIssueTitle = ""
                showNewIssueForm = false
            }
        }
    }

    // MARK: - Inline Self-Hosted Plane Connection Card

    private var connectionSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connect Self-Hosted Plane.so")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Enter your self-hosted Plane instance URL, workspace slug, and Personal API Token (Profile Settings → API Tokens).")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Self-Hosted URL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    TextField("https://plane.yourdomain.com", text: $planeBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace Slug")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    TextField("e.g. my-team", text: $planeWorkspaceSlug)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 155)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Personal API Token (X-API-Key)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 8) {
                    SecureField("plane_api_...", text: $planeApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button {
                        showConnectionForm = false
                        Task { await store.refresh() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.system(size: 11))
                            Text("Save & Sync")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(store.isConfigured ? accentColor.opacity(0.85) : Color.white.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.isConfigured)
                }
            }

            if let err = store.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Empty & Error States

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Couldn't reach Plane instance")
                .font(.caption.bold())
                .foregroundStyle(.white)
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 20)
            HStack(spacing: 8) {
                Button {
                    showConnectionForm = true
                } label: {
                    Text("Edit Connection")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(emptyStateDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.onlyActiveCycle || store.onlyAssignedToMe {
                HStack(spacing: 8) {
                    if store.onlyActiveCycle {
                        Button {
                            store.onlyActiveCycle = false
                            store.selectedCycleId = ""
                        } label: {
                            Text("Show All Cycles")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if store.onlyAssignedToMe {
                        Button {
                            store.onlyAssignedToMe = false
                        } label: {
                            Text("Show Everyone's Tickets")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateDescription: String {
        if !store.searchText.isEmpty {
            return "No tickets match \"\(store.searchText)\""
        }
        var parts: [String] = []
        if store.onlyActiveCycle { parts.append(store.activeCycleLabel) }
        if store.onlyAssignedToMe { parts.append("Assigned to Me") }
        parts.append(store.stateFilter.rawValue)
        return "No tickets in \(parts.joined(separator: " · "))"
    }
}

// MARK: - Single Plane Ticket Row (Pure SwiftUI Inline State/Priority Bar — Zero AppKit NSMenu Hangs)

private struct PlaneIssueRow: View {
    let issue: PlaneIssue
    let projectStates: [PlaneStateItem]
    let assignedFolder: PlaneAssignedFolder?
    let assignedAgent: String
    let availableFolders: [PlaneWorkFolder]
    let agentPresets: [String]
    let isPickerOpen: Bool
    let isFolderPickerOpen: Bool
    let folderScope: PlaneFolderScope
    let accentColor: Color
    let onTogglePicker: () -> Void
    let onToggleFolderPicker: () -> Void
    let onSelectFolderScope: (PlaneFolderScope) -> Void
    let onAssignFolder: (String?) -> Void
    let onBrowseFolder: () -> Void
    let onSelectAgent: (String) -> Void
    let onLaunchAgent: () -> Void
    let onForceLaunchAgent: () -> Void
    let onSelectState: (PlaneStateItem) -> Void
    let onSelectPriority: (PlanePriority) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                // 1. Compact Issue Key Badge (Click to open in Plane)
                Button {
                    PlaneStore.shared.openInBrowser(issue)
                } label: {
                    Text(issue.issueKey)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(accentColor.opacity(0.14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(accentColor.opacity(0.35), lineWidth: 0.7)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Open \(issue.issueKey) in Self-Hosted Plane")
                .padding(.top, 0.5)

                // 2. Full-width multi-line wrapping Title (click to toggle inline status/details bar)
                Text(issue.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(1.2)
                    .lineLimit((isPickerOpen || isFolderPickerOpen) ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTogglePicker)
                    .help(issue.name)

                // 3. Compact Right-Side Controls (Pure SwiftUI Buttons — No NSMenu!)
                HStack(spacing: 4) {
                    // Priority Button (opens inline state/priority bar)
                    Button(action: onTogglePicker) {
                        Image(systemName: issue.priority.icon)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(issue.priority.color)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(issue.priority.color.opacity(0.14))
                                    .overlay(Circle().strokeBorder(issue.priority.color.opacity(0.35), lineWidth: 0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Priority: \(issue.priority.label) — click to change")

                    // State Pill Button (opens inline state/priority bar)
                    Button(action: onTogglePicker) {
                        HStack(spacing: 3) {
                            Image(systemName: issue.stateGroup.icon)
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(issue.stateName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(issue.stateGroup.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(issue.stateGroup.color.opacity(isPickerOpen ? 0.26 : 0.14))
                                .overlay(Capsule().strokeBorder(issue.stateGroup.color.opacity(isPickerOpen ? 0.65 : 0.36), lineWidth: 0.7))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("State: \(issue.stateName) — click to switch")

                    // Copy Git Branch Slug Icon Button
                    Button {
                        PlaneStore.shared.copyBranchSlug(issue)
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy git branch (\(issue.suggestedBranchName))")

                    // Working Folder Dropdown Pill (Assign folder to ticket or project before opening into Agent)
                    Button(action: onToggleFolderPicker) {
                        HStack(spacing: 3) {
                            Image(systemName: assignedFolder != nil ? "folder.fill" : "folder.badge.plus")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(assignedFolder?.name ?? "Folder")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: 68)
                            Image(systemName: isFolderPickerOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 6.5, weight: .bold))
                        }
                        .foregroundStyle(folderBadgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(folderBadgeColor.opacity(isFolderPickerOpen ? 0.24 : 0.12))
                                .overlay(
                                    Capsule().strokeBorder(
                                        folderBadgeColor.opacity(isFolderPickerOpen ? 0.65 : 0.32),
                                        lineWidth: 0.7
                                    )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(folderTooltip)

                    // Launch Coding Agent Icon Button
                    Button(action: onLaunchAgent) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.orange.opacity(0.16))
                                    .overlay(Circle().strokeBorder(Color.orange.opacity(0.38), lineWidth: 0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(
                        assignedFolder.map { "Open \(issue.issueKey) with \(assignedAgent) in \($0.displayPath)" }
                            ?? "Select a folder and launch Coding Agent for \(issue.issueKey)"
                    )
                }
            }

            // Inline Folder & Coding Agent Dropdown Bar (Appears when clicking Folder pill or Agent button when unassigned)
            if isFolderPickerOpen {
                VStack(alignment: .leading, spacing: 4) {
                    // Row 1: Scope (This Ticket vs Project) + Browse + Agent CLI selector + Open in Agent button
                    HStack(spacing: 5) {
                        Text("Assign to:")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(PlaneFolderScope.allCases) { sc in
                            let selected = folderScope == sc
                            let labelText = sc == .ticket ? "Ticket (\(issue.issueKey))" : "Project (\(issue.projectIdentifier))"
                            Button {
                                onSelectFolderScope(sc)
                            } label: {
                                Text(labelText)
                                    .font(.system(size: 9, weight: selected ? .bold : .medium))
                                    .foregroundStyle(selected ? .white : .secondary)
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(selected ? accentColor.opacity(0.32) : Color.white.opacity(0.06))
                                            .overlay(
                                                Capsule().strokeBorder(selected ? accentColor.opacity(0.6) : Color.clear, lineWidth: 0.7)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()
                            .frame(height: 11)
                            .overlay(Color.white.opacity(0.14))

                        // Agent CLI selector pills
                        Text("Agent:")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(agentPresets.prefix(4), id: \.self) { preset in
                            let isCurrentAgent = assignedAgent == preset
                            Button {
                                onSelectAgent(preset)
                            } label: {
                                Text(preset)
                                    .font(.system(size: 9, weight: isCurrentAgent ? .bold : .medium, design: .monospaced))
                                    .foregroundStyle(isCurrentAgent ? Color.orange : .white.opacity(0.68))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isCurrentAgent ? Color.orange.opacity(0.22) : Color.white.opacity(0.05))
                                            .overlay(
                                                Capsule().strokeBorder(isCurrentAgent ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 0.7)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 4)

                        // Launch Agent directly in the selected folder
                        Button(action: onForceLaunchAgent) {
                            HStack(spacing: 3.5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8.5, weight: .bold))
                                Text("Open in \(assignedAgent)")
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Row 2: Available Local Folders Dropdown List + Browse + Clear
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Text("Folder:")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Button(action: onBrowseFolder) {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 8.5, weight: .semibold))
                                    Text("Browse…")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(accentColor)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule()
                                        .fill(accentColor.opacity(0.15))
                                        .overlay(Capsule().strokeBorder(accentColor.opacity(0.45), lineWidth: 0.7))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Choose any local folder from Finder")

                            ForEach(availableFolders) { folder in
                                let isCurrentFolder = assignedFolder?.expandedPath == folder.expandedPath
                                Button {
                                    onAssignFolder(folder.expandedPath)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: isCurrentFolder ? "checkmark.circle.fill" : "folder.fill")
                                            .font(.system(size: 8))
                                        Text(folder.name)
                                            .font(.system(size: 9.5, weight: isCurrentFolder ? .bold : .medium))
                                    }
                                    .foregroundStyle(isCurrentFolder ? .white : .white.opacity(0.82))
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule()
                                            .fill(isCurrentFolder ? Color.cyan.opacity(0.32) : Color.white.opacity(0.06))
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    isCurrentFolder ? Color.cyan.opacity(0.8) : Color.white.opacity(0.1),
                                                    lineWidth: 0.7
                                                )
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(folder.displayPath)
                            }

                            if let assignedFolder, assignedFolder.isExplicit {
                                Button {
                                    onAssignFolder(nil)
                                } label: {
                                    Text("Clear")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Inline State & Priority Picker Bar (Appears when clicking state pill, priority badge, or title)
            if isPickerOpen {
                VStack(alignment: .leading, spacing: 4) {
                    // Workflow State Pills
                    if !projectStates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Text("State:")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(projectStates) { st in
                                    let isCurrent = st.id == issue.stateId
                                    Button {
                                        onSelectState(st)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: st.group.icon)
                                                .font(.system(size: 8))
                                            Text(st.name)
                                                .font(.system(size: 9.5, weight: isCurrent ? .bold : .medium))
                                        }
                                        .foregroundStyle(isCurrent ? .white : st.group.color)
                                        .padding(.horizontal, 6.5)
                                        .padding(.vertical, 2.5)
                                        .background(
                                            Capsule()
                                                .fill(isCurrent ? st.group.color.opacity(0.35) : Color.white.opacity(0.06))
                                                .overlay(
                                                    Capsule().strokeBorder(isCurrent ? st.group.color : Color.white.opacity(0.1), lineWidth: 0.7)
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Priority Pills + Ticket Metadata
                    HStack(spacing: 4) {
                        Text("Priority:")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ForEach(PlanePriority.allCases) { p in
                            let isCurrent = p == issue.priority
                            Button {
                                onSelectPriority(p)
                            } label: {
                                HStack(spacing: 2.5) {
                                    Image(systemName: p.icon)
                                        .font(.system(size: 7.5))
                                    Text(p.label)
                                        .font(.system(size: 9, weight: isCurrent ? .bold : .regular))
                                }
                                .foregroundStyle(isCurrent ? .white : p.color)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(isCurrent ? p.color.opacity(0.32) : Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 4)

                        if let cyc = issue.cycleName {
                            Text(cyc)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.orange.opacity(0.9))
                        }

                        Button {
                            PlaneStore.shared.copyIssueKey(issue)
                        } label: {
                            Text("Copy ID")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity((isPickerOpen || isFolderPickerOpen) ? 0.065 : 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((isPickerOpen || isFolderPickerOpen) ? accentColor.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1)
                )
        )
        .hoverHighlight(radius: 8)
    }

    private var folderBadgeColor: Color {
        guard let assignedFolder else {
            return Color.white.opacity(0.62)
        }
        if assignedFolder.isTicketSpecific {
            return Color.cyan
        }
        return accentColor
    }

    private var folderTooltip: String {
        guard let assignedFolder else {
            return "Assign a local folder for \(issue.issueKey) or \(issue.projectIdentifier) before opening in Coding Agent"
        }
        let scopeDesc = assignedFolder.isTicketSpecific ? "Ticket folder" : "Project folder"
        return "\(scopeDesc): \(assignedFolder.displayPath) — click to change folder or agent"
    }
}
