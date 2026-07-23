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
                arguments: ["-c", "color.ui=false", "pull", "--rebase"]
            )
        } catch {
            if await isRebaseInProgress(repository: repository) {
                let originalMessage = error.localizedDescription
                do {
                    _ = try await runner.runText(
                        repositoryURL: repository.rootURL,
                        arguments: ["rebase", "--abort"]
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
            ]
        )
    }

    private func tracking(for reference: GitReference) throws -> GitBranchTracking {
        guard let tracking = reference.tracking else {
            throw GitRemoteServiceError.upstreamRequired
        }
        return tracking
    }

    private func isRebaseInProgress(repository: GitRepository) async -> Bool {
        (try? await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["rev-parse", "--verify", "REBASE_HEAD"],
            maximumBytes: 1_024
        )) != nil
    }
}
