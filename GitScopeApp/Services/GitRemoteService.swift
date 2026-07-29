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
        guard !(await isRebaseInProgress(repository: repository)) else {
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
            if await isRebaseInProgress(repository: repository) {
                let originalMessage = error.localizedDescription
                do {
                    _ = try await runner.runText(
                        repositoryURL: repository.rootURL,
                        arguments: ["rebase", "--abort"],
                        timeout: Self.localWriteTimeout,
                        exclusive: true
                    )
                    throw GitRemoteServiceError.rebaseAborted(originalMessage)
                } catch let serviceError as GitRemoteServiceError {
                    throw serviceError
                } catch {
                    throw GitRemoteServiceError.rebaseNeedsAttention(originalMessage)
                }
            }
            throw error
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

    private func tracking(for reference: GitReference) throws -> GitBranchTracking {
        guard let tracking = reference.tracking else {
            throw GitRemoteServiceError.upstreamRequired
        }
        return tracking
    }

    /// rebase 가 지금 진행 중인지 본다.
    ///
    /// `REBASE_HEAD` 는 rebase 가 정상적으로 끝난 뒤에도 남아 있어 판정에 쓸 수 없다.
    /// 실제로 진행 중일 때만 존재하는 `rebase-merge`·`rebase-apply` 디렉터리로 확인한다.
    /// 경로는 `--git-path` 로 물어봐 worktree 나 분리된 gitdir 에서도 맞게 나온다.
    private func isRebaseInProgress(repository: GitRepository) async -> Bool {
        for stateDirectory in ["rebase-merge", "rebase-apply"] {
            guard let path = try? await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: ["rev-parse", "--git-path", stateDirectory],
                maximumBytes: 4_096
            ).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                continue
            }

            // 상대 경로로 나오면 git 을 실행한 저장소 루트 기준이다.
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : repository.rootURL.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }
        }
        return false
    }
}
