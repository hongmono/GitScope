# 커밋 다중 선택 설계 (변경 파일 합집합 보기)

날짜: 2026-07-31
상태: 승인된 접근(A안: 선택 상태를 배열로 일반화) 기반 설계

## 배경과 목표

IntelliJ Git Log처럼 히스토리 목록에서 커밋 여러 개를 선택하면, 커밋 상세 영역에
선택된 커밋들에서 수정된 파일을 한 번에 보여준다.

- 다중 선택 제스처: 클릭(단일), ⌘클릭(토글), ⇧클릭(범위) — AppKit 기본 동작 사용
- 변경 파일: 선택된 각 커밋의 변경 파일 **합집합** (범위 diff 아님 — 띄엄띄엄 선택해도
  선택한 커밋의 변경만 정확히 반영)
- 파일 클릭 시: 그 파일을 건드린 선택 커밋들의 patch를 **커밋 오래된 순**으로 이어붙여
  표시, 각 patch 앞에 커밋 구분 헤더(짧은 해시 + 제목)
- 서로 다른 저장소의 커밋 동시 선택 **허용** — 파일 목록을 저장소별 섹션으로 표시
- 상단 메타데이터: "N개 커밋 선택" 요약 + 선택 커밋의 짧은 해시·제목 목록
- **작업 중(isWorkingTree) 행은 다중 선택에서 제외** — 작업 중 행을 선택하면 항상
  단일 선택으로 전환되고, 작업 중 행이 선택된 상태에서 다른 커밋을 ⌘클릭하면
  그 커밋의 단일 선택으로 바뀐다
- GitHub Actions 체크 상세는 단일 선택일 때만 로드·표시한다

범위 제외: 다중 선택 컨텍스트 메뉴 작업(cherry-pick 등), 범위 diff 모드, 선택 커밋 수 상한 외
가상 스크롤 성능 개선.

## 아키텍처

### 선택 상태 (AppModel)

- `selectedCommit: GitCommit?` → `selectedCommits: [GitCommit]`으로 교체.
  순서는 히스토리 목록(타임라인) 순서를 따른다. 파생 프로퍼티
  `selectedCommit: GitCommit? { selectedCommits.count == 1 ? selectedCommits[0] : nil }`을
  남겨 단일 선택을 전제하는 기존 코드(GitHub checks, 팝오버 등)의 변경 폭을 줄인다.
- `selectCommit(_:)`은 유지(단일 선택)하고, 다중 선택 진입점
  `selectCommits(_ commits: [GitCommit])`을 추가한다. 이 함수가 유일한 정규화 지점:
  - `isWorkingTree` 커밋이 포함되면 그 커밋 하나의 단일 선택으로 축소
  - 빈 배열이면 `clearSelection()`
  - 목록(row) 순서로 정렬해 저장
- `QuietSelection.commitID: CommitID?` → `commitIDs: [CommitID]`로 확장. 자동 fetch 후
  복원 시 여전히 존재하는 커밋만 남기고 복원한다.

### 목록 다중 선택 (HistoryCollectionBridge)

- `allowsMultipleSelection = true`. ⌘/⇧클릭 제스처는 NSCollectionView가 처리한다.
- `didSelectItemsAt`/`didDeselectItemsAt`에서 개별 IndexPath가 아니라
  `collectionView.selectionIndexPaths` **전체**를 커밋 배열로 변환해
  `onSelectionChange?([GitCommit])` 한 개의 콜백으로 모델에 전달한다.
  (기존 `onSelect`/`onClearSelection` 두 콜백을 대체)
- 작업 중 행 제약은 델리게이트가 아니라 모델(`selectCommits`)에서 정규화하고,
  정규화 결과가 뷰의 selectionIndexPaths와 다르면 기존 `isSynchronizingSelection`
  가드 패턴으로 되돌려 그린다.
- 프로그램적 선택 복원(`selectedCommitID` 동기화 로직)은 `selectedCommitIDs: Set<CommitID>`
  기준으로 바꾼다.

### 상세 로딩 (AppModel + GitRepositoryLoader)

- `loadDetails`는 커밋 단위 API 그대로 두고, AppModel이 선택된 커밋들의 details를
  `withThrowingTaskGroup`으로 병렬 로드해 `selectedDetailsList: [CommitDetails]`
  (선택 순서)를 만든다. 단일 선택은 원소 1개인 같은 경로를 쓴다.
  기존 `selectedDetails: CommitDetails?`는 제거하고 뷰는 리스트를 소비한다.
- 일부 커밋의 details 로드가 실패하면: 성공한 커밋들로 목록을 구성하고 실패는
  기존 `errorMessage` 규칙(`저장소 · 해시: 메시지`)으로 안내한다. 전부 실패면 에러만.
- 선택이 바뀌면 진행 중인 detailsTask/patchTask를 기존 패턴대로 취소한다.
  로드 완료 시 선택이 그대로인지 확인하는 가드도 기존 패턴(선택 ID 비교)을 따른다.

### 합집합 파일 목록 (파생 모델)

새 파생 타입을 모델 계층에 둔다 (뷰에서 조립하지 않는다):

```swift
struct MergedChangedFile: Identifiable, Sendable {
    let repositoryID: RepositoryID
    let path: String
    let statuses: [String]          // 커밋별 상태 (중복 제거·순서 유지)
    let commits: [GitCommit]        // 이 파일을 건드린 선택 커밋 (오래된 순)
    var id: String { "\(repositoryID.rawValue)::\(path)" }
}
```

- `[CommitDetails]` → `[MergedChangedFile]` 병합 함수는 순수 함수로 두고 단위 테스트한다.
- 같은 파일이 여러 커밋에서 수정되면 한 항목으로 합치고 배지에 커밋 수를 표시한다.
- 상태 표기는 커밋별 상태가 섞이면(M+D 등) 마지막 커밋의 상태를 대표로 쓰되
  툴팁에 전체를 나열한다.
- 저장소가 2개 이상 걸치면 저장소별 섹션 헤더(저장소 이름)로 묶는다.
  단일 저장소면 헤더를 숨긴다(기존 "단일 저장소에서 저장소 열 숨김" 관례와 동일).

### 파일 patch 이어붙이기

- `selectChangedFile`은 `MergedChangedFile` 기준으로 바꾼다. 파일의 `commits`를
  오래된 순으로 순회하며 기존 `loadPatch(commit:repository:file:)`를 호출하고,
  각 patch 앞에 구분 헤더 줄("― <짧은해시> <제목>")을 붙여 이어붙인다.
- `DiffLine.Kind`에 `commitHeader` 케이스를 추가해 구분 헤더를 시각적으로 구별한다.
- 단일 커밋 선택이면 구분 헤더를 붙이지 않는다 (기존과 동일한 화면).

### 상세 뷰 (CommitDetailsView)

- 단일 선택: 기존 화면 그대로 (메시지·작성자·해시·Actions·파일·diff).
- 다중 선택: 상단에 "N개 커밋 선택 · 파일 M개" 요약과 선택 커밋 목록
  (짧은 해시 + 제목 한 줄씩, 스크롤 가능한 컴팩트 리스트), 아래에 합집합 파일 목록.
  Actions 체크 영역은 표시하지 않는다.
- 빈 선택: 기존 placeholder 유지.

## 영향 범위 정리

`selectedCommit`을 읽는 기존 코드의 처리 방침:

- `loadSelectedGitHubChecks`: 단일 선택일 때만 호출 (파생 `selectedCommit` 사용)
- 커밋 우클릭 팝오버, 그래프 강조: 파생 `selectedCommit` 기준 유지 (다중 선택 시
  목록 하이라이트는 NSCollectionView 선택 표시가 담당)
- `refresh()` 후 사라진 커밋 정리(`AppModel.swift`의 selectedCommit 존재 확인 로직):
  `selectedCommits`에서 사라진 커밋만 걸러내고, 전부 사라지면 clearSelection

## 테스트

- 병합 함수 단위 테스트: 합집합·중복 파일 병합·커밋 수 배지·저장소별 그룹·순서
  (오래된 순) / 상태 혼합 표기
- `selectCommits` 정규화: isWorkingTree 포함 시 단일 축소, 빈 배열 clear, 순서 정렬
- patch 이어붙이기: 실제 git 저장소로 두 커밋이 같은 파일을 수정한 경우 헤더 포함
  결합 출력 검증 (기존 통합 테스트 패턴)
- QuietSelection 복원: 일부 커밋이 사라진 뒤 남은 커밋만 복원

## 구현 순서 제안

1. 모델: `MergedChangedFile` + 병합 순수 함수 + 테스트
2. AppModel: `selectedCommits` 전환, `selectCommits` 정규화, details 병렬 로드,
   patch 이어붙이기, QuietSelection 확장 + 테스트
3. HistoryCollectionBridge: 다중 선택 활성화와 selectionIndexPaths 동기화
4. CommitDetailsView: 다중 선택 헤더·저장소 섹션·commitHeader diff 라인
5. 통합 테스트와 빌드 검증
