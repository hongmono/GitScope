# GitScope

IntelliJ의 Git Log 화면과 GitKraken 스타일 그래프를 독립 macOS 앱으로 옮긴 Apple Silicon 전용 Git 이력 뷰어입니다. 여러 저장소의 브랜치와 작업 상태를 하나의 타임라인에서 확인하고, 현재 브랜치를 안전하게 동기화할 수 있습니다.

## 설치

[GitHub Releases](https://github.com/hongmono/GitScope/releases/latest)에서 최신 Apple Silicon용 DMG를 내려받아 `GitScope.app`을 Applications 폴더로 옮깁니다. 배포본은 Developer ID로 서명되고 Apple 공증을 거치며, 앱 안에서 Sparkle 자동 업데이트를 지원합니다.

- 지원 환경: macOS 14 이상
- 지원 아키텍처: Apple Silicon

## 현재 구현 범위

- 여러 Git 저장소 또는 워크스페이스 폴더 동시 선택
- 하위 Git 저장소 자동 탐색
- 로컬/원격 브랜치와 태그 표시
- 로컬 브랜치의 upstream 및 ahead/behind 커밋 수 표시
- 브랜치 우클릭 메뉴에서 rebase pull 및 upstream push
- 여러 저장소의 커밋을 하나의 타임라인으로 병합
- 현재 보이는 레인 수에 맞춰 폭이 조절되는 커밋 그래프
- 현재 체크아웃 위치의 `HEAD` 강조 표시
- 커밋되지 않은 변경 사항을 그래프 최상단의 `작업 중` 항목으로 표시
- 작업 중 항목에서 변경 파일과 unified diff 확인
- 커밋 우클릭 팝오버에서 브랜치/태그 확인 및 해시·메시지 복사
- 커밋 메시지, 작성자, 시간 표시
- 메시지/해시 검색, 작성자/기간/저장소 필터
- 경로 필터 재조회
- 변경 파일과 unified diff 표시
- Git 로그 초기 로딩 화면과 부드러운 상태 전환
- Sparkle 기반 자동 업데이트 확인과 앱 내 설치

commit, checkout, merge, force push 기능은 포함하지 않습니다. Pull은 현재 체크아웃되어 있고 upstream이 설정된 브랜치에 `--rebase` 방식으로 실행됩니다.

## 열기

`GitScope.xcodeproj`를 Xcode로 열어 `GitScope` scheme을 실행합니다. 프로젝트 파일은 `project.yml`을 기준으로 XcodeGen으로 생성됩니다.

## 배포

`release` 대상 pull request에서는 Apple Silicon Release 빌드를 검증합니다. `release` 브랜치에 반영된 커밋은 Developer ID 서명과 Apple 공증을 거쳐 ZIP, DMG, SHA-256 체크섬, Sparkle appcast와 함께 GitHub Release로 배포됩니다. 배포된 앱은 하루 주기로 새 버전을 확인하며, GitScope 메뉴의 **업데이트 확인…**에서 즉시 확인할 수도 있습니다.

Apple 인증서와 App Store Connect API key 등록 방법은 [배포 설정](docs/releasing.md)을 참고하세요.
