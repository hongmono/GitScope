import Foundation

enum GitBranchServiceError: LocalizedError {
    case localBranchRequired
    case tagRequired
    case detachedHead
    case rebaseOntoCurrentBranch(String)
    case rebaseInProgress
    case currentBranchNotDeletable(String)
    case branchNotMerged(String)
    case rebaseAborted(String)
    case rebaseNeedsAttention(String)

    var errorDescription: String? {
        switch self {
        case .localBranchRequired:
            return "로컬 브랜치에서만 사용할 수 있습니다."
        case .tagRequired:
            return "태그에서만 사용할 수 있습니다."
        case .detachedHead:
            return "체크아웃된 브랜치가 없습니다(detached HEAD). 먼저 브랜치를 체크아웃해주세요."
        case .rebaseOntoCurrentBranch(let name):
            return "'\(name)'은 지금 체크아웃된 브랜치라서 자기 자신 위로 rebase할 수 없습니다."
        case .rebaseInProgress:
            return "진행 중인 rebase를 먼저 완료하거나 중단해주세요."
        case .currentBranchNotDeletable(let name):
            return "'\(name)'은 지금 체크아웃된 브랜치라서 삭제할 수 없습니다."
        case .branchNotMerged(let name):
            return "'\(name)'에는 병합되지 않은 커밋이 있습니다."
        case .rebaseAborted(let message):
            return "충돌로 rebase를 완료하지 못해 변경을 되돌렸습니다.\n\n\(message)"
        case .rebaseNeedsAttention(let message):
            return "rebase가 중단되었고 자동으로 되돌리지 못했습니다. 터미널에서 `git rebase --continue` 또는 `git rebase --abort`를 실행해주세요.\n\n\(message)"
        }
    }
}

/// 로컬 저장소만 건드리는 브랜치·태그 조작.
///
/// 네트워크를 타는 연산은 `GitRemoteService` 가 맡는다. 두 서비스는 각자
/// `GitCommandRunner` 인스턴스를 갖고, 저장소를 바꾸는 명령은 모두 `exclusive` 로 실행해
/// 같은 저장소의 다른 쓰기 명령과 겹치지 않게 한다.
actor GitBranchService {
    private let runner = GitCommandRunner()

    /// 로컬 저장소만 건드리는 쓰기 명령의 상한. 큰 저장소의 rebase 도 여기 안에서 끝난다.
    private static let localWriteTimeout: TimeInterval = 60

    /// 지금 체크아웃된 브랜치를 `reference` 위로 rebase 한다.
    ///
    /// 어떤 실패 경로에서도 저장소를 rebase 중간 상태로 남기지 않는 것이 원칙이다.
    /// 충돌이 나면 곧바로 `rebase --abort` 로 되돌리고, abort 조차 실패한 경우에만
    /// 터미널에서 직접 정리하라고 안내한다.
    func rebase(repository: GitRepository, ontoReference reference: GitReference) async throws {
        let currentBranch = try? await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            maximumBytes: 4_096
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentBranch, !currentBranch.isEmpty else {
            throw GitBranchServiceError.detachedHead
        }
        guard currentBranch != reference.shortName else {
            throw GitBranchServiceError.rebaseOntoCurrentBranch(reference.shortName)
        }
        guard !(await runner.isRebaseInProgress(repositoryURL: repository.rootURL)) else {
            throw GitBranchServiceError.rebaseInProgress
        }

        do {
            _ = try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: ["-c", "color.ui=false", "rebase", reference.fullName],
                timeout: Self.localWriteTimeout,
                exclusive: true
            )
        } catch {
            let originalMessage = error.localizedDescription
            switch await runner.recoverFromFailedRebase(
                repositoryURL: repository.rootURL,
                timeout: Self.localWriteTimeout
            ) {
            case .notInRebase:
                // 더러운 워킹 트리처럼 rebase 를 시작하지도 못한 경우. 저장소는 그대로다.
                throw error
            case .aborted:
                throw GitBranchServiceError.rebaseAborted(originalMessage)
            case .abortFailed:
                throw GitBranchServiceError.rebaseNeedsAttention(originalMessage)
            }
        }
    }

    /// 로컬 브랜치를 삭제한다.
    ///
    /// - Parameter force: `-d` 대신 `-D`. 미병합 브랜치를 지우려면 UI 가 한 번 더 확인을
    ///   받은 뒤에만 참으로 넘긴다. 미병합 여부는 `-d` 를 실제로 시도해야 알 수 있으므로,
    ///   `-d` 가 그 이유로 실패하면 `branchNotMerged` 로 옮겨 담아 재확인 경로를 연다.
    func deleteLocalBranch(
        repository: GitRepository,
        reference: GitReference,
        force: Bool
    ) async throws {
        guard reference.kind == .local else {
            throw GitBranchServiceError.localBranchRequired
        }
        guard !reference.isCurrent else {
            throw GitBranchServiceError.currentBranchNotDeletable(reference.shortName)
        }

        do {
            _ = try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: [
                    "-c", "color.ui=false",
                    "branch", force ? "-D" : "-d",
                    reference.shortName
                ],
                timeout: Self.localWriteTimeout,
                exclusive: true
            )
        } catch let error as GitCommandError {
            guard !force,
                  case .commandFailed(_, _, let message) = error,
                  // 실행기가 `LC_ALL=C` 를 걸어 두므로 git 메시지는 항상 영어다.
                  message.contains("not fully merged") else {
                throw error
            }
            throw GitBranchServiceError.branchNotMerged(reference.shortName)
        }
    }

    func deleteLocalTag(repository: GitRepository, reference: GitReference) async throws {
        guard reference.kind == .tag else {
            throw GitBranchServiceError.tagRequired
        }
        _ = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["-c", "color.ui=false", "tag", "-d", reference.shortName],
            timeout: Self.localWriteTimeout,
            exclusive: true
        )
    }
}
