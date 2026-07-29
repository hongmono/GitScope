import Foundation

enum TestFixtures {
    static let repositoryID = RepositoryID(rawValue: "/tmp/fixture-repo")

    static func commit(
        _ oid: String,
        parents: [String] = [],
        repositoryID: RepositoryID = TestFixtures.repositoryID,
        committerDate: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GitCommit {
        GitCommit(
            id: CommitID(repositoryID: repositoryID, oid: oid),
            parentOIDs: parents,
            subject: "commit \(oid)",
            body: "",
            authorName: "Tester",
            authorEmail: "tester@example.com",
            authorDate: committerDate,
            committerDate: committerDate,
            references: [],
            isHead: false,
            isWorkingTree: false
        )
    }

    static func reference(
        _ shortName: String,
        kind: GitReference.Kind = .local,
        repositoryID: RepositoryID = TestFixtures.repositoryID,
        isCurrent: Bool = false,
        tracking: GitBranchTracking? = nil
    ) -> GitReference {
        GitReference(
            repositoryID: repositoryID,
            fullName: fullReferenceName(shortName, kind: kind),
            shortName: shortName,
            targetOID: "0123456789abcdef",
            kind: kind,
            isCurrent: isCurrent,
            tracking: tracking
        )
    }

    static func fullReferenceName(_ shortName: String, kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "refs/heads/\(shortName)"
        case .remote: return "refs/remotes/\(shortName)"
        case .tag: return "refs/tags/\(shortName)"
        }
    }

    /// NUL 로 구분된 git 출력 데이터를 만든다. 마지막 필드 뒤에도 NUL 이 붙는
    /// 실제 git `-z` 출력과 같은 형태다.
    static func nulSeparatedData(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            data.append(contentsOf: Array(field.utf8))
            data.append(0)
        }
        return data
    }
}
