# 개발과 배포

## 준비

- Xcode 26 이상
- `brew install xcodegen`
- Python 3 (모의 서버와 e2e 스크립트)

## 명령

| 명령 | 하는 일 |
| --- | --- |
| `make test` | 동기화 규칙과 앱 로직 테스트 |
| `make app` | 디버그 빌드. 결과는 `build/Build/Products/Debug/ToDooray.app` |
| `make e2e` | 디버그 빌드를 로컬 모의 서버에 붙여 시나리오를 확인 |
| `make mock SCENARIO=basic` | `fixtures/scenarios/basic`을 `127.0.0.1:8765`에서 제공. 토큰은 `test-token` |
| `make release` | 배포용 빌드. 디버그 콘솔이 빠짐 |
| `make dist` | 배포용 빌드를 서명, 공증해 `build/dist/ToDooray-<버전>.zip`으로 만듦 |

디버그 빌드의 번들 ID는 `com.megastudymobile.ToDooray.debug`입니다. 그래서 설치한 배포판과 키체인 항목, 설정이 섞이지 않습니다.

## 배포판 만들기

`make dist`는 Developer ID 인증서로 서명하고 Apple에 공증을 받습니다. 공증을 받은 앱은 팀원의 Mac에서 경고 없이 열립니다.

### 처음 한 번: 공증 자격 증명 등록

1. [appleid.apple.com](https://appleid.apple.com)에서 앱 암호를 만듭니다.
2. 터미널에서 아래 명령을 실행하고, 앱 암호를 입력합니다. `<팀 ID>`는 Developer ID 인증서의 팀 ID입니다.

```bash
xcrun notarytool store-credentials todooray-notary --apple-id "<Apple ID 이메일>" --team-id "<팀 ID>"
```

자격 증명은 이 Mac의 키체인에 `todooray-notary`라는 이름으로 저장됩니다.

### 릴리스할 때마다

1. `App/project.yml`의 `MARKETING_VERSION`을 올리고 `CURRENT_PROJECT_VERSION`을 1 늘립니다.
2. `make dist`를 실행합니다. 공증에는 보통 몇 분이 걸립니다.
3. `build/dist/ToDooray-<버전>.zip`을 GitHub Releases에 `v<버전>` 태그로 올립니다.

환경 변수로 기본값을 바꿀 수 있습니다.

| 변수 | 기본값 | 뜻 |
| --- | --- | --- |
| `TODOORAY_SIGN_IDENTITY` | `Developer ID Application` | `codesign`에 넘기는 인증서 이름 |
| `TODOORAY_NOTARY_PROFILE` | `todooray-notary` | `notarytool` 자격 증명 이름 |
| `SKIP_NOTARIZE` | 없음 | `1`이면 서명과 압축만 하고 공증은 건너뜀 |

번들 ID `com.megastudymobile.ToDooray`는 바꾸지 않습니다. 팀원의 키체인 항목, 로그인 항목, 설정이 이 ID에 묶여 있어서, 바꾸면 모두 다시 설정해야 합니다.

## 디버그 콘솔

디버그 빌드는 `TODOORAY_CONSOLE=1`로 실행하면 표준 입력으로 명령을 받고 JSON 한 줄씩 답합니다. 명령 목록은 `Sources/ToDoorayApp/DebugConsole.swift` 맨 위에 있습니다. `TODOORAY_CONFIG=<파일>`을 주면 키체인과 설정 대신 그 파일을 읽습니다. 실제 토큰 없이 모의 서버로 확인할 때 씁니다.
