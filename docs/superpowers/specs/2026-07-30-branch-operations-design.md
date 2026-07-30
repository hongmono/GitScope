# 브랜치 작업 고도화 설계 (rebase · pull · push · 삭제)

날짜: 2026-07-30
상태: 승인된 접근(A안: 기존 구조 확장) 기반 설계

## 배경과 목표

GitScope는 현재 브랜치 우클릭 메뉴에서 `pull --rebase`(현재 브랜치 한정)와 upstream push만 지원한다.
이번 작업은 브랜치 사이드바를 중심으로 다음을 추가·고도화한다.

1. **브랜치 rebase** — 현재 체크아웃된 브랜치를 우클릭한 다른 브랜치 위로 rebase
2. **pull 고도화** — 체크아웃되지 않은 로컬 브랜치를 fast-forward로 원격과 동기화
3. **push 고도화** — upstream이 없는 로컬 브랜치를 `push -u`로 게시
4. **삭제** — 로컬 브랜치, 원격 브랜치, 태그 삭제 (확인 다이얼로그 + 미병합 경고)

범위 제외: 인터랙티브 rebase, 충돌 해결 UI, force push, merge, checkout, commit.
충돌이 나면 기존 `pullRebase`와 동일하게 **자동 `rebase --abort`** 후 안내한다.

참고: "체크아웃 안 된 브랜치 push"는 이미 지원된다(`MergedReferenceGroup.pushTargets`가
`isCurrent`를 요구하지 않음). push 쪽 신규 작업은 upstream 없는 브랜치 게시뿐이다.

## 아키텍처

A안: 기존 구조를 확장한다. 새 화면·새 상태 체계를 만들지 않는다.

### 서비스 계층

- **`GitRemoteService`(기존 확장)** — 네트워크를 타는 연산만 담당
  - `fastForwardFetch(repository:reference:)` — 체크아웃 안 된 브랜치 동기화.
    `git fetch <remote> <remoteBranch>:<localBranch>` 실행. fast-forward가 불가능하면 git이
    실패하므로 그 메시지를 사용자에게 안내("fast-forward할 수 없습니다. 체크아웃 후 Pull(Rebase)을 사용해주세요." 계열).
    현재 체크아웃된 브랜치에는 이 명령이 거부되므로 대상에서 제외한다.
  - `publish(repository:reference:remoteName:)` — upstream 없는 브랜치 게시.
    `git push --porcelain -u <remote> <fullName>:refs/heads/<shortName>`.
    remote 선택: `git remote` 목록에서 `origin` 우선, 없으면 첫 항목. remote가 0개면 에러.
  - `deleteRemoteBranch(repository:reference:)` — 원격 브랜치 행(kind == .remote)에서
    `git push --porcelain <remote> --delete <branch>` 실행. remote 이름과 브랜치 이름은
    `shortName`(`origin/feature/x`)의 첫 `/` 기준으로 분리한다.
  - `deleteRemoteTag(repository:tagName:)` — `git push --porcelain <remote> --delete refs/tags/<tag>`.
  - 기존과 동일하게 `networkTimeout`(120초), `exclusive: true`, `color.ui=false` 규칙을 따른다.

- **`GitBranchService`(신설, actor)** — 로컬 저장소만 건드리는 연산 담당.
  `GitRemoteService`가 이미 pull/push 복구 흐름으로 190줄이라 역할 분리한다.
  `GitCommandRunner` 인스턴스는 자체 보유(기존 서비스와 동일 패턴).
  - `rebase(repository:ontoReference:)` — 현재 브랜치를 대상 브랜치 위로 rebase.
    1. `symbolic-ref --quiet --short HEAD`로 현재 브랜치 확인(detached HEAD면 에러)
    2. rebase 진행 중이면 에러(기존 `isRebaseInProgress` 로직을 이 서비스로 이동하거나 공유)
    3. `git -c color.ui=false rebase <onto>` 실행
    4. 실패 시 rebase 진행 중이면 `rebase --abort` 후 `rebaseAborted` 계열 에러로 변환
       (기존 `pullRebase`의 복구 패턴 재사용 — 공통 헬퍼로 추출 가능하면 추출)
  - `deleteLocalBranch(repository:reference:force:)` —
    `git branch -d <name>`(force면 `-D`). 현재 체크아웃된 브랜치는 호출 전에 걸러진다.
    `-d` 실패 시 stderr에 "not fully merged"가 있으면 전용 에러
    `branchNotMerged(name:)`를 던져 UI가 `-D` 재확인 다이얼로그를 띄우게 한다.
  - `deleteLocalTag(repository:tagName:)` — `git tag -d <name>`.
  - 타임아웃은 `localWriteTimeout`(60초) 수준, `exclusive: true`.

`isRebaseInProgress`는 두 서비스가 모두 필요하므로 `GitCommandRunner` 확장 또는
독립 헬퍼(`GitRebaseStateProbe` 등)로 옮겨 중복을 없앤다.

### 모델

- `GitRemoteOperationKind`에 케이스 추가: `rebase`, `fastForwardPull`, `publish`,
  `deleteLocalBranch`, `deleteRemoteBranch`, `deleteTag`.
  기존 `GitRemoteOperation` 구조는 그대로 재사용한다(작업 중 중복 실행 차단, 메뉴 비활성화).
- `MergedReferenceGroup`에 파생 프로퍼티 추가(규칙은 기존처럼 모델 한 곳에만 둔다):
  - `fastForwardPullTargets: [GitReference]` — local && !isCurrent && hasLivingUpstream && behind > 0
  - `publishTargets: [GitReference]` — local && tracking == nil
  - `deletableLocalReferences: [GitReference]` — local && !isCurrent
  - 원격 브랜치/태그 그룹은 references 전체가 삭제 대상.

### AppModel

- 기존 `runRemoteOperation(_:references:)` switch에 새 케이스 추가. 그룹이 여러 저장소에
  걸치면 기존처럼 저장소별로 순회 실행하고 실패를 모아 `errorMessage`로 보여준다.
- 삭제 확인 상태 추가: `pendingBranchAction: PendingBranchAction?`
  ```swift
  struct PendingBranchAction: Identifiable {
      enum Kind { case deleteLocalBranch(force: Bool), deleteRemoteBranch, deleteTag }
      let kind: Kind
      let group: MergedReferenceGroup
      let id = UUID()
  }
  ```
  (실제 필드 구성은 구현 시 다이얼로그 문구에 필요한 만큼만 둔다)
  `ContentView`(또는 사이드바 루트)에 `.confirmationDialog`/`.alert` 하나를 붙여
  이 상태로 구동한다. 미병합(-d 실패) 시 `force: true`로 같은 상태를 다시 세워
  "병합되지 않은 커밋이 있습니다. 그래도 삭제할까요?" 재확인을 받는다.
- 삭제·rebase 완료 후 기존과 동일하게 `refresh()` 호출. rebase/push 완료 시 기존
  `githubActionsFastPollUntil` 갱신 규칙을 따른다(rebase는 로컬 작업이므로 불필요).

### UI (ReferenceTree)

- **로컬 브랜치 메뉴(`branchContextMenu`) 확장**
  - `Pull (Rebase)` — 기존 유지(현재 브랜치)
  - `Pull (Fast-Forward)` — 체크아웃 안 된 브랜치용. `fastForwardPullTargets` 기준 활성화
  - `Push` — 기존 유지
  - `Push (Upstream 설정)` — `publishTargets` 기준. 완료되면 tracking이 생겨 일반 Push로 전환됨
  - `현재 브랜치를 이 브랜치 위로 Rebase` — 우클릭한 그룹이 현재 브랜치가 아닐 때 활성화.
    레이블에 실제 이름을 넣는다: "‘feature/x’를 ‘main’ 위로 rebase" 형식
  - Divider 후 `브랜치 삭제…` — destructive 스타일, `deletableLocalReferences` 기준
- **원격 브랜치 행 메뉴 신설**(kind == .remote): `원격 브랜치 삭제…`
- **태그 행 메뉴 신설**(kind == .tag): `태그 삭제…`(로컬), `원격에서 태그 삭제…`
- 진행 중 표시는 기존 패턴("Pull 중…")을 따르고, `model.remoteOperation != nil`이면
  모든 변경 메뉴를 비활성화한다.
- rebase 대상이 여러 저장소에 걸친 그룹이면 현재 브랜치와 대상 브랜치가 **둘 다 있는
  저장소에서만** 실행한다.

## 에러 처리 원칙

- 모든 실패는 기존처럼 `저장소 · 브랜치: 메시지` 형태로 모아 `errorMessage`에 표시.
- rebase 충돌: 자동 `rebase --abort` 후 "충돌로 rebase를 완료하지 못해 되돌렸습니다" 안내.
  abort조차 실패하면 기존 `rebaseNeedsAttention`과 같은 터미널 안내 문구.
- 저장소는 어떤 실패 경로에서도 rebase 중간 상태로 남지 않는 것을 원칙으로 한다
  (abort 실패라는 최후 경우만 예외, 명시적 안내 동반).
- 삭제는 확인 다이얼로그를 거치기 전에는 어떤 git 명령도 실행하지 않는다.
  (미병합 판정도 `-d` 시도 결과로 알게 되므로, 첫 확인 후 `-d` → 실패 시 재확인 → `-D` 순서)

## 테스트

기존 `GitScopeTests` 유닛 테스트 타깃에 추가한다. 실제 git 저장소를 임시 디렉터리에
만들어 검증하는 통합 스타일(기존 테스트 패턴을 우선 확인하고 따른다).

- rebase: 정상 rebase / 충돌 시 자동 abort 후 워킹트리 원상복구 / detached HEAD 거부
- fast-forward pull: behind만 있는 브랜치 성공 / diverged 브랜치 실패 메시지
- publish: upstream 없는 브랜치 push 후 tracking 생성 확인 (로컬 bare remote 사용)
- 삭제: `-d` 미병합 실패 → `branchNotMerged` 매핑 / `-D` 성공 / 현재 브랜치 대상 제외 /
  원격 브랜치·태그 삭제 (로컬 bare remote 사용)
- `MergedReferenceGroup` 파생 프로퍼티(fastForwardPullTargets 등) 단위 테스트

## 구현 순서 제안

1. `isRebaseInProgress` 공용화 + `GitBranchService` 신설(rebase, 로컬 삭제)
2. `GitRemoteService` 확장(fast-forward fetch, publish, 원격 삭제)
3. 모델 확장(`GitRemoteOperationKind`, 파생 타깃 프로퍼티) + 테스트
4. `AppModel` 연결(`runRemoteOperation` 확장, `pendingBranchAction`)
5. `ReferenceTree` 메뉴 확장(로컬/원격/태그)
6. 통합 테스트 및 수동 QA(디버그 인스턴스, pid 고정 — 릴리스 인스턴스와 겹침 주의)
