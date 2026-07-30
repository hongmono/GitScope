import Foundation

enum GitRemoteServiceError: LocalizedError {
    case localBranchRequired
    case currentBranchRequired
    case upstreamRequired
    case upstreamGone(String)
    case remoteOperationInProgress
    case unsupportedUpstream(String)
    case rebaseAborted(String)
    case rebaseNeedsAttention(String)
    case checkedOutBranchNotFastForwardable
    case upstreamAlreadySet(String)
    case remoteRequired
    case remoteBranchRequired
    case unsupportedRemoteBranchName(String)
    case fastForwardUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .localBranchRequired:
            return "로컬 브랜치에서만 사용할 수 있습니다."
        case .currentBranchRequired:
            return "Pull은 현재 체크아웃된 브랜치에서만 사용할 수 있습니다."
        case .upstreamRequired:
            return "먼저 이 브랜치의 upstream을 설정해주세요."
        case .upstreamGone(let name):
            return "upstream '\(name)'을 찾을 수 없습니다. 원격 브랜치가 삭제되었는지 확인해주세요."
        case .remoteOperationInProgress:
            return "진행 중인 rebase를 먼저 완료하거나 중단해주세요."
        case .unsupportedUpstream(let name):
            return "upstream '\(name)'은 Push 대상으로 사용할 수 없습니다."
        case .rebaseAborted(let message):
            return "Pull 중 rebase를 완료하지 못해 변경을 되돌렸습니다.\n\n\(message)"
        case .rebaseNeedsAttention(let message):
            return "Pull 중 rebase가 중단되었고 자동으로 되돌리지 못했습니다. 터미널에서 `git rebase --continue` 또는 `git rebase --abort`를 실행해주세요.\n\n\(message)"
        case .checkedOutBranchNotFastForwardable:
            return "체크아웃된 브랜치에는 Fast-Forward Pull을 쓸 수 없습니다. Pull(Rebase)을 사용해주세요."
        case .upstreamAlreadySet(let name):
            return "이 브랜치에는 이미 upstream '\(name)'이 설정돼 있습니다."
        case .remoteRequired:
            return "이 저장소에 설정된 원격이 없습니다. 먼저 원격을 추가해주세요."
        case .remoteBranchRequired:
            return "원격 브랜치에서만 사용할 수 있습니다."
        case .unsupportedRemoteBranchName(let name):
            return "원격 브랜치 이름 '\(name)'에서 원격 이름을 알아낼 수 없습니다."
        case .fastForwardUnavailable(let message):
            return "fast-forward할 수 없습니다. 체크아웃 후 Pull(Rebase)을 사용해주세요.\n\n\(message)"
        }
    }
}

actor GitRemoteService {
    private let runner = GitCommandRunner()

    /// 네트워크를 타는 명령이 응답 없는 원격에 매달리지 않도록 두는 상한.
    private static let networkTimeout: TimeInterval = 120
    /// 로컬 저장소만 건드리는 복구 명령의 상한.
    private static let localWriteTimeout: TimeInterval = 60

    func fetchAll(repository: GitRepository) async throws {
        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["-c", "color.ui=false", "fetch", "--all"],
            timeout: Self.networkTimeout,
            exclusive: true
        )
    }

    /// `fetch --all` 을 실행하고 원격 ref 가 실제로 바뀌었는지 알려준다.
    ///
    /// 자동 fetch 는 변화가 있을 때만 화면을 다시 그리기 위해 이 값을 쓴다. 스냅샷을
    /// 읽지 못하면 변화가 있다고 보고 갱신에 맡긴다.
    func fetchAllDetectingChanges(repository: GitRepository) async throws -> Bool {
        let before = try? await remoteReferenceSnapshot(repository: repository)
        try await fetchAll(repository: repository)
        guard let before,
              let after = try? await remoteReferenceSnapshot(repository: repository) else {
            return true
        }
        return before != after
    }

    private func remoteReferenceSnapshot(repository: GitRepository) async throws -> String {
        try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "for-each-ref",
                "--format=%(objectname) %(refname)",
                "refs/remotes",
                "refs/tags"
            ]
        )
    }

    func pullRebase(repository: GitRepository, reference: GitReference) async throws {
        guard reference.kind == .local else {
            throw GitRemoteServiceError.localBranchRequired
        }
        guard reference.isCurrent else {
            throw GitRemoteServiceError.currentBranchRequired
        }
        let tracking = try tracking(for: reference)
        guard !tracking.isGone else {
            throw GitRemoteServiceError.upstreamGone(tracking.upstreamShortName)
        }

        let currentBranch = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == reference.shortName else {
            throw GitRemoteServiceError.currentBranchRequired
        }
        guard !(await runner.isRebaseInProgress(repositoryURL: repository.rootURL)) else {
            throw GitRemoteServiceError.remoteOperationInProgress
        }

        do {
            _ = try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: ["-c", "color.ui=false", "pull", "--rebase"],
                timeout: Self.networkTimeout,
                exclusive: true
            )
        } catch {
            let originalMessage = error.localizedDescription
            switch await runner.recoverFromFailedRebase(
                repositoryURL: repository.rootURL,
                timeout: Self.localWriteTimeout
            ) {
            case .notInRebase:
                throw error
            case .aborted:
                throw GitRemoteServiceError.rebaseAborted(originalMessage)
            case .abortFailed:
                throw GitRemoteServiceError.rebaseNeedsAttention(originalMessage)
            }
        }
    }

    func push(repository: GitRepository, reference: GitReference) async throws {
        guard reference.kind == .local else {
            throw GitRemoteServiceError.localBranchRequired
        }
        let tracking = try tracking(for: reference)
        guard !tracking.isGone else {
            throw GitRemoteServiceError.upstreamGone(tracking.upstreamShortName)
        }
        guard !tracking.remoteName.isEmpty,
              tracking.remoteName != ".",
              tracking.remoteRef.hasPrefix("refs/heads/") else {
            throw GitRemoteServiceError.unsupportedUpstream(tracking.upstreamShortName)
        }

        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "push", "--porcelain",
                tracking.remoteName,
                "\(reference.fullName):\(tracking.remoteRef)"
            ],
            timeout: Self.networkTimeout,
            exclusive: true
        )
    }

    /// 체크아웃되지 않은 로컬 브랜치를 원격과 fast-forward 로 맞춘다.
    ///
    /// `git fetch <remote> <remoteRef>:<localRef>` 는 `+` 없는 refspec 이라 fast-forward 가
    /// 아니면 git 이 거절한다. 이 명령은 체크아웃된 브랜치를 대상으로는 거부되므로
    /// 현재 브랜치는 애초에 대상에서 제외한다(그쪽은 Pull(Rebase) 경로다).
    func fastForwardFetch(repository: GitRepository, reference: GitReference) async throws {
        guard reference.kind == .local else {
            throw GitRemoteServiceError.localBranchRequired
        }
        guard !reference.isCurrent else {
            throw GitRemoteServiceError.checkedOutBranchNotFastForwardable
        }
        let tracking = try tracking(for: reference)
        guard !tracking.isGone else {
            throw GitRemoteServiceError.upstreamGone(tracking.upstreamShortName)
        }
        guard !tracking.remoteName.isEmpty,
              tracking.remoteName != ".",
              tracking.remoteRef.hasPrefix("refs/heads/") else {
            throw GitRemoteServiceError.unsupportedUpstream(tracking.upstreamShortName)
        }

        do {
            _ = try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: [
                    "-c", "color.ui=false",
                    "fetch",
                    tracking.remoteName,
                    "\(tracking.remoteRef):\(reference.fullName)"
                ],
                timeout: Self.networkTimeout,
                exclusive: true
            )
        } catch {
            guard case GitCommandError.commandFailed(_, _, let message) = error,
                  Self.isNonFastForwardRejection(message) else {
                throw error
            }
            throw GitRemoteServiceError.fastForwardUnavailable(message)
        }
    }

    /// 원격이 refspec 을 fast-forward 아님으로 거절했는지 본다.
    ///
    /// 인증 실패나 원격 없음 같은 다른 실패까지 "체크아웃 후 Pull 하세요"로 안내하면
    /// 사용자를 엉뚱한 곳으로 보내므로, 거절 사유가 실제로 그것일 때만 바꿔 담는다.
    private static func isNonFastForwardRejection(_ message: String) -> Bool {
        message.contains("non-fast-forward") || message.contains("non-fast forward")
    }

    /// upstream 이 없는 로컬 브랜치를 원격에 게시하고 추적까지 걸어 둔다.
    ///
    /// - Parameter remoteName: 지정하지 않으면 저장소의 원격 목록에서 고른다(`origin` 우선).
    func publish(
        repository: GitRepository,
        reference: GitReference,
        remoteName: String? = nil
    ) async throws {
        guard reference.kind == .local else {
            throw GitRemoteServiceError.localBranchRequired
        }
        if let tracking = reference.tracking, !tracking.isGone {
            throw GitRemoteServiceError.upstreamAlreadySet(tracking.upstreamShortName)
        }

        let remote = try await resolveRemoteName(remoteName, repository: repository)
        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "push", "--porcelain", "-u",
                remote,
                "\(reference.fullName):refs/heads/\(reference.shortName)"
            ],
            timeout: Self.networkTimeout,
            exclusive: true
        )
    }

    /// 원격 브랜치를 원격에서 지운다.
    ///
    /// 원격 이름은 `origin/feature/x` 처럼 생긴 `shortName` 의 첫 `/` 앞부분이다.
    /// 브랜치 이름 자체에도 `/` 가 들어가므로 첫 구분자에서만 자른다.
    func deleteRemoteBranch(repository: GitRepository, reference: GitReference) async throws {
        guard reference.kind == .remote else {
            throw GitRemoteServiceError.remoteBranchRequired
        }
        guard let separator = reference.shortName.firstIndex(of: "/") else {
            throw GitRemoteServiceError.unsupportedRemoteBranchName(reference.shortName)
        }
        let remote = String(reference.shortName[..<separator])
        let branch = String(reference.shortName[reference.shortName.index(after: separator)...])
        guard !remote.isEmpty, !branch.isEmpty else {
            throw GitRemoteServiceError.unsupportedRemoteBranchName(reference.shortName)
        }

        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "push", "--porcelain",
                remote, "--delete", branch
            ],
            timeout: Self.networkTimeout,
            exclusive: true
        )
    }

    /// 태그를 원격에서 지운다. 로컬 태그는 `GitBranchService` 가 따로 지운다.
    func deleteRemoteTag(
        repository: GitRepository,
        tagName: String,
        remoteName: String? = nil
    ) async throws {
        let remote = try await resolveRemoteName(remoteName, repository: repository)
        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "push", "--porcelain",
                remote, "--delete", "refs/tags/\(tagName)"
            ],
            timeout: Self.networkTimeout,
            exclusive: true
        )
    }

    /// 호출자가 원격을 지정하지 않았으면 저장소의 원격 목록에서 고른다.
    ///
    /// `origin` 이 있으면 그것, 없으면 첫 항목이다. 원격이 하나도 없으면 실패한다.
    private func resolveRemoteName(
        _ remoteName: String?,
        repository: GitRepository
    ) async throws -> String {
        if let remoteName, !remoteName.isEmpty { return remoteName }
        let names = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["remote"],
            maximumBytes: 64_000
        )
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

        guard let remote = names.first(where: { $0 == "origin" }) ?? names.first else {
            throw GitRemoteServiceError.remoteRequired
        }
        return remote
    }

    private func tracking(for reference: GitReference) throws -> GitBranchTracking {
        guard let tracking = reference.tracking else {
            throw GitRemoteServiceError.upstreamRequired
        }
        return tracking
    }
}
