# GitScope

IntelliJ의 Git Log 화면과 GitKraken 스타일 그래프를 독립 macOS 앱으로 옮긴 Apple Silicon 전용 읽기 전용 Git 이력 뷰어입니다.

## 현재 구현 범위

- 여러 Git 저장소 또는 워크스페이스 폴더 동시 선택
- 하위 Git 저장소 자동 탐색
- 로컬/원격 브랜치와 태그 표시
- 여러 저장소의 커밋을 하나의 타임라인으로 병합
- 커밋 그래프, 메시지, 작성자, 시간 표시
- 메시지/해시 검색, 작성자/기간/저장소 필터
- 경로 필터 재조회
- 변경 파일과 unified diff 표시

Git을 변경하는 commit, checkout, merge, push, pull 기능은 포함하지 않습니다.

## 열기

`GitScope.xcodeproj`를 Xcode로 열어 `GitScope` scheme을 실행합니다. 프로젝트 파일은 `project.yml`을 기준으로 XcodeGen으로 생성됩니다.

## 배포

`release` 대상 pull request에서는 Apple Silicon Release 빌드를 검증합니다. `release` 브랜치에 반영된 커밋은 Developer ID 서명과 Apple 공증을 거쳐 GitHub Release로 배포됩니다.

Apple 인증서와 App Store Connect API key 등록 방법은 [배포 설정](docs/releasing.md)을 참고하세요.
