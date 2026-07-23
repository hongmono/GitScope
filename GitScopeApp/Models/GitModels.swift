import Foundation
import SwiftUI

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

struct GraphRowLayout: Sendable, Hashable {
    let nodeLane: Int
    let incomingLanes: [Int]
    let passThroughLanes: [Int]
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
