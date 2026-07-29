import AppKit
import SwiftUI

/// 히스토리 표의 그래프 열 위에 얹혀 커밋 노드·연결선을 직접 그리는 오버레이.
///
/// 행마다 SwiftUI 뷰를 두는 대신 보이는 구간만 `CGContext` 로 그린다. 스크롤 중에도 프레임을
/// 지키려면 행 단위 뷰 계층을 만들지 않는 편이 유리하기 때문이다.
@MainActor
final class VisibleCommitGraphView: NSView {
    private var rows: [CommitRow] = []
    private var selectedCommitID: CommitID?
    private var laneSpacing: CGFloat = 18
    private var contentOffsetY: CGFloat = 0
    private let avatarCache = NSCache<NSString, NSImage>()
    private var avatarTasks: [String: Task<Void, Never>] = [:]
    /// 조회 결과가 없는 것으로 확정된 키. 이 기록이 없으면 스크롤 알림마다 같은 작성자에 대해
    /// `Task` 가 새로 생긴다(성공한 조회만 `avatarCache` 에 남기 때문).
    private var unavailableAvatarKeys: Set<String> = []
    /// 설정의 '커밋 작성자 아바타 불러오기' 상태. 꺼지면 캐시에 남은 이미지도 쓰지 않는다.
    private var showsRemoteAvatars = AppSettings.isAuthorAvatarLookupEnabled

    /// 첫 lane 노드의 중심 x.
    ///
    /// 노드에 그리는 가장 큰 원은 HEAD 강조 배경(`nodeDiameter + 10`)이다. 그 반지름보다
    /// 왼쪽 여백이 좁으면 원이 그래프 열 밖으로 나가 잘린다.
    private var originX: CGFloat {
        nodeDiameter / 2 + 6
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAvatarCache()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAvatarCache()
    }

    private func configureAvatarCache() {
        avatarCache.countLimit = 256
        // 개수 상한만으로는 큰 이미지 256장이 수십 MB 를 붙잡을 수 있다.
        // AuthorAvatarResolver 의 16MB 정책과 같은 바이트 상한을 둔다.
        avatarCache.totalCostLimit = 16 * 1_024 * 1_024
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// `draw(_:)` 안에서 시맨틱 `NSColor` 를 그때그때 해석하므로 외형이 바뀌면 다시 그려야 한다.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(
        rows: [CommitRow],
        selectedCommitID: CommitID?,
        laneSpacing: CGFloat,
        contentOffsetY: CGFloat,
        showsRemoteAvatars: Bool
    ) {
        self.rows = rows
        self.selectedCommitID = selectedCommitID
        self.laneSpacing = laneSpacing
        self.contentOffsetY = contentOffsetY
        self.showsRemoteAvatars = showsRemoteAvatars

        if showsRemoteAvatars {
            scheduleVisibleAvatarLoads()
        } else {
            cancelPendingAvatarLoads()
            unavailableAvatarKeys.removeAll()
        }
        needsDisplay = true
    }

    func cancelPendingAvatarLoads() {
        for task in avatarTasks.values {
            task.cancel()
        }
        avatarTasks.removeAll()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let visibleRange else {
            return
        }

        context.saveGState()
        context.clip(to: bounds)

        for index in visibleRange {
            drawConnections(
                rows[index].graph,
                rowFrame: frameForRow(at: index),
                in: context
            )
        }

        for index in visibleRange {
            drawNode(
                for: rows[index],
                isSelected: selectedCommitID == rows[index].id,
                rowFrame: frameForRow(at: index),
                in: context
            )
        }

        context.restoreGState()
    }

    private var visibleRange: ClosedRange<Int>? {
        guard !rows.isEmpty, bounds.height > 0 else { return nil }

        let rowHeight = HistoryColumnMetrics.rowHeight
        let topInset = HistoryColumnMetrics.topContentInset
        let firstContentY = max(0, contentOffsetY - topInset)
        let lastContentY = max(
            firstContentY,
            contentOffsetY + bounds.height - topInset
        )
        let firstIndex = max(
            0,
            Int(floor(firstContentY / rowHeight)) - 1
        )
        let lastIndex = min(
            rows.count - 1,
            Int(ceil(lastContentY / rowHeight))
        )
        return firstIndex...max(firstIndex, lastIndex)
    }

    private func frameForRow(at index: Int) -> NSRect {
        NSRect(
            x: 0,
            y: HistoryColumnMetrics.topContentInset
                + CGFloat(index) * HistoryColumnMetrics.rowHeight
                - contentOffsetY,
            width: bounds.width,
            height: HistoryColumnMetrics.rowHeight
        )
    }

    private func drawConnections(
        _ layout: GraphRowLayout,
        rowFrame: NSRect,
        in context: CGContext
    ) {
        let topY = rowFrame.minY
        let centerY = rowFrame.midY
        let bottomY = rowFrame.maxY

        for connection in layout.passThroughConnections {
            let incomingX = laneX(connection.incomingLane)
            let outgoingX = laneX(connection.outgoingLane)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: incomingX, y: topY))

            if connection.incomingLane == connection.outgoingLane {
                path.addLine(to: CGPoint(x: outgoingX, y: bottomY))
            } else {
                appendLaneTransition(
                    to: path,
                    fromX: incomingX,
                    toX: outgoingX,
                    fromY: topY,
                    toY: bottomY
                )
            }

            stroke(
                path,
                color: graphColor(for: connection.colorIndex),
                in: context
            )
        }

        for (incomingIndex, incomingLane) in layout.incomingLanes.enumerated() {
            let incomingX = laneX(incomingLane)
            let nodeX = laneX(layout.nodeLane)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: incomingX, y: topY))

            if incomingLane == layout.nodeLane {
                path.addLine(to: CGPoint(x: nodeX, y: centerY))
            } else {
                appendLaneTransition(
                    to: path,
                    fromX: incomingX,
                    toX: nodeX,
                    fromY: topY,
                    toY: centerY
                )
            }

            stroke(
                path,
                color: graphColor(
                    for: layout.incomingColorIndices[incomingIndex]
                ),
                in: context
            )
        }

        for (parentIndex, parentLane) in layout.parentLanes.enumerated() {
            let nodeX = laneX(layout.nodeLane)
            let parentX = laneX(parentLane)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: nodeX, y: centerY))

            if layout.nodeLane == parentLane {
                path.addLine(to: CGPoint(x: parentX, y: bottomY))
            } else {
                appendLaneTransition(
                    to: path,
                    fromX: nodeX,
                    toX: parentX,
                    fromY: centerY,
                    toY: bottomY
                )
            }

            stroke(
                path,
                color: graphColor(
                    for: layout.parentColorIndices[parentIndex]
                ),
                in: context
            )
        }
    }

    /// lane 을 옮겨 가는 연결선을 잇는다. 세로로 흐르다 둥근 모서리로 방향을 바꾼다.
    ///
    /// 한 행 안에서 여러 lane 을 건너뛰면 가로 거리가 세로 거리보다 훨씬 길어진다. 이때
    /// 양 끝을 S 자 곡선으로 이으면 가운데가 눌려 꺾인 선처럼 보이므로, 세로 구간과 가로
    /// 구간을 각각 유지하고 그 사이만 둥글린다. 두 거리가 비슷하면 모서리 두 개가 맞붙어
    /// 자연스러운 S 자가 된다.
    private func appendLaneTransition(
        to path: CGMutablePath,
        fromX: CGFloat,
        toX: CGFloat,
        fromY: CGFloat,
        toY: CGFloat
    ) {
        let midY = (fromY + toY) / 2
        let radius = min(abs(toX - fromX), abs(toY - fromY)) / 2
        path.addArc(
            tangent1End: CGPoint(x: fromX, y: midY),
            tangent2End: CGPoint(x: toX, y: midY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: toX, y: midY),
            tangent2End: CGPoint(x: toX, y: toY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: toX, y: toY))
    }

    private func stroke(
        _ path: CGPath,
        color: CGColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    private func drawNode(
        for row: CommitRow,
        isSelected: Bool,
        rowFrame: NSRect,
        in context: CGContext
    ) {
        let commit = row.commit
        let center = CGPoint(
            x: laneX(row.graph.nodeLane),
            y: rowFrame.midY
        )

        if commit.isHead {
            fillCircle(
                center: center,
                diameter: nodeDiameter + 10,
                color: NSColor.controlAccentColor.withAlphaComponent(0.16),
                in: context
            )
            strokeCircle(
                center: center,
                diameter: nodeDiameter + 7,
                color: .controlAccentColor,
                width: 1.75,
                in: context
            )
        }

        let nodeColor = graphColor(for: row.graph.nodeColorIndex)
        if isSelected {
            fillCircle(
                center: center,
                diameter: nodeDiameter + 6,
                color: nodeColor.copy(alpha: 0.24) ?? nodeColor,
                in: context
            )
        }

        fillCircle(
            center: center,
            diameter: nodeDiameter + 3,
            color: .textBackgroundColor,
            in: context
        )

        if commit.isWorkingTree {
            fillCircle(
                center: center,
                diameter: max(1, nodeDiameter - 3),
                color: .systemOrange,
                in: context
            )
            drawSymbol(
                "hammer.fill",
                center: center,
                pointSize: max(5, nodeDiameter * 0.42),
                color: .white
            )
        } else {
            drawAvatar(for: commit, center: center, in: context)
        }

        strokeCircle(
            center: center,
            diameter: nodeDiameter,
            color: nodeColor,
            width: commit.parentOIDs.count > 1
                ? min(3.25, max(lineWidth, nodeDiameter * 0.18))
                : lineWidth,
            in: context
        )
    }

    private func drawAvatar(
        for commit: GitCommit,
        center: CGPoint,
        in context: CGContext
    ) {
        let diameter = max(0, nodeDiameter - 4)
        guard diameter > 0 else { return }

        let rect = circleRect(center: center, diameter: diameter)
        if showsRemoteAvatars,
           let key = avatarKey(for: commit),
           let image = avatarCache.object(forKey: key as NSString) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            let imageSide = min(image.size.width, image.size.height)
            let sourceRect = NSRect(
                x: (image.size.width - imageSide) * 0.5,
                y: (image.size.height - imageSide) * 0.5,
                width: imageSide,
                height: imageSide
            )
            image.draw(
                in: rect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        fillCircle(
            center: center,
            diameter: diameter,
            color: authorColor(for: commit),
            in: context
        )
        drawSymbol(
            "person.fill",
            center: center,
            pointSize: 7,
            color: .white.withAlphaComponent(0.96)
        )
    }

    private func fillCircle(
        center: CGPoint,
        diameter: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        fillCircle(center: center, diameter: diameter, color: cgColor(color), in: context)
    }

    private func fillCircle(
        center: CGPoint,
        diameter: CGFloat,
        color: CGColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(color)
        context.fillEllipse(in: circleRect(center: center, diameter: diameter))
        context.restoreGState()
    }

    private func strokeCircle(
        center: CGPoint,
        diameter: CGFloat,
        color: NSColor,
        width: CGFloat,
        in context: CGContext
    ) {
        strokeCircle(center: center, diameter: diameter, color: cgColor(color), width: width, in: context)
    }

    private func strokeCircle(
        center: CGPoint,
        diameter: CGFloat,
        color: CGColor,
        width: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokeEllipse(in: circleRect(center: center, diameter: diameter))
        context.restoreGState()
    }

    private func drawSymbol(
        _ name: String,
        center: CGPoint,
        pointSize: CGFloat,
        color: NSColor
    ) {
        guard let image = SymbolImageCache.image(
            named: name,
            pointSize: pointSize,
            color: color
        ) else {
            return
        }

        let imageRect = NSRect(
            x: center.x - image.size.width * 0.5,
            y: center.y - image.size.height * 0.5,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func circleRect(center: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(
            x: center.x - diameter * 0.5,
            y: center.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
    }

    private func scheduleVisibleAvatarLoads() {
        guard showsRemoteAvatars, let visibleRange else { return }

        for index in visibleRange {
            let commit = rows[index].commit
            guard !commit.isWorkingTree,
                  let key = avatarKey(for: commit),
                  avatarCache.object(forKey: key as NSString) == nil,
                  !unavailableAvatarKeys.contains(key),
                  avatarTasks[key] == nil else {
                continue
            }

            avatarTasks[key] = Task { [weak self] in
                let data = await AuthorAvatarResolver.shared.imageData(for: commit)
                guard !Task.isCancelled, let self else { return }
                if let data, let image = NSImage(data: data) {
                    self.avatarCache.setObject(
                        image,
                        forKey: key as NSString,
                        cost: data.count
                    )
                } else if self.showsRemoteAvatars {
                    // 토글이 켜진 채로 조회에 실패한 경우에만 기록한다. 조회 도중 토글이 꺼져
                    // nil 이 돌아온 것을 실패로 남기면 다시 켰을 때 복구되지 않는다.
                    self.unavailableAvatarKeys.insert(key)
                }
                self.avatarTasks[key] = nil
                self.needsDisplay = true
            }
        }
    }

    private func avatarKey(for commit: GitCommit) -> String? {
        historyAvatarKey(
            repositoryID: commit.id.repositoryID,
            authorEmail: commit.authorEmail
        )
    }

    /// 프리페치 경로가 조회 실패가 확정된 작성자를 다시 조회하지 않도록 공유하는 가드.
    func isAvatarUnavailable(forKey key: String) -> Bool {
        unavailableAvatarKeys.contains(key)
    }

    func markAvatarUnavailable(forKey key: String) {
        unavailableAvatarKeys.insert(key)
    }

    private var nodeDiameter: CGFloat {
        min(18, max(2, laneSpacing + 2))
    }

    private var lineWidth: CGFloat {
        min(2.75, max(0.5, nodeDiameter * 0.15))
    }

    private func laneX(_ lane: Int) -> CGFloat {
        originX + CGFloat(lane) * laneSpacing
    }

    private func graphColor(for lane: Int) -> CGColor {
        GraphPaletteCache.graphColor(at: lane, appearance: effectiveAppearance)
    }

    private func authorColor(for commit: GitCommit) -> CGColor {
        let key = commit.authorEmail.isEmpty
            ? commit.authorName
            : commit.authorEmail
        let index = stableColorIndex(
            for: key,
            count: AppPalette.avatarColors.count
        )
        return GraphPaletteCache.avatarColor(at: index, appearance: effectiveAppearance)
    }

    private func stableColorIndex(for value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    private func cgColor(_ color: NSColor) -> CGColor {
        color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
    }
}

/// 그래프·아바타 팔레트를 `CGColor` 로 변환해 두는 캐시.
///
/// `draw(_:)` 는 스크롤마다 보이는 행 전체를 다시 그리는데, 호출마다 `NSColor(Color)` 브리지와
/// `usingColorSpace(.deviceRGB)` 변환을 반복하면 프레임당 수백 회 색 변환이 된다. 현재 팔레트는
/// 고정 sRGB 값이라 외형과 무관하지만, 동적 색으로 바뀌어도 조용히 틀리지 않도록 appearance
/// 이름이 달라지면 다시 만든다.
@MainActor
private enum GraphPaletteCache {
    private static var appearanceName: NSAppearance.Name?
    private static var graphColors: [CGColor] = []
    private static var avatarColors: [CGColor] = []

    static func graphColor(at index: Int, appearance: NSAppearance) -> CGColor {
        refreshIfNeeded(for: appearance)
        return graphColors[index % graphColors.count]
    }

    static func avatarColor(at index: Int, appearance: NSAppearance) -> CGColor {
        refreshIfNeeded(for: appearance)
        return avatarColors[index % avatarColors.count]
    }

    private static func refreshIfNeeded(for appearance: NSAppearance) {
        guard appearance.name != appearanceName || graphColors.isEmpty else { return }
        var resolvedGraphColors: [CGColor] = []
        var resolvedAvatarColors: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            resolvedGraphColors = AppPalette.graphColors.map(resolveCGColor)
            resolvedAvatarColors = AppPalette.avatarColors.map(resolveCGColor)
        }
        appearanceName = appearance.name
        graphColors = resolvedGraphColors
        avatarColors = resolvedAvatarColors
    }

    private nonisolated static func resolveCGColor(_ color: Color) -> CGColor {
        let nsColor = NSColor(color)
        return nsColor.usingColorSpace(.deviceRGB)?.cgColor ?? nsColor.cgColor
    }
}

/// 아바타 폴백 심볼("person.fill", "hammer.fill") 이미지 캐시.
///
/// `drawSymbol` 이 호출마다 `SymbolConfiguration` 2개와 `NSImage` 를 새로 만들면 아바타 없는
/// 행이 보이는 동안 스크롤 프레임마다 이미지 생성이 반복된다. 쓰이는 색은 고정 흰색 계열이라
/// appearance 무효화는 필요 없고, 심볼·크기·색 조합별로 한 번만 만들어 재사용한다.
@MainActor
private enum SymbolImageCache {
    private static var images: [String: NSImage] = [:]

    static func image(named name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(color.description)"
        if let cached = images[key] { return cached }

        let pointConfiguration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .bold
        )
        let colorConfiguration = NSImage.SymbolConfiguration(
            paletteColors: [color]
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            pointConfiguration.applying(colorConfiguration)
        ) else {
            return nil
        }

        // 라이브 리사이즈 중에는 lane 간격을 따라 pointSize 가 연속적으로 변해 조합이 늘어날
        // 수 있다. 흔치 않은 경로라 정교한 LRU 대신 통째로 비우는 것으로 충분하다.
        if images.count >= 64 {
            images.removeAll(keepingCapacity: true)
        }
        images[key] = image
        return image
    }
}

/// 그래프 오버레이의 보이는 행 경로와 프리페치 경로가 같은 키로 아바타를 다루도록 하는
/// 공통 키 생성. `AuthorAvatarResolver` 의 키와 같은 형태다.
func historyAvatarKey(
    repositoryID: RepositoryID,
    authorEmail: String
) -> String? {
    let email = authorEmail
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !email.isEmpty else { return nil }
    return "\(repositoryID.rawValue)::\(email)"
}
