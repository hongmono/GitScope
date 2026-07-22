import Foundation

enum GitCommandError: LocalizedError {
    case launchFailed(String)
    case commandFailed(arguments: [String], status: Int32, message: String)
    case outputTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Git을 실행할 수 없습니다: \(message)"
        case .commandFailed(_, _, let message):
            return message.isEmpty ? "Git 명령 실행에 실패했습니다." : message
        case .outputTooLarge(let limit):
            return "Git 출력이 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) 제한을 초과했습니다. 더 좁은 필터를 적용해주세요."
        }
    }
}

actor GitCommandRunner {
    private let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    func runData(
        repositoryURL: URL,
        arguments: [String],
        maximumBytes: Int = 12_000_000
    ) throws -> Data {
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

        do {
            try process.run()
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()

        let errorData = try Data(contentsOf: errorURL)
        if process.terminationStatus != 0 {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitCommandError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                message: message
            )
        }

        let outputData = try Data(contentsOf: outputURL)
        if outputData.count <= maximumBytes {
            return outputData
        }
        throw GitCommandError.outputTooLarge(limit: maximumBytes)
    }

    func runText(
        repositoryURL: URL,
        arguments: [String],
        maximumBytes: Int = 12_000_000
    ) throws -> String {
        String(
            decoding: try runData(
                repositoryURL: repositoryURL,
                arguments: arguments,
                maximumBytes: maximumBytes
            ),
            as: UTF8.self
        )
    }
}
