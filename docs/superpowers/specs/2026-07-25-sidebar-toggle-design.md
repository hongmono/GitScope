# 사이드바 토글 설계 (2026-07-25)

## 목적

GitScope 워크스페이스 화면의 왼쪽 브랜치 사이드바와 오른쪽 커밋 상세 패널을
버튼과 키보드 단축키로 숨기고 다시 표시할 수 있게 한다. 히스토리 그래프를
넓게 보고 싶을 때 주변 패널을 접는 것이 목표다.

## 요구사항

- ⌘B: 왼쪽 브랜치 사이드바(`BranchSidebarView`) 토글
- ⇧⌘B: 오른쪽 커밋 상세 패널(`CommitDetailsView`) 토글
- 상단 툴바에 각 패널용 토글 버튼 제공
- macOS 표준 "보기" 메뉴에 토글 항목 노출
- 접힘 상태는 앱 재실행 후에도 유지

## 설계

### 상태 (AppModel)

- `@Published var isBranchSidebarVisible: Bool` (기본값 `true`)
- `@Published var isCommitDetailsVisible: Bool` (기본값 `true`)
- `didSet`에서 UserDefaults 저장, `init`에서 복원
- 키: `branchSidebarVisible.v1`, `commitDetailsVisible.v1`
  (기존 `workspaceTabs.v1` 네이밍 컨벤션을 따름)

### 레이아웃 (ContentView)

`workspaceContent`의 `HSplitView` 안에서 조건부 렌더링:

- `isBranchSidebarVisible`가 `false`면 `BranchSidebarView`를 뷰 트리에서 제거
- `isCommitDetailsVisible`가 `false`면 `CommitDetailsView`를 제거
- 남은 폭은 `HistoryView`가 차지. 둘 다 숨기면 히스토리 단독 전체 폭
- `HSplitView`는 SwiftUI 애니메이션과 궁합이 나빠 전환은 즉시(애니메이션 없음)

### 버튼 (ToolWindowTabs)

- 맨 왼쪽(탭 앞)에 `sidebar.leading` 아이콘 버튼 — 왼쪽 사이드바 토글,
  help 툴팁 "브랜치 사이드바 숨기기/보기 (⌘B)"
- 맨 오른쪽(fetch 버튼 뒤)에 `sidebar.trailing` 아이콘 버튼 — 상세 패널 토글,
  help 툴팁 "커밋 상세 숨기기/보기 (⇧⌘B)"
- 기존 툴바 버튼과 동일한 `.plain` 스타일. disabled 조건 없음(항상 토글 가능)

### 메뉴·단축키 (GitScopeApp)

`commands`에 `CommandGroup(after: .sidebar)` 추가:

- "브랜치 사이드바 숨기기/보기" — `.keyboardShortcut("b", modifiers: .command)`
- "커밋 상세 숨기기/보기" — `.keyboardShortcut("b", modifiers: [.command, .shift])`
- 메뉴 라벨은 현재 상태에 따라 "숨기기"/"보기"로 전환
- 기존 단축키(⌘O, ⌘R, ⌘1–9)와 충돌 없음

## 범위 밖

- 패널 전환 애니메이션
- 사이드바 폭 기억(HSplitView 기본 동작에 위임)
- Welcome/로딩 화면 동작 변경(워크스페이스 콘텐츠에만 적용)

## 검증

1. `xcodebuild` 빌드 통과
2. 앱 실행 후: 버튼 2개·단축키 2개·보기 메뉴 항목으로 각 패널 토글 확인
3. 패널을 숨긴 채 앱 재실행 → 접힘 상태 복원 확인
