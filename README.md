# GitScope

IntelliJ의 Git Log 화면과 GitKraken 스타일 그래프를 독립 macOS 앱으로 옮긴 Apple Silicon 전용 Git 이력 뷰어입니다. 여러 저장소의 브랜치와 작업 상태를 하나의 타임라인에서 확인하고, 현재 브랜치를 안전하게 동기화할 수 있습니다.

[홈페이지](https://hongmono.github.io/GitScope/) · [GitHub Releases](https://github.com/hongmono/GitScope/releases/latest)

## 설치

Homebrew로 설치합니다.

```sh
brew install hongmono/tap/gitscope
```

Homebrew를 사용하지 않는 경우 [GitHub Releases](https://github.com/hongmono/GitScope/releases/latest)에서 최신 Apple Silicon용 DMG를 내려받아 `GitScope.app`을 Applications 폴더로 옮길 수 있습니다. 배포본은 Developer ID로 서명되고 Apple 공증을 거치며, 앱 안에서 Sparkle 자동 업데이트를 지원합니다.

- 지원 환경: macOS 14 이상
- 지원 아키텍처: Apple Silicon

## 현재 구현 범위

- 여러 Git 저장소 또는 워크스페이스 폴더 동시 선택
- 저장소별 탭 열기와 앱 재시작 후 탭 복원
- `⌘1`~`⌘9`로 순서에 맞는 저장소 탭 전환
- 비활성 탭의 Git 로그를 메모리에서 해제하는 저메모리 탭 전환
- 하위 Git 저장소 자동 탐색
- 로컬/원격 브랜치와 태그 표시
- 로컬 브랜치의 upstream 및 ahead/behind 커밋 수 표시
- 브랜치 우클릭 메뉴에서 rebase pull 및 upstream push
- `⌘R`로 모든 저장소에서 `fetch --all` 실행 후 로그 새로고침
- 여러 저장소의 커밋을 하나의 타임라인으로 병합
- 단일 저장소에서는 불필요한 저장소 열과 개수 표시 자동 숨김
- 활성 lane을 왼쪽부터 빈틈없이 배치하고 새 브랜치를 주선 오른쪽으로 분기하는 안정적인 커밋 그래프
- 현재 보이는 lane 수에 맞춰 그래프 열 너비 자동 조절
- 현재 체크아웃 위치의 `HEAD` 강조 표시
- 커밋되지 않은 변경 사항을 그래프 최상단의 `작업 중` 항목으로 표시
- 작업 중 항목에서 변경 파일과 unified diff 확인
- 커밋 우클릭 팝오버에서 브랜치/태그 확인 및 해시·메시지 복사
- 커밋 메시지, 작성자, 시간 표시
- GitHub 저장소 커밋의 Actions 상태를 커밋 메시지 오른쪽에 표시
- Actions 실행 중 자동 갱신, 워크플로 및 Job/Check 결과와 GitHub 링크 제공
- 메시지/해시 검색, 작성자/기간/저장소 필터
- 경로 필터 재조회
- 변경 파일과 unified diff 표시
- Git 로그 초기 로딩 화면과 부드러운 상태 전환
- Sparkle 기반 자동 업데이트 확인과 앱 내 설치

commit, checkout, merge, force push 기능은 포함하지 않습니다. Pull은 현재 체크아웃되어 있고 upstream이 설정된 브랜치에 `--rebase` 방식으로 실행됩니다.

공개 GitHub 저장소의 Actions 상태는 별도 설정 없이 조회합니다. 비공개 저장소는 [GitHub CLI](https://cli.github.com/)가 설치되어 있고 `gh auth login`으로 로그인되어 있으면 기존 Keychain 인증을 재사용합니다. 토큰은 GitScope 설정이나 파일에 별도로 저장하지 않습니다.

## 열기

`GitScope.xcodeproj`를 Xcode로 열어 `GitScope` scheme을 실행합니다. 프로젝트 파일은 `project.yml`을 기준으로 XcodeGen으로 생성됩니다.

Debug 빌드는 `GitScope Dev.app`과 `dev.hongmono.gitscope.debug` bundle ID를 사용하고 자동 업데이트를 실행하지 않아, 배포용 `GitScope.app`과 설정 및 실행 상태가 분리됩니다.

## 배포

`release` 대상 pull request에서는 Apple Silicon Release 빌드를 검증합니다. `release` 브랜치에 반영된 커밋은 Developer ID 서명과 Apple 공증을 거쳐 ZIP, DMG, SHA-256 체크섬, Sparkle appcast와 함께 GitHub Release로 배포됩니다. [`RELEASE_NOTES.md`](RELEASE_NOTES.md)의 내용은 GitHub Release와 Sparkle 업데이트 화면에 함께 표시됩니다. 배포된 앱은 하루 주기로 새 버전을 확인하며, GitScope 메뉴의 **업데이트 확인…**에서 즉시 확인할 수도 있습니다.

Apple 인증서와 App Store Connect API key 등록 방법은 [배포 설정](docs/releasing.md)을 참고하세요.
