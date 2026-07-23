import SwiftUI

struct CommitGraphView: View {
    let layout: GraphRowLayout
    let commit: GitCommit
    let isSelected: Bool
    let laneSpacing: CGFloat

    private let originX: CGFloat = 12
    private var nodeDiameter: CGFloat {
        min(18, max(2, laneSpacing + 2))
    }
    private var lineWidth: CGFloat {
        min(2.75, max(0.5, nodeDiameter * 0.15))
    }
    private var nodeStrokeWidth: CGFloat {
        commit.parentOIDs.count > 1
            ? min(3.25, max(lineWidth, nodeDiameter * 0.18))
            : lineWidth
    }

    var body: some View {
        GeometryReader { geometry in
            let centerY = geometry.size.height / 2

            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    drawGraph(in: context, size: size)
                }

                commitNode
                    .position(x: laneX(layout.nodeLane), y: centerY)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("커밋 그래프")
        .accessibilityValue(accessibilityValue)
    }

    private var commitNode: some View {
        ZStack {
            if commit.isHead {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: nodeDiameter + 10, height: nodeDiameter + 10)

                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.75)
                    .frame(width: nodeDiameter + 7, height: nodeDiameter + 7)
            }

            if isSelected {
                Circle()
                    .fill(color(for: layout.nodeLane).opacity(0.24))
                    .frame(width: nodeDiameter + 6, height: nodeDiameter + 6)
            }

            Circle()
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: nodeDiameter + 3, height: nodeDiameter + 3)

            avatarContent

            Circle()
                .stroke(
                    color(for: layout.nodeLane),
                    lineWidth: nodeStrokeWidth
                )
                .frame(width: nodeDiameter, height: nodeDiameter)
        }
        .frame(width: nodeDiameter + 6, height: nodeDiameter + 6)
        .shadow(
            color: isSelected ? color(for: layout.nodeLane).opacity(0.35) : .clear,
            radius: 2
        )
    }

    @ViewBuilder
    private var avatarContent: some View {
        if commit.isWorkingTree {
            Circle()
                .fill(Color.orange)
                .frame(width: nodeDiameter - 3, height: nodeDiameter - 3)
                .overlay {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: max(5, nodeDiameter * 0.42), weight: .bold))
                        .foregroundStyle(.white)
                }
        } else {
            AuthorAvatarView(
                commit: commit,
                size: max(0, nodeDiameter - 4),
                fallbackColor: authorColor
            )
        }
    }

    private func drawGraph(in context: GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        let strokeStyle = StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round
        )

        for lane in layout.passThroughLanes {
            var path = Path()
            let x = laneX(lane)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path,
                with: .color(color(for: lane)),
                style: strokeStyle
            )
        }

        for incomingLane in layout.incomingLanes {
            var incoming = Path()
            let incomingX = laneX(incomingLane)
            let nodeX = laneX(layout.nodeLane)
            incoming.move(to: CGPoint(x: incomingX, y: 0))

            if incomingX == nodeX {
                incoming.addLine(to: CGPoint(x: nodeX, y: centerY))
            } else {
                let direction: CGFloat = nodeX > incomingX ? 1 : -1
                let cornerRadius = min(
                    8,
                    centerY * 0.72,
                    abs(nodeX - incomingX) * 0.5
                )
                incoming.addLine(
                    to: CGPoint(x: incomingX, y: centerY - cornerRadius)
                )
                incoming.addQuadCurve(
                    to: CGPoint(
                        x: incomingX + direction * cornerRadius,
                        y: centerY
                    ),
                    control: CGPoint(x: incomingX, y: centerY)
                )
                incoming.addLine(to: CGPoint(x: nodeX, y: centerY))
            }

            context.stroke(
                incoming,
                with: .color(color(for: incomingLane)),
                style: strokeStyle
            )
        }

        for (parentIndex, parentLane) in layout.parentLanes.enumerated() {
            let nodeX = laneX(layout.nodeLane)
            let parentX = laneX(parentLane)
            var outgoing = Path()
            outgoing.move(to: CGPoint(x: nodeX, y: centerY))

            if nodeX == parentX {
                outgoing.addLine(to: CGPoint(x: parentX, y: size.height))
            } else {
                let lowerSpan = size.height - centerY
                let direction: CGFloat = parentX > nodeX ? 1 : -1
                let cornerRadius = min(
                    8,
                    lowerSpan * 0.72,
                    abs(parentX - nodeX) * 0.5
                )
                outgoing.addLine(
                    to: CGPoint(
                        x: parentX - direction * cornerRadius,
                        y: centerY
                    )
                )
                outgoing.addQuadCurve(
                    to: CGPoint(
                        x: parentX,
                        y: centerY + cornerRadius
                    ),
                    control: CGPoint(x: parentX, y: centerY)
                )
                outgoing.addLine(to: CGPoint(x: parentX, y: size.height))
            }

            context.stroke(
                outgoing,
                with: .color(
                    parentIndex == 0
                        ? color(for: layout.nodeLane)
                        : color(for: parentLane)
                ),
                style: strokeStyle
            )
        }
    }

    private func laneX(_ lane: Int) -> CGFloat {
        originX + CGFloat(lane) * laneSpacing
    }

    private func color(for lane: Int) -> Color {
        AppPalette.graphColors[lane % AppPalette.graphColors.count]
    }

    private var authorColor: Color {
        let key = commit.authorEmail.isEmpty ? commit.authorName : commit.authorEmail
        let index = stableColorIndex(for: key, count: AppPalette.avatarColors.count)
        return AppPalette.avatarColors[index]
    }

    private var accessibilityValue: String {
        if commit.isWorkingTree {
            return "커밋되지 않은 작업 트리 변경 사항, \(layout.nodeLane + 1)번 레인"
        }
        if commit.isHead {
            return "현재 HEAD 커밋, \(layout.nodeLane + 1)번 레인"
        }
        if layout.isBranchPoint {
            return "브랜치 \(layout.incomingLanes.count)개가 갈라진 기준 커밋, \(layout.nodeLane + 1)번 레인"
        }
        if commit.parentOIDs.isEmpty {
            return "루트 커밋, \(layout.nodeLane + 1)번 레인"
        }
        if commit.parentOIDs.count > 1 {
            return "부모 \(commit.parentOIDs.count)개를 가진 병합 커밋, \(layout.nodeLane + 1)번 레인"
        }
        return "일반 커밋, \(layout.nodeLane + 1)번 레인"
    }

    private func stableColorIndex(for value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

private struct AuthorAvatarView: View {
    let commit: GitCommit
    let size: CGFloat
    let fallbackColor: Color

    @State private var avatarImage: NSImage?

    var body: some View {
        ZStack {
            fallbackAvatar

            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: avatarLookupKey) {
            let lookupKey = avatarLookupKey
            avatarImage = nil
            let imageData = await AuthorAvatarResolver.shared.imageData(for: commit)
            guard !Task.isCancelled, lookupKey == avatarLookupKey else { return }
            avatarImage = imageData.flatMap(NSImage.init(data:))
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(fallbackColor)

            Image(systemName: "person.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
        }
    }

    private var avatarLookupKey: String {
        "\(commit.id.repositoryID.rawValue)::\(commit.authorEmail.lowercased())"
    }
}

actor AuthorAvatarResolver {
    static let shared = AuthorAvatarResolver()

    private var resolvedURLs: [String: URL] = [:]
    private var resolvedImageData: [String: Data] = [:]
    private var imageCacheKeys: [String] = []
    private var missingCommitIDs: Set<CommitID> = []
    private var pendingTasks: [String: Task<URL?, Never>] = [:]
    private var pendingImageTasks: [String: Task<Data?, Never>] = [:]
    private let imageCacheLimit = 256
    private let imageCacheCostLimit = 16 * 1_024 * 1_024
    private let individualImageLimit = 1_024 * 1_024
    private var imageCacheCost = 0

    func imageData(for commit: GitCommit) async -> Data? {
        let key = avatarKey(for: commit)
        guard !key.isEmpty else { return nil }
        if let cached = resolvedImageData[key] {
            return cached
        }
        if let pendingTask = pendingImageTasks[key] {
            return await pendingTask.value
        }

        let individualImageLimit = self.individualImageLimit
        let task = Task<Data?, Never>(priority: .utility) {
            guard let url = await self.url(for: commit) else { return nil }
            await AvatarImageDownloadGate.shared.acquire()
            guard !Task.isCancelled else {
                await AvatarImageDownloadGate.shared.release()
                return nil
            }

            let result: Data?
            do {
                let (bytes, response) = try await URLSession.shared.bytes(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    bytes.task.cancel()
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }

                let expectedSize = httpResponse.expectedContentLength
                guard expectedSize <= 0 || expectedSize <= individualImageLimit else {
                    bytes.task.cancel()
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }

                var data = Data()
                if expectedSize > 0 {
                    data.reserveCapacity(Int(expectedSize))
                }
                for try await byte in bytes {
                    guard data.count < individualImageLimit else {
                        bytes.task.cancel()
                        await AvatarImageDownloadGate.shared.release()
                        return nil
                    }
                    data.append(byte)
                }
                guard !data.isEmpty else {
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }
                result = data
            } catch {
                result = nil
            }
            await AvatarImageDownloadGate.shared.release()
            return result
        }
        pendingImageTasks[key] = task

        let data = await task.value
        pendingImageTasks[key] = nil
        if let data {
            cacheImageData(data, for: key)
        }
        return data
    }

    func url(for commit: GitCommit) async -> URL? {
        let email = commit.authorEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return nil }

        let key = avatarKey(for: commit)
        if let cached = resolvedURLs[key] {
            return cached
        }
        if missingCommitIDs.contains(commit.id) {
            return nil
        }
        if let pendingTask = pendingTasks[key] {
            return await pendingTask.value
        }

        let repositoryPath = commit.id.repositoryID.rawValue
        let commitOID = commit.id.oid
        let task = Task.detached(priority: .utility) {
            await AvatarLookupGate.shared.acquire()
            let url = Self.resolveURL(
                repositoryPath: repositoryPath,
                commitOID: commitOID,
                email: email
            )
            await AvatarLookupGate.shared.release()
            return url
        }
        pendingTasks[key] = task

        let url = await task.value
        pendingTasks[key] = nil
        if let url {
            resolvedURLs[key] = url
        } else {
            missingCommitIDs.insert(commit.id)
        }
        return url
    }

    private func avatarKey(for commit: GitCommit) -> String {
        let email = commit.authorEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return "" }
        return "\(commit.id.repositoryID.rawValue)::\(email)"
    }

    private func cacheImageData(_ data: Data, for key: String) {
        if let previousData = resolvedImageData[key] {
            imageCacheCost -= previousData.count
        } else {
            imageCacheKeys.append(key)
        }
        resolvedImageData[key] = data
        imageCacheCost += data.count

        while imageCacheKeys.count > imageCacheLimit
            || imageCacheCost > imageCacheCostLimit {
            let evictedKey = imageCacheKeys.removeFirst()
            imageCacheCost -= resolvedImageData[evictedKey]?.count ?? 0
            resolvedImageData[evictedKey] = nil
        }
    }

    private nonisolated static func resolveURL(
        repositoryPath: String,
        commitOID: String,
        email: String
    ) -> URL? {
        if let username = gitHubUsername(from: email) {
            return URL(string: "https://github.com/\(username).png?size=64")
        }

        guard run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repositoryPath,
                "branch", "-r", "--contains", commitOID,
                "--format=%(refname)"
            ]
        ) != nil else {
            return nil
        }

        if let repository = gitHubRepository(path: repositoryPath),
           let ghPath = ghExecutablePath(),
           let avatar = run(
                executable: ghPath,
                arguments: [
                    "api", "--cache", "1h",
                    "repos/\(repository)/commits/\(commitOID)",
                    "--jq", ".author.avatar_url // empty"
                ]
           ),
           let url = URL(string: avatar) {
            return url
        }
        return nil
    }

    private nonisolated static func gitHubUsername(from email: String) -> String? {
        guard email.hasSuffix("@users.noreply.github.com"),
              let localPart = email.split(separator: "@").first else {
            return nil
        }
        let username = localPart.split(separator: "+").last.map(String.init) ?? ""
        return username.isEmpty ? nil : username
    }

    private nonisolated static func gitHubRepository(path: String) -> String? {
        guard let remote = run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "remote", "get-url", "origin"]
        ) else {
            return nil
        }

        let repository: String
        if remote.hasPrefix("git@github.com:") {
            repository = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URL(string: remote), url.host == "github.com" {
            repository = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }

        return repository.hasSuffix(".git")
            ? String(repository.dropLast(4))
            : repository
    }

    private nonisolated static func ghExecutablePath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private nonisolated static func run(
        executable: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = Date().addingTimeInterval(4)
        while process.isRunning, Date() < timeout {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private actor AvatarLookupGate {
    static let shared = AvatarLookupGate(limit: 3)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor AvatarImageDownloadGate {
    static let shared = AvatarImageDownloadGate(limit: 4)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
