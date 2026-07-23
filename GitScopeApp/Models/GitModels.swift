import Foundation
import SwiftUI

struct WorkspaceTab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let paths: [String]

    init(id: UUID = UUID(), paths: [String]) {
        self.id = id
        self.paths = paths
    }

    var title: String {
        guard let firstPath = paths.first else { return "워크스페이스" }
        let firstName = URL(fileURLWithPath: firstPath).lastPathComponent
        return paths.count == 1 ? firstName : "\(firstName) 외 \(paths.count - 1)"
    }

    var subtitle: String {
        paths.joined(separator: "\n")
    }
}

struct RepositoryID: Hashable, Sendable, Codable, Identifiable {
    let rawValue: String
    var id: String { rawValue }
}

struct CommitID: Hashable, Sendable, Codable, Identifiable {
    let repositoryID: RepositoryID
    let oid: String

    var id: String { "\(repositoryID.rawValue)::\(oid)" }
}

struct GitRepository: Identifiable, Hashable, Sendable {
    let id: RepositoryID
    let name: String
    let rootURL: URL
    let colorIndex: Int
    let githubRepository: GitHubRepository?
}

struct GitReference: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case local
        case remote
        case tag
    }

    let repositoryID: RepositoryID
    let fullName: String
    let shortName: String
    let targetOID: String
    let kind: Kind
    let isCurrent: Bool
    let tracking: GitBranchTracking?

    var id: String { "\(repositoryID.rawValue)::\(fullName)" }
}

struct GitBranchTracking: Hashable, Sendable {
    let upstreamFullName: String
    let upstreamShortName: String
    let remoteName: String
    let remoteRef: String
    let aheadCount: Int
    let behindCount: Int
    let isGone: Bool
}

enum GitRemoteOperationKind: String, Sendable {
    case fetch
    case pull
    case push
}

struct GitRemoteOperation: Equatable, Sendable {
    let repositoryID: RepositoryID
    let referenceID: String
    let kind: GitRemoteOperationKind
}

struct MergedReferenceGroup: Identifiable, Hashable, Sendable {
    let kind: GitReference.Kind
    let shortName: String
    let references: [GitReference]

    var id: String { "\(kind.rawValue)::\(shortName)" }
    var isCurrent: Bool { references.contains(where: \.isCurrent) }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let id: CommitID
    let parentOIDs: [String]
    let subject: String
    let body: String
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerDate: Date
    let references: [GitReference]
    let isHead: Bool
    let isWorkingTree: Bool

    var shortOID: String { String(id.oid.prefix(8)) }
}

struct RepositorySnapshot: Sendable {
    let repository: GitRepository
    let references: [GitReference]
    let commits: [GitCommit]
}

struct WorkspaceSnapshot: Sendable {
    let repositories: [GitRepository]
    let referencesByRepository: [RepositoryID: [GitReference]]
    let commits: [GitCommit]
}

struct ChangedFile: Identifiable, Hashable, Sendable {
    let status: String
    let path: String
    let diffPaths: [String]
    var id: String { "\(status)::\(path)" }
}

struct CommitDetails: Sendable {
    let commit: GitCommit
    let files: [ChangedFile]
}

struct GitHubRepository: Hashable, Sendable {
    let owner: String
    let name: String

    var webURL: URL {
        URL(string: "https://github.com/\(owner)/\(name)")!
    }

    var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)")!
    }

    init?(remoteURL: String) {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path: String
        if let scpSeparator = trimmed.firstIndex(of: ":"),
           !trimmed.contains("://"),
           trimmed[..<scpSeparator].contains("@") {
            let hostStart = trimmed.index(after: trimmed.firstIndex(of: "@")!)
            let host = trimmed[hostStart..<scpSeparator]
            guard host.caseInsensitiveCompare("github.com") == .orderedSame else {
                return nil
            }
            path = String(trimmed[trimmed.index(after: scpSeparator)...])
        } else {
            guard let components = URLComponents(string: trimmed),
                  components.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
                return nil
            }
            path = components.path
        }

        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let repositoryName = parts[1].hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        guard !parts[0].isEmpty, !repositoryName.isEmpty else { return nil }

        owner = parts[0]
        name = repositoryName
    }
}

enum GitHubActionsState: String, Hashable, Sendable {
    case queued
    case inProgress
    case success
    case failure
    case cancelled
    case neutral
    case unknown

    var isActive: Bool {
        self == .queued || self == .inProgress
    }
}

struct GitHubWorkflowRun: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let displayTitle: String
    let headSHA: String
    let pullRequestHeadSHAs: [String]
    let headBranch: String?
    let event: String
    let status: String
    let conclusion: String?
    let webURL: URL
    let runNumber: Int
    let runAttempt: Int
    let updatedAt: Date

    var state: GitHubActionsState {
        GitHubActionsState(status: status, conclusion: conclusion)
    }
}

struct GitHubActionsSummary: Hashable, Sendable {
    let commitID: CommitID
    let repository: GitHubRepository
    let runs: [GitHubWorkflowRun]

    var state: GitHubActionsState {
        GitHubActionsState.aggregate(runs.map(\.state))
    }

    var primaryURL: URL? {
        runs.first(where: { $0.state.isActive })?.webURL
            ?? runs.first(where: { $0.state == .failure })?.webURL
            ?? runs.first?.webURL
    }
}

struct GitHubCheckRun: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let webURL: URL?
    let appName: String?
    let startedAt: Date?
    let completedAt: Date?

    var state: GitHubActionsState {
        GitHubActionsState(status: status, conclusion: conclusion)
    }
}

extension GitHubActionsState {
    init(status: String, conclusion: String?) {
        switch status {
        case "queued", "requested", "waiting", "pending":
            self = .queued
        case "in_progress":
            self = .inProgress
        case "completed":
            switch conclusion {
            case "success":
                self = .success
            case "failure", "timed_out", "action_required", "stale":
                self = .failure
            case "cancelled":
                self = .cancelled
            case "neutral", "skipped":
                self = .neutral
            default:
                self = .unknown
            }
        default:
            self = .unknown
        }
    }

    static func aggregate(_ states: [GitHubActionsState]) -> GitHubActionsState {
        if states.contains(.inProgress) { return .inProgress }
        if states.contains(.queued) { return .queued }
        if states.contains(.failure) { return .failure }
        if states.contains(.cancelled) { return .cancelled }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.success) { return .success }
        if states.contains(.neutral) { return .neutral }
        return .unknown
    }
}

struct GraphLaneConnection: Sendable, Hashable {
    let incomingLane: Int
    let outgoingLane: Int
}

struct GraphRowLayout: Sendable, Hashable {
    let nodeLane: Int
    let incomingLanes: [Int]
    let passThroughConnections: [GraphLaneConnection]
    let parentLanes: [Int]
    let laneCount: Int

    var isBranchPoint: Bool { incomingLanes.count > 1 }
}

struct CommitRow: Identifiable, Hashable, Sendable {
    let commit: GitCommit
    let graph: GraphRowLayout
    var id: CommitID { commit.id }
}

enum HistoryDateScope: String, CaseIterable, Identifiable {
    case all = "전체"
    case today = "오늘"
    case sevenDays = "최근 7일"
    case thirtyDays = "최근 30일"

    var id: String { rawValue }

    func includes(_ date: Date, now: Date = .now) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            return date >= calendar.date(byAdding: .day, value: -7, to: now)!
        case .thirtyDays:
            return date >= calendar.date(byAdding: .day, value: -30, to: now)!
        }
    }
}

enum AppPalette {
    static let repositoryColors: [Color] = [
        Color(red: 0.35, green: 0.43, blue: 0.90),
        Color(red: 0.25, green: 0.65, blue: 0.45),
        Color(red: 0.92, green: 0.40, blue: 0.46),
        Color(red: 0.30, green: 0.66, blue: 0.78),
        Color(red: 0.65, green: 0.42, blue: 0.86)
    ]

    static let repositoryBackgrounds: [Color] = [
        Color(red: 0.92, green: 0.92, blue: 0.99),
        Color(red: 0.89, green: 0.97, blue: 0.91),
        Color(red: 1.00, green: 0.90, blue: 0.92),
        Color(red: 0.89, green: 0.96, blue: 0.98),
        Color(red: 0.95, green: 0.91, blue: 0.99)
    ]

    static let graphColors: [Color] = [
        Color(red: 0.00, green: 0.72, blue: 0.84),
        Color(red: 0.10, green: 0.47, blue: 0.96),
        Color(red: 0.55, green: 0.20, blue: 0.92),
        Color(red: 0.83, green: 0.13, blue: 0.76),
        Color(red: 0.96, green: 0.45, blue: 0.17),
        Color(red: 0.16, green: 0.72, blue: 0.46)
    ]

    static let avatarColors: [Color] = [
        Color(red: 0.31, green: 0.72, blue: 0.68),
        Color(red: 0.25, green: 0.56, blue: 0.86),
        Color(red: 0.57, green: 0.43, blue: 0.82),
        Color(red: 0.88, green: 0.43, blue: 0.39),
        Color(red: 0.85, green: 0.63, blue: 0.25),
        Color(red: 0.29, green: 0.64, blue: 0.44)
    ]
}
