# 하네스 원본 세션 저장 — 2026-09-13

상태: 구현됨. 아래 날짜가 붙은 절은 그때 정한 규칙과 확인한 결과다.

## 2026-09-15 추가 계정 선택

별도 계정을 사용자가 선택한 작업은 nullable `connection_binding`에 하네스·제공자·계정
홈·CLI 선택자를 원본 세션 ID 및 scope와 함께 저장한다. null인 기존 작업은 아래의
native/yardlet 저장 의미를 유지한다. 별도 환경으로 새 작업을 만드는 경우에도 원본
인증·대화 파일을 복사하지 않는다. 재개·포크·사이드 채팅·제목 조회는 저장된 환경을
따르며, 새 작업의 기본 계정 변경은 기존 작업에 영향을 주지 않는다.

GJC의 같은 인증 저장소 내 계정 선택 외에 기존 작업을 다른 계정 폴더로 이동하는 동작은
추가하지 않는다. 2026-10-06 예외: Claude는 두 계정 폴더의 `projects`가 같은 실제 폴더로
풀릴 때만 작업의 계정 바인딩을 바꾼다. 기록이 처음부터 같은 곳에 있으므로 이동·복사가 없고
provider ID·scope·기록 위치가 그대로 유지된다. Claude 기록 읽기는 설정 폴더 바로 아래의
`projects` 링크 하나만 따라가고, 그 아래의 링크·FIFO는 이전처럼 거절한다. 현재 구현·검증과 CLI별 범위는 [PROVIDER_CONNECTIONS.md](PROVIDER_CONNECTIONS.md)를
따른다. 아래 설치 기록은 당시 이력이다.

2026-10-27 계정 자동 배정: 에이전트가 시작하는 하위 작업(`create_task`)·하위 에이전트(`run_agent`)·사람이 시작하는
제안 칩은 같은 하네스의 자동 배정 계정 가운데 하나에서 시작한다. 고른 계정은 새 작업의 `connection_binding`으로 provider 세션 ID·scope
(`.native`)와 함께 처음부터 저장되고, 이후 재개·포크·제목 조회는 지금처럼 그 binding을 따른다. 기존 작업의 계정·기록·scope는 옮기지
않는다. 기본 배정 대상은 기본 로그인과 대화 기록을 같은 곳에 두는 계정이라, Session Switch의 Claude 폴더 셋(모두 `projects` →
`~/.claude/projects`, 2026-10-27 이 Mac에서 읽어 확인)에서 시작한 하위 작업은 어느 계정이든 같은 기록 폴더에 남고 한도 카드의 계정 전환
(2026-10-06 예외)도 그대로 쓸 수 있다. 별도 `CODEX_HOME`의 Codex 로그인은 기록이 따로라 사람이 넣기 전에는 배정하지 않는다. 인증·기록
파일을 복사하거나 계정 폴더를 바꾸지 않는다. 배정 이유는 Yardlet 파일 `~/.yardlet/account-assignments.json`(작업 ID → 계정 ID·창·시각)이다.

## 변경 이유와 동작

2026-10-23 Codex 작업별 모드: 선택한 Plan/Default preset을 기존 provider options의
`codex.collaborationMode` JSON으로 저장한다. 모델·추론 수준·Fast 변경은 이 모드를 지우지 않는다.
재개 전에 같은 작업의 어댑터에 복원하고, 런타임 목록을 읽으면 ID 우선·mode 차선으로 현재 preset에
맞춘다. 키가 없거나 읽을 수 없는 기존 작업에는 모드를 추가하지 않는다. 명시적으로 Plan을 끄거나
계획 구현을 시작하면 Default를 저장한다. 저장 실패 때는 provider 선택을 이전 모드로 되돌리며,
런타임이 preset 이름을 바꿨으면 새 목록에서 같은 모드를 찾는다. 포크와 기존 새 대화 옵션 전달은
저장값을 그대로 따른다. provider ID·계정·scope·원본 기록·초안은 이동하거나 변경하지 않는다.

2026-10-06 detached Claude 재독해: 선택/상태 갱신과 resume 전에 저장된 provider ID·account/home·
scope·runtime·workspace로 native main chain을 읽는다. 최대 2,000 entries와 기존 8 MiB 파일
한도이며 다른 하네스의 기본 cache 한도는 유지한다. attach/실행 중이거나 identity/cache가 바뀐
늦은 결과는 적용하지 않는다. stable native UUID를 쓰고 읽기 anchor는 유일한 content 일치에만
옮긴다. 초안·원본 파일을 보존하고 실패 시 cache/ID를 유지한다. 자동 import·세션 이동·모델
입력·credential/home 복사는 없다. Codex service tier는 기존 선택 JSON의 optional 필드이며
Files의 per-file 초안은 app-owned workspace preferences에 저장한다.
2026-10-13부터 이 재독해는 처음에 파일 끝 1 MiB만 읽고 이전 턴은 스크롤할 때
읽는다(아래 "긴 기록 나눠 읽기" 절). 8 MiB·2,000 항목은 그 상한으로 남는다.

2026-10-05 대화 복구 후속: Claude 편집 시 `inherited_context.nativeConversationOrigin`의 optional
JSON에 원본 provider ID·harness·계정/home·scope·workspace·runtime·옵션·프로젝트/추가 roots를
함께 저장한다. 기존 context/draft JSON과 SQLite schema는 호환한다. 원본 열기는 이 binding의
main chain을 bounded read로 읽고 별도 local record에 원본 ID를 연결한다. 마지막 unanswered user
입력도 읽으며 같은 ID가 다른 home/scope에 있다고 재사용하지 않는다. 현재 채팅·초안·읽기 위치·
ID와 원본 파일을 보존하며 provider attach·모델 전송·인증 변경이 없다. 동일 binding의 열린 record는
그대로 재사용한다. 원본 metadata 없는 오래된 context를 현재 계정에 임의로 연결하지 않는다.

첫 메시지 편집에는 fork assistant 경계가 없어 위 origin을 보관하되 text context로 주입하지 않는다.
`HarnessNewSessionConfiguring`은 저장한 계획 ID가 아직 없는 경우에만 같은 native ID의 새
`--session-id` launch를 명시적으로 준비한다. 저장한 child가 있으면 own-ID resume며 손상/대체
파일은 빈 대화로 대체하지 않는다. 일반 resume에는 이 새 세션 경로를 적용하지 않는다.
Codex Retry는 original input의 복제 없이 native empty continuation이다. 원래 provider ID·scope·
계정·초안과 retained history는 유지하며 새 latest turn을 읽어 중복/늦은 동작을 거절한다.

2026-10-05 Claude 원본 이미지 편집 후속: active chain에서 text/base64 image만 공통 초안으로
복원한다. 원본 이미지 MIME·decoded bytes를 immutable data URL로 저장하고 YHP에서는
`inline_data` block으로 전달한다. 로컬 파일로 잘못 변환하거나 원격 URL을 읽지 않는다.
`ConversationEditState.originalInputFingerprint`는 optional digest로 기존 JSON을 호환하며 전송
직전 원본 user content의 변경을 검사한다. 첨부 preflight는 provider ID/history 전환보다 먼저다.
cancel은 원래 미전송 text/첨부를 복구한다. 해당 변경은 provider history/home/credential을 복사·
이동하지 않는다. base64 이미지 8개/각 decoded 8 MiB 상한과 기존 scoped JSONL read 상한을
유지하며 문서/unknown/non-base64 이미지는 편집 입력으로 복원하지 않는다. 실제 모델 수락은 별도다.

2026-10-08 보낸 메시지 이미지 표시: 공통 전사의 user 항목은 보낸 이미지(URL·이름)를 함께 가진다. Yardlet 읽기
캐시와 사이드 채팅 문맥 JSON에는 파일 URL과 이름만 쓰고 인라인 data URL 바이트는 쓰지 않는다. 인라인 이미지는
실시간 항목과 provider 기록(Claude는 작업을 열 때 JSONL을 다시 읽음)에서만 미리보기하며, 캐시에서 복원된
항목은 "이미지" 이름으로 보인다. 미리보기는 읽기 전용이며 파일을 만들거나 원격 URL을 받지 않는다.

2026-10-05 Claude Desktop 패키지 경로 후속: 현재 CLI는
`claude-code/<version>/<package-hash>/claude.app/Contents/MacOS/claude`에 있다. discovery와
missing-runtime relocation은 같은 helper로 기존 flat 경로와 regular `.verified` marker가 있는
완료한 패키지를 버전 순서로 찾는다. 미완료/잘못된 marker/연결 디렉터리는 제외한다. 존재하는
저장 선택과 사용자 관리 CLI는 변경하지 않는다. 누락된 app-managed 경로만 같은 Claude root의
후속 경로로 이어가며 provider ID·저장 scope·계정 binding·원본 history는 유지한다. credential을
복사하거나 로그인하지 않는다.
2026-10-26: Yardlet이 도는 동안 Claude Desktop이 업데이트하며 고른 버전을 지우면(03:08, 2.1.299 → 2.1.308), 실행할 때 찾은
선택이 사라진 경로를 쥐어 모든 Claude Code 계정이 "런타임 없음"이었고 새 작업도 시작할 수 없었다. 이제 `RuntimeSelectionStore.selectedURL`도
같은 relocation helper로 그 자리의 후속 경로를 돌려준다(다음 실행에서 하던 것과 같음). 사용자 관리 CLI는 여전히 추측하지 않는다.

2026-10-04 최신 입력 편집·파일 복원 추가: `TaskDraftSnapshot.editState`는 optional JSON으로
원본 provider ID·계정·scope·workspace, user/assistant 경계, 편집 전 미전송 초안·첨부와 bounded
읽기 cache를 함께 저장한다. 기존 draft JSON은 그대로 읽으며 DB schema는 바꾸지 않는다. 편집
열기/취소는 provider history를 쓰지 않는다. 전송 전 동일 원본·idle 상태를 다시 확인한다.
Codex는 같은 ID의 native revert/legacy rollback 뒤 retained history를 읽고 입력을 보낸다.
실제 0.160.0은 legacy rollback을 지원하지 않는다. 지원하지 않는 method 응답은 정확한 실패로
처리하며 draft/원본을 보존한다. 다른 오류를 지원 부재로 바꾸거나 원본 형식을 자동 이전하지 않는다.
Claude는 계획한 새 UUID를 draft에 먼저 저장하고 같은 local record의 provider ID와 기존
`inherited_context.nativeForkSource`를 함께 전환한다. 준비한 전환은 재시작·재시도 후에도 고정하며
이전 원본 JSONL을 수정하거나 다른 home으로 복사하지 않는다. 전송 후 원래 ID로 돌아가는 취소를
제공하지 않는다. retired handle의 늦은 이벤트가 새 ID를 덮어쓰지 못하게 한다.

Claude file checkpointing은 provider process의 native 환경 flag로 활성화한다. 이미 저장된 기록에
새 체크포인트를 만들어 넣지 않는다. 파일 복원은 원본 user UUID의 `rewind_files` dry-run과
명시적인 별도 실행이며 대화 전환을 하지 않는다. 변경 파일은 저장된 workspace/추가 roots의
regular file만 읽어 검토 시 fingerprint를 고정하고 실행 전에 다시 확인한다. symlink·FIFO·범위 밖
파일·변경된 검토 결과는 거절한다.

2026-10-03 원본 분기·초기화 추가: Codex 선택 턴 분기는 원본 ID와 `lastTurnId`를 함께 보내 새
provider thread ID로 별도 local record를 만든다. source의 history를 rollback/revert하지 않는다.
Claude 분기에는 부모와 같은 계정·scope·workspace를 사용하며 원본 assistant UUID를 고정한다.
새 UUID와 `inherited_context` JSON의 optional `nativeForkSource`에 원본 ID·지점을 함께 저장한다.
첫 입력 전 child 파일을 만들지 않는 CLI에서 재시작해도 같은 경계로 native fork를 준비하고,
child 원본이 저장돼 있으면 그 ID로 재개한다. 원본 준비에 실패하면 text snapshot으로 대체하지
않는다. 파일 탐색은 기존 scoped read 경계를 사용하고 원본을 직접 쓰거나 다른 home으로 옮기지
않는다. 기존 context JSON과 DB schema는 호환되며 이전 snapshot side chat은 자동 변환하지 않는다.
초기화는 같은 프로젝트·계정·scope의 빈 local record를 만든다. 기존 ID·history·draft·읽기 상태를
보존하며 해당 원본을 clear하지 않는다. 프로젝트/추가 roots와 저장된 옵션도 함께 유지한다.

2026-10-01 하위 대화 읽기 추가: 부모 작업에 저장한 provider session ID·account binding·scope를
사용해 해당 Claude config의 원본 subagent 로그만 읽는다. task ID·agent ID·tool-use ID는 optional
UI metadata로 보존하며 새 provider session ID로 바꾸지 않는다. 읽기에는 원본 세션 재개·작업 생성·
모델 턴·부모 선택 변경·history 쓰기가 없다. 파일 읽기 전후에도 현재 record의 저장 범위를 확인한다.
하위 대화는 읽기 전용이며 별도 하위 세션의 직접 입력을 지원한다고 해석하지 않는다.

이전에는 같은 신규 작업이라도 Codex만 Yardlet 전용 홈에 저장됐다. 이제 신규 작업은
각 하네스의 원래 저장 환경을 사용한다. Codex는 기본 `~/.codex` 또는 기존에 지정한
native home을 사용하며, Account Center의 조회·모니터·로그인·로그아웃도 같은 홈을 본다.
실제 인증 동작은 하네스가 수행하며 이 변경에서 로그인·로그아웃을 실행하지 않았다.

Yardlet은 `~/.yardlet/session-index.sqlite3`의 연결 인덱스, 초안과 읽기 캐시를 유지한다.
이 데이터는 하네스의 원본 대화·세션 ID와 별개다. config, 인증, history, SQLite를
새 홈으로 복사하거나 원래 config의 `sqlite_home`을 재작성하지 않는다.

Codex 읽기 캐시(`~/.yardlet/transcripts/<작업 UUID>.json`)는 형식이 그대로 `[TranscriptEntry]`다.
2026-10-08(대화 화면 통일 M7)부터 항목 ID만 thread·turn·item ID에서 만든 이름 기반 UUID(v5)라 체크포인트마다
같다. 턴을 연 메시지는 turn ID만으로 이름을 짓는다. 그래서 분리 상태에서 저장한 읽기 위치와 붙은 상태의 Codex 턴
ID가 서로 이어진다(`ConversationAnchorResolver`). 이전 캐시의 무작위 ID도 그대로 읽히고, 다음 체크포인트에서 새
ID로 다시 쓰인다. 작업 화면 상태(`Yardlet.taskWorkspace.<id>`, version 1)의 `transcript`·`codex` 두 북마크도
그대로 디코드한다.

Codex 기록에서 빠지는 카드(명령·파일 변경·도구 호출·이미지 생성, 끊긴 턴의 답)는 2026-10-24부터
`~/.yardlet/codex-timeline-items/<작업 UUID>.json`에 둔다. 형식은 그대로 `[CodexPersistedTimelineItem]` JSON이고 작업마다 최근
500장이다. 전에는 설정(`NativeHarnessClient.codexTimelineItems.<작업 UUID>`)에 있었고, 앱이 시작할 때 남은 값을 그대로 파일로 옮긴 뒤
설정 키를 지운다(파일이 이미 있으면 파일을 둔다). 작업을 보관하거나 지우면 파일도 지운다.

2026-10-12부터 분리된 Codex 작업을 열면(입력창이 나타날 때) 그 작업의 App Server(같은 계정·저장 범위)로 저장된 스레드를
`thread/read`(`includeTurns: true`)로 읽어 명령·파일 변경까지 보인다(YHP `yardlet.codex.thread.read`). `thread/resume`·
`turn/start`는 보내지 않고 계정·홈·인증도 바꾸지 않는다. 읽기 캐시는 첫 화면으로 남고, 읽은 스레드가 같은 대화 뷰에서
그것을 대신한다(읽기 위치는 위 이름 기반 ID로 이어진다). 읽기 자체는 아무것도 저장하지 않는다(앱 종료 때는 보이는 다른
Codex 스레드처럼 읽기 캐시를 그 화면에서 다시 쓴다). 실패하거나 턴이 없는 응답은 캐시를 그대로 둔다. 2026-10-13부터는
스레드 전체가 아니라 메타데이터(`includeTurns: false`)와 최신 턴 한 페이지만 읽고, 이전 페이지는 스크롤할 때 읽는다(아래
"긴 기록 나눠 읽기" 절).

2026-10-09(대화 화면 통일 D13)부터 모든 하네스의 읽기 캐시 항목에 선택 필드 `joinsRunningTurn`(Bool)이 있다. Claude
Code가 실행 중인 턴의 다음 단계에서 읽은 후속 메시지에만 `true`로 쓰이고, 그 밖에는 키가 없다(전과 같은 모양). 옛 캐시는
그대로 읽히고(nil), 옛 빌드는 모르는 키를 무시한다. 새 렌더러는 이 메시지를 새 턴이 아니라 실행 중이던 턴 안에 그린다.
2026-10-12부터 Claude 기록을 다시 읽을 때도(분리된 작업 열기, 가져오기) Claude가 그 메시지를 남긴 `queued_command` 첨부 항목을 이 표시가 붙은 메시지로 읽어 같은 턴에 둔다. Codex 기록에는 해당이 없다.

- `SessionRecord`, `SessionStore`, `HarnessRegistry`의 신규 기본 scope는 `.native`다.
- Codex 어댑터와 실제 프로세스까지 저장된 scope를 전달한다.
- 앱 시작·신규 작업 생성은 옛 capability snapshot을 만들지 않는다.
- 기존 `.yardlet` 작업은 SQLite 복원 뒤에도 전용 홈과 provider ID를 유지한다.
  재개와 사이드 채팅 fork도 해당 홈을 사용한다. 기존 파일을 자동 이동·삭제하지 않는다.
- native history를 가져올 때 scope와 ID를 함께 비교한다. 별도 홈에서 우연히 동일한
  문자열 ID가 존재해도 잘못된 기존 작업을 선택하지 않는다.
- 설정 조회의 Codex 프로세스도 동일한 native 기본값을 따른다.

## 검증

| 범위 | 결과 |
|---|---|
| 집중 검사 | 환경·계정 명령·세션 저장과 프로세스 경계 26개 통과 |
| 프로세스 통합 | 실제 subprocess + YHP + AppModel + SQLite를 통해 신규 저장, 재시작, 외부 변경 원본 재독해, 같은 ID 재개와 fork 확인 |
| 기존 격리 호환 | 전용 홈 생성 기록을 SQLite에서 복원하고 같은 홈으로 resume/fork. native/isolated의 동일 ID를 분리해 import |
| 계정 | 원샷 account/read와 모니터의 account/read가 같은 native 홈 사용. 로그인·로그아웃은 생성된 명령 환경만 검사 |
| 실제 Codex | 선택된 `/Applications/ChatGPT.app/Contents/Resources/codex` 0.153.4로 임시 native 홈에서 무프롬프트 작업 생성·종료 성공. 사용자 홈·계정·대화 사용 안 함 |
| 전체 회귀 | 총 633개, 624개 통과, opt-in live 9개 제외, 실패 0개 |

검사 fixture는 임시 위치에 복사되어 실행되며 `CODEX_HOME`, 메서드와 fixture thread ID만
기록한다. 프로세스 환경 전체, 사용자 프롬프트나 인증 값을 기록하지 않는다.

## 설치와 남은 경계

새로운 모델 턴이나 실제 사용자 세션의 이어쓰기·동시 실행은 수행하지 않았다.

공유 저장소와 양쪽 앱의 작업 목록 동기화는 별개다. 전체 원본 작업 자동 가져오기,
제목·보관 상태의 상시 양방향 동기화, 동시 클라이언트 실행 조정은 이번 변경에 포함하지
않는다. 기존 전용 홈의 인증 상태도 그대로 보존하며 native 계정으로 자동 교체하지 않는다.

재현 로그는 `.build/native-sessions-focused.log`, `.build/native-sessions-provider-smoke.log`,
`.build/native-sessions-all-tests.log`, `.build/native-sessions-release.log`에 있다.

원본 저장 단독 설치 당시 릴리스 빌드와 strict codesign 검증도 통과했다. 당시 실행 파일 SHA-256:

```text
18ee6855f083f94bdceaa26924b0dcbeb31eb25c460d48dca58163a9e1ef4a00
```

영구 검증 로그와 읽기 전용 저장 행 집계:

```text
~/Library/Application Support/Yardlet/Session Closeouts/2026-09-13-native-sessions-021617
```

설치 백업·저장 행 일치·실행 확인:

```text
~/Library/Application Support/Yardlet/App Backups/2026-09-13-native-session-install-024828
```


## 후속 제목 갱신과 최종 설치

제목 갱신은 이미 가져온 Grok Build·Claude Code·OpenCode의 provider 제목을
앱 시작·작업 선택·앱 복귀 때 다시 읽는다. 기존 resolver가 지원하는 원본 metadata만
읽고, provider가 분리돼 있으면 작업을 재개하거나 메시지를 보내지 않는다.
Codex는 기존 presentation 이벤트 경로를 유지하며 이 파일 resolver의 대상이 아니다.
(2026-10-08부터 코드에서는 이 구분이 `ProviderTitleSource`의 push(Codex)와 pull(그 밖)이고, 두 출처가 같은
갱신 시점과 같은 반영 규칙을 쓴다.)

- 수동 이름과 출처가 불명확한 옛 이름은 보존한다. provider/automatic/provisional
  제목과 정확히 첫 프롬프트 제목인 legacy 기록만 후보로 삼는다.
- 제목 반영은 `updatedAt`을 변경하지 않으며 같은 제목의 반복 SQL 쓰기를 생략한다.
- 세션별 읽기 토큰과 최신 record의 ID/scope/title/origin을 재확인한다. 늦은 응답이
  새 읽기, 수동 이름, 삭제, 취소 또는 종료 이후 결과를 덮어쓰지 않는다.
- 핀·읽음·provider 옵션·초안·선택·최근 활동 순서 보존을 집중 검사로 확인했다.
- 2026-10-12부터 작업 연결(attach), 연결 때 런타임이 보내는 시작·준비 상태 보고(진행 중이던 턴이 없을 때), 모델·추론·
  모드 같은 설정 저장도 `updatedAt`을 바꾸지 않는다. 최근 활동은 보내기, 턴 진행·승인 대기·완료·실패, 이름 바꾸기다.

별도 QA 앱의 resource lookup이 개발 폴더를 찾다 시작 중 멈추는 것을 재현했다.
이 수정은 패키지 번역 파일을 먼저 판별하고, 로고를 읽을 때 `Bundle.module`을
미리 평가하지 않도록 수정했다. 같은 릴리스 실행 파일을 별도 앱 식별자와 임시
`CFFIXED_USER_HOME`으로 실행해 원본 사용자 데이터 없이 검증했다.

| 최종 검증 | 결과 |
|---|---|
| 전체 검사 | 639개, 630개 통과, opt-in live 9개 제외, 실패 0개 |
| 실제 QA 창 | 시작 시 cached 제목 갱신, fixture summary 외부 변경 후 작업 전환으로 새 제목 표시, 공백·줄바꿈·이모지 초안 보존을 AX/화면으로 확인 |
| QA 저장 | provider ID와 최근 활동 시각 유지, 미전송 초안 파일의 정확한 텍스트 유지 |
| 앱 활성화 | visible-only refresh와 상태 보존 단위 검사 통과. CUA로 native 활성화 이벤트를 확정하지 못해 실제 앱 전환 수락은 미확인 |
| 기존 저장 | 11개 기록 보존. 원본과 일치하는 Grok provider 제목 1개만 갱신, 모든 다른 필드 동일 |
| 기존 UI | Codex와 Grok 작업을 열고 원래 Grok 작업·오른쪽 패널 복구 확인 |

현재 `/Applications/Yardlet.app` 실행 파일 SHA-256:

```text
c83e05de3e0bd17bcbf808fceff3d8b5722aedd4343f09a719034fe86b9a5457
```

최종 설치 백업과 영구 검증 로그:

```text
~/Library/Application Support/Yardlet/App Backups/2026-09-13-provider-title-refresh-031254
```

`install.json`, `installed-verification.json`, `native-ui-verification.json`에 서로 다른
검증 경계를 기록했다. 실제 모델 턴, 로그인/로그아웃, 원본 세션 파일 쓰기는 없었다.

## 보관과 보관 해제 — 2026-10-08

보관은 이제 되돌릴 수 있다. 사이드바 아래 **보관된 작업**(작업 메뉴와 명령 팔레트에도 있음)이 작업 목록 자리에
보관된 작업을 최근 보관 순으로 보여 주고, 제목·프로젝트·하네스로 검색하며, **보관 해제**로 되돌린다.

- **색인:** `archived` 열은 0(목록), 1(보관), 2(삭제 또는 실패한 포크·가져오기·사이드 채팅이 만든 뒤 버린 작업)이다.
  보관 때 `archived_at`과 `provider_archived`를 함께 쓴다. 두 열이 생기기 전 행은 날짜가 없고 `provider_archived = 0`으로
  읽으며, 그때 삭제·폐기된 행도 1이라 보관된 작업에 함께 보인다(구별할 기록이 없다).
- **보관 해제:** 같은 행을 `archived = 0`으로 되돌린다. provider 세션 ID, 저장 범위, 계정 연결, 프로젝트, 추가 루트,
  고정, 제목은 그대로다. 실행 중에 보관된 작업은 재실행 복원처럼 준비 상태로 돌아온다. 그 작업의 프로젝트가 숨겨져
  있었으면 다시 보이게 한다. 작업을 열거나 붙이지 않으며 모델 턴도 시작하지 않는다.
- **Codex 원본:** Yardlet의 보관은 붙어 있는 Codex 작업일 때만 `thread/archive`를 보낸다. 그 경우에만
  `provider_archived = 1`이고, 보관 해제는 그 계정·범위의 App Server로 `thread/unarchive`(`threadId`)만 보낸 뒤 색인을
  되돌린다. `thread/resume`이나 `turn/start`는 없다. 실패하면 보관 상태로 남아 다시 시도할 수 있다. 붙어 있지 않을 때
  보관했거나 이전 행처럼 기록이 없는 작업은 원본을 건드리지 않는다. 원본 쪽 보관·보관 해제·삭제·이름 바꾸기는
  `HarnessSessionLifecycleProviding`을 구현한 어댑터에만 간다(지금은 Codex와 그 YHP 래퍼뿐).
- **로컬 캐시:** 보관 때 지우던 초안·대화 캐시·Codex 타임라인 캐시는 예전처럼 지운다. 되돌린 Claude 작업은 열 때
  원본 기록을 다시 읽고, Codex 작업은 열 때 원본 스레드를 `thread/read`로 읽어 보이고 이어서 하기(`thread/resume`)나
  다음 전송 때 원본에서 대화를 불러온다.

## 다른 앱의 대화 가져오기 — 2026-10-12

가져오기는 여전히 사용자가 고른 것만 색인 행 하나로 더한다. 원본 기록·인증·홈을 복사하거나 옮기지 않고, provider 세션 ID·
`.native` 범위·계정 연결을 함께 저장한다. 바뀐 계약은 다음과 같다.

- **가져오기는 런타임을 띄우지 않는다:** 가져온 작업은 재실행 뒤 복원된 작업처럼 분리 상태로 만들어진다(`attach` 없음). 처음
  보낼 때 붙는다. 열면 Claude는 원본 JSONL을 다시 읽고, Codex는 `thread/read`로 스레드를 읽는다(위 2026-10-06·
  2026-10-12 절). 검색 결과로 가져온 Codex 작업의 일치 위치는 같은 계정·범위의 App Server에 `thread/searchOccurrences`로만
  묻는다. 이미 가져온 대화(같은 하네스·범위·provider ID·계정, Claude는 기록을 공유하는 계정)는 기존 작업을 연다.
- **한꺼번에 가져오기(파일 > 다른 앱의 대화 가져오기…):**
  - Claude 출처는 Claude 앱의 `~/Library/Application Support/Claude/claude-code-sessions/<조직>/<계정>/local_*.json`이다.
    Claude 앱 소유의 문서화되지 않은 파일이라 읽기만 하고(파일당 4 MiB, 2,000개 한도, 링크 제외), 키가 없거나 형이 달라도
    그 값만 없는 것으로 본다. 보관되지 않았고 `cliSessionId`의 기록이 고른 Claude 계정의 `projects/<폴더 이름>/<id>.jsonl`에
    있는 세션만 보인다. provider 세션 ID는 `cliSessionId`이고 계정은 시트에서 고른 계정(기본은 새 작업 계정)이다.
  - Codex 출처는 기본 Codex 로그인(`~/.codex`)의 App Server `thread/list`다. 폴더 없이 `archived: false`,
    `sourceKinds: ["cli", "vscode", "appServer"]`로 묻고(YHP `yardlet.codex.history.interactive`), 응답에서도 `source`가
    `exec`·`subAgent`이거나 `parentThreadId`가 있거나 `ephemeral`인 스레드는 뺀다. Codex 앱 스레드는 `vscode`
    출처다(codex-cli 0.157.1 실측). 계정은 기본 Codex 로그인(연결 없음)이다.
  - 배치는 `ConversationImportPlacement` 한 곳에서 정한다. `ChatWorkspaces`의 채팅 폴더는 프로젝트 없음(프로젝트를 만들지
    않는다), Claude 앱의 워크트리(`cwd`가 `originCwd` 안)는 원래 저장소의 프로젝트, 나머지는 새 작업과 같은 규칙
    (`projectForNewTask`)이다. 작업 폴더는 언제나 대화의 `cwd`이고, 워크트리의 원점·이름·브랜치는 기존
    `origin_workspace_path`·`worktree_name`·`branch` 열에 쓴다. 폴더의 Git 기록이 우선하고, 폴더가 없으면 세션 파일 값을 쓴다.
  - 옮겨 오는 값: 제목(`titleOrigin` provider), Claude의 model·effort·permissionMode(`ClaudeLaunchOption` 키, `default`는
    `manual`, 그 밖은 그대로). Codex는 스레드가 모델을 갖고 있어 옮기지 않는다. 작업의 최근 활동은 다른 앱의 마지막 활동이다.
  - 재실행 때 폴더→프로젝트 변환은 이미 프로젝트에 보이는 작업(ID·폴더·워크트리 원점)과 채팅 폴더에 프로젝트를 만들지 않는다.
- **다른 앱이 잡고 있는 Claude 대화:** Claude 앱은 열린 세션의 CLI 프로세스를 살려 두고, 한 프로세스는 자기 클라이언트에만
  스트리밍한다. 두 프로세스가 한 대화를 이어 쓰면 안 되므로, 고른 계정의 `sessions/<pid>.json`에 살아 있는 다른 앱의
  프로세스가 그 세션 ID를 갖고 있으면(Yardlet이 띄운 자식·손자 프로세스는 제외) 붙기·보내기·`resume`을 거절하고 작업에
  "Claude 앱에서 아직 열려 있습니다. 그 앱에서 닫으면 여기서 이어집니다."를 보인다. 초안은 남고 작업 상태는 바뀌지 않는다.
  가져오기 자체는 막지 않는다. 그 프로세스가 끝나면 보내기가 평소처럼 붙는다.
- **읽기 전용 따라가기:** 분리된 Claude·Codex 작업이 보이는 동안 2초마다 원본 파일(Claude JSONL, Codex는 마지막
  `thread/read`가 알려 준 rollout `path`)의 크기·수정 시각을 보고, 바뀌면 여는 경로와 같은 가드로 다시 읽는다. 아무것도
  저장·전송·재개하지 않는다. 작업이 붙거나 보이지 않으면 멈춘다. 2026-10-13부터 다시 읽는 것은 최신 부분뿐이다(아래 절).
- **Codex의 경계:** 다른 App Server가 연 스레드를 알려 주는 등록부가 없어 Codex에는 보내기 가드가 없다. Codex 앱이 아직
  실행 중인 스레드를 Yardlet에서 보내면 두 App Server가 같은 rollout을 이어 쓸 수 있으며, 이 조정은 제공자가 소유한다.

## 긴 기록 나눠 읽기 — 2026-10-13

분리된 작업을 열 때 기록 전체를 먼저 읽지 않는다. 최신 부분만 읽어 보이고, 사람이 대화 꼭대기까지 스크롤하거나 레일의 ▲를
누르면 이전 부분을 더 읽는다. 다른 앱이 쓰는 것을 따라갈 때도 최신 부분만 다시 읽는다. 읽기는 모두 작업에 저장된 provider
ID·계정·저장 범위로 하고, 아무것도 저장·전송·재개·연결하지 않으며 원본 기록·인증·홈을 바꾸지 않는다.

2026-10-18부터 이 열기 읽기는 작업을 고르는 순간 시작하고(전에는 작업 화면의 입력창이 나타난 뒤), 사이드바에서 포인터가 행에
120 ms 머물면 이번 실행에서 아직 아무것도 읽지 않은 분리 작업을 미리 읽는다(`AppModel.readSavedConversation`·
`prefetchSavedConversation`). 읽는 것·범위·계정은 같고, 쓰는 것은 예전처럼 Yardlet의 읽기 캐시뿐이다. 읽는 동안 보일 것이
없는 대화는 "대화 시작" 대신 불러오는 중으로 보인다.

- **Codex(분리된 작업):**
  - 열 때: 그 작업의 App Server(레지스트리 어댑터, 같은 계정·범위)로 `thread/read`(`includeTurns: false`, 메타데이터와
    rollout `path`)를 읽고 `thread/turns/list`(`sortDirection: "desc"`, `itemsView: "full"`, `limit` 5 =
    `CodexThreadPaging.newestTurns`)로 최신 턴만 읽는다. 응답은 `data`(최신 순), `nextCursor`(그 앞, 즉 이전 턴),
    `backwardsCursor`(그 뒤)이며, codex-cli 0.157.1은 로드되지 않은 스레드에도 답한다(실측). `nextCursor`는 기존
    `turnsNextCursor`에 두고 대화에서는 `ConversationEarlierTurns.provider(cursor:)`다.
  - 이전 페이지: `loadMoreCodexTurns`는 분리된 작업을 붙이지 않는다(전에는 붙였다). 같은 App Server로 `thread/turns/list`
    (그 커서, `limit` 10 = `CodexThreadPaging.earlierTurns`)를 읽어 앞에 붙인다. 작업이 붙었거나 커서가 바뀐 뒤 도착한
    페이지는 버린다. 붙은 작업은 전처럼 어댑터의 `loadTurns`이고, 한 페이지가 50턴에서 10턴이 됐다.
  - 따라가기·다시 열기: 이미 보이는 스레드는 `thread/turns/list` 첫 페이지만 다시 읽어 합친다
    (`CodexTaskReducer.mergeNewestTurnPage`). 페이지의 턴은 새로 받은 것으로 바꾸고, 페이지의 가장 오래된 턴 뒤인데
    페이지에 없는 턴(되돌린 턴)은 뺀다. 그 앞의 이미 읽은 턴과 커서는 둔다. 겹치는 턴이 없으면(한 페이지보다 많은 턴이
    쌓임) 그 페이지부터 다시 시작한다.
  - YHP: `yardlet.codex.thread.read`(`HarnessProtocolCodexThreadReadParams`)의 선택 필드 `newestTurns`. 없으면 전처럼
    스레드 전체를 읽는다(옛 피어). 새 메서드 `yardlet.codex.thread.turns.read`
    (`HarnessProtocolCodexThreadTurnsReadParams`: `threadID`, `cursor`, `limit` → `HarnessProtocolCodexTurnPage`, 턴은
    오래된 순). 둘 다 세션을 만들거나 등록하지 않는다.
  - 읽기 캐시(`[TranscriptEntry]`, 최대 500 항목)는 보이는 스레드에서 다시 쓰이므로 이제 불러온 턴만 담는다.
- **Claude(분리된 작업과 붙은 작업):** 2026-10-14에 8 MiB 상한을 없앴다.
  - 읽기 예산 `ClaudeTranscriptTail`: 처음 파일 끝 1 MiB(`readNewest`). 이전 턴을 원할 때마다 두 배(2·4·8 MiB), 그 뒤로는
    8 MiB씩(`stepBytes`: 16·24·32 …) 파일 시작까지 늘린다. 예산은 처음 읽은 때의 파일 끝에서 센다. 예산과 읽은 범위는
    작업·provider ID별로 메모리에만 있다(다른 대화 ID면 처음부터). 아무것도 저장하지 않는다.
  - 창(`ClaudeTranscriptWindow`): 읽은 줄의 색인(레코드 ID → 줄 오프셋·길이·부모·`logicalParentUuid`·종류·meta·
    sidechain·도구 호출/결과 ID; 본문은 없다), 처음 보이는 턴의 요청 레코드와 그 항목(경계), 체인이 앞으로 이어지는지
    (`hasEarlierRecords`). 파일의 장치·inode와 처음 읽은 크기를 함께 두어, 바뀐 파일(다른 inode, 줄어든 크기)에서는 더
    읽지 않는다.
  - 더 뒤로 읽기(`readEarlier`, `readEarlierTurns`): 창 앞의 바이트만 읽어 파싱하고 색인에 더한다(같은 ID면 파일에서 뒤에
    있는 줄이 이긴다). 체인은 경계 레코드의 부모부터 새로 덮은 부분으로 이어 가고, 그 투영을 보이는 항목 앞에 넣는다.
    읽기가 걸친 첫 턴(요청 앞)은 빼고, 아직 어떤 턴의 요청에도 닿지 않았으면(한 단계보다 긴 턴) 아무것도 넣지 않고 더
    읽는다. 경계 앞의 이미 덮은 레코드(뺐던 턴)는 색인의 오프셋으로 파일에서 다시 읽는다. 한 요청 안의 여러 단계는 파싱한
    값을 이어 받아 같은 바이트를 두 번 파싱하지 않는다. 항목 ID는 기록의 uuid와 순서(`세션|uuid|순번`)에서 만들어, 나눠
    읽은 결과가 같은 예산을 한 번에 읽은 결과와 같다.
  - 마지막 턴이 첫 읽기보다 길면 그 턴의 일부만(요청 없이) 보인다(`partialRecord`/`partialEntry`). 더 뒤로 읽으면 그 턴을
    요청부터 통째로 다시 투영해 그 일부 자리에 넣는다(`ClaudeTranscriptRead.replacesThrough`,
    `TranscriptBuilder.replaceEntries(through:)`).
  - 첫 읽기(`readNewest`)가 앞 턴 안에서 시작하면 그 턴의 뒷부분(마지막 단계·최종 답)을 빼지 않고 첫 요청 위에 보인다
    (`partialEntry`가 그 부분의 마지막 항목, 경계는 첫 요청). 더 뒤로 읽으면 위와 같이 그 턴을 통째로 그 자리에 넣는다.
    2026-10-22 전에는 이 뒷부분을 뺐고, 창 경계가 최종 답 바로 앞에 걸리면 최종 보고가 화면과 `read_task`에서 사라졌다.
    파일을 다시 따라 읽을 때(`refreshConversation`)는 새 읽기의 첫 요청부터 이어 붙인다(`ClaudeTranscriptWindow.splicing`).
  - 백그라운드 명령·에이전트가 끝났다는 Claude Code의 알림(`origin.kind` "task-notification", `<task-notification>` 블록)은
    그 알림에 답한 턴을 여는 항목으로 읽고, 화면에서는 사람의 말풍선이 아니라 "백그라운드 작업" 알림 줄
    (`ClaudeTaskNotification`, 요약)로 보인다. 앞 턴의 최종 답은 그 턴의 답으로 남는다. 편집·되감기 지점은 아니다.
  - Claude Code 자신의 예약이 보낸 프롬프트도 그 턴을 여는 항목이다(2026-10-22, `ClaudeScheduledPrompt`). 저장 모양(2.1.299):
    `CronCreate` 작업·`/loop` 깨우기는 `type: "user"`, `isMeta: true`, `promptSource: "system"`, `turnOrigin: "scheduled"`,
    새 `promptId`, `turnPosition`, `queueSkipAttachments`(CLI가 `wakeupSource`가 있는 대기 프롬프트를 모두 이렇게 쓴다; 두 경우
    저장 모양이 같다), Claude 앱 예약 작업은 meta가 아니고 `origin: {kind: "task-notification", subkind: "scheduled-trigger"}`에
    `<scheduled-task name="…" file="…/SKILL.md">` 블록이다. 항목은 `TranscriptEntry.origin = .scheduled`(없으면 저장 모양에서
    빠짐)를 달고, 화면에서는 사람의 말풍선이 아니라 왼쪽 "예약된 체크인"(이름이 있으면 "예약된 작업: {이름}", Claude 앱 문구) 아래
    두 줄 접힌 상자로, `read_task`에서는 "Scheduled task: …"로 보인다. 편집·되감기·파일 복원 지점이 아니다(예약 프롬프트에는
    `file-history-snapshot`이 없다). 같은 `promptId`의 이어 쓰기 항목(`isMeta`, `turnCompanion: true`, "Your response above was cut
    off mid-stream…")과 턴 출처를 이어 받은 압축 요약(`isCompactSummary`)은 전처럼 빼서 같은 턴에 둔다.
  - 붙은 작업에서 CLI가 자기 대기열의 명령(예약 프롬프트, 백그라운드 알림, 다른 세션의 메시지)으로 턴을 시작하면 stream-json에는
    `command_lifecycle`(`started`, `command_uuid` = 저장 항목 uuid) → `system/init` → 답 → `result` → `completed`만 오고 `user`
    프레임은 없다(`--replay-user-messages`로도 예약 프롬프트는 재생되지 않는다). 기록은 100 ms마다 써서 `started` 때는 아직 없다.
    Yardlet이 보내지 않은 uuid의 `started`가 실행 중인 턴이 없을 때 오면 어댑터가 `providerStartedTurn(messageID:)`를 내고, 앱이 그
    자리에 요청 없는 턴(`origin = .provider`)을 연 뒤 파일 끝 1 MiB에서 그 uuid의 줄을 찾아(0.15 s부터 약 10 s까지 다시 봄) 위 규칙과
    같은 투영으로 채운다(`ClaudeSubagentTranscriptReader.request(savedUnder:sessionID:)`, `TranscriptBuilder.settleRequest`).
    읽기만 하고 아무것도 쓰거나 보내지 않는다. 끝내 못 찾으면 턴은 요청 없이 남는다.
  - 압축: 대화를 보이는 읽기(`readNewest`, `readEarlier`, `readConversation`)는 압축 경계에서 멈추지 않고
    `logicalParentUuid`로 그 앞 기록을 잇는다. 경계는 압축 표시(`.compaction`, `compactMetadata`의 토큰 수)로, 요약
    (`isCompactSummary`, `isVisibleInTranscriptOnly`)은 숨긴다. 편집·포크 지점(`readSession`, `conversationPoints`)은 전처럼
    압축에서 멈춘다.
  - 붙은 작업은 첫 턴부터 뒤(런타임이 스트리밍한 것 포함)를 그대로 두고, 읽은 턴을 경계 항목 앞에 넣는다
    (`TranscriptBuilder.replaceEntries(before:)`). 대화에서는 `ConversationEarlierTurns.providerFile`이며, 시작까지 읽으면
    표시가 사라진다.
  - 저장된 읽기 위치가 직전에 보이던 항목인데 최신 부분 밖이면, 그 항목이 들어올 때까지 더 뒤로 읽는다(8 MiB까지,
    `placeBytes`).
  - 따라가기·다시 열기(`refreshConversation`)는 최신 1 MiB만 다시 읽어, 그 첫 턴의 요청이 보이는 항목에 있으면 그 자리부터
    바꾼다(앞서 불러온 턴과 창은 그대로). 요청에서 만나지 못하면 8 MiB까지 더 읽고, 그래도 못 만나면 최신 부분부터 다시
    시작한다.
  - 한도: 본 대화 읽기는 20,000줄로 거절하지 않는다(한 번에 읽는 바이트로 묶인다). 하위 대화 읽기는 전처럼 20,000줄.
    Claude 작업의 항목 한도는 읽은 항목 + 2,000이다(`TranscriptBuilder` 최대 200,000). 읽기 캐시(500 항목)는 그대로다.
  - 편집·포크·파일 복원(`readSession`, `conversationPoints`)과 하위 대화 읽기는 전처럼 8 MiB 한도다.

## 작업 리소스 사용량의 읽기 — 2026-10-13

작업 리소스 사용량은 다른 앱이 실행하는 Claude 대화를 Yardlet 작업에
귀속하려고 `sessions/<pid>.json`을 읽기만 한다. 위 "다른 앱이 잡고 있는 Claude 대화"와 같은 규칙이다: 작업의 계정이
쓰는 설정 폴더의 `sessions`(Session Switch 계정 폴더는 공유 폴더로의 링크 하나를 따라감)에 그 작업의 provider 세션 ID가
있어야 하고, Yardlet의 자식·손자 프로세스는 제외한다. 덧붙여 파일의 `startedAt`이 그 pid 프로세스의 시작 시각과 30초
넘게 다르면 다른 프로세스가 ID를 이어받은 낡은 파일로 보고 건너뛴다. `entrypoint`가 `claude-desktop`이면 "Claude 앱",
그 밖은 "다른 앱"으로 표시한다. 바뀐 파일만 다시 읽고(수정 시각·크기), 64 KiB 이상·형이 다른 파일은 건너뛴다. 아무것도
쓰거나 옮기지 않고, 작업의 provider ID·계정·범위·기록을 바꾸지 않는다.

## 작업을 다른 프로젝트로 옮기기 — 2026-10-14

저장 계약은 다음과 같다.

- **바뀌는 것은 색인 행의 두 열뿐이다:** `project_id`(옮긴 프로젝트, 채팅으로 되돌리면 NULL)와 `additional_roots`
  (`TaskProjectMove.additionalRoots`: 그 프로젝트의 루트 중 작업 폴더와, 워크트리면 그 원점 루트를 뺀 것. 채팅이면 빈 값).
  `SessionStore.moveSession`이 기존 upsert로 쓴다. 스키마 변경은 없다. `workspace_path`(cwd), provider 세션 ID, 저장 범위,
  계정 연결, 런타임, 제목, 상태, 고정, 읽지 않음, 최근 활동(`updated_at`), 워크트리 원점 열은 그대로다. 원본 기록·홈·인증,
  초안(작업 ID 키), 읽기 상태는 건드리지 않고, 디스크의 어떤 파일도 복사·이동하지 않으며 provider에 아무것도 쓰지 않는다
  (Codex `thread/metadata/update` 없음).
- **재실행이 되돌리지 않는다:** 작업의 프로젝트는 저장된 ID가 먼저다(`ProjectProjection.project(for:in:)`). 옮긴 작업은 ID로
  프로젝트에 속하므로 `ProjectStore.ensureProjects(forTasks:)`와 폴더 설정 변환이 그 폴더로 프로젝트를 만들지 않고, 채팅으로
  되돌린 작업은 채팅 폴더라 만들지 않는다. 다시 가져오기는 같은 provider ID의 기존 작업을 열 뿐 행을 고치지 않는다.
- **추가 루트가 하네스에 닿는 때:** 지금처럼 붙을 때(`thread/start`·`thread/resume`의 `runtimeWorkspaceRoots`, Claude 실행의
  `--add-dir`)다. 붙어 있는 작업은 실행 중인 턴과 세션을 그대로 두고, 다음에 시작하거나 다시 붙을 때(재실행, 연결이 끊긴 뒤
  재개) 새 루트를 넘긴다.
- **가져오기는 Codex 앱의 프로젝트를 쓸 수 없다(조사, 읽기 전용):** codex-cli 0.157.1 App Server의 `thread/list`·`thread/read`
  스레드에는 `projectId` 필드가 있지만, 대화형 스레드 67개 모두 `null`이었다(Codex 앱이 `13주`로 옮긴 스레드
  `01a034ad-…`도). `~/.codex/state_5.sqlite`에도 `projects`(27개)·`project_roots` 표는 있으나 `threads.project_id`는 모두
  NULL이다. Codex 앱 번들을 보면 앱은 옮긴 결과를 자기 전역 상태(`THREAD_PROJECT_ASSIGNMENTS`)에 두고, 서버 프로젝트 기능이
  켜졌을 때만 `thread/metadata/update {threadId, projectId}`로 App Server에 알린다. 그래서 가져오기 배치는 바꾸지 않았다. 그
  기능이 켜져 `projectId`가 오면 `project/read`(바이너리에 있는 메서드, 호출하지 않았다)로 루트를 읽어 배치에 쓸 수 있다.

## 풀 리퀘스트 링크 읽기 — 2026-10-15

작업의 풀 리퀘스트는 Claude Code 작업의 기록에서 Claude Code CLI가 쓰는
`{"type":"pr-link","sessionId","prNumber","prUrl","prRepository","timestamp"}` 기록만 읽는다. 대화 읽기와 같은 규칙이다: 작업에
저장된 provider ID로, 작업의 계정이 쓰는 설정 폴더의 `projects` 아래 그 ID의 파일 하나(링크 하나만 따라가고 그 아래 링크·FIFO
거절, `ClaudeSubagentTranscriptReader.pullRequestLinkScan`).

- 첫 읽기는 파일 끝에서 1 MiB씩 거꾸로, 최신 기록에서 멈추고 최대 8 MiB까지(`ClaudePullRequestLinkScanner`). Claude Code가
  기록을 계속 다시 써서, 이 Mac의 기록 124개 모두에서 최신 것이 끝에서 33 KiB 안에 있었다. 그다음은 같은 파일(장치·inode)이
  줄지 않았으면 덧붙은 바이트만, 끝의 쓰는 중인 줄은 다음에 읽는다. 바뀌거나 줄어든 파일은 다시 끝에서 읽는다.
- 2026-10-16부터 찾은 파일의 `projects` 아래 경로도 메모리에 두고, 다음 스캔은 그 파일이 같은 파일(장치·inode)이면 폴더를 다시
  훑지 않고 읽는다. 없어지거나 다른 파일이면 처음처럼 찾는다(같은 이름이 둘이면 거절).
- 기록의 번호·URL·저장소만 메모리에 둔다(작업별). 대화 글은 읽어 두지 않고, 아무것도 쓰거나 옮기지 않으며, 모델 턴·연결·
  인증 변경이 없다. 기록에 없으면 폴더의 브랜치로 `gh`에 묻는다(Git 파일만 읽음).

## 작업의 부모 링크 — 2026-10-15

2026-10-22 Codex 하위 대화 경계 보강: 기존 하위 작업 재사용과 provider가 보고한 부모 연결(가져오기·스레드 읽기 포함)은
하네스·provider ID뿐 아니라 저장된 `environmentScope`와 계정 바인딩 전체를 함께 비교한다. 기본 계정의 null 바인딩도
별도 계정과 구분하며, 같은 계정 ID라도 저장 홈이 다르면 재사용하지 않는다. 기존에 기록된 부모 링크를 소급해서 바꾸지는 않는다.
새 하위 작업은 부모의 `projectID`·`additionalRoots`를 보존한다. 이 값이 재개의 `runtimeWorkspaceRoots`, MCP 작업 폴더 범위와
프로젝트 지침(프로젝트에서 끈 경우 포함)에 사용된다. 하위 대화를 열기 전과 새 하위 작업 생성·재개 뒤에는 부모의 저장된 세션
식별자가 여전히 같은지 확인하고, 바뀌었다면 이번에 만든 하위 작업만 폐기한다. 다른 저장 범위의 기록·초안·읽기 위치는 유지한다.

사이드바 중첩은 작업이 시작된 작업을 색인 행 하나에만 적는다.

- **열:** `sessions.parent_task_id TEXT` nullable, 부모 작업의 Yardlet ID(하네스와 무관). 기존 행은 NULL(맨 위)이고, 열이 없는
  이전 빌드는 이 열을 읽지 않으며 그 빌드의 저장(`ON CONFLICT DO UPDATE`의 나열된 열만)도 값을 지우지 않는다. `inherited_context`
  JSON은 side chat·포크의 대화 문맥이라(값이 있으면 보내기·편집 경로가 달라진다) 쓰지 않았고, `provider_options`는 하네스 실행
  인자라 쓰지 않았다. provider 세션 ID·저장 범위·계정·작업 폴더·기록·초안·최근 활동은 그대로다.
- **쓰는 때:** 작업을 만들 때(포크·하위 에이전트·원본 열기·가져오기) 또는 `SessionStore.linkParents`가 비어 있는 링크만 채울 때.
  있는 링크는 덮어쓰지 않고, 자기 자신·고리를 만드는 링크는 버린다. 링크는 활동이 아니라 작업의 자리가 그대로다. 보관·보관 해제는
  링크를 그대로 둔다.
- **Claude 앱에서 읽는 것:** 가져오기 목록과 같은 `ClaudeDesktopSessionCatalog`(Claude 앱의 `local_*.json`, 읽기만, 크기·개수
  한도 그대로)에서 `sessionId`(앱의 `local_` ID), `spawnedFrom.sessionId`, `forkedFromSessionId`, `lineageDetached`만 더 읽는다.
  자식·부모의 `cliSessionId`가 둘 다 Yardlet 작업의 provider ID일 때만 잇는다. Claude Code CLI 기록에는 이 관계가 없다(CLI
  2.1.291은 `spawnedFrom`을 모른다). 가져오기 때마다(목록에서 잇고, Claude면 파일을 다시 읽어 먼저 들어온 자식도 잇는다)와 이
  빌드의 첫 실행 때 한 번(`Yardlet.taskLineage.claudeAppLinksRead`) 읽는다. Claude 작업이 없거나 모두 링크가 있으면 읽지 않는다.
- **Codex에서 읽는 것:** `thread/list`의 `forkedFromId`(가져오기 목록), 스레드를 읽을 때(`thread/read`·`thread/resume`·포크)의
  `forkedFromId`·`parentThreadId`. 새 요청은 없다.
- 아무것도 원본 기록·Claude 앱 파일·Codex 스레드에 쓰지 않고, 모델 턴·연결·인증 변경이 없다.
- **최상위로 분리(2026-10-16):** 행 메뉴 "최상위 레벨로 분리"는 `parent_task_id`를 비우고 새 열
  `sessions.lineage_detached INTEGER NOT NULL DEFAULT 0`을 1로 쓴다(`SessionRecord.isLineageDetached`, `SessionStore.detachFromParent`).
  1인 작업은 `linkParents`·`TaskLineage.links`가 다시 잇지 않는다(가져오기, Claude 앱 파일 읽기, Codex 스레드 읽기 모두). 기존 행은
  0이고, 이 열을 모르는 이전 빌드는 읽지 않으며 그 빌드의 저장도 값을 지우지 않는다. 그 이전 빌드가 다시 잇는 것은 막지 못한다
  (그 빌드는 표시를 모른다). 분리도 활동이 아니며, 보관·보관 해제는 표시를 그대로 둔다. Claude 앱에서 분리한 세션
  (`lineageDetached`)은 이전처럼 링크 없이 가져오지만, 이미 Yardlet에 링크가 있던 작업은 그대로다(링크는 덮어쓰지 않음).

## 작업 제안의 결과 — 2026-10-16

작업 제안 칩([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) "작업 제안 도구")은 제안 자체를 저장하지 않는다. 무엇을 제안했는지는 하네스 기록의
`spawn_task` 호출과 Yardlet의 답이고, Yardlet은 그 뒤에 일어난 것만 작업 곁에 둔다.

- **저장:** `UserDefaults` `Yardlet.taskSuggestions.<작업 ID>` = `{"version":1,"resolutions":{"task_1a2b3c4d":{"outcome":"started"|
  "dismissed"|"sentHere","at":…,"startedTaskID":…}}}`(`sentHere`는 "여기서 하기", 2026-10-22 — 그 전 앱은 이 값이 있는 작업의 결과를
  못 읽고 비운다), 작업마다 최근 100개(Claude 앱 `resolvedBackgroundTaskSuggestions`와 같은 한도). 색인
  스키마·`provider_options`·작업 화면 상태(`Yardlet.taskWorkspace.<id>`, 보관하면 지워짐)는 쓰지 않았다.
- **보관·삭제:** 보관·보관 해제는 그대로 두고, 작업을 삭제하면 함께 지운다.
- **초안:** 새 작업 초안(`~/.yardlet/drafts/drafts.json`의 `home`)에 선택 필드 `suggestion`(제안한 작업 ID, 제안 ID, 제목, 프롬프트,
  에이전트가 `parent_task_id`로 정한 부모 작업 ID `parentTaskID` — 2026-10-22, 없으면 제안한 작업).
  초안을 비우거나 그 초안으로 작업을 만들면 없어진다. 없는 예전 초안은 그대로 읽힌다. 2026-10-22부터 칩의 "옵션"은 초안을 열지 않아
  (팝오버) 이 필드를 새로 쓰는 길은 없고, 이미 저장된 초안의 것만 읽는다. 옵션에서 고른 값은 저장하지 않는다(앱이 켜져 있는 동안만).
- **만든 작업:** 부모 링크(`sessions.parent_task_id`)가 제안한 작업(에이전트가 `parent_task_id`를 주었으면 그 작업)이고, 프롬프트를 고치지 않았으면 제목이 제안 제목에 `title_origin`
  `manual`(하네스 제목이 덮지 않음). "시작"(2026-10-22부터 바로 시작)으로 만든 작업은 부모가 된 작업의 계정(`connection_binding`)과
  `provider_options`(모델·effort·권한, 다음 메시지 추천 제외)를 물려받고, provider 세션 ID·저장 범위는 다른 새 작업처럼 새로 받는다.
  "옵션"의 초안으로 만든 작업은 다른 새 작업과 같다.
- **여기서 하기:** 제안한 작업에 사람의 메시지 하나("이 작업을 여기에서 진행해 주세요: “제목”")를 입력창과 같은 길로 보낸다. 그 메시지는
  하네스 기록에 사람의 메시지로 남는다(Claude 앱도 같음).
- 하네스 기록·Claude 앱 파일에는 아무것도 쓰지 않는다. Claude 앱의 `backgroundTaskSuggestions`·`resolvedBackgroundTaskSuggestions`는
  읽지 않는다(키 이름·형식만 조사).

## Antigravity CLI 대화 — 2026-10-16

Antigravity CLI(`agy` 1.4.0)는 자기 대화를 `~/.gemini/antigravity-cli`에 둔다. Yardlet은 이것을 읽기만 하고(`AntigravityConversationStore`)
아무것도 쓰지 않는다.

- **색인 `conversation_summaries.db`:** `agy`의 `/resume` 목록. WAL 모드라 읽기 전용으로 열어도 `-wal`·`-shm`이 생길 수 있어,
  0700 임시 폴더에 사본(있으면 `-wal`도)을 만들어 읽고 바로 지운다(64 MiB 한도). 읽는 열: `conversation_id`, `title`, `preview`,
  `step_count`, `last_modified_time`, `workspace_uris`(파일 URI의 JSON 배열), `parent_conversation_id`, `nesting_depth`, `app_data_dir`.
- **가져오기 대상:** `app_data_dir`이 `antigravity-cli`(앱의 `antigravity` 행은 CLI가 `/resume` Other 탭에서 자기 저장소로
  복사해야 이어갈 수 있어 뺀다), `nesting_depth` 0(하위 에이전트 대화 제외), `step_count` > 0, 폴더가 알려진 것(행의
  `workspace_uris`, 없으면 `cache/last_conversations.json`의 폴더 → ID). 가져온 작업은 provider 세션 ID = `conversation_id`,
  `.native` 범위, 연결 없음(Antigravity는 키체인 로그인 하나), 분리 상태다. 제목은 CLI가 만든 `title`(없으면 `preview` 첫 줄),
  부모는 `parent_conversation_id`. 이미 가져온 대화는 기존 작업을 연다. CLI는 대화 첫 턴의 `--add-dir` 폴더도
  `workspace_uris`에 기록하고 이어갈 때 되살린다(2026-10-16 감사) — 그래서 Yardlet은 Antigravity에 자기 폴더를 넘기지 않는다
  (그 폴더를 넘기던 승인 훅 갈래는 설치 전에 되돌림). 대화의 폴더는 사용자의 작업 폴더뿐이다.
- **로그 `brain/<id>/.system_generated/logs/transcript_full.jsonl`(없으면 `transcript.jsonl`):** 분리된 작업을 열 때와 보이는
  동안 크기·시각이 바뀌면 끝 8 MiB를 읽는다. 기록 `{step_index, type, source, status, created_at, content?, thinking?,
  tool_calls?, error?, input_tokens?, …}`: `USER_INPUT`(요청은 `<USER_REQUEST>` 안, 뒤의 CLI 메타데이터는 버림),
  `PLANNER_RESPONSE`(생각·도구 호출 `{name, args}`·답), `GENERIC` ERROR(실패한 호출, 단계 번호 = 응답 단계 + 1 + 호출 순서),
  `SYSTEM_MESSAGE`(보이지 않음). 도구 출력은 로그에 없다.
- **캐시와의 관계:** Yardlet의 읽기 캐시(`~/.yardlet/transcripts/<작업>.json`, 실시간 출력 포함)는 로그의 요청 수가 더 많을
  때까지 둔다. 캐시가 비었거나(가져오기·보관 해제) 로그에 요청이 더 많으면 로그로 바꾸고, 그 뒤 바뀔 때마다 다시 읽는다.
  작업이 붙으면(턴을 보내면) 이 상태를 잊고 처음부터 다시 판단한다. 읽기 실패는 캐시와 ID를 그대로 둔다.
- **제목:** 작업 제목의 pull 경로(`ProviderSessionTitleResolver`)가 색인의 `title`을 읽는다. 첫 턴 전(로컬 자리표시 ID)은 읽지 않는다.
- **모델 목록:** 작업이 읽은 접힌 모델 목록을 `model-catalogs.json`의 `antigravity`(선택 필드, 이전 빌드는 무시)에 둔다 — 새 작업
  화면이 쓴다.
- 원본 대화·색인·로그·설정·자격 증명을 복사·이동·수정하지 않고, 읽기만으로는 모델 턴·연결·인증 변경이 없다.

## 컨텍스트 사용량의 마지막 값과 기록 읽기 — 2026-10-17

입력창 링·세션 레일 Context 카드가 재시작 뒤에도 보이도록, Yardlet은 작업이 마지막으로 보인 값을 색인 행 옆에
두고, 작업을 열 때 하네스 기록에서 다시 읽는다.

- **열:** `sessions.context_usage TEXT` nullable, `TaskContextUsageSnapshot` JSON `{"providerSessionID":…, "recordedAt":<초>,
  "provider":HarnessProtocolUsage?, "codex":CodexThreadTokenUsage?}`. 기존 행은 NULL이고, 열을 모르는 이전 빌드는 읽지 않으며 그 빌드의
  저장(`ON CONFLICT DO UPDATE`의 나열된 열만)도 값을 지우지 않는다. 이 빌드의 `upsert`도 쓰지 않는다 — `saveContextUsage`(`UPDATE … SET
  context_usage`)만 쓴다. 활동이 아니라 `updated_at`·순서·읽음 상태가 그대로다. 보관 중인 행은 읽지 않고, 보관 해제하면 다시 읽힌다.
  못 읽는 값은 없는 것으로 친다.
- **쓰는 때:** 하네스 보고(`usageUpdated`, Codex 스레드의 턴 사용량)와 기록 읽기로 보이는 값이 바뀔 때, 작업별로 순서대로. 같은 값은 쓰지
  않는다. `providerSessionID`는 그때 작업의 대화 ID이고, 복원 때 작업의 대화 ID가 다르면(새 채팅·포크·편집 갈래) 버린다.
- **Claude Code 기록:** 분리된 작업을 열 때·따라갈 때 이미 읽는 `projects/<폴더>/<세션>.jsonl`의 끝(1 MiB부터)에서 주 체인의 마지막 응답
  `message.usage`·`message.model`·`timestamp`만 더 쓴다. 창은 `model-catalogs.json`의 선택 필드 `claudeContextWindows`(모델 이름 →
  `get_context_usage`가 보고한 `rawMaxTokens`; 이전 빌드는 무시)에서 찾는다.
- **Codex 롤아웃:** 분리된 작업의 `thread/read`가 알려 준 `path`의 끝(1 MiB부터 8 MiB까지)에서 마지막 `event_msg` `token_count`의
  `info`만 읽는다. 롤아웃을 찾으려고 Codex 폴더를 뒤지지 않고, Codex의 SQLite·설정은 읽지 않는다.
- 원본 기록·롤아웃·CLI 설정·자격 증명을 복사·이동·수정하지 않고, 읽기만으로는 모델 턴·연결·resume·인증 변경이 없다.

## 세션 목록 따라가기 — 2026-10-22

사용자가 Claude 앱(Code 탭)·Codex 앱에서 Yardlet으로 옮기며 "세션 목록도 최신화하자 codex/claudecode 기준으로". 가져오기(위 2026-10-12 절)는
사람이 고른 것을 한 번 더할 뿐이라, 10-16 한꺼번에 가져온 뒤 목록이 어긋났다(10-22 읽기 전용 비교: Claude 앱에 열려 있고 Yardlet에 없는 세션 24,
Claude 앱에서 보관했는데 Yardlet 목록에 있는 작업 20, 최근 활동이 며칠 뒤처진 작업들; Codex는 시험 스레드만 없음). 이제 Codex 앱이 `~/.codex`의
스레드를 가져오기 없이 모두 보이듯, Yardlet이 두 출처를 읽기만 하며 따라간다(`SessionListFollow`, `AppModel.followSessionLists`). 컨트롤·메뉴·
단축키는 없고 가져오기 시트는 그대로다.

- **출처(읽기만):**
  - Claude: 가져오기와 같은 Claude 앱 세션 파일(`ClaudeDesktopSessionCatalog`, 파일당 4 MiB·2,000개 한도·링크 제외 그대로)을 가져오기 시트가
    기본으로 고르는 Claude 계정(새 작업 계정, 없으면 첫 계정, `ProviderConnectionStore.defaultImportChoice`)의 기록과 맞춰 읽는다. 열린 세션과
    보관된 세션 모두, `cliSessionId`의 기록이 그 계정의 `projects/<폴더 이름>/<id>.jsonl`에 있는 것만(`followedConversations`). 한 세션의 파일이
    조직·계정마다 있으면 하나라도 열려 있으면 열린 것으로, 가장 최근 활동의 열린 파일 하나로 센다. 따라갈 제목은 Claude 앱 자신의 `title`뿐이다
    (없으면 제목을 따라가지 않는다; 가져올 때 이름은 예전처럼 기록에서).
  - Codex: 가져오기 시트와 같은 기본 Codex 로그인의 App Server `thread/list`(같은 `sourceKinds`, 응답에서 exec·subAgent·부모 있음·ephemeral 제외,
    100개씩 20쪽 한도)를 `archived: false`와 `archived: true`로 한 번씩. YHP `yardlet.codex.history.interactive`의 매개변수에 선택 필드
    `archived`를 더했다(없으면 열린 것; 이전 피어와 호환). 두 목록에 다 있는 스레드는 열린 것으로 센다. 보관 목록을 못 읽으면 보관은 따라가지
    않는다. Codex 쪽을 못 읽으면(설치 안 됨·App Server 실패) 그 회차는 Claude만 따라간다. App Server를 띄우는 것은 가져오기 시트와 같고,
    모델 턴·인증 변경이 없다.
  - 마지막 활동: Claude는 앱의 `lastActivityAt`(없으면 기록 파일의 수정 시각, 가져오기와 같음). Codex는 스레드의 `recencyAt`(사람이 마지막으로
    그 스레드에서 일한 때, Codex 앱 목록의 순서; 0.163 App Server의 Thread 필드), 없으면 `updatedAt`. `updatedAt`은 설정만 바뀌어도 움직인다
    (실측: 10-21 턴 뒤 10-22에 `thread_settings_applied`만 써져 `updated_at`이 하루 뒤로). `CodexThreadSummary.recencyAt`·YHP 요약의 선택 필드
    `recencyAt`을 더했고, 가져오기 시트의 Codex 대화도 이 마지막 활동을 쓴다.
- **언제:** 색인을 복원한 뒤 한 번, 그리고 앱이 활성화될 때. 한 번에 하나, 시작 사이가 10분 이상일 때만(`SessionListFollow.Schedule`). 복원
  전의 활성화는 세지 않는다. 화면 고정 장면(visual fixture)에서는 하지 않는다.
- **새 대화:** 출처에서 열려 있고 Yardlet 색인에 행이 없는 대화는 가져오기 경로(`importConversations` — 분리 상태, 런타임 없음, 선택 안 함,
  `ConversationImportPlacement`·`ChatWorkspaces`로 채팅 폴더는 프로젝트 없음, Claude 앱 scratch 작업 공간 포함, 워크트리는 저장소 프로젝트,
  `linkImportedConversations`로 부모 링크)로 더한다. 계정은 Claude는 위 기본 계정, Codex는 기본 로그인. 하네스 런타임이 선택되지 않았으면
  더하지 않는다. 다음은 더하지 않는다:
  - 출처에서 보관된 대화.
  - 폴더가 임시 폴더 안: `NSTemporaryDirectory()`, `/private/var/folders`, `/var/folders`, `/tmp`, `/private/tmp`(링크를 풀어 비교).
  - 같은 하네스·provider 세션 ID(소문자 비교)의 행이 색인에 어떤 상태로든 있는 대화 — 목록·보관(1)·삭제·폐기(2), 어느 계정·저장 범위든
    (`SessionRepository.indexedProviderSessions`, SQLite는 `archived`와 무관하게 `provider_session_id`가 있는 모든 행), 그리고 지금 붙어 있는 작업의
    ID. 사람이 Yardlet에서 보관하거나 지운 대화는 돌아오지 않고, Yardlet이 만든 세션(하위 작업·자식 작업 등, Claude 앱에는 보이지 않음)이 나중에
    어느 출처 목록에 나타나도 두 번째 작업이 생기지 않는다. 기록을 공유하는 계정(Session Switch 계정 폴더)의 작업은 아래처럼 같은 작업으로 따라간다.
  - 같은 하네스·같은 폴더에 provider ID가 아직 없는 작업이 최근 10분 안에 만들어졌고 대화의 마지막 활동이 그 뒤(1분 여유)인 대화. Codex 기본 범위
    작업의 스레드는 `thread/start` 직후 목록에 보이지만 작업이 ID를 저장하는 것은 조금 뒤라, 다음 회차로 미룬다.
- **이미 있는 작업:** 출처의 대화와 같은 작업은 가져오기 시트의 `existingTask`(같은 하네스, `.native`, 같은 provider ID, 같은 계정 또는 Claude 기록을
  공유하는 계정)로 찾는다. 출처에서 열려 있으면:
  - 출처의 마지막 활동이 작업의 `updated_at`보다 뒤일 때만 그 값으로 앞당긴다(`SessionStore.moveLastActivity`, 뒤로는 옮기지 않음). 사이드바 순서만
    바뀐다.
  - `title_origin`이 `provider`이고 출처의 제목(정규화 뒤)이 다를 때만 제목을 바꾼다(`provider` 그대로, 최근 활동 아님). 사람이 지은 제목
    (`manual`)·Yardlet 대체 제목(`automatic`·`provisional`)·`legacy`는 그대로. Codex는 스레드 `name`만 따라간다(이름 없는 스레드의 첫 요청은 아님).
  - provider 세션 ID·저장 범위·계정 연결·프로젝트·추가 루트·초안·읽음 상태·고정·부모 링크는 바꾸지 않는다.
- **보관:** 출처가 보관했고 Yardlet 목록에 있는 작업은 Yardlet에서만 보관한다(`archived = 1`, `provider_archived = 0`). 다음이면 건너뛴다(다음
  회차에 다시 본다): 실행 중·승인 대기, 런타임이 붙어 있음, 셸 명령 실행 중, 비어 있지 않은 초안(글·첨부·편집·diff 댓글), 대기열 메시지, 보이고 있음
  (선택·분할 화면), 이동·계정 전환·보관 해제 중, 고정됨, Yardlet의 마지막 활동이 출처의 마지막 활동보다 뒤(사람이 Yardlet에서 이어 감), 사람이
  Yardlet에서 보관 해제함(아래). 조건은 계획 때와 보관 직전에 두 번 본다.
  - 보관이 지우는 것: 초안(`composerDrafts.remove`)·대기열(`followUps.discard`)·대화와 Codex 타임라인 캐시·대기 요청·검색 위치·스냅숏·컨텍스트
    사용량 메모리(위 2026-10-08 절). 초안과 대기열은 위 조건 때문에 비어 있을 때만 이 길에 오고(검사로 확인), 나머지는 원본에서 다시 읽는
    캐시다. 붙은 작업은 보관하지 않으므로 `thread/archive`를 보내는 길(`archiveTask`)을 타지 않고, Yardlet 워크트리 정리도 하지 않는다.
  - Yardlet이 보관 해제한 Claude·Codex 작업은 선호 설정 `Yardlet.sessionListFollow.keptListed`(작업 ID 목록)에 남아, 출처가 여전히 보관 중이어도
    다시 보관하지 않는다. 출처가 그 대화를 다시 열린 것으로 보이면 목록에서 빠지고, 그 뒤 출처의 보관은 다시 따른다. 목록에 없는 작업의 ID는 회차마다
    지운다.
  - 출처에서 열려 있어도 Yardlet에서 보관된 작업을 보관 해제하지 않는다(사람이 Yardlet에서 고른 것).
- **건드리지 않는 것:** Claude 앱 파일·Claude Code 기록·Codex 롤아웃·스레드에 쓰지 않는다(`thread/archive`·`thread/unarchive`·`thread/name/set`·
  `thread/resume`·`thread/read`·`turn/start` 없음, `thread/list`만). 모델 턴·런타임 붙이기·자격 증명 복사·계정 변경이 없다. 바뀌는 것은 Yardlet 색인
  행(새 행, `updated_at`, provider 제목, `archived`)과 가져오기가 만드는 프로젝트, 위 선호 설정 하나다.
- **실측(읽기 전용, 2026-10-22 14:51 사본):** 실제 Claude 앱 파일과 `~/.yardlet/session-index.sqlite3`의 임시 사본으로 계획만 세운
  `testLiveDryRunOverTheClaudeAppsSessions`: 출처 293(열림 69), 새로 가져올 것 24(채팅 1·프로젝트 23), 활동 앞당김 19, 제목 0, 보관 20(바쁨은
  모름으로 계산). Codex는 `~/.codex/state_5.sqlite` 사본을 같은 규칙으로 센 것: 새로 가져올 것 2(둘 다 `~/Desktop/workspace/yardlet-sandbox`의
  QA 스레드), 임시 폴더라 건너뜀 3, 활동 앞당김 4(`recency_at` 기준), 보관 0.

## 파일을 다룬 작업의 색인 — 2026-10-26

파일에서 그 파일을 다룬 작업은 각 작업이 읽고 고친 파일을 Yardlet의 폴더에 따로
둔다. provider 기록은 읽기만 하고, 하네스 설정과 기록, 세션 색인(`session-index.sqlite3`)의 형식은 바꾸지 않는다.

- **위치:** `~/.yardlet/file-activity/<작업 UUID>.json`, 작업마다 한 파일(`FileTouchRepository`). 형식은 `FileTouches` JSON이다:
  파일 경로마다 마지막 고침과 마지막 읽음(시각, 호출 ID), 결과를 아직 읽지 않은 호출(256개까지), Claude Code 기록을 어디까지 읽었는지
  (provider 세션 ID, 장치, inode, 다 읽은 줄의 끝 바이트, `projects` 아래 경로).
- **만드는 때:** 사람이 검토 화면이나 파일 패널에서 파일을 볼 때만 만든다. 그 파일의 저장소에서 일한, 보관하지 않은 작업만 읽는다.
  - Claude Code 작업은 대화 읽기와 같은 규칙으로(작업에 저장된 provider ID, 그 계정 설정 폴더의 `projects` 아래 그 ID의 파일 하나, 링크
    하나만 따라감) 기록을 처음 물을 때 처음부터 읽고, 그다음은 같은 파일(장치, inode)이 줄지 않았으면 덧붙은 바이트만 읽는다. 바뀌거나
    줄어든 파일, 다른 provider ID는 처음부터 다시 읽는다. 쓰는 중인 마지막 줄은 다음에 읽는다. `"type":"tool_use"`가 든 줄과 열린 호출의
    결과 줄만 파싱한다(`ClaudeFileTouchScanner`).
  - Codex와 다른 하네스 작업은 Yardlet이 그때 메모리에 든 대화(Codex 스레드의 파일 변경과 명령의 읽기, 다른 하네스의 파일 변경)를 더한다.
    Codex rollout은 읽지 않는다.
- **크기와 시간(실측, 2026-10-26):** 한 저장소의 작업 12개(가장 큰 기록 197 MB)를 처음 물을 때 4.9초(디버그 빌드), 그다음 3 ms, 색인 12개
  파일 108 KB. 작업 하나가 수 KB에서 수십 KB이며 파일 경로 수에 따라 는다.
- **지우는 법:** 폴더째 지워도 된다. 다음에 파일을 볼 때 Claude Code 작업의 것은 기록에서 다시 만들고, 다른 작업의 것은 그 뒤에 Yardlet이 읽는
  것부터 다시 모은다. 작업을 삭제하면 그 파일도 지우고(`FileTaskIndex.remove`), 보관하면 남긴다. 앱을 지우면 Yardlet 폴더와 함께 없어진다.
- **찾는 것:** 작업 트리와 원래 저장소의 같은 파일은 저장소 기본 폴더와 그 안의 상대 경로로 맞춘다(`FileRepositoryResolver`: 작업의
  `origin_workspace_path`, `.claude/worktrees/<이름>` 관례, `.git` 파일의 `commondir`). 디스크의 이름과 Git의 작은 파일 둘만 읽고 Git 명령은
  돌리지 않는다.
- **열 때:** 관련 작업을 누르면 그 작업의 대화를 위로 스크롤할 때와 같은 읽기(`readEarlierClaudeHistory`, `loadMoreCodexTurns`)로 그 호출이
  들 때까지 앞부분을 더 읽고(256번까지), 그 호출이 든 턴으로 간다. 아무것도 보내거나 붙이거나 재개하지 않는다.
