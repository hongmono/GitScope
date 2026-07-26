# 사이드바 토글 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 왼쪽 브랜치 사이드바(⌘B)와 오른쪽 커밋 상세 패널(⇧⌘B)을 버튼·단축키·보기 메뉴로 숨기고 표시하며, 상태를 재실행 후에도 유지한다.

**Architecture:** `AppModel`에 `@Published` 가시성 상태 2개를 추가하고 UserDefaults로 영구 저장한다. `ContentView`의 `HSplitView`에서 조건부 렌더링으로 패널을 넣고 빼며, 상단 툴바 버튼과 앱 `commands`의 보기 메뉴 항목이 같은 상태를 토글한다.

**Tech Stack:** SwiftUI (macOS 14+), Swift 6 (strict concurrency), UserDefaults, XcodeGen 프로젝트

## Global Constraints

- 스펙: `docs/superpowers/specs/2026-07-25-sidebar-toggle-design.md`
- 이 프로젝트는 테스트 타깃이 없다 (단일 app 타깃). 각 태스크의 검증은 빌드 통과이며, 최종 태스크에서 수동 QA를 수행한다. 테스트 타깃 신설은 범위 밖.
- 빌드 명령 (레포 루트에서): `xcodebuild -project GitScope.xcodeproj -scheme GitScope -configuration Debug build`
- 새 소스 파일을 만들지 않으므로 `xcodegen` 재생성 불필요.
- UserDefaults 키 네이밍은 기존 `workspaceTabs.v1` 컨벤션을 따른다: `branchSidebarVisible.v1`, `commitDetailsVisible.v1`
- 사용자-facing 문구는 한국어, 기존 툴바/메뉴 문구 톤을 따른다 (예: "워크스페이스 열기 (⌘O)").
- 패널 전환 애니메이션 없음. 토글 버튼에 disabled 조건 없음.
- 커밋 메시지는 Conventional Commits (`feat:` 등) + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

---

### Task 1: AppModel 가시성 상태 + 영구 저장

**Files:**
- Modify: `GitScopeApp/App/AppModel.swift` (프로퍼티 선언부 ~45행, 키 상수부 ~63행)

**Interfaces:**
- Consumes: 없음
- Produces: `AppModel.isBranchSidebarVisible: Bool`, `AppModel.isCommitDetailsVisible: Bool` — 둘 다 `@Published var` (외부에서 직접 toggle 가능), 기본값 `true`. Task 2·3이 이 두 프로퍼티를 읽고 토글한다.

- [x] **Step 1: 가시성 프로퍼티 추가**

`AppModel.swift`의 `@Published private(set) var isCurrentBranchesSelected = false` (45행) 바로 아래에 추가:

```swift
    @Published var isBranchSidebarVisible =
        UserDefaults.standard.object(
            forKey: AppModel.branchSidebarVisibleDefaultsKey
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                isBranchSidebarVisible,
                forKey: Self.branchSidebarVisibleDefaultsKey
            )
        }
    }
    @Published var isCommitDetailsVisible =
        UserDefaults.standard.object(
            forKey: AppModel.commitDetailsVisibleDefaultsKey
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                isCommitDetailsVisible,
                forKey: Self.commitDetailsVisibleDefaultsKey
            )
        }
    }
```

`object(forKey:) as? Bool ?? true`를 쓰는 이유: `bool(forKey:)`는 키가 없을 때 `false`를 돌려주므로 기본값 `true`를 표현할 수 없다. `didSet`은 프로퍼티 기본값 초기화 시에는 불리지 않으므로 복원 시 재저장이 발생하지 않는다. 초기값 식에서는 클래스 저장 프로퍼티 제약상 `Self.` 대신 `AppModel.`로 키 상수를 참조한다.

- [x] **Step 2: UserDefaults 키 상수 추가**

같은 파일의 `private static let activeWorkspaceTabDefaultsKey = "activeWorkspaceTabID.v1"` (64행) 바로 아래에 추가:

```swift
    private static let branchSidebarVisibleDefaultsKey = "branchSidebarVisible.v1"
    private static let commitDetailsVisibleDefaultsKey = "commitDetailsVisible.v1"
```

- [x] **Step 3: 빌드로 검증**

Run: `xcodebuild -project GitScope.xcodeproj -scheme GitScope -configuration Debug build`
Expected: `** BUILD SUCCEEDED **` (Swift 6 strict concurrency 오류 없음)

- [x] **Step 4: Commit**

```bash
git add GitScopeApp/App/AppModel.swift
git commit -m "feat: add sidebar visibility state to AppModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: ContentView 조건부 렌더링 + 툴바 토글 버튼

**Files:**
- Modify: `GitScopeApp/Views/ContentView.swift` (`workspaceContent` 58–69행, `ToolWindowTabs.body` 135–229행)

**Interfaces:**
- Consumes: `AppModel.isBranchSidebarVisible`, `AppModel.isCommitDetailsVisible` (Task 1)
- Produces: 없음 (UI 최종 소비자)

- [x] **Step 1: `workspaceContent`에 조건부 렌더링 적용**

`ContentView.swift`의 `workspaceContent` 프로퍼티(58–69행)를 다음으로 교체:

```swift
    private var workspaceContent: some View {
        HSplitView {
            if model.isBranchSidebarVisible {
                BranchSidebarView(model: model)
                    .frame(minWidth: 235, idealWidth: 285, maxWidth: 380)
            }

            HistoryView(model: model)
                .frame(minWidth: 650, idealWidth: 900)

            if model.isCommitDetailsVisible {
                CommitDetailsView(model: model)
                    .frame(minWidth: 300, idealWidth: 480)
            }
        }
    }
```

- [x] **Step 2: 툴바 왼쪽에 사이드바 토글 버튼 추가**

`ToolWindowTabs.body`의 `HStack(spacing: 4) {` (136행) 바로 다음, `if !model.workspaceTabs.isEmpty {` 앞에 추가:

```swift
            Button {
                model.isBranchSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.plain)
            .help(
                model.isBranchSidebarVisible
                    ? "브랜치 사이드바 숨기기 (⌘B)"
                    : "브랜치 사이드바 보기 (⌘B)"
            )
```

- [x] **Step 3: 툴바 오른쪽에 상세 패널 토글 버튼 추가**

같은 `HStack`에서 fetch 버튼(`arrow.clockwise`, 216–223행) 바로 아래에 추가:

```swift
            Button {
                model.isCommitDetailsVisible.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.plain)
            .help(
                model.isCommitDetailsVisible
                    ? "커밋 상세 숨기기 (⇧⌘B)"
                    : "커밋 상세 보기 (⇧⌘B)"
            )
```

- [x] **Step 4: 빌드로 검증**

Run: `xcodebuild -project GitScope.xcodeproj -scheme GitScope -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 5: Commit**

```bash
git add GitScopeApp/Views/ContentView.swift
git commit -m "feat: add sidebar toggle buttons and conditional panels

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: 보기 메뉴 항목 + 단축키 (⌘B / ⇧⌘B)

**Files:**
- Modify: `GitScopeApp/App/GitScopeApp.swift` (`commands` 블록 46–84행)

**Interfaces:**
- Consumes: `AppModel.isBranchSidebarVisible`, `AppModel.isCommitDetailsVisible` (Task 1)
- Produces: 없음

- [x] **Step 1: CommandGroup 추가**

`GitScopeApp.swift`의 `.commands {` 블록 안, `CommandGroup(replacing: .newItem) { ... }` 닫는 중괄호(59행) 바로 아래에 추가:

```swift
            CommandGroup(after: .sidebar) {
                Button(
                    model.isBranchSidebarVisible
                        ? "브랜치 사이드바 숨기기"
                        : "브랜치 사이드바 보기"
                ) {
                    model.isBranchSidebarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(
                    model.isCommitDetailsVisible
                        ? "커밋 상세 숨기기"
                        : "커밋 상세 보기"
                ) {
                    model.isCommitDetailsVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
```

`CommandGroupPlacement.sidebar`는 macOS 표준 "보기(View)" 메뉴의 사이드바 명령 영역에 배치된다. 기존 단축키(⌘O, ⌘R, ⌘1–9)와 충돌 없음.

- [x] **Step 2: 빌드로 검증**

Run: `xcodebuild -project GitScope.xcodeproj -scheme GitScope -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 3: Commit**

```bash
git add GitScopeApp/App/GitScopeApp.swift
git commit -m "feat: add view menu items and shortcuts for sidebar toggles

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: 수동 QA + 코드 리뷰

**Files:**
- 없음 (검증만)

**Interfaces:**
- Consumes: Task 1–3의 전체 기능
- Produces: 검증 결과 보고

- [x] **Step 1: 앱 실행 후 수동 QA**

Debug 빌드 산출물을 실행하고 스펙의 검증 항목을 확인:

1. 툴바 왼쪽 `sidebar.leading` 버튼 클릭 → 브랜치 사이드바가 사라지고 히스토리가 넓어짐. 다시 클릭 → 복귀.
2. 툴바 오른쪽 `sidebar.trailing` 버튼 클릭 → 커밋 상세 패널 토글.
3. ⌘B / ⇧⌘B 단축키로 동일 동작 확인.
4. 메뉴 바 "보기" 메뉴에 두 항목이 보이고, 상태에 따라 "숨기기"/"보기" 라벨이 바뀌는지 확인.
5. 두 패널 모두 숨김 → 히스토리 단독 전체 폭 확인.
6. 사이드바를 숨긴 채 앱 종료 후 재실행 → 접힘 상태 복원 확인.

Expected: 6개 항목 모두 통과. 실패 항목은 수정 후 해당 태스크의 빌드·커밋 단계를 반복.

- [x] **Step 2: code-reviewer 서브에이전트 실행**

변경된 3개 파일(diff 기준)에 대해 `code-reviewer` 서브에이전트로 리뷰를 수행하고, 지적 사항이 있으면 수정 후 재빌드·커밋.
