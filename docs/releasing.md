# GitScope 배포 설정

GitScope는 `release` 브랜치를 배포 기준으로 사용합니다.

- `release` 대상 pull request: Apple Silicon용 unsigned Release 빌드를 검증합니다.
- `release` 브랜치 push 또는 해당 브랜치에서의 수동 실행: Developer ID로 서명하고 Apple 공증을 거쳐 GitHub Release를 생성합니다.
- 버전 형식: `v0.1.<GitHub Actions run number>`
- 산출물: `GitScope-<version>-macOS-arm64.zip`과 SHA-256 체크섬

pull request에서는 fork를 포함한 변경 코드에 Apple 인증 정보가 전달되지 않습니다. 서명과 공증은 `release` 브랜치에 반영된 코드에만 수행됩니다.

## GitHub Actions secrets

저장소의 **Settings → Environments → release → Environment secrets**에 다음 값을 등록합니다. 배포 job은 `release` Environment 승인을 받은 뒤에만 이 값을 읽습니다.

| 이름 | 값 |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID Application 인증서와 private key를 포함한 `.p12` 파일의 Base64 문자열 |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` 내보내기 암호 |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: 이름 (TEAM_ID)` 형식의 전체 인증서 이름 |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID |
| `APPLE_API_PRIVATE_KEY` | `AuthKey_<KEY_ID>.p8` 파일 전체 내용 |

Keychain Access에서 Developer ID Application 인증서와 private key를 함께 `.p12`로 내보낸 뒤 다음 명령으로 Base64 값을 복사할 수 있습니다.

```sh
base64 < DeveloperIDApplication.p12 | pbcopy
```

`APPLE_SIGNING_IDENTITY`는 다음 명령 결과에서 선택합니다.

```sh
security find-identity -v -p codesigning
```

App Store Connect의 **Users and Access → Integrations → Team Keys**에서 공증용 API key를 만들고 key ID, issuer ID, 내려받은 `.p8` 파일을 등록합니다. `.p8` 파일은 한 번만 내려받을 수 있으므로 별도로 안전하게 보관해야 합니다.

## 배포 활성화

`release` Environment에는 hongmono 사용자의 배포 승인이 필요하고 `release` 브랜치만 배포할 수 있도록 설정합니다. 모든 secret을 등록한 후 저장소의 **Actions variables**에 있는 `RELEASE_ENABLED`를 `true`로 변경합니다.

```sh
gh variable set RELEASE_ENABLED --body true --repo hongmono/GitScope
```

그 전까지 `release` push는 Release 빌드 검증까지만 실행되고 서명·공증·배포 job은 건너뜁니다. 활성화 후에는 `release` push가 빌드를 시작하고, Environment 승인 뒤 서명·공증·배포를 계속합니다.

## 배포 실행

일반적인 배포는 `main`의 변경을 `release` 대상 pull request로 검증한 뒤 merge하는 방식입니다. merge로 발생한 `release` push가 자동 배포를 시작합니다. 필요한 경우 GitHub Actions의 **Release → Run workflow**에서 `release` 브랜치를 선택해 새 버전을 수동 배포할 수 있습니다. 같은 버전을 다시 만들려면 기존 workflow run의 **Re-run jobs**를 사용합니다.
