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

## 업무 웹 주소

`https://{테넌트}.dooray.com/task/{projectId}/{postId}` 형식이다. 테넌트 주소는 API로 얻지 못하므로 설정에서 받는다.
