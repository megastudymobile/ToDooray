# Dooray API 규격

MegaMind가 쓰는 Dooray 공식 API와 업무 선별 규칙을 적는다. macOS 앱과 이후의 Windows 앱이 이 문서와 `fixtures/`를 같은 기준으로 쓴다.

근거는 두 가지다. 호출 형식은 `@bifos/dooray-cli` 0.33.1의 소스에서 확인했다. 응답 필드는 2026-11-19에 실제 계정으로 받은 업무 241건의 구조에서 확인했다.

## 공통

- 기본 주소는 `https://api.dooray.com`이다. 공공 테넌트는 주소가 다르므로 설정에서 바꿀 수 있어야 한다.
- 모든 요청에 `Authorization: dooray-api {개인 API 토큰}` 헤더를 붙인다.
- 응답은 `{ "header": { "isSuccessful": bool, "resultCode": int, "resultMessage": string }, "result": ..., "totalCount": int }` 형태다. `header.isSuccessful`이 `true`가 아니면 실패로 처리한다.
- 목록은 `page`(0부터)와 `size`(최대 100)로 나눠 받는다. 받은 개수가 `totalCount`에 닿을 때까지 `page`를 올린다.
- 호출 한도를 넘으면 HTTP 429가 온다. 한도 수치는 확인하지 못했다. 동시 요청 수를 제한하고 429에는 간격을 늘려 다시 시도한다.
- HTTP 401은 토큰이 틀렸거나 만료됐다는 뜻이다.

## 호출

| 목적 | 요청 |
| --- | --- |
| 내 멤버 ID | `GET /common/v1/members/me` |
| 내가 속한 프로젝트 | `GET /project/v1/projects?member=me&page=&size=` |
| 프로젝트의 워크플로우 | `GET /project/v1/projects/{projectId}/workflows` |
| 프로젝트의 내 담당 업무 | `GET /project/v1/projects/{projectId}/posts?toMemberIds={내 ID}&postWorkflowClasses=registered,working&page=&size=` |

전 프로젝트의 업무를 한 번에 주는 호출은 CLI에 없다. 프로젝트마다 한 번씩 부른다.

## 쓰는 필드

`members/me`의 `result`에서는 `id`만 쓴다.

프로젝트 항목에서는 `id`와 `code`를 쓴다.

워크플로우 항목에서는 `id`, `name`, `class`를 쓴다. `class`는 `backlog`, `registered`, `working`, `closed` 중 하나다.

업무 항목에서 쓰는 필드는 다음과 같다.

| 필드 | 설명 |
| --- | --- |
| `id` | 업무 ID. 숫자로 된 문자열이다. |
| `subject` | 제목 |
| `project.id`, `project.code` | 프로젝트 |
| `number` | 프로젝트 안의 업무 번호. 정수다. |
| `priority` | `highest`, `high`, `normal`, `low`, `none` |
| `dueDate` | 마감 시각. UTC ISO 8601 문자열이다. 마감이 없으면 필드가 없다. |
| `workflowClass` | 업무 전체의 상태 분류 |
| `updatedAt` | 마지막 수정 시각 |
| `users.to[]` | 담당자 목록. 아래 참고. |

담당자 항목은 `type`에 따라 모양이 다르다.

- `type`이 `member`이면 `member.organizationMemberId`와 `workflow.id`가 있다.
- `type`이 `group`이면 `group.members[]`의 각 항목에 `organizationMemberId`와 `workflowId`가 있다.

## 업무 선별 규칙

Dooray는 담당자마다 상태를 따로 가진다. 업무 전체는 진행 중인데 내 몫은 끝난 경우가 있다. 그래서 "내 담당 미완료"는 내 담당자 항목의 상태로 판정한다.

1. `users.to[]`에서 내 멤버 ID가 든 항목을 찾는다. `member` 항목을 먼저 보고, 없으면 `group.members[]`를 본다.
2. 그 항목의 워크플로우 ID를 프로젝트의 워크플로우 목록에서 찾아 `class`를 얻는다.
3. `class`가 `registered`나 `working`이면 보여준다. `backlog`와 `closed`는 제외한다.
4. 내 항목이나 워크플로우를 찾지 못하면 업무의 `workflowClass`로 같은 판정을 한다.

서버의 `postWorkflowClasses` 필터는 전송량을 줄이는 용도다. 판정은 항상 위 규칙으로 클라이언트에서 한다.

## 긴급도와 정렬

긴급도는 `dueDate`와 사용자의 현지 날짜로 계산한다.

| 긴급도 | 조건 |
| --- | --- |
| 마감 지남 | `dueDate`가 현재 시각보다 이르다. |
| 오늘 마감 | `dueDate`가 오늘 안이고 아직 지나지 않았다. |
| 예정 | `dueDate`가 내일 이후다. |
| 마감 없음 | `dueDate`가 없다. |

목록은 위 표의 순서로 정렬한다. 같은 긴급도 안에서는 마감이 이른 업무가 먼저다. 마감이 없는 업무는 우선순위가 높은 것, 그다음 최근에 수정한 것 순이다.

## 구현 세부 규칙

위 규칙이 정하지 않은 부분을 여기서 정한다. 두 앱이 같은 응답에서 같은 목록을 내기 위해서다. 항목마다 확인에 쓰는 `fixtures/` 파일을 적는다.

### 정렬 동률

다음 기준을 차례로 적용한다. 앞 기준이 같을 때만 다음 기준을 본다.

1. 긴급도. 마감 지남, 오늘 마감, 예정, 마감 없음 순이다.
2. `dueDate`가 이른 순. 마감이 있는 업무에만 적용한다.
3. 우선순위가 높은 순. `highest`, `high`, `normal`, `low`, `none` 순이다.
4. `updatedAt`이 최근인 순.
5. `id`가 작은 순. 숫자로 비교한다. 자릿수가 적은 쪽이 먼저고, 자릿수가 같으면 문자열 순이다.

`fixtures/rules/ordering.json`으로 확인한다.

### 페이지 받기

다음 중 하나에 해당하면 멈춘다.

- 받은 개수가 `totalCount`에 닿았다.
- 빈 페이지가 왔다.
- 100페이지를 받았다.

`totalCount`가 없는 응답이면 `size`보다 적게 온 페이지에서 멈춘다. 읽는 사이에 항목이 페이지 사이로 밀릴 수 있으므로 `id`로 중복을 없앤다.

`fixtures/scenarios/paging`으로 확인한다.

### 동시 요청과 429

- 프로젝트는 한 번에 네 개까지 처리한다. 한 프로젝트 안의 호출은 하나씩 차례로 보낸다.
- 429를 받으면 `Retry-After` 헤더의 초만큼 기다린다. 헤더가 없으면 1초, 2초, 4초, 8초를 차례로 기다린다.
- 재시도는 네 번까지다. 다섯 번째 응답도 429면 동기화를 실패로 끝낸다.
- 한 요청이 기다리는 동안에는 같은 동기화의 다른 요청도 기다린다.

`fixtures/scenarios/rate-limited`, `rate-limited-exhausted`, `many-projects`로 확인한다.

### 실패 처리

프로젝트의 워크플로우 호출이나 업무 호출이 403 또는 404를 주면 그 프로젝트만 건너뛴다.

그 밖의 실패는 동기화 전체의 실패다. 401, 재시도 뒤에도 남은 429, 5xx, 네트워크 오류, 규격과 다른 본문이 여기에 든다. 이때 앱은 이전 목록을 지우지 않고, 갱신하지 못했다는 표시와 함께 보여준다. 일부가 빠졌는데 온전해 보이는 목록이 오래된 목록보다 나쁘기 때문이다.

`fixtures/scenarios/project-forbidden`, `server-error`, `api-failure`, `unauthorized`로 확인한다.

### 모르는 값

- 워크플로우의 `class`가 네 값 밖이면 워크플로우를 찾지 못한 것으로 본다. 선별 규칙 4를 적용한다.
- `priority`가 다섯 값 밖이면 `none`으로 본다.
- `users.to[]` 항목의 `type`이 `member`도 `group`도 아니면 무시한다. `emailUser`가 그런 예다.
- 보여줄 업무의 `dueDate`를 읽을 수 없으면 오류다. 마감 없음으로 바꾸지 않는다. 마감을 숨기는 것보다 실패가 낫다.

`fixtures/rules/selection.json`, `fixtures/scenarios/malformed-due-date`, `malformed-post`로 확인한다.

### 워크플로우 캐시

프로젝트의 워크플로우 목록은 받은 뒤 6시간까지 다시 쓴다. 캐시한 목록에 내 담당자 항목의 워크플로우 ID가 없으면 그 프로젝트의 목록을 한 번 다시 받고 나서 선별 규칙을 적용한다. 방금 받은 목록에 없을 때는 다시 받지 않는다.

`fixtures/scenarios/workflow-cache-miss`로 확인한다.

### 하루의 경계

"오늘"은 사용자 시스템 시간대의 달력 날짜다. `현재 시각 <= dueDate < 내일 0시`이면 오늘 마감이다. `dueDate`가 현재 시각과 같으면 마감 지남이 아니라 오늘 마감이다.

`fixtures/rules/urgency.json`으로 확인한다.

## 업무 웹 주소

`https://{테넌트}.dooray.com/task/{projectId}/{postId}` 형식이다. 테넌트 주소는 API로 얻지 못하므로 설정에서 받는다.
