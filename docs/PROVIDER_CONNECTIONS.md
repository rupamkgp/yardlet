# 하네스·모델 제공자·계정 연결 — 2026-09-15

사용자는 여러 계정의 남은 사용량을 보고 계정을 직접 고르고, ChatGPT에 한정하지 않는
구조를 요청했다. 하네스 연결과 모델 제공자 인증을 구분하고, 실제로 지원하는 경로만
각 하네스에 연결한다. 임의 모델 프록시나 OAuth 토큰 변환·복사를 추가하지 않는다.

최신 화면 흐름과 설계 결정은 [ACCOUNT_SELECTION_UX.md](ACCOUNT_SELECTION_UX.md)를 따른다.

## 사용자 동작

- **설정 › 계정 → 계정 추가**(사이드바 **연결**이 이 섹션을 연다)에서 별도 계정을 연결하거나
  고급 설정에서 기존 CLI 계정 폴더를 지정한다. 기존 로그인도 같은 목록에 표시하며
  이름과 폴더는 필수 입력이 아니다. 새 폴더는 비어 있는 상태로 만들고 해당 하네스의
  공식 로그인·제공자 설정을 연다. 비밀 값은 계속 CLI가 소유한다.
- 새 작업의 프로젝트·하네스 옆 **계정 선택**에서 남은 한도와 초기화 시각을 보고 고른다.
  선택은 초안과 함께 보존하며, 제출 직전에 계정 바인딩을 고정한다.
- 작업 재개·포크·사이드 채팅은 저장된 계정 환경과 원본 세션 ID를 함께 사용한다.
  새 작업의 기본 계정을 바꿔도 기존 작업의 계정은 바뀌지 않는다.
- Claude Code는 작업 메뉴의 **계정 선택**에서, 같은 대화 기록 폴더를 쓰는 계정으로만 바꿀
  수 있다(2026-10-06). 두 계정 폴더의 `projects`가 링크를 따라 같은 실제 폴더를 가리킬 때만
  허용하므로 세션 ID와 기록 위치는 그대로이고 파일을 옮기거나 복사하지 않는다. Session Switch
  계정 폴더가 이 구조다(`projects` 등을 `~/.claude`로 링크하고 로그인만 계정별로 둔다). 바꿀
  계정의 CLI가 `auth status`에서 로그인을 확인해 주지 않으면 바꾸지 않는다. 진행 중인 턴·승인
  대기 중에는 바꾸지 않으며, 바꾼 뒤 같은 세션 ID로 다시 연결한다.
- 사용량이 공개되지 않은 경우 조회 불가로 표시한다. 단기·장기 한도를 합치지 않고 각각
  표시하며 숫자가 없는 한도를 0으로 만들지 않는다.

## 지원 경계

| 하네스 | 모델 공급 경로 | 추가 계정 환경 | 잔여 한도 | 기존 작업 계정 변경 |
|---|---|---|---|---|
| Codex | 기본 OpenAI 서비스 또는 CLI에 설정한 제공자 | CODEX_HOME | App Server가 공개한 계정의 primary/secondary | 새 작업에서 환경 선택 |
| Claude Code | 기본 Anthropic 서비스 또는 CLI에 설정한 제공자 | CLAUDE_CONFIG_DIR | CLI `get_usage` 제어 요청의 5시간·주간·모델별 주간 한도 | 같은 기록 폴더를 공유하는 계정끼리 선택 |
| Pi | 별도 모델 제공자 | PI_CODING_AGENT_DIR, 제공자 선택 | CLI가 공개하지 않으면 미표시 | 새 작업에서 환경 선택 |
| OpenCode | 별도 모델 제공자 | 계정별 XDG data/config/state/cache | 기존 CLI 조회 경계 | 새 작업에서 환경 선택 |
| Hermes Agent | 별도 모델 제공자 | HERMES_HOME | 안전한 구조화 조회 없음 | 새 작업에서 환경 선택 |
| 나머지 하네스 | 해당 CLI가 소유한 기본 또는 외부 제공자 설정 | 기존 연결 유지 | 기존에 검증한 공개 조회만 사용 | 추가 경로를 임의로 만들지 않음 |

Gemini CLI 항목은 앞선 설치에서 제거했으며, Pi 등 다른 하네스의 Google 모델 제공자 선택과는
별개다. Gajae Code·Oh My Pi(Deep Agents Code 포함)는 2026-10-23 기본 목록 기준으로 뺐다.
아래 근거 절의 Gajae 기록은 그때의 근거로 남긴다.

OpenCode는 공식 `auth login`의 제공자·인증 방법 선택을 호스팅한다. Pi는 사용자가
지정하거나 자신의 settings.json에 설정된 제공자를 조회한다. 설정이 없으면
ChatGPT를 임의로 기본 제공자로 추정하지 않는다. 기본 Pi 연결과 새 Pi 계정 추가에서는
제공자를 먼저 선택한다. Pi의 인증 방법 선택 화면도 입력 대기로 인식한다.
Pi의 명시적 제공자 로그인은 기존
`auth check --provider … --json --no-refresh` 완료 감지와 취소·늦은 응답 방어를 유지한다.

## 저장·프로세스 계약

`~/.yardlet/provider-connections.json`에는 이름, 하네스, 제공자 ID, 계정 폴더와 선택자만
저장한다. 토큰·API 키는 읽거나 복사하지 않는다. 파일은 atomic write와 0600 권한을
사용하며, 읽기 실패 시 원본 파일을 덮어쓰지 않는다. 새로운 계정 폴더는 0700이다.

같은 폴더의 `account-snapshots.json`(2026-10-08)은 계정 목록이 열자마자 보일 마지막 조회
결과다. 연결 ID(기본 로그인은 `native:<하네스>`)마다 로그인 여부(`signedIn`/`signedOut`),
CLI가 알려 준 계정 이름·조직·요금제 줄, 한도 행(이름·사용 비율·표시 문구·초기화 시각·근거
종류)과 조회 시각만 둔다. 토큰·자격 증명·계정 폴더 경로·CLI 출력·작업별 토큰 사용량은 두지
않는다. atomic write·0600이며, 읽지 못하면 비어 있는 것으로 시작하고 다음 조회가 새로 쓴다.
조회가 로그인·로그아웃을 확인하면 바꿔 쓰고, 조치 필요(폴더 없음 등)면 지운다. 조회를 끝내지
못하면(시간 초과·오류) 마지막 로그인 값을 화면에 유지하되 "새로 고치지 못함"으로 표시하고,
런타임이 없으면 그 상태를 그대로 보인다. 지난 실행에서 기억한 로그인은 새 작업 기본 계정
자동 대체(`replaceSignedOutDefaultSelection`)의 후보가 아니다. 이번 실행에서 확인된 것만 쓴다.
새 작업 입력창의 계정 칩은 같은 파일에서 로그인 상태로 기억한 계정 이름을 쓴다. 그래서 다음 실행에서 다시 확인하는
동안에도 이름이 보인다. 이 이름은 표시용이며 바인딩·선택·자격 증명과 무관하다. 확인 전이고 기억한 이름도 없으면
"계정 확인 중…"이다. (갈래에서 따로 두었던 `account-labels.json`은 병합 때 이 파일로 합쳐 만들지 않는다.)

읽기와 확인의 소유자는 `ProviderConnectionStore` 하나다(2026-10-08, B5). 기본 로그인과 저장 계정의 값,
`AccountReadingStatus`, 확인 중 표시를 모두 여기서 갖고, 계정 화면(`AccountCenterModel`)은 로그인 콘솔만
맡는다. 확인은 `check(defaultsOf:savedOf:connectionIDs:policy:checkUsage:runtimeSelections:)` 하나로만 시작한다.
- 같은 계정(기본 로그인은 `native:<하네스>`, 저장 계정은 연결 ID, GJC는 계정 홈 단위 목록)의 확인이 이미 돌고 있으면
  새 CLI 프로세스를 띄우지 않고 그 확인을 기다린다.
- 신선도 기준은 하나다: 이번 실행의 확인이 1분 안에 "현재"로 확인한 값은 목록이 열릴 때(`ifStale`) 다시 확인하지
  않는다. 지난 실행에서 기억한 값과 "새로 고치지 못함" 값은 언제나 다시 확인한다. 새로 고침 버튼(`refresh`)은
  신선해도 다시 확인하되 돌고 있는 확인에는 합류한다.
- 로그인 콘솔이 끝났거나 런타임을 바꾼 뒤(`restart`)에는 그 전에 시작한 확인의 답을 버리고 새로 확인한다. 나중에
  시작한 확인이나 읽기(Codex 계정 알림, Pi 로그인 확인)의 답만 화면에 남는다.
- Codex 기본 로그인은 앱의 Codex 작업과 같은 환경(`CodexEnvironmentManager`)에서 읽는다. Codex 계정 알림
  모니터는 계정 화면이 열려 있는 동안만 App Server 하나로 돈다.

SQLite의 nullable `connection_binding`은 `SessionRecord.connection`을 보존한다. 과거
작업의 null 값은 기존 native/yardlet scope 의미를 그대로 유지한다. provider ID,
scope, 계정 바인딩이 다른 작업을 원본 기록 가져오기에서 동일 작업으로 취급하지 않는다.
등록한 폴더가 사라졌거나 GJC 계정이 없어졌다면 기본 계정으로 대체하지 않는다.

별도 환경에는 부모 프로세스의 모델 API 키·OAuth override·모델 라우팅 override를
전달하지 않는다. HOME과 일반 개발 도구 환경은 유지한다. 하네스 자체 설정에서 제공자
어댑터를 구성할 수 있지만 Yardlet이 임의 엔진에 임의 제공자 연결을 보장하지 않는다.
기존 작업을 다른 계정 폴더로 이동하거나 원본 대화를 복제하지 않는다.

GJC 조회는 공개 `accounts list --json`만 자동 실행한다. **사용량 새로고침**을 누르면
CLI 소유의 `accounts check --json` 후 다시 목록을 읽는다. auth DB나 credential payload를
직접 열지 않으며 API-key/env 행을 OAuth 다중 계정으로 가장하지 않는다.
계정 전환은 바인딩·작업 상태를 재검사하고, 해당 핸들을 닫은 뒤 같은 provider 세션 ID로
재개한다. 다른 작업의 핸들과 초안을 유지한다. 종료한 ACP transport를 재사용하지 않는다.

## 검증

- 전체 `swift test`: 669개, 660개 통과, opt-in live 9개 제외, 실패 0개.
- 세 개의 Codex 계정 폴더(공백 포함)로 subprocess + YHP + AppModel + SQLite를 통과해
  생성, 재시작, 같은 ID 재개, 포크와 원래 native 홈 보존을 확인했다. 인증 없는 fixture다.
- GJC의 공개 inventory와 실제 ACP subprocess fixture로 A→B→A 전환, 다른 B 작업 연결
  유지, 동일 세션 ID, 초안 보존, 삭제된 계정 거부, permission/abort 정책 보존을 확인했다.
  모델 prompt를 보내지 않았다.
- 실제 설치된 Codex 0.153.4와 Claude Code 2.1.270에서 비어 있는 별도 계정 환경을
  `login status`/`auth status`로 읽었고 기존 계정을 상속하지 않는 것을 확인했다.
- 실제 세 개의 사용자 계정 OAuth 로그인·유료 모델 턴·계정별 실제 한도 소진은 수행하지 않았다.
  사용자의 로그인은 각 CLI가 수행한다.
- 네이티브 UI fixture에서 세 계정의 한도 비교, 새 작업 기본 계정 선택 및 팝오버의
  다른 계정 선택 반영을 확인했다.

근거: Gajae Code v0.16.0 공식 소스의 accounts CLI, account-inventory, root flags;
설치된 Pi 0.84.1 문서/CLI 소스; OpenAI App Server 공식 account 문서.
재현 로그는 `.build/provider-connections-*.log`, fixture는 `scripts/fixtures/codex-session-home.py`에
있다(Gajae용 `gjc-account-selection.py`는 2026-10-23에 Gajae Code와 함께 지웠다).

## Claude 요금제 한도 조회 — 2026-10-06

Claude 계정이 로그인 상태이면 공식 CLI를 그 계정 환경으로 `-p --input-format stream-json
--output-format stream-json --verbose --strict-mcp-config`로 실행해 `initialize`와
`get_usage` 제어 요청만 보낸다. Claude Code 자신의 로그인으로 사용량을 조회하며 모델 요청과
대화 기록 쓰기가 없고 Yardlet은 토큰을 다루지 않는다. Session Switch 0.5.0이 쓰는 방식과 같다.
CLI가 사용량 엔드포인트를 비필수 트래픽으로 보므로 이 조회에서만
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`를 뺀다. 빈 임시 폴더에서 실행하고 끝나면 지운다.
응답의 `limits` 행(`session` 5시간, `weekly` 주간, `scope.model`이 있으면 모델별 주간)을 우선
쓰고, 없으면 `five_hour`·`seven_day`·`model_scoped`를 읽는다. 알 수 없는 묶음은 한도로 표시하지
않는다. `rate_limits_available: false`(API 키 등)나 조회 실패는 "한도를 알려 주지 않음"으로
표시하며 0으로 만들지 않는다.

