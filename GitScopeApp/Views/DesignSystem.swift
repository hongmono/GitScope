import AppKit
import SwiftUI

/// 앱 전역 표면·구분 색 토큰.
///
/// 미세 구분용 채움은 모두 `Color.primary` 기반이다. 흰색 기반 오버레이는 라이트 모드의
/// 밝은 표면 위에서 사라지고 다크 모드에서는 과하게 밝아지므로 사용하지 않는다.
enum AppColor {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    static let contentSurface = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    /// 표면 위에 아주 얇게 얹는 구분용 채움.
    static let subtleFill = Color.primary.opacity(0.04)
    /// 검색 필드·칩 등 컴팩트 컨트롤의 바탕.
    static let controlFill = Color.primary.opacity(0.06)
    /// 표 열 머리글 띠.
    static let columnHeaderFill = Color.primary.opacity(0.05)
    /// 목록 교차 행 배경.
    static let zebraStripe = Color.primary.opacity(0.03)
    /// 카드·컨트롤 테두리.
    static let surfaceStroke = Color.primary.opacity(0.10)

    static let selectionFill = Color.accentColor.opacity(AppGlassDesign.tintFillOpacity)
}

/// 상태를 나타내는 전경·채움 색 토큰.
///
/// 시스템 원색(`Color.green` 등)은 라이트 배경 위 작은 텍스트에서 대비가 2:1 안팎이라
/// (systemGreen 2.12:1, systemOrange 2.20:1) 그대로 쓰지 않는다. 아래 전경 토큰은 라이트에서
/// 원색보다 어둡게, 다크에서 밝게 잡아 각 외형의 표면 위에서 4.5:1 이상을 확보한다.
/// 의미(초록=성공/추가 등)는 원색과 같으므로 매핑을 바꾸지 않는다.
enum AppStatusColor {
    /// 성공·추가·앞선 커밋(↑). 라이트 5.95:1 / 다크 10.23:1.
    static let success = appearanceColor(
        light: srgb(0.10, 0.45, 0.20),
        dark: srgb(0.52, 0.87, 0.60)
    )
    /// 경고·대기 중·뒤처진 커밋(↓)·수정된 파일. 라이트 5.63:1 / 다크 9.70:1.
    static let warning = appearanceColor(
        light: srgb(0.62, 0.33, 0.02),
        dark: srgb(1.00, 0.72, 0.35)
    )
    /// 실패·삭제·사라진 upstream. 라이트 6.09:1 / 다크 7.82:1.
    static let danger = appearanceColor(
        light: srgb(0.72, 0.18, 0.16),
        dark: srgb(1.00, 0.58, 0.54)
    )
    /// 진행 중·이름 변경. 라이트 5.46:1 / 다크 7.93:1.
    static let progress = appearanceColor(
        light: srgb(0.06, 0.40, 0.82),
        dark: srgb(0.45, 0.72, 1.00)
    )
    /// 원격 참조. 라이트 5.76:1 / 다크 8.01:1.
    static let remote = appearanceColor(
        light: srgb(0.53, 0.26, 0.78),
        dark: srgb(0.80, 0.63, 1.00)
    )
    /// 중립·취소됨·건너뜀. 라이트 5.74:1 / 다크 7.91:1.
    static let neutral = appearanceColor(
        light: srgb(0.40, 0.40, 0.40),
        dark: srgb(0.70, 0.70, 0.70)
    )

    /// 아래 `*Fill` 은 diff 하이라이트처럼 낮은 불투명도로 깔리는 **채움 전용** 원색이다.
    /// 전경 텍스트에 쓰면 대비가 무너지므로 위 전경 토큰과 섞어 쓰지 않는다.
    static let successFill = appearanceColor(
        light: srgb(0.157, 0.804, 0.255),
        dark: srgb(0.188, 0.820, 0.345)
    )
    static let dangerFill = appearanceColor(
        light: srgb(1.000, 0.231, 0.188),
        dark: srgb(1.000, 0.271, 0.227)
    )
    static let progressFill = appearanceColor(
        light: srgb(0.000, 0.478, 1.000),
        dark: srgb(0.039, 0.518, 1.000)
    )
}

private func srgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

/// 외형에 따라 다른 값을 내는 색. 라이트/다크 한쪽만 만족하는 고정 색으로는
/// 두 외형 모두에서 4.5:1 을 넘길 수 없어 `NSColor` 의 dynamic provider 를 쓴다.
private func appearanceColor(light: NSColor, dark: NSColor) -> Color {
    Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    )
}

/// 앱 전역 타이포그래피 스케일.
///
/// 사용자가 읽어야 하는 텍스트는 11pt 이상만 사용한다. 그 미만은 `.secondary` 로 그렸을 때
/// WCAG 4.5:1 대비를 넘기지 못한다.
enum AppFont {
    /// 의미가 주변 레이블에 있는 장식용 글리프 전용. 읽어야 하는 텍스트에는 쓰지 않는다.
    static let decorativeGlyph = Font.system(size: 10, weight: .semibold)

    /// 목록·표 행의 기본 본문.
    static let rowLabel = Font.system(size: 11)
    /// 행 안에서 한 단계 강조되는 값(작성자 등).
    static let rowLabelEmphasized = Font.system(size: 11, weight: .medium)
    /// 표 열 머리글.
    static let columnHeader = Font.system(size: 11, weight: .medium)
    /// 상태 배지·칩.
    static let badge = Font.system(size: 11, weight: .semibold)
    /// 파일 상태 코드처럼 폭을 맞춰야 하는 배지.
    static let badgeMono = Font.system(size: 11, weight: .bold, design: .monospaced)
    /// 상세 패널 메타데이터 항목 이름.
    static let metadataTitle = Font.system(size: 11, weight: .medium)
    /// 상세 패널 메타데이터 값.
    static let metadataValue = Font.system(size: 11)
    /// 해시·diff 본문 등 고정폭 텍스트.
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    /// 워크스페이스 탭 제목.
    static let tabTitle = Font.system(size: 11)
    /// 툴바 컨트롤 기본 크기.
    static let toolbarControl = Font.system(size: 12)
    /// 패널 헤더 제목.
    static let paneTitle = Font.system(size: 12, weight: .semibold)
    /// 커밋 제목 등 섹션 제목.
    static let sectionTitle = Font.system(size: 13, weight: .semibold)

    static let loadingGlyph = Font.system(size: 28, weight: .light)
    static let loadingTitle = Font.system(size: 16, weight: .semibold)
    static let loadingBody = Font.system(size: 12)

    static let emptyStateGlyph = Font.system(size: 42, weight: .light)
    static let emptyStateTitle = Font.system(size: 18, weight: .semibold)
    static let emptyStateBody = Font.system(size: 13)
}

/// 앱 전역 모션 토큰.
enum AppMotion {
    /// 사이드바·인스펙터 열고 닫기.
    ///
    /// `NavigationSplitView` 가 툴바에 넣는 기본 사이드바 버튼은 이 전환을 스스로 애니메이션한다.
    /// 메뉴 커맨드나 커스텀 버튼처럼 모델 값을 직접 바꾸는 경로는 트랜잭션 밖이라 즉시 튀므로,
    /// 같은 감각을 내려면 이 값으로 `withAnimation` 을 감싸야 한다.
    ///
    /// 커맨드 클로저는 View body 가 아니라 `@Environment` 를 못 읽으므로 AppKit 쪽을 직접 본다.
    static var pane: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .spring(response: 0.30, dampingFraction: 0.88)
    }
}
