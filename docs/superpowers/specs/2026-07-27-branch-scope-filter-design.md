# 브랜치 범위 필터 설계 (2026-07-27)

## 목적

지금 히스토리의 브랜치 축은 한 번에 하나만 고를 수 있다. 사이드바에서 브랜치를
클릭하면 그 브랜치에서 도달 가능한 커밋만 남고, 여러 브랜치를 함께 보려면 필터를
아예 꺼서 모든 커밋을 보는 수밖에 없다.

브랜치가 수백 개인 저장소에서는 이 둘 사이가 너무 멀다. 실제로 필요한 것은
`origin/main`, `origin/dev`, `origin/prod`, 그리고 내가 만든 로컬 브랜치 정도이고,
나머지 팀원들의 feature 브랜치는 히스토리에서 지워져 있는 편이 낫다.

브랜치 범위는 그 "관심 있는 브랜치 집합"을 한 번 정해두고 계속 쓰는 필터다.

## 요구사항

- 여러 브랜치를 함께 골라 그 합집합을 히스토리에 표시
- "로컬 브랜치 전부"를 하나의 항목으로 고를 수 있고, 새로 만든 로컬 브랜치는
  자동으로 포함
- 한 번 정한 집합은 탭별로 저장되어 앱을 다시 켜도 남는다
- 기존 사이드바 단일 선택 동작은 그대로 유지
- 사이드바 선택을 풀면 저장해둔 집합으로 즉시 돌아온다

## 개념 — 두 층으로 나뉜 브랜치 축

| 층 | 이름 | 개수 | 수명 | 조작 위치 |
|----|------|------|------|-----------|
| 넓은 쪽 | 브랜치 범위 (신규) | 여러 개 | 탭별 저장, 재시작 후 복원 | 필터 바 브랜치 메뉴 |
| 좁은 쪽 | 브랜치 선택 (기존) | 하나 | 임시 | 사이드바 클릭 |

두 층은 교집합이 아니라 **덮어쓰기** 관계다.

- 사이드바 선택이 있으면 → 그 브랜치만 (현재 동작과 동일)
- 선택을 풀면 → 저장해둔 범위로 복귀
- 범위도 비어 있으면 → 모든 커밋

교집합으로 만들면 범위에 없는 브랜치를 사이드바에서 클릭했을 때 빈 화면이 된다.
사용자는 그 순간 "이 브랜치를 보고 싶다"고 말한 것이므로, 좁은 쪽이 이겨야 한다.

## 상태

`Models/GitModels.swift`에 값 타입을 하나 추가한다.

```swift
struct BranchScope: Equatable, Codable, Sendable {
    /// 체크한 ref 그룹의 ID. `MergedReferenceGroup.id` 와 같은 "kind::shortName" 형태.
    var referenceGroupIDs: Set<String>
    /// "로컬 브랜치 전부" 동적 그룹.
    var includesAllLocalBranches: Bool

    var isActive: Bool { includesAllLocalBranches || !referenceGroupIDs.isEmpty }

    static let empty = BranchScope(referenceGroupIDs: [], includesAllLocalBranches: false)
}
```

저장소 경로가 아니라 **이름**을 기억한다. 워크스페이스에 저장소가 여러 개일 때
`origin/main`을 한 번 체크하면 그 이름을 가진 모든 저장소의 브랜치가 함께
들어간다. 사이드바가 이미 `MergedReferenceGroup`으로 같은 규칙을 쓰고 있다.

`AppModel`에 다음을 더한다.

```swift
@Published private(set) var branchScope: BranchScope = .empty
@Published private(set) var isLoadingBranchScope = false
private var branchScopeMembership: Set<CommitID>?
private var branchScopeTask: Task<Void, Never>?
```

`isLoading`에 `isLoadingBranchScope`를 합류시킨다.

### 조작 API

```swift
func toggleBranchScopeMember(_ group: MergedReferenceGroup)
func removeBranchScopeMember(id: String)
func toggleAllLocalBranchesInScope()
func clearBranchScope()
```

넷 다 `branchScope`를 갱신하고, 탭에 저장한 뒤 `reloadBranchScopeMembership()`을
부른다. `clearBranchScope()`는 범위만 비우며 사이드바 선택은 건드리지 않는다.
필터 메뉴의 "모든 브랜치"는 이 둘을 함께 초기화한다.

`removeBranchScopeMember(id:)`는 지금 워크스페이스에 없는 브랜치를 해제하기
위한 경로다. 아래 "사라진 브랜치 항목" 참고.

## 커밋 집합 계산

`GitRepositoryLoader`의 기존 단일 revision 메서드 옆에 복수형을 추가한다.

```swift
func loadReachableCommitIDs(
    repository: GitRepository,
    revisions: [String],
    includesAllLocalBranches: Bool,
    limit: Int = 50_000
) async throws -> Set<CommitID>
```

인자는 이렇게 조립된다.

```
git -c color.ui=false rev-list --max-count=50000 [--branches] <ref1> <ref2> ...
```

`--branches`가 "로컬 브랜치 전부"를 대신하므로, 로컬 브랜치가 200개여도 호출은
저장소당 1회다. 개별 ref는 `MergedReferenceGroup`에서 해당 저장소에 실제로
존재하는 `fullName`만 뽑아 넘긴다.

`AppModel.reloadBranchScopeMembership()`의 동작:

- `branchScope.isActive == false` → `branchScopeMembership = nil`, 즉시 `rebuildRows()`
- 활성이면 저장소를 순회하며 `rev-list` 실행 후 합집합
- 그 저장소에 넘길 ref가 하나도 없고 `--branches`도 아니면 건너뛴다
- 범위에 현재 브랜치가 포함되면 해당 저장소의 `WORKTREE` 커밋 ID를 넣는다.
  `includesAllLocalBranches`면 항상 포함이고, 아니면 체크된 그룹 중
  `isCurrent`인 것이 있을 때만 포함한다
- `branchScopeTask`로 감싸고, 새 요청이 오면 이전 것을 취소한다.
  `referenceTask`와 같은 패턴

호출 시점:

- `branchScope` 변경 직후
- `loadWorkspaces` 완료 후 (수동·조용한 갱신 모두). 탭에서 복원한 범위를 그때
  처음 계산한다
- `unloadCurrentWorkspace()`에서 `branchScope`·membership·task 정리

## 히스토리 필터 적용

`rebuildRows()`의 브랜치 조건 한 줄을 바꾼다.

```swift
if let branchMembership {                     // 사이드바 선택이 이긴다
    if !branchMembership.contains(commit.id) { return false }
} else if let branchScopeMembership {         // 없을 때만 범위가 적용된다
    if !branchScopeMembership.contains(commit.id) { return false }
}
```

`selectRepository(nil)`이 `branchMembership`을 `nil`로 되돌리므로, 사이드바
선택 해제 시 범위 복귀는 별도 코드 없이 이 분기만으로 이루어진다.

## UI — 필터 바 브랜치 메뉴

`HistoryView.swift`의 브랜치 `FilterMenu`를 교체한다.

```
모든 브랜치 (필터 끄기)
────────────────────
☑ 로컬 브랜치 전부          ← 체크 여부와 무관하게 항상 이 자리
☑ origin/main               ← 체크된 개별 항목만 평평하게
☑ origin/dev
☑ origin/prod
────────────────────
로컬                     ▸
원격                     ▸
  └ origin/            ▸
      ☑ main
      ☐ hotfix
      feature/         ▸
태그                     ▸
```

- **모든 브랜치** — 범위를 비우고 사이드바 선택도 해제한다
- **로컬 브랜치 전부** — 서브메뉴에 숨기지 않는다. 이 기능의 핵심 항목이라
  발견 가능해야 한다
- **체크된 항목** — 상단에 평평하게 모아 한 번에 끄고 켤 수 있게 한다.
  `includesAllLocalBranches` 다음에 kind·이름 순으로 정렬
- **사라진 브랜치 항목** — 체크해둔 브랜치가 지금 워크스페이스에 없으면 저장된
  ID에서 이름을 꺼내 같은 상단 목록에 `origin/prod (없음)`으로 흐리게 그린다.
  누르면 `removeBranchScopeMember(id:)`로 해제된다. 이 항목을 감추면 해제할
  방법이 "모든 브랜치"로 전부 지우는 것뿐이라 막다른 상태가 된다
- **종류별 서브메뉴** — 사이드바와 같은 폴더 트리. 각 항목에
  `checkmark.square.fill` / `square` 아이콘을 붙여 토글

버튼 제목:

| 상태 | 제목 |
|------|------|
| 사이드바 선택 있음 | 그 브랜치 이름 (현재와 동일) |
| 선택 없고 범위 활성 | `브랜치 N개` (N = 체크 수 + 로컬 전부 1) |
| 둘 다 없음 | `브랜치` |

`isActive`는 둘 중 하나라도 켜져 있으면 참이다.

### 폴더 트리 공유

`BranchSidebarView.swift`가 private으로 갖고 있는 `ReferenceFolder`,
`MutableReferenceFolder`, 트리 구성 코드를 `Views/ReferenceTree.swift`로 옮겨
사이드바와 필터 메뉴가 함께 쓴다. 두 곳의 계층이 어긋나면 곧바로 혼란이 되는
부분이라 복제하지 않는다. 사이드바 쪽 동작은 바뀌지 않는다.

메뉴 안의 재귀는 사이드바와 마찬가지로 함수가 아니라 뷰 타입으로 만든다.
`@ViewBuilder` 함수를 자기 자신으로 재귀시키면 반환 타입이 순환한다.

### 감수하는 점

macOS 메뉴는 항목을 누르면 닫히므로 브랜치 4개를 체크하려면 메뉴를 4번 열어야
한다. 기존 "경로" 필터도 같은 방식이라 일관은 맞고, 처음 한 번만 겪는 번거로움이다.
메뉴를 열어둔 채 여러 개를 체크하려면 `NSMenu`를 직접 만들어야 해서 이번 범위에
넣지 않는다.

## 저장

`WorkspaceTab`에 필드를 하나 더한다.

```swift
var branchScope: BranchScope
```

`hiddenRepositoryPaths`를 추가할 때 쓴 `decodeIfPresent` 패턴을 그대로 따라, 이
필드가 없던 시절에 저장된 탭도 그대로 열린다. 기본값은 `.empty`다.

`persistBranchScope()`는 `persistRepositoryVisibility()`와 같은 형태로, 활성 탭을
찾아 값이 실제로 바뀐 경우에만 `persistWorkspaceTabs()`를 부른다.

저장소 필터는 **숨긴 쪽**을 기억하고(새 저장소는 기본 표시), 브랜치 범위는
**체크한 쪽**을 기억한다(기본은 필터 꺼짐). 방향이 반대인 것은 각각의 기본값이
반대이기 때문이다.

## 엣지 케이스

- **체크한 브랜치가 사라짐** — 저장 목록에서 지우지 않는다. `origin/prod`가
  잠깐 없어졌다가 fetch로 돌아왔을 때 체크가 살아 있어야 한다. 계산할 때만
  존재하지 않는 ref를 걸러내고, 메뉴에는 `(없음)`으로 남겨 직접 해제할 수 있게
  한다
- **일부 저장소에서 `rev-list` 실패** — 그 저장소만 건너뛰고 나머지로 계산한다.
  전부 실패해야 `errorMessage`를 띄운다. `selectReferenceGroup`의
  `successfulLoadCount` 처리와 같은 규칙
- **범위에 걸리는 커밋이 없음** — 기존 "표시할 커밋이 없습니다" 화면이 그대로
  나온다
- **탭 전환** — 탭마다 다른 범위를 갖는다. `unloadCurrentWorkspace()`가 상태를
  비우고, 다음 탭 로드 완료 시 그 탭의 범위로 다시 계산한다
- **조용한 갱신** — 자동 fetch 후에도 범위를 다시 계산한다. 새 커밋이 범위 안
  브랜치에 들어왔으면 목록에 나타나야 한다

## 범위 밖

- 사이드바 다중 선택 — 사이드바는 지금처럼 하나만 고른다
- 사이드바 우클릭 "필터에 추가" — 필터 메뉴 한 곳에서만 조작한다
- 이름 붙여 저장하는 여러 개의 프리셋 — 탭당 하나의 범위만 갖는다
- 글로브 패턴(`feature/*`) 입력 — 동적 그룹은 "로컬 브랜치 전부" 하나뿐이다
- 사이드바 목록 자체를 줄이는 것 — 이 필터는 히스토리에만 적용된다
- 범위를 브랜치 사이드바의 ahead/behind 표시나 GitHub Actions 조회에 반영하는 것

## 검증

테스트 타깃이 없는 프로젝트이므로 빌드와 수동 QA로 확인한다.

1. `xcodebuild` 빌드 통과
2. `origin/main`·`origin/dev` 두 개를 체크하면 두 브랜치의 합집합만 남고, 버튼
   제목이 `브랜치 2개`로 바뀌는지 확인
3. "로컬 브랜치 전부"를 켠 뒤 새 로컬 브랜치를 만들고 `⌘R` → 별도 조작 없이
   그 브랜치의 커밋이 포함되는지 확인
4. 범위가 켜진 상태에서 사이드바의 다른 브랜치를 클릭 → 그 브랜치만 보이고,
   선택을 풀면 범위로 돌아오는지 확인. 범위에 없는 브랜치를 클릭해도 정상
   표시되는지 확인
5. 앱을 껐다 켜고 범위가 복원되는지 확인
6. 탭을 두 개 열고 각각 다른 범위를 설정한 뒤 오가며 서로 침범하지 않는지 확인
7. 저장소 두 개를 한 탭에 열고 같은 이름의 브랜치가 양쪽에서 함께 잡히는지 확인
8. 체크한 원격 브랜치를 삭제하고 fetch → 나머지 범위가 유지되고, 브랜치를
   되살리면 체크가 살아 있는지 확인
9. 범위가 켜진 상태에서 자동 fetch로 새 커밋이 들어왔을 때 목록에 반영되는지 확인
