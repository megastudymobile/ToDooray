# fixtures

`docs/dooray-api.md`를 실행해서 확인하는 자료다. macOS 앱의 테스트, 로컬 모의 서버(`tools/mock-dooray/server.py`), 이후의 Windows 앱이 같은 파일을 읽는다. 응답 본문은 실제 API와 같은 모양이고 내용은 지어낸 것이다.

## 시나리오: `scenarios/<이름>/`

동기화 한 번이 보내는 요청과 그 결과를 한 폴더에 담는다.

### `scenario.json`

```jsonc
{
  "description": "한 줄 설명",
  "tags": ["e2e"],                      // "e2e"가 있으면 실제 앱으로도 돌린다
  "now": "2026-11-19T12:00:00+09:00",   // 긴급도와 워크플로우 캐시 수명을 계산하는 시각
  "timeZone": "Asia/Seoul",             // "오늘"을 정하는 시간대
  "token": "test-token",                // Authorization은 "dooray-api test-token"이어야 한다
  "pageSize": 2,                        // 선택. 기본 100
  "runs": 2,                            // 선택. 한 클라이언트로 동기화하는 횟수. 마지막 결과를 확인한다
  "requests": [
    {
      "path": "/project/v1/projects/3000000000000000001/posts",
      "query": { "toMemberIds": "…", "postWorkflowClasses": "registered,working", "page": "0", "size": "100" },
      "responses": [
        { "status": 429, "headers": { "Retry-After": "2" } },
        { "status": 200, "body": "responses/posts-3000000000000000001-0.json", "delayMs": 0 }
      ]
    }
  ],
  "expect": "expected.json"
}
```

요청을 고르는 규칙은 다음과 같다.

- `path`가 정확히 같고 `query`의 키와 값이 모두 같아야 한다. 순서는 상관없다. 적지 않은 키가 요청에 있으면 맞지 않는 것이다. `query`가 없으면 쿼리 없는 요청만 맞는다.
- `responses`는 그 요청이 올 때마다 차례로 하나씩 쓴다. 마지막 응답은 계속 되풀이한다.
- `body`와 `expect`는 이 폴더를 기준으로 한 경로다. 다른 시나리오의 파일을 `../basic/…`로 가리킬 수 있다. `body`가 없으면 빈 본문이다.
- `Authorization` 헤더가 다르면 401을 준다.
- 맞는 요청이 없으면 599를 준다. 테스트는 이것을 실패로 본다.

### `expected.json`

성공하는 시나리오는 정렬까지 끝낸 전체 목록을 적는다.

```jsonc
{
  "tasks": [
    { "id": "5000000000000000001", "key": "FE-1203", "urgency": "overdue", "state": "registered" }
  ],
  "requestCounts": { "/project/v1/projects/3000000000000000001/workflows": 2 },  // 선택. 경로별 요청 횟수
  "maxConcurrentRequests": 4,                                                    // 선택. 동시에 처리 중이던 요청의 최댓값
  "notes": { "…": "사람이 읽는 설명" }                                             // 선택
}
```

`urgency`는 `overdue`, `dueToday`, `upcoming`, `noDue` 중 하나다. `state`는 내 담당자 상태이고 `registered`나 `working`이다. `key`는 `{프로젝트 코드}-{업무 번호}`다.

실패하는 시나리오는 오류 종류를 적는다.

```json
{ "error": "unauthorized" }
```

| `error` | 뜻 |
| --- | --- |
| `unauthorized` | HTTP 401 |
| `rateLimited` | 재시도 후에도 HTTP 429 |
| `http` | 그 밖의 2xx가 아닌 응답 |
| `api` | 2xx인데 `header.isSuccessful`이 `false` |
| `network` | 응답을 받지 못함 |
| `invalidResponse` | 본문이 규격과 다름 |

## 규칙 표: `rules/<규칙>.json`

네트워크 없이 확인하는 규칙이다. 파일마다 `cases` 배열이 있고 각 항목은 입력과 `expect`를 가진다.

| 파일 | 규칙 | 입력 |
| --- | --- | --- |
| `urgency.json` | 긴급도 | `now`, `timeZone`, `dueDate` |
| `selection.json` | 업무 선별 규칙 1–4 | `me`, `workflows`(ID → class), 업무의 `workflowClass`, API 모양 그대로의 `users.to` |
| `ordering.json` | 정렬과 동률 처리 | `now`, `timeZone`, 순서를 섞은 `tasks` |
