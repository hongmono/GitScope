# 업데이트 내용

## GitHub Actions 상태

- GitHub 저장소의 커밋마다 Actions 실행 상태를 커밋 메시지 오른쪽에서 바로 확인할 수 있습니다.
- 대기, 실행 중, 성공, 실패, 취소 상태를 구분해 표시하고 배지를 누르면 해당 실행 페이지를 엽니다.
- 커밋을 선택하면 실행된 워크플로와 Job/Check 결과를 세부 정보에서 확인할 수 있습니다.
- GitScope에서 push한 직후에는 상태를 빠르게 갱신하고, 실행 중인 워크플로가 끝날 때까지 자동으로 추적합니다.
- 공개 저장소는 별도 설정 없이 동작하며, 비공개 저장소는 기존 GitHub CLI 로그인을 안전하게 재사용합니다.

## 설치

- Homebrew에서 `brew install hongmono/tap/gitscope` 한 줄로 설치할 수 있습니다.
- 기존과 같이 서명과 Apple 공증을 마친 DMG 설치 파일도 GitHub Release에서 제공합니다.
