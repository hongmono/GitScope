import Foundation

enum GitCommandError: LocalizedError {
    case launchFailed(String)
    case commandFailed(arguments: [String], status: Int32, message: String)
    case outputTooLarge(limit: Int)
    case timedOut(seconds: TimeInterval)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Git을 실행할 수 없습니다: \(message)"
        case .commandFailed(_, _, let message):
            return message.isEmpty ? "Git 명령 실행에 실패했습니다." : message
        case .outputTooLarge(let limit):
            return "Git 출력이 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) 제한을 초과했습니다. 더 좁은 필터를 적용해주세요."
        case .timedOut(let seconds):
            return "Git 명령이 \(Self.secondsText(seconds))초 안에 끝나지 않아 중단했습니다. 네트워크 상태를 확인해주세요."
        case .invalidPath(let path):
            return "파일 경로를 UTF-8 로 해석할 수 없어 diff 를 표시할 수 없습니다: \(path)"
        }
    }

    /// 30.0 은 "30", 1.5 는 "1.5" 로 보여주기 위한 표기.
    private static func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }
}

/// 프로세스 종료를 async 로 기다리기 위한 신호.
///
/// `Process.terminationHandler` 는 임의의 스레드에서 불리고, 기다리는 쪽보다 먼저
/// 불릴 수도 있다. 잠금으로 상태를 지켜 `finish()` 와 `wait()` 의 순서에 관계없이
/// 정확히 한 번씩만 재개되도록 한다.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// `Process` 는 Sendable 이 아니라서 취소 핸들러·자식 태스크로 넘기려면 상자가 필요하다.
private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    /// 아직 살아 있을 때만 SIGTERM 을 보낸다. 이미 끝난 프로세스에는 아무것도 하지 않는다.
    func terminateIfRunning() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// 저장소 단위로 쓰기 명령을 한 줄로 세우는 게이트.
///
/// fetch/pull/push 처럼 저장소를 건드리는 명령이 겹치면 git 이 index.lock 을 두고
/// 충돌한다. `exclusive` 로 실행하는 명령만 저장소 경로 기준으로 순서를 지키게 하고,
/// 읽기 전용 명령은 게이트를 거치지 않아 그대로 병렬로 돈다.
actor GitRepositoryCommandGate {
    static let shared = GitRepositoryCommandGate()

    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// 저장소 소유권을 얻는다. 이미 사용 중이면 FIFO 대기열에 선다.
    func acquire(_ path: String) async {
        guard busy.contains(path) else {
            busy.insert(path)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[path, default: []].append(continuation)
        }
    }

    /// 소유권을 내려놓는다. 대기자가 있으면 `busy` 를 유지한 채 첫 대기자에게 그대로 넘긴다.
    func release(_ path: String) {
        guard var queue = waiters[path], !queue.isEmpty else {
            busy.remove(path)
            waiters[path] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[path] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

/// git 명령 하나를 실행하고 표준 출력을 돌려주는 실행기.
///
/// 상태가 없어 값 타입으로 두고, 명령 사이의 직렬화는 필요할 때만
/// `GitRepositoryCommandGate` 로 저장소 단위로 건다.
struct GitCommandRunner: Sendable {
    private let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// 프로세스 종료 대기의 결말.
    private enum WaitOutcome {
        case exited
        case timedOut
    }

    /// git 명령을 실행하고 표준 출력을 그대로 돌려준다.
    ///
    /// - Parameters:
    ///   - maximumBytes: 표준 출력 상한. 넘으면 읽지 않고 `outputTooLarge` 를 던진다.
    ///   - timeout: 지정하면 이 시간 안에 끝나지 않은 프로세스를 종료하고 `timedOut` 을 던진다.
    ///   - exclusive: 저장소를 수정하는 명령에 쓴다. 같은 저장소의 다른 exclusive 명령과 겹치지 않는다.
    func runData(
        repositoryURL: URL,
        arguments: [String],
        maximumBytes: Int = 12_000_000,
        timeout: TimeInterval? = nil,
        exclusive: Bool = false
    ) async throws -> Data {
        guard exclusive else {
            return try await execute(
                repositoryURL: repositoryURL,
                arguments: arguments,
                maximumBytes: maximumBytes,
                timeout: timeout
            )
        }

        let gateKey = repositoryURL.standardizedFileURL.path
        await GitRepositoryCommandGate.shared.acquire(gateKey)
        do {
            let data = try await execute(
                repositoryURL: repositoryURL,
                arguments: arguments,
                maximumBytes: maximumBytes,
                timeout: timeout
            )
            await GitRepositoryCommandGate.shared.release(gateKey)
            return data
        } catch {
            await GitRepositoryCommandGate.shared.release(gateKey)
            throw error
        }
    }

    func runText(
        repositoryURL: URL,
        arguments: [String],
        maximumBytes: Int = 12_000_000,
        timeout: TimeInterval? = nil,
        exclusive: Bool = false
    ) async throws -> String {
        String(
            decoding: try await runData(
                repositoryURL: repositoryURL,
                arguments: arguments,
                maximumBytes: maximumBytes,
                timeout: timeout,
                exclusive: exclusive
            ),
            as: UTF8.self
        )
    }

    private func execute(
        repositoryURL: URL,
        arguments: [String],
        maximumBytes: Int,
        timeout: TimeInterval?
    ) async throws -> Data {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent("gitscope-output-\(token)")
        let errorURL = fileManager.temporaryDirectory.appendingPathComponent("gitscope-error-\(token)")

        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw GitCommandError.launchFailed("임시 출력 파일을 만들 수 없습니다.")
        }

        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = repositoryURL
        process.arguments = ["--no-pager", "-C", repositoryURL.path] + arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        // 종료 신호를 놓치지 않도록 실행 전에 핸들러를 건다.
        let exitSignal = ExitSignal()
        process.terminationHandler = { _ in exitSignal.finish() }
        let processBox = ProcessBox(process)

        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        let outcome = await withTaskCancellationHandler {
            await waitForExit(signal: exitSignal, process: processBox, timeout: timeout)
        } onCancel: {
            processBox.terminateIfRunning()
        }

        // 취소로 대기가 끝난 경우를 타임아웃으로 오해하지 않는다.
        if Task.isCancelled {
            processBox.terminateIfRunning()
            throw CancellationError()
        }
        if outcome == .timedOut, let timeout {
            throw GitCommandError.timedOut(seconds: timeout)
        }

        try outputHandle.synchronize()
        try errorHandle.synchronize()

        if process.terminationStatus != 0 {
            let errorData = try Data(contentsOf: errorURL)
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitCommandError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                message: message
            )
        }

        // 큰 출력을 메모리에 올리기 전에 파일 크기로 먼저 거른다.
        if let fileSize = try? fileManager.attributesOfItem(atPath: outputURL.path)[.size],
           let byteCount = (fileSize as? NSNumber)?.int64Value,
           byteCount > Int64(maximumBytes) {
            throw GitCommandError.outputTooLarge(limit: maximumBytes)
        }

        let outputData = try Data(contentsOf: outputURL)
        if outputData.count <= maximumBytes {
            return outputData
        }
        throw GitCommandError.outputTooLarge(limit: maximumBytes)
    }

    /// 프로세스 종료를 기다린다. `timeout` 이 있으면 그 시간과 경주시킨다.
    private func waitForExit(
        signal: ExitSignal,
        process: ProcessBox,
        timeout: TimeInterval?
    ) async -> WaitOutcome {
        guard let timeout, timeout > 0 else {
            await signal.wait()
            return .exited
        }

        return await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                await signal.wait()
                return .exited
            }
            group.addTask {
                // 취소로 sleep 이 일찍 깨도 .timedOut 으로 돌아온다. 취소 여부는 호출자가 가른다.
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }

            let outcome = await group.next() ?? .exited
            group.cancelAll()
            if outcome == .timedOut {
                // 종료를 기다리는 자식 태스크가 영원히 남지 않도록 실제로 프로세스를 끝낸다.
                // 그룹을 벗어날 때 남은 자식이 끝나기를 기다리므로 실제 종료까지 대기하게 된다.
                process.terminateIfRunning()
            }
            return outcome
        }
    }
}

/// 실패한 rebase 를 되돌리려 시도한 결과.
enum GitRebaseRecovery: Sendable {
    /// 애초에 rebase 중간 상태로 들어가지도 않았다. 저장소는 그대로다.
    case notInRebase
    /// `rebase --abort` 로 되돌렸다.
    case aborted
    /// 되돌리지 못했다. 저장소가 rebase 중간 상태로 남아 있으므로 사용자에게 알려야 한다.
    case abortFailed
}

/// rebase 상태 판정과 복구.
///
/// `GitRemoteService`(pull --rebase)와 `GitBranchService`(rebase) 가 같은 규칙을 써야 하므로
/// 실행기 쪽에 한 번만 둔다.
extension GitCommandRunner {
    /// rebase 가 지금 진행 중인지 본다.
    ///
    /// `REBASE_HEAD` 는 rebase 가 정상적으로 끝난 뒤에도 남아 있어 판정에 쓸 수 없다.
    /// 실제로 진행 중일 때만 존재하는 `rebase-merge`·`rebase-apply` 디렉터리로 확인한다.
    /// 경로는 `--git-path` 로 물어봐 worktree 나 분리된 gitdir 에서도 맞게 나온다.
    func isRebaseInProgress(repositoryURL: URL) async -> Bool {
        for stateDirectory in ["rebase-merge", "rebase-apply"] {
            guard let path = try? await runText(
                repositoryURL: repositoryURL,
                arguments: ["rev-parse", "--git-path", stateDirectory],
                maximumBytes: 4_096
            ).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                continue
            }

            // 상대 경로로 나오면 git 을 실행한 저장소 루트 기준이다.
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : repositoryURL.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    /// rebase 를 동반한 명령이 실패한 뒤, 저장소를 rebase 중간 상태로 남기지 않도록 되돌린다.
    ///
    /// 호출자는 결과에 따라 자기 도메인의 에러로 옮겨 담는다. 여기서 던지지 않는 것은
    /// 복구 실패도 "알려야 할 결말"이지 예외 상황이 아니기 때문이다.
    func recoverFromFailedRebase(
        repositoryURL: URL,
        timeout: TimeInterval
    ) async -> GitRebaseRecovery {
        guard await isRebaseInProgress(repositoryURL: repositoryURL) else {
            return .notInRebase
        }
        do {
            _ = try await runText(
                repositoryURL: repositoryURL,
                arguments: ["rebase", "--abort"],
                timeout: timeout,
                exclusive: true
            )
            return .aborted
        } catch {
            return .abortFailed
        }
    }
}
