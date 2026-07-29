import SwiftUI

enum AppGlassDesign {
    static let controlCornerRadius: CGFloat = 8

    /// `tint` 는 반드시 원색으로 넘긴다. 아래 세 값이 유일한 불투명도 적용 지점이며,
    /// 호출부에서 미리 흐리게 만든 색을 넘기면 불투명도가 두 번 곱해져 선택 상태가 사라진다.
    static let tintFillOpacity: Double = 0.22
    static let tintGlassOpacity: Double = 0.25
    static let tintStrokeOpacity: Double = 0.55
}

private struct AppGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(
                    fillColor,
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .glassEffect(
                    Glass.regular
                        .tint(tint?.opacity(AppGlassDesign.tintGlassOpacity))
                        .interactive(interactive),
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        strokeColor,
                        lineWidth: 0.5
                    )
                }
        } else {
            content
                .background(
                    fillColor,
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        strokeColor,
                        lineWidth: 0.5
                    )
                }
        }
    }

    private var fillColor: Color {
        tint?.opacity(AppGlassDesign.tintFillOpacity) ?? AppColor.subtleFill
    }

    private var strokeColor: Color {
        tint?.opacity(AppGlassDesign.tintStrokeOpacity) ?? AppColor.surfaceStroke
    }
}

extension View {
    func appGlassSurface(
        cornerRadius: CGFloat = AppGlassDesign.controlCornerRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            AppGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive
            )
        )
    }

    func appGlassControl(
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        appGlassSurface(
            cornerRadius: AppGlassDesign.controlCornerRadius,
            tint: tint,
            interactive: interactive
        )
        .background(
            AppColor.controlFill,
            in: RoundedRectangle(
                cornerRadius: AppGlassDesign.controlCornerRadius,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    func appGlassSelection(
        _ isSelected: Bool,
        tint: Color = .accentColor
    ) -> some View {
        if isSelected {
            appGlassControl(
                tint: tint,
                interactive: true
            )
        } else {
            self
        }
    }
}

struct ContentView: View {
    // 인스펙터 표시 여부에 `$model.isCommitDetailsVisible` 바인딩을 넘겨야 해서 `@Bindable` 이다.
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stateAnimation: Animation? {
        reduceMotion
            ? .linear(duration: 0.10)
            : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    /// 사이드바 표시 여부의 단일 원본은 모델의 Bool 이다. 네이티브 분할선으로 사이드바를
    /// 접었을 때도 `⌘B` 메뉴 문구가 어긋나지 않도록 별도 `@State` 없이 양방향으로 변환한다.
    ///
    /// 현재 값은 `get` 클로저가 아니라 여기서 미리 읽는다. 프로퍼티 단위 관찰에서는 `body`
    /// 평가 중에 읽은 것만 추적되므로, 나중에 불리는 클로저 안에서만 읽으면 값이 바뀌어도
    /// 화면이 다시 그려지지 않는다.
    private var branchColumnVisibility: Binding<NavigationSplitViewVisibility> {
        let isVisible = model.isBranchSidebarVisible
        return Binding(
            get: { isVisible ? .doubleColumn : .detailOnly },
            set: { visibility in
                let isVisible = visibility != .detailOnly
                if model.isBranchSidebarVisible != isVisible {
                    model.isBranchSidebarVisible = isVisible
                }
            }
        )
    }

    var body: some View {
        // 얼럿의 표시 여부와 문구 모두 이 값 하나에서 나온다. 아래 클로저 안에서만 읽으면
        // 관찰에 잡히지 않으므로 body 평가 중인 여기서 한 번 읽어 둔다.
        let errorMessage = model.errorMessage

        Group {
            if model.workspaceURLs.isEmpty && model.isLoadingWorkspace {
                InitialWorkspaceLoadingView()
                    .transition(.opacity)
            } else if model.workspaceURLs.isEmpty {
                WelcomeView(model: model)
                    .transition(.opacity)
            } else {
                workspaceSplitView
                    .transition(.opacity)
            }
        }
        .animation(stateAnimation, value: model.isLoadingWorkspace)
        .animation(stateAnimation, value: model.workspaceURLs)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WorkspaceToolbarTabs(model: model)
            }

            // 저장소 상태·액션은 창 오른쪽 끝에 붙인다. 유연한 간격이 없으면 두 그룹이
            // 모두 왼쪽으로 몰려 탭 바로 옆에 붙는다.
            ToolbarItem(placement: .navigation) {
                Spacer()
            }

            ToolbarItem(placement: .primaryAction) {
                WorkspaceToolbarActions(model: model)
            }
        }
        .onAppear {
            model.restoreWorkspaceIfNeeded()
        }
        .alert(
            "GitScope 오류",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }

    /// 워크스페이스 탭을 바꾸면 세 열의 내용은 새로 만들되, 사용자가 분할선으로 조절한
    /// 열 너비는 유지해야 하므로 `id` 를 split view 가 아니라 각 열 내용에 건다.
    private var workspaceSplitView: some View {
        NavigationSplitView(columnVisibility: branchColumnVisibility) {
            BranchSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 420)
                .id(model.activeWorkspaceTabID)
        } detail: {
            HistoryView(model: model)
                .id(model.activeWorkspaceTabID)
        }
        .inspector(isPresented: $model.isCommitDetailsVisible) {
            CommitDetailsView(model: model)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 500)
                .id(model.activeWorkspaceTabID)
        }
        .overlay {
            if model.isLoadingWorkspace {
                WorkspaceLoadingOverlay()
                    .transition(.opacity)
            }
        }
    }
}

private struct InitialWorkspaceLoadingView: View {
    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(AppFont.loadingGlyph)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text("Git 로그를 불러오는 중")
                    .font(AppFont.loadingTitle)
                Text("저장소와 브랜치를 확인하고 커밋 그래프를 구성하고 있습니다.")
                    .font(AppFont.loadingBody)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Git 로그를 불러오는 중")
    }
}

private struct WorkspaceLoadingOverlay: View {
    var body: some View {
        ZStack {
            AppColor.windowBackground
                .opacity(0.36)

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Git 로그 업데이트 중…")
                    .font(AppFont.loadingBody.weight(.medium))
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppColor.separator.opacity(0.55), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Git 로그 업데이트 중")
    }
}

private struct WorkspaceToolbarTabs: View {
    var model: AppModel
    @State private var tabContentWidth: CGFloat = 640

    private let maximumTabContentWidth: CGFloat = 560

    /// 사이드바 토글은 `NavigationSplitView` 가 툴바에 기본 제공하므로 따로 두지 않는다.
    ///
    /// 이 HStack 에 `fixedSize(horizontal:)` 를 걸면 안 된다. 탭 스크롤 영역의 `minWidth: 0` 이
    /// 무시되고 최대 560pt 를 그대로 요구해, 툴바 고유 너비가 창 최소 너비를 220pt 넘게
    /// 밀어올린다. 그러면 좁은 창에서 사이드바 내용이 왼쪽으로 잘린다.
    var body: some View {
        HStack(spacing: 4) {
            if !model.workspaceTabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.workspaceTabs) { tab in
                            WorkspaceTabItem(
                                tab: tab,
                                isSelected: model.activeWorkspaceTabID == tab.id,
                                isDisabled: model.remoteOperation != nil,
                                onSelect: {
                                    model.activateWorkspaceTab(tab.id)
                                },
                                onClose: {
                                    model.closeWorkspaceTab(tab.id)
                                }
                            )
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: TabContentWidthPreferenceKey.self,
                                value: geometry.size.width
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(
                    minWidth: 0,
                    idealWidth: min(tabContentWidth, maximumTabContentWidth),
                    maxWidth: min(tabContentWidth, maximumTabContentWidth),
                    alignment: .leading
                )
                .layoutPriority(1)
                .onPreferenceChange(TabContentWidthPreferenceKey.self) { width in
                    tabContentWidth = width
                }
            }

            Button {
                model.openWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .disabled(model.remoteOperation != nil)
            .help("워크스페이스 열기 (⌘O)")
            .accessibilityLabel("워크스페이스 열기")
        }
        .font(AppFont.toolbarControl)
        .padding(.horizontal, 6)
    }
}

private struct WorkspaceToolbarActions: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            if model.repositories.count > 1 {
                Text("\(model.repositories.count)개 저장소")
                    .font(AppFont.rowLabel)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            // 아래 세 안내는 모두 얼럿 없이 아이콘과 툴팁으로만 알린다. 화면을 가리지 않으면서
            // 정상 상태와는 구별되게 하는 것이 목적이다.
            if let notice = model.repositoryLoadNotice {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(AppStatusColor.warning)
                    .help(notice)
                    .accessibilityLabel("일부 저장소를 불러오지 못함")
            }

            if let notice = model.autoFetchFailureNotice {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(AppStatusColor.warning)
                    .help(notice)
                    .accessibilityLabel("자동 가져오기가 계속 실패하는 중")
            }

            if let notice = model.githubActionsNotice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppStatusColor.warning)
                    .help(notice)
                    .accessibilityLabel("GitHub Actions 정보를 불러오지 못함")
            }

            if model.repositories.contains(where: { $0.githubRepository != nil }) {
                Button {
                    model.refreshGitHubActions()
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                }
                .help("GitHub Actions 상태 새로고침")
                .accessibilityLabel("GitHub Actions 상태 새로고침")
            }

            Button {
                model.fetchAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.repositories.isEmpty || model.isLoading)
            .help("모든 원격 저장소 가져오기 (⌘R)")
            .accessibilityLabel("모든 원격 저장소 가져오기")

            Button {
                withAnimation(AppMotion.pane) {
                    model.isCommitDetailsVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(
                        model.isCommitDetailsVisible ? Color.accentColor : .secondary
                    )
            }
            .help(
                model.isCommitDetailsVisible
                    ? "커밋 상세 숨기기 (⇧⌘B)"
                    : "커밋 상세 보기 (⇧⌘B)"
            )
            .accessibilityLabel(
                model.isCommitDetailsVisible ? "커밋 상세 숨기기" : "커밋 상세 보기"
            )
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 6)
    }
}

private struct TabContentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkspaceTabItem: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .font(AppFont.tabTitle.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(AppFont.decorativeGlyph)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("탭 닫기")
            .accessibilityLabel("\(tab.title) 탭 닫기")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 84, maxWidth: 170, minHeight: 24)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? AppColor.selectionFill
                        : AppColor.subtleFill
                )
        }
        .help(tab.subtitle)
    }
}

private struct WelcomeView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(AppFont.emptyStateGlyph)
                .foregroundStyle(.secondary)
            Text("Git 워크스페이스를 열어주세요")
                .font(AppFont.emptyStateTitle)
            Text("선택한 폴더와 하위 폴더의 Git 저장소를 한 화면에 표시합니다.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(.secondary)
            Button("워크스페이스 열기…") {
                model.openWorkspace()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
