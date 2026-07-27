# 자동 fetch 설계 (2026-07-27)

## 목적

지금은 원격 상태를 최신으로 맞추려면 사용자가 `⌘R`로 `fetch --all`을 직접
실행해야 한다. 자동 fetch는 이 작업을 백그라운드에서 대신 수행해, 앱을 보고
있는 동안 브랜치의 ahead/behind 수와 원격 브랜치 목록이 스스로 최신을
유지하도록 한다.

수동 `⌘R`은 그대로 남는다. 자동 fetch는 그 위에 얹히는 보조 수단이다.

## 요구사항

- 설정한 주기마다, 그리고 다른 앱에서 GitScope로 돌아왔을 때 자동으로
  `fetch --all` 실행
- 원격 ref가 실제로 바뀐 경우에만 화면 갱신. 변화가 없으면 사용자에게 아무
  변화도 보이지 않는다
- 갱신 시 선택 중이던 커밋과 상세 패널 유지
- 자동 fetch가 사용자의 조작을 막지 않는다
- 설정 창(`⌘,`)에서 켜고 끄기 + 주기 선택
- 실패는 조용히 넘어간다

## 동작 규칙

### 트리거

| 트리거 | 조건 |
|--------|------|
| 주기 타이머 | 설정 간격(기본 5분)마다 |
| 창 복귀 | `NSApplication.didBecomeActiveNotification`, 단 마지막 자동 fetch로부터 30초 경과 후 |

창 복귀에 최소 간격을 두는 이유는 앱을 빠르게 오갈 때 fetch가 연달아 실행되는
것을 막기 위해서다.

### 대상

활성 워크스페이스 탭에 로드된 저장소(`AppModel.repositories`)만 fetch한다.
비활성 탭의 저장소는 이미 메모리에서 해제되어 있으므로 대상이 아니다.

### 건너뛰는 조건

다음 중 하나라도 해당하면 이번 차례를 건너뛴다.

- 설정에서 자동 fetch가 꺼져 있음
- 로드된 저장소가 없음
- `remoteOperation != nil` — 수동 fetch·pull·push 진행 중
- `isLoadingWorkspace == true` — 워크스페이스 로딩 중
- 자동 fetch가 이미 진행 중

### 사용자 조작을 막지 않음

자동 fetch는 `remoteOperation`을 설정하지 않는다. 이 값은 툴바 fetch 버튼,
탭 전환, `⌘O`를 비활성화하는 UI 차단 플래그이며, 5분마다 조작이 막히면 방해가
된다. 진행 중임을 알리는 표시도 띄우지 않는다.

git 잠금 충돌은 별도 장치 없이 방지된다. `GitCommandRunner`가 `actor`이고
`AppModel`은 단일 `GitRemoteService` 인스턴스를 공유하므로, 수동 pull/push는
자동 fetch가 끝난 뒤 순차 실행된다.

### 실패 처리

자동 fetch 실패는 `errorMessage`를 건드리지 않고 조용히 넘어간다. 다음 주기에
다시 시도한다. 오프라인 상태에서 주기마다 에러 창이 뜨는 상황을 피하기 위한
선택이다. 에러 내용을 확인하고 싶으면 `⌘R` 수동 실행으로 볼 수 있다.

## 변화 감지

`GitRemoteService`에 다음을 추가한다.

```swift
func fetchAllDetectingChanges(repository: GitRepository) async throws -> Bool
```

1. `git for-each-ref --format=%(objectname) %(refname) refs/remotes refs/tags`로
   fetch 이전 스냅샷 확보
2. `git fetch --all` 실행
3. 같은 명령으로 이후 스냅샷 확보
4. 두 문자열이 다르면 `true`

저장소 중 하나라도 `true`면 갱신하고, 전부 `false`면 아무것도 하지 않는다.

## 조용한 갱신

`loadWorkspaces`에 조용한 경로를 추가한다. 기존 수동 경로의 동작은 바뀌지
않는다.

- `isLoadingWorkspace`를 켜지 않는다 → `WorkspaceLoadingOverlay`가 뜨지 않음
- 로드 시작 시 `clearSelection()`을 호출하지 않는다
- 로드 완료 후 선택 중이던 커밋이 새 목록에 남아 있으면 선택과 상세 패널을
  유지하고, 사라졌으면(rebase·force push 등) 그때만 선택을 해제한다

## 설정

`AppSettings`에 키 두 개를 추가한다.

| 키 | 기본값 |
|----|--------|
| `settings.autoFetchEnabled.v1` | `true` |
| `settings.autoFetchIntervalMinutes.v1` | `5` |

`SettingsView`에 기존 두 섹션과 같은 형태로 "자동 가져오기" 섹션을 둔다.

- `Toggle("자동으로 원격 저장소 가져오기")`
- `Picker("주기")` — 1분·5분·15분·30분, 토글이 꺼지면 비활성
- footer: 자동 fetch의 동작과 실패 시 조용히 넘어간다는 설명

설정 변경은 스케줄러 재시작으로 즉시 반영된다.

## 구조

### 새 파일: `Services/AutoFetchScheduler.swift`

`@MainActor final class`. 언제 실행할지만 판단하고, 실제 작업은 콜백으로
넘긴다. git도 `AppModel` 상태도 알지 못한다.

- `start(intervalMinutes:)` — 주기 타이머 시작, `didBecomeActive` 관찰 시작
- `stop()` — 타이머·관찰 해제
- `onFire: () async -> Void` — 실행 시점 콜백
- 마지막 실행 시각을 기록해 창 복귀 최소 간격(30초)을 스스로 판단
- 콜백이 실행되는 동안 중복 실행하지 않는다

### `GitRemoteService`

`fetchAllDetectingChanges(repository:)` 추가. 기존 `fetchAll`은 수동 경로가
계속 사용하므로 그대로 둔다.

### `AppModel`

- `autoFetchScheduler` 보유, 콜백을 `performAutoFetch()`로 연결
- `performAutoFetch()` — 건너뛰는 조건 검사 → 저장소 순회 fetch → 변화가
  있으면 조용한 갱신
- 워크스페이스 로드 완료 시 스케줄러 시작, `unloadCurrentWorkspace()`에서 중지
- 설정 변경 관찰(`UserDefaults.didChangeNotification`)로 주기·on/off 반영

## 범위 밖

- 자동 pull — fetch만 수행한다. 로컬 브랜치는 건드리지 않는다
- 비활성 탭 저장소의 백그라운드 fetch
- 실패 누적 시 지수 백오프 — 고정 주기로 재시도한다
- 새 커밋 도착 알림(배너·뱃지·시스템 알림)
- 스크롤 위치 복원 — 선택 커밋만 유지한다

## 검증

1. `xcodebuild` 빌드 통과
2. 주기를 1분으로 설정하고 다른 클론에서 push → 1분 안에 새 커밋이 목록에
   나타나고, 선택 중이던 커밋과 상세 패널이 유지되는지 확인
3. 원격 변화가 없는 주기에 화면 깜빡임이나 선택 해제가 없는지 확인
4. 네트워크를 끊은 상태로 주기를 넘겨 에러 창이 뜨지 않는지 확인
5. 자동 fetch가 도는 동안 탭 전환과 툴바 버튼이 막히지 않는지 확인
6. 설정 토글을 끄면 더 이상 fetch하지 않고, 주기를 바꾸면 즉시 반영되는지 확인
