# 앱 검증 기록

최신 실물 결과(2026-10-11)는 [두 iPhone 시험 기록](physical-validation-20261011.md)에 있습니다. 아래 작업별 미검증 표기는 각 작업 당시의 범위입니다.

조각보 홈 앱에서 실행한 검증을 날짜별로 적는다. 2026-10-06까지의 Power Base 등록·삭제·재등록과 설정
코드 QR 입력의 첫 검증 기록은 펌웨어 저장소의 `docs/validation-status.md`에 있다(그 저장소가 규약의
기준 문서를 갖고 있기 때문이다). 이 파일은 앱만 바뀐 작업의 기록을 둔다.

- 무엇을 **실행했는지**와 무엇을 **실행하지 않았는지**를 나눠 적는다. 가짜 의존성으로 한 test, 실제
  이미지 디코딩, SDK 빌드, 실제 기기는 서로 다른 것이다.
- 설정 코드, QR의 내용, 토큰, 보드·허브 식별값은 적지 않는다. 아래의 EUI-64와 코드는 모두 공개된 가짜
  값이다.

## event stream의 실제 수신 (2026-10-11, `1.3.4 (17)`)

아래 절(`1.3.3 (16)`)의 작업이 찾고 독립 검토가 재현한 결함의 수정이다: 실제 연결에서 허브의 event가 한 번도 적용되지
않고, 그 `data:` 줄이 연결이 살아 있는 동안 parser에 쌓였다. **앱만 바꿨다.** 허브(Linux bridge 0.5.0)와 보드, 허브 API,
BLE 규약, 앱의 저장 형식, 화면과 문구는 그대로다.

**이 절의 어느 것도 실제 iPhone의 결과가 아니다.** 검사는 셋으로 나뉜다 — ① **합성 HTTP**: 실제 `URLSession`에
`URLProtocol`이 응답 본문을 조각내어 넘긴 것(소켓도 허브도 없다) ② **실제 로컬 HTTP**: 시뮬레이터의 앱 코드를 Mac에서
빌드한 허브의 서버 코드에 loopback으로 연결한 것(허브 쪽 프로그램이 보드와 다른 기기의 역할을 한다) ③ **시뮬레이터**의
XCTest. 앱 인스턴스 하나의 검사를 두 iPhone의 검사로 읽지 않는다.

### 무엇이 바뀌었나

- `URLSessionSensorAPITransport.openEventStream`이 `URLSession.AsyncBytes.lines`(빈 줄을 넘겨주지 않는다) 대신
  `SSELineSplitter`로 연결의 바이트를 줄로 나눈다(`Core/API/SensorAPITransport.swift`). 빈 줄을 포함해 모든 줄을 넘긴다.
  줄 끝은 LF·CR LF·CR. 줄은 CR에서 바로 넘기고 바로 뒤의 LF는 삼킨다. 바이트는 줄이 끝날 때 한 번에 해석한다.
- 한계(`SSEStreamLimits`): 한 줄 1 MiB, 한 event의 data 1 MiB. 넘는 줄은 통째로 버리고 그 바이트를 쌓지 않는다. 넘는
  event는 모은 것을 바로 놓고 발행하지 않는다(`SSELineParser`). 정상 event의 data는 발행할 때 놓는다.
- splitter와 parser는 연결마다 새로 만들어진다. 끝나지 않은 줄·event는 연결과 함께 버려진다.
- 5초 간격의 `GET`, heartbeat·watchdog, 재연결, 인증·TLS, `1.3.3`의 순서 판단은 그대로다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리. 시작 시 status 143줄(미추적 68), stage 0, index SHA-256 `e8dc6c3b…a3580`: 작업 지시가 적은 값과 같았다 |
| 버전 | `1.3.3 (16)` → **`1.3.4 (17)`** (PATCH: 결함 수정. 빌드 번호 17은 쓰인 적이 없었다). 네 번들 모두 같은 값 |
| 작업 전 식별 | `05375341f70d+dirty.3786889c5a58` |
| 작업 후 식별 | `05375341f70d+dirty.653f46116d4d` (지문 `653f46116d4db52113bc5141d58f3b387f7bc31918e759ebe5fc6f78e4ddf681`) |
| 허브 | 읽기만 했다. Linux bridge 0.5.0, `590e2a11d2cb+dirty.dbbfd0450300` 그대로 |
| 도구 | Xcode 27.0 (27A266a), iOS·macOS SDK 27.0, Swift 6.4. 시뮬레이터: "PogoHome iPhone 13 mini", iPhone 16 Pro Max, iPad Air 11-inch (M4) — iOS 27.0; Mac Catalyst |

### 검토가 남긴 재현

검토(`pogo-forget4-review-20261011/`)의 `repro_sse_transport.swift`는 이 저장소의 `SensorAPITransport.swift`와
`SSELineParser.swift`를 고치지 않고 컴파일해, 실제 `URLSession`에 `URLProtocol`이 넘기는 합성 응답을 읽힌다. 원본·실행기·
기존 로그는 고치지 않았다(SHA-256이 시작 때와 모든 실행 뒤에 같다). 종료 코드 1은 결함이 있다는 뜻이다.

세 입력: LF로 끝나는 event 2개, CR LF로 끝나는 event 2개, LF로 끝나는 event 1,000개.

| 실행 | 빌드 / 판정 | 발행된 event (기대 2 · 2 · 1,000) | parser에 남은 data 줄 | 기록 (`~/esp-builds/pogosse_20261011_results/repro/`) |
|---|---|---|---|---|
| 원본 그대로, 검토의 실행기, **수정 전** 트리 (`1.3.3 (16)`) | 0 / **1** | 0 · 0 · 0 | 2 · 2 · 1,000 | `sse_original_before_fix.stdout.txt` (검토 디렉터리의 `sse-run-ivdsm5op/`) |
| 원본 그대로, 검토의 실행기, **수정 후** 트리(최종, `1.3.4 (17)`) | 0 / **0** | 2 · 2 · 1,000 | 0 · 0 · 0 | `sse_original_after_fix.stdout.txt`, `final_repro.txt` (검토 디렉터리의 `sse-run-122epcf_/`) |
| 대조: 원본 그대로, **사본**에서 "시스템의 줄 읽기로 되돌림" | 0 / **1** | 0 · 0 · 0 | 2 · 2 · 1,000 | `sse_control_lines_sequence_again.txt` |
| 대조: 원본 그대로, **사본**에서 "빈 줄을 넘기지 않음" | 0 / **1** | 0 · 0 · 0 | 2 · 2 · 1,000 | `sse_control_empty_lines_left_out.txt` |
| 대조: 원본 그대로, **사본**에서 "발행할 때 data를 놓지 않음" | 0 / **1** | 2 · 2 · 1,000 | 2 · 2 · 1,000 | `sse_control_data_not_released.txt` |

- **원본이 수정 후에도 고치지 않고 빌드되고 통과한다.** adapter는 없다. 재현이 컴파일하는 두 제품 파일만으로 수정이 닫혀
  있고(줄 분리기는 `SensorAPITransport.swift` 안에 있다), 재현이 `Mirror`로 읽는 parser의 `dataLines`도 그 이름 그대로다.
- 대조 실행은 검토의 실행기로는 할 수 없다(트리 경로가 고정이다). 같은 빌드 명령과 같은 원본 소스를 **사본 트리**에
  연결하는 실행기를 따로 두었다(`run_sse_with_tree.py`: 트리 경로와 결과 디렉터리만 다르다). 미리 정한 기대 없이 돌렸고
  셋 모두 재현이 다시 실패한다.
- 검토의 실행기가 자기 디렉터리에 만든 실행 디렉터리: `sse-run-ivdsm5op`(수정 전), `sse-run-122epcf_`(수정 후). 그 밖의
  검토 파일은 시작 때와 같다(`review4_sources_sha256.*.txt`).

### 무엇을 어떻게 확인했나

기록은 `~/esp-builds/pogosse_20261011_results/logs/`. 종류를 나눠 적는다.

| 무엇 | 종류 | 결과 |
|---|---|---|
| `SSELineSplitterTests` (8), `SSELineParserBoundsTests` (5) | 단위 | 통과. 줄 끝 셋, 스트림을 자르는 **모든 한 곳**과 두 곳의 조합(CR LF·UTF-8이 조각 사이에서 잘리는 경우 포함), BOM, 끝나지 않은 줄, 한계를 넘는 줄(1만 바이트 동안 한계 넘게 쥐지 않음), 한계를 넘는 event(1,000줄 동안), 정확히 한계인 event, 발행 뒤 0 |
| `URLSessionEventStreamTests` (13) | **합성 HTTP** — 실제 `URLSession`에 `URLProtocol`이 본문을 조각내어 넘긴다. 생산 `URLSessionSensorAPITransport` → `SSELineSplitter` → `SSELineParser` | 통과. 줄 끝 셋 각각, **연결이 열려 있는 동안의 발행**(이 결함 자체), 열린 연결에 이어지는 event와 heartbeat, CR과 LF가 다른 조각, 마지막 바이트가 CR인 event, 글자 중간에서 자른 UTF-8, 한 조각의 여러 event와 1바이트씩 온 event, 여러 data 줄, 끝나지 않은 event의 EOF, event 1,000개(발행 1,000, 잔류 0), 1 MiB를 넘는 줄(버려지고 다음 event는 발행), 가장 큰 snapshot, event stream이 아닌 응답 거부 |
| `LiveSourceRealSessionEventTests` (4) | **합성 HTTP** 위의 실제 `LiveSensorDataSource`와 실제 `AppModel` | 통과. 연결 응답 뒤 event 둘이 차례로 도착(`GET`은 한 번뿐), 중간에 끝난 연결의 것이 다음 연결로 넘어가지 않음, 모델이 event만으로 화면을 바꿈, **event 뒤에 도착한 오래된 `GET` 응답이 화면을 되돌리지 않음** |
| `HubEventStreamLiveNetworkTests` (1) | **실제 로컬 HTTP** — 실제 `AppModel`·`LiveSensorDataSource`(주기 `GET` **끔**) ↔ Mac에서 빌드한 허브 0.5.0의 서버 코드 | 통과(약 30초). 연결 → 다른 Base가 들림(event) → 삭제 요청·수행·재등록이 그때그때 보임 → 설정 변경이 event로 옴 → **25초 동안 event 없이 연결 유지**(watchdog 한계 22초: heartbeat 줄이 닿지 않았다면 끊겼다) → 허브가 event보다 **먼저 만든** `GET` 응답을 그 event 뒤에 넣으면 순서 판단이 거부 → 서버 재시작 → 스스로 재연결, 새 stream의 event를 따라감 |
| `PowerBaseRemovalLiveNetworkTests` (3) | **실제 로컬 HTTP** ↔ 허브 0.5.0과 0.4.2의 서버 코드 | 통과 3, **알려진 실패 0**. `testTheEventStreamOfARealHubDeliversItsFirstSnapshot`의 알려진 실패 표시를 지웠고 통과한다. 0.4.2의 서버에서도 첫 event가 도착한다(순서 필드 없이) |
| 실제 로컬 HTTP 검사 넷 | iPhone 13 mini, iPhone 16 Pro Max 시뮬레이터에서 한 번씩 | 4 / 4, 4 / 4 (`final_live_mini.*`, `final_live_promax.*`) |

| 전체·경로 실행 (최종 트리 `…653f46116d4d`) | 통과 | 실패 | skip |
|---|---|---|---|
| 전체, 한국어, iPhone 13 mini 시뮬레이터 (iOS 27.0) | 1,329 | 0 | 27 |
| 전체, 한국어, iPhone 16 Pro Max 시뮬레이터 | 1,329 | 0 | 27 |
| 변경 경로의 class 14개, 한국어, iPad Air 11-inch (M4) 시뮬레이터 | 92 | 0 | 0 |
| 변경 경로의 class 14개, 한국어, Mac Catalyst | 92 | 0 | 0 |
| 변경 경로의 class 14개, 영어, iPhone 13 mini 시뮬레이터 | 92 | 0 | 0 |

- skip 27개는 환경 변수가 있어야 도는 렌더링 test와 실제 연결 test(위의 넷 포함)다. 실제 연결 test는 `tools/run_live.sh`로
  따로 돌렸다.
- iPad와 Mac Catalyst에서는 **전체를 돌리지 않았다**: 화면과 문구가 바뀌지 않았고, 변경 경로(event 읽기, 데이터 소스,
  watchdog, 순서 판단, 주기 갱신, 소스 전환)의 class만 돌렸다. 렌더링도 다시 만들지 않았다.
- **가장 큰 snapshot**: Base 16, 모듈 64, 삭제 작업 64를 채운 것이 41,862바이트(한계 1,048,576의 약 1/25). 실제
  `URLSession`으로 1,000바이트씩 잘라 보내 통째로 받는다.

| 변형 (`tools/mutate_sse.py`: 사본에서 규칙을 하나씩 뺌) | 결과 |
|---|---|
| 23개 (줄 분리기 15, parser의 한계 8) × event 경로의 class 8개(test 56개) | **23개 모두** 관련 test로 잡혔다 (`mutations_sse.txt`) |

- 변형 검사 뒤에 실제 연결 test 파일 하나에 확인 다섯 줄을 더했다(0.4.2 서버의 첫 event:
  `app_tree_since_mutation_pass.diff.txt`). 제품 파일 둘은 변형·대조 실행 때와 바이트까지 같다(`repro/final_repro.txt`).
- **실패했거나 다시 돌린 것**: 최종 트리의 실행에는 없다. 개발 중에는 새 test 자체의 결함으로 셋이 실패했다
  (`dev4_sse_mini_ko`: 닫힌 연결을 열린 것으로 센 대역의 경쟁, 조각 수를 잘못 센 단언, 말 없이 목록에서 빠진 Base를
  기다린 것 — 앱이 그런 Base를 계속 보여 주는 것은 기존 동작이다). 고친 뒤 두 번 연속 42개 통과(`dev6`, `dev7`). 첫
  빌드는 Watch 앱 타깃에서 실패했다(`dev1_build_for_testing.log`: 전송 파일이 그 타깃에도 들어 있다): 줄 분리기를 그
  파일로 옮겼다. 원인을 확정하지 못한 실패는 없다.

### 후보

`~/esp-builds/pogosse_20261011_app_device_release_signed/artifact/PogoHome.app` (Release, development 서명,
`generic/platform=iOS`). manifest SHA-256 `45491e8b66398195598d78e7db1bc12c237a162ba48f085e369726bd58843442`.

- 빌드 입력 383개의 해시가 빌드 전·후에 같다. manifest가 지금의 트리와 맞는다(`--match-current-tree`,
  `--expect-version 1.3.4`). 실제 번들과 내장된 세 번들이 `1.3.4 (17)`과 같은 build id를 말한다. Release 번들에 디버그 등록
  화면이 없다. `codesign --verify --deep --strict`와 번들 넷 각각의 확인이 통과한다.
- **프로파일은 이전 후보의 것과 같다. 유효 기간이 늘지 않았다.** 가장 이른 만료는 `2026-10-12T02:22:14Z`(한국 시간
  10월 12일 11:22:14). 프로파일의 기기는 iPhone 쪽 2대, Watch 쪽 1대이고, 그것이 iPhone 13 mini와 iPhone 16 Pro Max인지는
  **확인하지 못했다**(기기에 접근하지 않았다).

### 하지 않은 것, 남은 것

- **실제 iPhone, 실제 Wi-Fi, 실제 허브(Linux), 백그라운드 전환, 오래 켜 둔 연결의 메모리**: 하지 않았다(금지된 범위).
  최소 실물 시험 순서는 `~/esp-builds/pogo_sse_hwtest_20261011/public/docs/HWTEST_SSE.md`.
- event마다 snapshot 전체를 해석해 적용하는 부담을 실제 기기에서 재지 않았다.
- 줄이 transport에서 화면 쪽으로 넘어가는 대기열(`AsyncThrowingStream`)은 이전부터 길이 제한이 없다. 바꾸지 않았다.
- 1 MiB를 넘는 snapshot을 event로 보내는 허브가 생기면 그 event는 버려지고 화면은 5초 `GET`으로만 따라간다.
- 순서 필드가 없는 허브(0.4.2 이하)에서는, event가 적용되기 시작한 지금 "event 뒤의 오래된 `GET`"을 막을 근거가 없다.
- 서명 없는 빌드 넷(Debug·Release × 시뮬레이터·Mac Catalyst)을 따로 만들지 않았다: Debug는 시뮬레이터와 Mac Catalyst의
  test 실행이, Release는 서명된 기기용 빌드(네 번들)가 컴파일했다.

## 삭제 요청의 등록 결속과 snapshot 순서 (2026-10-11, `1.3.3 (16)`)

아래 절(`1.3.2 (15)`)을 다시 독립 검토한 결과 나온 둘의 수정이다. 허브 쪽 설계와 기록은 펌웨어 저장소의
`docs/power-base-management.md` 16절, `docs/validation-status.md` "삭제 요청의 등록 결속과 snapshot 순서 (2026-10-11)".

**이 절의 어느 것도 실제 iPhone의 결과가 아니다.** 시뮬레이터(iPhone 13 mini, iPhone 16 Pro Max, iPad)와 Mac Catalyst에서
돌린 XCTest와 화면 렌더링이다. 두 번째 기기는 두 번째 `AppModel`이다. "실제 HTTP"는 시뮬레이터의 앱 코드가 Mac에서
빌드한 허브 서버 코드에 loopback으로 보낸 요청이고, 그 허브 쪽 프로그램이 보드 역할도 한다(무선·보드·Linux 없음).

### 무엇이 바뀌었나

1. **삭제 요청이 확인한 등록을 가리킨다.** 확인창이 열릴 때 그 Base의 `record`와 `removal_serial`을 잡아 두고
   (`PowerBaseRemovalConfirmation`), 확인 버튼은 그 값과 그 확인의 `request_id`로 요청한다
   (`PowerBaseRemovalBinding`, `URLSessionPowerBaseRemovalTransport.request`). 응답을 받지 못한 요청은
   `.resultUnknown`으로 남고 "다시 요청"이 **같은 요청**을 다시 보낸다. 응답 없는 요청은 snapshot으로 정리된다
   (`PowerBaseRemovalController.settleRequests`): 자기 `request_id`의 작업이 응답이고, 그 Base가 다른 등록으로 목록에
   있으면 요청은 버려지며, 그 뒤에 도착한 응답은 적용되지 않는다.
2. **오래된 snapshot을 적용하지 않는다.** 허브가 snapshot 끝에 싣는 `snapshot_stream`·`snapshot_sequence`와, 앱이
   요청마다 붙이는 시작 순서(`SnapshotRequestClock`)로, `AppModel.applyIncoming`의 맨 앞에서 판단한다
   (`HubSnapshotOrdering`). 시각은 쓰지 않는다. `PowerBaseReleaseEvidence`(판정 함수)는 바꾸지 않았다.
3. **이전 허브(Linux bridge 0.4.2 이하)에는 삭제를 요청하지 않는다.** Base 항목에 `record`와 `removal_serial`이 둘 다
   있을 때만 삭제를 내놓고, 아니면 "지원하지 않음: 연결된 허브가 Power Base 삭제를 지원하지 않습니다. 허브를 업데이트해야
   합니다."를 보여 준다. 목록 제거·작업 표시·등록·설정은 이전과 같다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리. 시작 시 status 138줄(미추적 64), stage 0, index SHA-256 `e8dc6c3b…a3580`: 작업 지시가 적은 값과 같았다 |
| 버전 | `1.3.2 (15)` → **`1.3.3 (16)`** (PATCH: 결함 수정. 빌드 번호 16은 쓰인 적이 없었다). 네 번들(iPhone 앱, iPhone 위젯, Watch 앱, Watch 위젯) 모두 같은 값 |
| 작업 전 식별 | `05375341f70d+dirty.e996a7cfd8f6` |
| 작업 후 식별 | `05375341f70d+dirty.3786889c5a58` (지문 `3786889c5a587ff960314ccca6524a3c9181244d54ab48a21d474a62ca819576`) |
| 도구 | Xcode 27.0 (27A266a), iOS·macOS SDK 27.0, Swift 6.4. 시뮬레이터: "PogoHome iPhone 13 mini", iPhone 16 Pro Max, iPad Air 11-inch (M4) — iOS 27.0; Mac Catalyst |

### 검토가 남긴 재현

세 번째 검토(`pogo-forget3-review-20261011/`)의 순서 재현(`repro_departure_order.swift`)은 이 저장소의 소스 14개와 함께
컴파일되는 Mac 프로그램이다. 원본과 실행 도구는 고치지 않았다(SHA-256이 시작 때와 모든 실행 뒤에 같다). 종료 코드 1은
결함이 있다는 뜻이다.

| 실행 | 빌드 / 판정 | 출력 | 기록 (`~/esp-builds/pogoforget4_20261011_results/`) |
|---|---|---|---|
| 원본 그대로, **수정 전** 트리 | 0 / **1** | `old GET after new registration SSE: new registration marked removed=true` | `repro/expanded_original_before_fix/departure/` |
| 원본 그대로, 수정 후 트리(최종) | 0 / **1** | 같은 줄. **그대로 실패한다** | `repro/expanded_original_after_fix/departure/` |
| adapter, 수정 후 트리(최종) | 0 / **0** | `old GET after new registration SSE: left out (older than one already applied); new registration marked removed=false` | `repro/adapters_after_fix/departure/` |
| 대조: adapter, **사본**에서 "같은 실행의 더 작은 번호도 적용" | 0 / **1** | `… marked removed=true` | `repro/control_app_older_number.txt` |
| 대조: adapter, **사본**에서 "허브의 순서를 읽지 않음" | 0 / **1** | `… marked removed=true` | `repro/control_app_order_not_read.txt` |

- **원본이 수정 후에도 판정 1인 것은 숨길 일이 아니라 설계의 결과다.** 원본은 판정 함수(`PowerBaseReleaseEvidence`)를
  직접 부른다. 수정은 그 앞의 수신 단계(`AppModel.applyIncoming`의 맨 앞)에 있고, 판정 함수는 바꾸지 않았다(받은 것을
  순서대로 판단할 뿐, 무엇이 오래된 것인지 스스로 기억하지 않는다). 그래서 이 원본은 "통과"로 세지 않고, 같은 순서를
  수신 단계에 연결한 adapter(`repro/adapter_departure/…_adapter.swift`, 원본과의 diff 54줄: 검토의 snapshot에 허브의
  순서 필드를 붙이고 실제 `HubSnapshotOrdering`을 지난 것만 판정 함수에 넣는다)와, 아래의 실제 수신 경로 XCTest로
  확인했다.
- 삭제 재현(`repro_removal_retry_new_registration.cpp`)은 허브의 코드에 대한 것이다: 펌웨어 저장소의 기록.

### 무엇을 어떻게 확인했나

실제 HTTP인 것, 생산 경로이되 전송만 대역인 것, 단위 검사를 나눠 적는다. 기록은 `~/esp-builds/pogoforget4_20261011_results/logs/`.

| 무엇 | 종류 | 결과 |
|---|---|---|
| `PowerBaseRemovalLiveNetworkTests` (환경 변수가 있을 때만 돈다) | **실제 HTTP**: 시뮬레이터의 실제 `URLSessionHubSettingsTransport`(페어링, TLS, 인증서 고정)·`LiveSensorDataSource`(`GET /api/v1/snapshot`)·`URLSessionPowerBaseRemovalTransport`를, Mac에서 빌드한 **허브의 실제 서버 코드**(0.5.0, 그리고 0.4.2)에 loopback으로 연결. 허브 쪽 프로그램이 보드 역할(삭제 수행, 재등록, poll)을 한다 | 통과 2, **알려진 실패 1** (`final2_live_mini.*`) |
| ↳ `testTheRemovalRequestAndTheSnapshotOrderAgainstARealHub` | 이 앱의 요청을 허브가 받는다 → 같은 요청 재전송은 같은 작업 → 보드가 삭제 수행 → 재등록 → **과거 요청 재전송**(그 요청의 작업이 답이거나 `stale_record`) → 새 id의 과거 등록 요청은 `stale_record` → 새 등록의 작업 없음, 보드 poll에 명령 없음 → 새 확인은 수행됨 → 취소 → 취소한 요청 재전송은 취소된 작업, 옛 serial은 `stale_record` → 지금의 serial로 확인하면 새 작업, 보드가 명령을 받음. 이전 형식의 본문은 `422`. 두 `GET`의 순서 필드와 요청 순서 | 통과 |
| ↳ `testAnEarlierHubIsReadAsOneThatCannotBeAskedToRemove` | 0.4.2의 실제 서버: Base는 `supported`이고 등록은 있으나 `removal_serial`이 없다 → 삭제를 내놓지 않는다(`.hubUnsupported`), 순서 필드 없음 → 도착 순서대로 | 통과 |
| ↳ `testTheEventStreamOfARealHubDeliversItsFirstSnapshot` | 실제 연결의 event stream | **알려진 실패**: event의 snapshot이 오지 않는다(아래 "하지 않은 것, 남은 것") |
| 같은 test, 허브 **사본**에서 등록 비교와 요청 인식을 뺌 | 실제 HTTP, 대조 | **실패**(기대한 방향): 과거 요청의 답이 새 작업이고 새로 등록된 보드가 `unenroll`을 받는다 (`final_live_control_mini.*`) |
| `AppModelRemovalBindingTests`, `AppModelSnapshotOrderTests`, `LiveSourceRequestOrdinalTests` | **생산 경로**: 실제 `LiveSensorDataSource` → `PogoSnapshotMapper` → `AppModel` → `PowerBaseRemovalController` → 관리 화면의 판단. 전송(줄과 응답)만 대역이다. 허브의 말은 허브가 쓰는 JSON 그대로 | 아래 합계에 포함 |
| `PowerBaseRemovalBindingWireTests`·`…PresentationTests`·`…ControllerTests`, `HubSnapshotOrderingTests`, `SnapshotOrderWireTests` | 단위 | 〃 |

`AppModelRemovalBindingTests`: 응답 유실 → 다른 기기의 삭제와 재등록 → 과거 요청이 남기는 것 없음, 새 등록을 알기 전의 "다시 요청"은
과거 요청을 그대로 보냄, 삭제·재등록 동안 열려 있던 확인창은 열릴 때의 등록을 요청, 재등록 뒤에 도착한 응답은 새 등록을
바꾸지 않음, 두 기기의 요청, 이전 허브. `AppModelSnapshotOrderTests`: 새 등록의 event 뒤의 오래된 `GET`, 검토의 snapshot들을
검토의 순서로, 삭제 완료 snapshot 뒤의 옛 목록, 같은 허브의 재연결, 허브 재시작과 그 전 실행의 늦은 응답, 다른 허브, 설정만
바뀐 snapshot, 순서를 말하지 않는 허브, 삭제를 통째로 놓친 기기의 옛 센서, 삭제·등록·센서 갱신이 막히지 않음.

| 전체 실행 (한국어) | 통과 | 실패 | skip |
|---|---|---|---|
| iPhone 13 mini 시뮬레이터 (iOS 27.0) | 1,299 | 0 | 26 |
| iPhone 16 Pro Max 시뮬레이터 | 1,299 | 0 | 26 |
| iPad Air 11-inch (M4) 시뮬레이터 | 1,299 | 0 | 26 |
| Mac Catalyst | 1,290 | **1** | 34 |
| Mac Catalyst, 다시 한 번 | 1,291 | 0 | 34 |

- skip 26개: 환경 변수가 있어야 도는 렌더링 test와 실제 연결 test 5개(이 절의 셋 포함), 그 밖의 조건부 test.
- **Mac의 실패 하나**는 `PowerBaseEnrollmentBLELifecycleTests.testTheWaitForThePermitHasNoTimeLimitAndTheConnectHasItsOwn`
  ("condition not met within 3.0 seconds")이다. BLE 등록 연결의 수명 주기 test이고, 그 파일과 대역 파일은 `1.3.2`의 것과
  바이트까지 같다(이번에 손대지 않은 코드와 test). **관찰**: 그 class만 Mac에서 세 번 다시 돌리자 두 번은 같은 class의
  다른 test 하나(`testACancelledOpeningDoesNotConnectEvenIfItsPermitAnswersFirst`)가 같은 문장으로 실패했고 한 번은 25개
  모두 통과했다. 전체를 다시 돌린 실행은 실패 0. 그 시간에 이 Mac에서는 이 작업과 무관한 프로세스들(Docker, Google
  Drive, fseventsd, 렌더링 직후의 mediaanalysisd)이 CPU를 쓰고 있었다(1분 load average 9~12, 그 뒤 200 이상). 앞선 세
  작업의 Mac 전체 실행에서는 그 test가 1.6초에 통과했다. **판단(확정하지 못했다)**: 400 ms 제한을 쓰는 test가 호스트
  부하에서 준비 단계를 넘기지 못한 것. 원인을 재실행 통과로 확정한 것이 아니다. 첫 로그는 `full_mac_ko.*`,
  `dev11_mac_ble_lifecycle_1..3.*`에 그대로 있다.

| 그 밖의 실행 | 결과 |
|---|---|
| 관련 class 34개, 영어·스페인어 × iPhone 13 mini·16 Pro Max·iPad | 여섯 실행 모두 305 통과, 0 실패, 1 skip |
| 이번 변경과 앞선 세 변경의 class, 세 번 더 × 두 iPhone | 여섯 실행 모두 142 통과, 0 실패 |
| 변형(`tools/mutate_app.py`: 사본에서 규칙을 하나씩 뺌, 96개) | **96개 모두** 관련 test로 잡혔다(매번 210개 test). 이 실행 뒤에 test 파일 하나의 문구 비교 셋을 언어와 무관하게 고쳤다(아래) |
| 화면 렌더링: ko/en/es × mini·Pro Max·iPad, Mac(ko) | 열 실행 모두 test 8개 통과. 변경된 화면 13장을 직접 열어 봤다(`render_viewed.txt`): 두 iPhone 크기, 가장 큰 글자, en/es에서 잘림·겹침·미번역 없음 |

**실패했거나 다시 돌린 것 (첫 로그는 지우지 않았다)**

- 첫 전체 묶음 실행(`logs/batch1_stopped/`)에서 영어·스페인어의 관련 class가 각 3개 실패했다(두 iPhone 모두). 새 test
  셋이 문구를 실행 언어와 무관하게 한국어 원문과 비교했기 때문이다(화면의 문구는 옳았다). 그 비교를 한국어 실행에서만
  하도록 고치고(`PowerBaseRemovalBindingTests.swift`, 25줄: `logs/app_tree_since_mutation_pass.diff.txt`) 묶음을 처음부터
  다시 돌렸다. 위 표는 다시 돌린 결과다. 변형 실행과 검토의 재현은 그 수정 전의 트리(`…5b03cbdabdbb`)에서 한 것이고,
  두 트리의 차이는 그 test 파일 하나다. 순서 재현의 adapter와 실제 HTTP test는 최종 트리에서 다시 돌렸다(결과 같음).
- 같은 첫 실행의 iPad 전체에서 `PowerBaseRemovalRealSceneTests` 셋이 실패했다(1,295 통과, 4 실패). 그 iPad 시뮬레이터의
  SpringBoard와 backboardd가 죽은 기록이 있다. 같은 class는 그 실행의 두 iPhone에서는 통과했고, 다시 돌린 묶음의
  iPad에서는 통과했다. 그 시간에 이 Mac에서 다른 앱을 접근성으로 조작하고 있었다(사용자의 요청). 그것이 원인인지는
  확정하지 못했다(`logs/batch1_stopped/ipad_realscene_failure_notes.txt`).
- 시뮬레이터 clone이 부팅에 실패한 실행 둘: 개발 중의 전체 실행 하나(`dev9_full_mini_ko`, 허브 변형 검사와 겹쳐
  돌렸다)와 렌더링 하나(`render_mini_ko.first_run_clone_boot_error.*`). test case의 실패는 없었고, 렌더링은 다시 돌려
  8개 통과·231장.
- 개발 중: 고정 자료에 허브의 등록·serial을 넣기 전의 첫 전체 실행에서 40개 실패(`dev1_full_mini_ko`), 그리고 화면
  class의 test 하나가 방금 부팅한 clone의 첫 test로 한 번 실패(`dev7_related_mini_ko`, 12.98초. 따로 세 번은 3.5~4.0초에
  통과: 원인은 확정하지 못했다).

### 후보

`~/esp-builds/pogoforget4_20261011_app_device_release_signed/artifact/PogoHome.app` (Release, development 서명,
`generic/platform=iOS`). manifest SHA-256 `c467dfb56cb4224437a46f0ef8e2262859bd65378a665f5dde0f998eeb0903ad`.

- 빌드 입력 381개의 해시가 빌드 전·후에 같다. manifest가 지금의 트리와 맞는다(`--match-current-tree`,
  `--expect-version 1.3.3`). 실제 번들과 내장된 세 번들이 `1.3.3 (16)`과 같은 build id를 말한다. Release 번들에 디버그
  등록 화면이 없다. `codesign --verify --deep --strict`와 번들 넷 각각의 확인이 통과한다.
- 서명 없는 빌드 넷(Debug·Release × 시뮬레이터·Mac Catalyst)이 빌드되고 번들 버전이 맞는다.
- **프로파일은 이전 후보의 것과 같다. 유효 기간이 늘지 않았다.** 가장 이른 만료는 `2026-10-12T02:22:14Z`(한국 시간
  10월 12일 11:22:14)다. 프로파일의 기기는 iPhone 쪽 2대, Watch 쪽 1대이고, 그것이 iPhone 13 mini와 iPhone 16 Pro Max인지는
  **확인하지 못했다**(기기에 접근하지 않았다).

### 하지 않은 것, 남은 것

- 실제 iPhone 설치·실행, 두 대 동시 사용, BLE: 하지 않았다(금지된 범위). 순서와 양식은
  `~/esp-builds/pogo_forget4_hwtest_20261011/public/docs/`.
- 확인창의 버튼을 누르는 동작 자체는 XCTest가 아니다: 확인창이 잡아 둔 값과 그 값으로 나가는 요청을 test했고 화면은
  렌더링으로 봤다.
- 응답 없는 요청은 메모리에만 있다. 앱을 다시 실행하면 "다시 요청"은 없다(과거 요청이 다시 나갈 길도 없다).
- **(2026-10-11에 덧붙임: `1.3.4 (17)`에서 고쳤다 — 위 절.) (이 작업에서 찾은, 이전부터 있던 결함. 고치지 않았다.) 실제 연결에서 event stream의 snapshot은 적용되지 않는다.**
  `URLSession.AsyncBytes.lines`가 event를 끝내는 빈 줄을 넘겨주지 않고 `SSELineParser`는 빈 줄에서만 event를 낸다. 앱은
  연결할 때의 `GET`과 5초 간격의 `GET`으로만 허브를 따라간다. 아래 event 경로의 test는 빈 줄을 넘겨주는 대역
  transport를 쓴 것이고, 실제 HTTP로 확인한 것은 `GET` 응답과 삭제 요청이다. 증거: macOS에서 실제 `URLSession`으로 읽은
  줄들(`live/sse_probe/result.txt`: `event: snapshot`, `data: …`, 15.1초 뒤 `: heartbeat` — 빈 줄 없음)과
  `PowerBaseRemovalLiveNetworkTests.testTheEventStreamOfARealHubDeliversItsFirstSnapshot`(알려진 실패로 표시). 실제
  iPhone에서는 확인하지 않았다. 범위 밖이고, 고치면 모든 기기에서 event마다 snapshot을 적용하는 일이 처음 시작되므로
  따로 검토할 변경으로 남겼다(`CHANGELOG.md` "검증 한계").
- 순서 필드가 없는 허브(0.4.2 이하)에 연결되면 오래된 응답이 화면을 잠깐 되돌리는 문제가 남는다.
- 허브가 다시 시작한 직후 실제로는 더 새로운 snapshot 하나를 버릴 수 있다(다음 요청에서 따라간다).

## 목록 제거 후속 수정 2 (2026-10-10, `1.3.2 (15)`)

`1.3.1`을 다시 독립 검토해 남은 결함의 수정이다: 다른 기기가 Power Base를 **삭제**하는 동안 10분 넘게 백그라운드에
있던 앱이 돌아와서 옛 센서를 "복구 중"으로 계속 보여 주는 것(`1.3.1`의 "하지 않은 것" 마지막 줄). 펌웨어 저장소
`docs/power-base-management.md` 15절, Linux bridge 0.4.2와 한 묶음이다. 화면과 문구는 `1.3.1 (14)`와 같고, `1.3.1 (14)`
이하의 기능이 모두 들어 있다. 허브 쪽 기록은 펌웨어 저장소 `docs/validation-status.md` "목록 제거 후속 수정 2
(2026-10-10)"에 있다(그 절에는 같은 검토가 재현한 방 지정 정리의 결함도 있다: 허브만의 수정이다).

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 허브·보드·iPhone에 접근하지 않았다.
"16분 뒤에 돌아온 기기"는 허브가 그때 쓰는 JSON을 넣은 것이고 **실제로 기다린 것이 아니다.** 시뮬레이터에서의 통과는
실제 기기에서의 통과가 아니다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.3.1 (14)`, 소스 지문 `be61e431024bda054e65f476b08c33df0ecc1f121a9c04804044b8fc8a53f218`. status 137줄(미추적 63), stage 0, index SHA-256 `e8dc6c3b…a3580`: 작업 지시가 적은 값과 같았다. `1.3.1` 작업이 끝났을 때와 달라진 파일은 Xcode의 화면 상태 파일과 `.DS_Store` 둘뿐이었다 |
| 작업 후 | `1.3.2 (15)`, 소스 지문 `e996a7cfd8f646a05fb7607e574fd3c5c5d9cdaf7a12c9cd1b4d648887082f1b`, 빌드 식별자 `05375341f70d+dirty.e996a7cfd8f6` |
| 도구 | Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임, macOS 26.6.2 |
| 시뮬레이터 | "PogoHome iPhone 13 mini"(iPhone 13 mini, iOS 27.0), "iPhone 16 Pro Max"(iOS 27.0), "iPad Air 11-inch (M4)"(iPadOS 27.0), Mac Catalyst(이 Mac) |
| 출력 | `~/esp-builds/pogoforget3_20261010_results`(로그·렌더링·diff·변형 결과), `~/esp-builds/pogoforget3_20261010_app_device_release_signed`(산출물). `1.3.1 (14)` 이하의 산출물은 그대로다 |

### 무엇으로 시험했나

이전과 같은 방식이다: 허브의 말은 허브가 쓰는 JSON 그대로이고(0.4.2가 `power_base_forgets` 뒤에 붙이는
`power_base_departures` 포함. 그 JSON이 허브가 실제로 쓰는 것과 같다는 것은 펌웨어 저장소의 host test가 실제 GET·SSE로
확인한다), 실제 `LiveSensorDataSource` → `PogoSnapshotMapper` → `AppModel`을 지난다. 두 번째 iPhone은 두 번째
`AppModel`과 controller다. "오래 뒤"는 허브가 그때 주는 snapshot — 끝난 작업이 더 없고, 목록 밖의 Base가 적힌 것 — 을
넣는 것이다.

새 test 19개 (`PowerBaseDepartureTests.swift` 새 파일: `PowerBaseDepartureWireTests` 3, `PowerBaseDepartureEvidenceTests` 5,
`AppModelPowerBaseDepartureTests` 11):

| 요구한 경우 | 본 것 |
|---|---|
| B가 센서를 보여 준 뒤 삭제를 통째로 놓치고 16분 뒤 복귀 (마지막 Base) | 처음 받은 snapshot으로 **센서와 Base가 화면 데이터에서 사라지고** `isRegistryRecovering`이 아니다. 17분·5시간 뒤의 snapshot에서도 그대로. 그 Base의 작업은 표시되지 않는다 |
| 같은 snapshot에 허브의 말이 없을 때 (0.4.1 이하의 허브, 그리고 그냥 재시작한 0.4.2) | 센서를 유지하고 복구 중으로 보인다: 빈 목록만으로는 지우지 않는다 |
| 완료 상태를 한 번도 못 본 기기: `pending`·`sent`까지 보고 떠남 | 돌아와서 사라진다. `sent`로 알던 작업은 어떤 상태로도, 요청 목록에도 남지 않는다 |
| **두 기기의 역할을 바꿔**: 첫째가 삭제하고 둘째가 놓침 → 재등록 → 둘째가 삭제하고 첫째가 놓침 | 매번 삭제한 쪽은 `released`에서, 놓친 쪽은 복귀한 첫 snapshot에서 비워진다. 그 사이의 새 등록은 두 기기 모두에 센서와 함께 보인다. 첫째의 예전 요청은 사라진 Base에 붙지 않는다 |
| 요청한 기기가 답(`pending`)만 받고 떠남 | 돌아와서 비워지고 요청 목록에 남는 것이 없다. 다시 등록된 Base에 예전 요청이 붙지 않는다 |
| 여러 Base 중 하나 삭제 | 삭제된 Base의 센서만 사라진다. 남은 Base의 센서는 사용자가 준 이름과 방 그대로. 허브가 동시에 재시작해 남은 센서에 값이 아직 없을 때도: 삭제된 것만 떠나고 남은 것은 복구 중으로 유지 |
| 삭제 후 재등록, 이후 허브 재시작 | 허브가 Base를 등록만으로 나열하고 센서가 아직 없어도 **새 등록의 센서를 유지**하고 복구 중으로 보인다. 이전 등록의 `completed` 작업이 아직 목록에 있어도 같다. 센서가 다시 보고되면 정상으로 돌아온다 |
| 정상적인 허브 시작의 빈 목록 | 아무 Base도 목록 밖이라고 하지 않거나, **다른** Base만 목록 밖이라고 할 때: 센서를 지우지 않는다 |
| 목록에 있는 Base가 같은 snapshot에서 목록 밖이라고도 나옴(허브가 쓰지 않는 모양) | 목록이 이긴다: 센서 유지 |
| 목록 제거 → 재등록 → 일반 삭제, 전부 놓침 | 끝난 등록이 이 기기가 본 등록과 달라도(또는 등록이 적혀 있지 않아도) 사라진다. 따라온 기기도 단계마다 같은 끝에 이른다 |
| 근거를 기억하지 않음 | 목록 밖이라고 했던 Base가 다시 목록에 오른 뒤, 그 말이 없는 빈 목록은 아무것도 지우지 않는다. 화면의 snapshot도 그 말을 더 갖고 있지 않다 |
| wire: 항목별 읽기, 필드가 없는 허브와 `[]`의 구별, 모르는 값 | 등록·이유가 없는 항목은 Base만. 모르는 이유·틀린 등록은 그 값만 버리고 Base는 읽는다. Base가 틀린 항목은 버린다. 나머지 snapshot은 그대로 읽힌다 |

**검사가 실제로 잡는지.** `tools/mutate_app.py`: 앱 저장소의 사본에서 규칙을 하나씩 뺀 변형 52가지(`1.3.1`까지의
43가지와 이번의 9가지). **52가지 모두에서 test가 실패하고, 처음 실패한 test가 뺀 규칙에 대한 것이다**
(`logs/mutations_app.txt`, `logs/mutations_app.recheck.txt`). 전체 실행에서 그중 하나("이전 등록의 작업이 새 등록의
작업을 가림")는 test 실행기가 시뮬레이터에 연결하지 못해("The test runner hung before establishing connection") 아무
test도 돌지 않았다. 도구는 그것을 "잡힘"으로 적었지만 잡힌 것이 아니므로 세지 않았고, 그 변형만 다시 돌려 관련
test(`testTheNewRegistrationCanBeManagedWhateverIsLeftOfTheEarlierOne`)로 잡았다. 이번의 변형: 목록 밖이라는 말을 근거로
쓰지 않음 / 목록에 있는 Base도 지움 / snapshot에서 읽지 않음 / 필드가 없어도 있다고 함 / 모르는 이유의 항목을 버림 /
틀린 Base를 받아들임 / 등록 값을 검사 없이 받음 / 그 말을 센서와 함께 보류함 / 방 적용 때 그 말을 잃음.

### 전체 실행

| 대상 | 범위 | 결과 |
|---|---|---|
| iPhone 13 mini 시뮬레이터 (iOS 27.0), ko | 전체 | 1,273개: 통과 1,250, 실패 0, 건너뜀 23 |
| iPhone 16 Pro Max 시뮬레이터 (iOS 27.0), ko | 전체 | 1,273개: 통과 1,250, 실패 0, 건너뜀 23 |
| iPad Air 11-inch (M4) 시뮬레이터 (iPadOS 27.0), ko | 전체 | 1,273개: 통과 1,250, 실패 0, 건너뜀 23 |
| Mac Catalyst, ko | 전체 | 1,273개: 통과 1,242, 실패 0, 건너뜀 31 |
| 세 시뮬레이터 각각, en / es | 문구·관리·삭제·목록 제거 26개 class | 각 257개: 통과 256, 실패 0, 건너뜀 1(ko에서만 도는 번역 검사) |
| iPhone 13 mini·16 Pro Max, ko | `1.3.2`·`1.3.1`의 새 test가 든 열 class(93개)를 세 번 더 | 여섯 번 모두 93개 통과 |
| Swift package `PowerBaseBLEKit` (`swift test`) | 전체 | 94개: 실패 0, 건너뜀 28(상호운용 harness가 필요한 것) |
| `Scripts/test_pogo_app_version.py` | | 181개, 실패 0. `check`: 여섯 타깃이 `1.3.2 (15)`을 쓴다 |

전체 test 수는 `1.3.1 (14)`의 1,254개에서 19개 늘었다. 열여섯 번의 실행 모두 **첫 실행에서** 통과했다(다시 돌린 것이
없다). `1.3.1` 때 iPad에서 한 번 시간 초과했던 QR test도 이번에는 통과했다.

### 렌더링 (화면을 실제로 그려 확인)

이번 변경에는 화면도 문구도 없다. 그래서 같은 장면을 다시 그려 **`1.3.1 (14)` 때의 렌더링과 한 장씩 비교**했다
(`tools/run_renders.sh`, `tools/compare_renders.py`, `tools/render_pixel_diff.py`).

| 기기 | ko | en | es |
|---|---|---|---|
| iPhone 13 mini (좁은 화면) | 8개 test 통과, PNG 210 | 8개 통과, PNG 230 | 8개 통과, PNG 238 |
| iPhone 16 Pro Max | 8개 통과, PNG 175 | 8개 통과, PNG 194 | 8개 통과, PNG 189 |
| iPad Air 11-inch | 8개 통과, PNG 176 | 8개 통과, PNG 186 | 8개 통과, PNG 194 |
| Mac Catalyst | 8개 통과, PNG 116 | — | — |

열 번의 실행 모두 첫 실행에서 통과했고, 장 수와 파일 이름이 `1.3.1 (14)` 때와 같다(1,908장).

| 비교 (`logs/render_compare.txt`, `logs/render_pixel_diff.summary.txt`) | 장 |
|---|---|
| 이전 회차의 같은 이름 파일과 **바이트까지 같다** | 1,680 |
| 바이트는 다르고 픽셀은 같다 | 6 |
| 픽셀이 다르되 어느 것도 40/255를 넘지 않는다(가장자리 처리·반투명. Mac Catalyst의 116장 가운데 대부분이 여기 든다) | 149 |
| 눈에 보이는 차이가 있다 | 73 |

눈에 보이는 차이 73장의 내용: 기기 화면의 "마지막 수신" 시각과 "n초 전"(26장: 그린 시각이 다르다), 요청 중·찾는 중의
진행 표시(33장: 돌아가는 표시의 프레임), 설정 화면의 버전·빌드 번호 줄(11장: `1.3.2`, `15`), 설정 코드 입력의 시스템
"붙여넣기" 버튼(3장: SwiftUI `PasteButton`은 클립보드에 글이 있을 때 보인다. 시뮬레이터의 그때 클립보드 상태다).

**직접 열어 본 것** (결과 디렉터리의 `render_viewed.txt`): 13 mini ko의 요청 중·찾는 중·설정 전체(버전 줄), 16 Pro Max
ko의 설정 코드 입력(이전 회차 파일과 나란히), iPad es의 기기 화면(이전 회차 파일과 나란히), Mac의 "삭제 미확인",
16 Pro Max en의 삭제 요청 목록(가장 큰 글자 크기), 13 mini es의 "Eliminación sin confirmar"(가장 큰 글자 크기), iPad ko의
목록 제거 제공 화면. 겹침·잘림이 없었고 `1.3.1 (14)` 때 본 것과 같았다. 그 밖의 장은 이번에 열어 보지 않았다: 그중
1,680장은 `1.3.1 (14)` 때의 파일과 바이트까지 같고, 그때 연 것은 그 절의 34장이다.

### 빌드와 산출물

| | 결과 |
|---|---|
| iOS Simulator Debug·Release, Mac Catalyst Debug·Release (서명 없는 빌드) | 넷 다 성공. 경고 수는 `1.3.1 (14)`·`1.3.0 (13)`과 같다(84·16·42·8). `check_release_enrollment_surface.sh`와 `verify-bundle` 통과 |
| 서명된 기기용 Release 빌드(`pogo_app_version.py build`) | 성공. `manifest-verify --match-current-tree --expect-version 1.3.2`, `verify-bundle --expect-identity`, `check_release_enrollment_surface.sh release` 통과(각각 종료 코드 0). 빌드 입력 377개의 SHA-256이 빌드 전후 같다(`logs/build_inputs_{before,after}.sha256`). `1.3.1 (14)` 후보의 입력과 다른 것은 여덟 개뿐이다: 바꾼 소스 여섯, `Version.xcconfig`, 새 test 파일 |
| 산출물 | `~/esp-builds/pogoforget3_20261010_app_device_release_signed/artifact/PogoHome.app`, `manifest.json` SHA-256 `378e20b96a6f9fdfd306f9116dba0d0597b402b6f7e2d5193eb75f59c8b8b576`(파일 60개), 실행 파일 SHA-256 `4b2f9f497a87c711b901c756f6cf98703d83913b8399dffc5d8f3d179314e5b9`. Release, `generic/platform=iOS`, development, `deployed=false`, `hardware_verified=false` |
| 앱·위젯·Watch 앱·Watch 위젯 | 넷 다 `1.3.2 (15)`(설치 확인 도구가 번들마다 읽었다) |
| 서명 재검사 (`logs/app_candidate_codesign_recheck.log`) | 이 Mac의 일반 로그인 shell에서 `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`, 종료 코드 0. 내장 번들 셋(위젯, Watch 앱, Watch 위젯)도 각각 0. 인증 경로는 Apple Development → Apple Worldwide Developer Relations Certification Authority → Apple Root CA. 신뢰 설정은 바꾸지 않았다 |
| `trustd`에 닿지 못하는 환경에서의 같은 검사 | `1.3.1 (14)` 때와 같은 진단을 이 후보로 다시 했다: 검사 프로세스가 `trustd`를 조회하지 못하게 하면(`sandbox-exec`로 그 조회만 막음) `CSSMERR_TP_NOT_TRUSTED`, 종료 코드 1. 바로 뒤 일반 shell에서는 다시 0. 다른 도구가 이 후보를 그런 환경에서 검사하면 같은 오류를 볼 것이고, 그것은 서명이 깨졌다는 뜻이 아니다 |
| 프로파일 | **`1.3.1 (14)` 후보와 같은 프로파일이다**(Xcode가 새로 만들지 않았다. 같은 프로파일로 다시 빌드해도 만료는 늦춰지지 않는다). iPhone 앱 2026-10-12 02:23:55 UTC, iPhone 위젯 02:23:53, Watch 앱 02:22:15, Watch 위젯 02:22:14 UTC에 만료. **가장 이른 것이 한국 시간 10월 12일 11:22:14**이고, 빌드 시점(10월 10일 23:51 KST)부터 약 35시간 30분이다. 그 뒤에는 새 빌드가 필요하고 그것은 새 산출물이다. iPhone 앱·위젯의 프로파일에 기기 2대, Watch 앱·위젯에 1대(대수만 읽었다) |
| 설치 확인 도구((15)용 사본, 준비물의 `tools/`) | 자체 시험 24개 실패 0(후보의 경로를 준 실행과 주지 않은 실행 모두), `candidate` 종료 코드 0, `candidate --at 2026-10-12T03:00:00Z`는 만료로 1(`~/esp-builds/pogo_forget3_hwtest_20261010/logs/app_install_check.*.log`) |
| 이전 후보 | `1.3.1 (14)`·`1.3.0 (13)`과 그 전의 산출물 디렉터리는 고치지 않았다(결과 디렉터리의 `logs/preservation_reviews_and_earlier_outputs.log`) |

### 하지 않은 것

- **실제 기기 전부**: iPhone 13 mini, iPhone 16 Pro Max, 두 대를 함께 쓰는 것, Watch. 설치도 실행도 하지 않았다.
- **실제 대기와 실제 백그라운드**: 15분 넘게 백그라운드에 둔 실제 앱이 돌아와서 무엇을 받는지는 보지 않았다. 앱이
  백그라운드에서 돌아올 때 snapshot을 새로 받는다는 것은 기존 동작이고 이번에 바꾸지 않았다.
- 두 실제 iPhone이 이 앱의 프로파일에 들어 있는지: 확인하지 못했다(프로파일의 기기 대수만 읽었다). 확인 방법은 준비물의
  `tools/app_install_check.py device <앱>`이다(기기를 연결해야 하므로 실행하지 않았다).
- 실제 허브(0.4.2)와의 통신: snapshot은 허브가 쓰는 형식 그대로 적은 JSON이다.
- **0.4.1 이하의 허브에 연결된 경우 그 결함은 남는다**(허브가 말해 주지 않는다). test로 그 동작(센서 유지)을 고정해
  두었다.
- 요청한 기기가 완료를 보지 못하고 오래 뒤에 돌아오면 "삭제 완료" 알림은 뜨지 않는다.
- 허브의 snapshot이 순서가 바뀌어 도착하는 경우(오래된 GET 응답이 새 event 뒤에 적용됨)는 이전부터 따로 막지 않는다.
  그런 snapshot이 "목록 밖"을 말하면 그 Base의 센서가 다음 snapshot까지 사라진다. 이번에 만든 문제도, 고친 문제도
  아니다. (2026-10-11에 덧붙임: 독립 검토가 이 순서를 판정 코드로 재현했고, `1.3.3`이 수신 단계에서 막는다 — 위 절.
  그 절이 함께 적은 것: 실제 연결에서는 event의 snapshot이 적용되지 않으므로, 실제로 뒤바뀔 수 있는 것은 두 `GET`
  응답이다.)
- (2026-10-11에 덧붙임) 삭제 요청이 Base의 식별값만 실어 보내는 것: 이 절의 버전까지 그랬고, 응답을 놓친 요청의
  재전송이 다시 등록된 Base의 새 등록을 삭제할 수 있었다(독립 검토가 허브의 코드로 재현). `1.3.3`과 Linux bridge
  0.5.0이 고쳤다 — 위 절.
- VoiceOver의 실제 음성, Watch·위젯의 실제 화면.

## 목록 제거 후속 수정 (2026-10-10, `1.3.1 (14)`)

`1.3.0`의 "허브 목록에서 제거"를 독립 검토한 결과 실제 코드로 재현된 결함과, `1.3.0`이 남겨 둔 것의 정리다(펌웨어
저장소 `docs/power-base-management.md` 14절, Linux bridge 0.4.1). 새 사용자 기능은 없다. `1.3.0 (13)`의 기능과 `1.2.1
(12)`의 센서 카드 간격·설명 축약이 그대로 들어 있다. 허브 쪽 기록은 펌웨어 저장소 `docs/validation-status.md` "목록 제거
후속 수정 (2026-10-10)"에 있다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 허브·보드·iPhone에 접근하지 않았다.
시뮬레이터에서의 통과는 실제 기기에서의 통과가 아니다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.3.0 (13)`, 소스 지문 `4044aa16197e20e8f9b09c5ed03346433acf35efb5b0aee6d12c71519a1fce0b`. status 136줄(미추적 62), stage 0, index SHA-256 `e8dc6c3b…a3580`: 작업 지시가 적은 값과 같았다. `1.3.0` 작업이 끝났을 때와 달라진 파일은 Xcode의 화면 상태 파일과 `.DS_Store` 둘뿐이었다 |
| 작업 후 | `1.3.1 (14)`, 소스 지문 `be61e431024bda054e65f476b08c33df0ecc1f121a9c04804044b8fc8a53f218`, 빌드 식별자 `05375341f70d+dirty.be61e431024b` |
| 도구 | Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임, macOS 26.6.2 |
| 시뮬레이터 | "PogoHome iPhone 13 mini"(iPhone 13 mini, iOS 27.0), "iPhone 16 Pro Max"(iOS 27.0), "iPad Air 11-inch (M4)"(iPadOS 27.0), Mac Catalyst(이 Mac) |
| 출력 | `~/esp-builds/pogoforget2_20261010_results`(로그·렌더링·diff·변형 결과), `~/esp-builds/pogoforget2_20261010_app_device_release_signed`(산출물). `1.3.0 (13)` 이하의 산출물은 그대로다 |

### 검토가 남긴 재현

검토의 `repro_evidence.swift`(고치지 않음)는 허브의 실제 snapshot 셋 — 제거 전, **섞인 것**(이전 목록 + 새 기록), 제거
뒤 — 을 실제 `PogoSnapshotMapper`와 `PowerBaseReleaseEvidence`에 순서대로 넣고 마지막에 제거가 인정되는지를 본다.

| 허브의 snapshot | 앱의 판정 | 결과 |
|---|---|---|
| 수정 전 허브(0.4.0)가 만든 것: 섞인 snapshot에 옛 Base가 있다 | 수정 전(`1.3.0`) | **실패**(종료 코드 1): 제거가 인정되지 않는다 |
| 같은 것 | 수정 후(`1.3.1`) | 통과(0) |
| 수정 후 허브(0.4.1)가 만든 것: 섞이지 않는다 | 수정 전(`1.3.0`) | 통과(0) |
| 같은 것 | 수정 후(`1.3.1`) | 통과(0) |

기록: 결과 디렉터리의 `repro/evidence_matrix.txt`, 최종 트리에서의 실행 `repro/adapter_final.stdout.txt`
(`repro/run-bo3jgfos/`). 허브 쪽 재현은 훅의 형식이 바뀌어 두 줄짜리
adapter로 돌렸다(펌웨어 저장소의 같은 절). 이 재현은 Mac에서 실제 코드에 순서를 주입한 것이고, 실제 HTTP 통신이나 두
iPhone의 재현이 아니다.

### 무엇으로 시험했나

`1.3.0`과 같은 방식이다: 허브의 말은 허브가 쓰는 JSON 그대로이고, 실제 `LiveSensorDataSource` → `PogoSnapshotMapper`
→ `AppModel` → `PowerBaseRemovalController` → 관리 화면이 읽는 값까지 지난다. 요청에 대한 허브의 답은 스크립트이고,
두 번째 iPhone은 두 번째 `AppModel`과 controller다.

새 test 36개 (`PowerBaseRegistrationBindingTests.swift` 새 파일, `PowerBaseForgetTests.swift`와
`AppModelPowerBaseForgetTests.swift`에 추가):

| 요구한 경우 | 본 것 |
|---|---|
| 섞인 snapshot → 빈 목록, `AppModel`까지 | 다른 기기가 제거한 Base: 섞인 snapshot 동안은 센서가 보이고, 목록이 따라오면 **센서가 화면 데이터에서 사라지고** `isRegistryRecovering`이 아니다. 그 뒤의 snapshot에서도 그대로 |
| 이 기기가 요청한 경우, 답과 섞인 snapshot이 엇갈림 | 센서가 사라지고 알림은 한 번 |
| 최초 연결이 섞인 snapshot인 경우 | 다음 snapshot에서 센서가 사라진다 |
| 과거 기록 + 새 등록 | 이전 등록의 기록이 남아 있는 동안 허브의 목록이 잠시 비어도(재시작) **새 등록의 센서는 유지**되고 복구 중으로 표시된다 |
| 같은 등록이 그대로 목록에 있는 경우, 등록이 적혀 있지 않은 경우, 여러 번 반복 | 기록을 써 버리지 않는다. 다른 등록이 목록에 오를 때만 지난 일이 된다 |
| 삭제 작업(`released`·`completed`)의 같은 판정 | 작업의 `generation`과 목록의 `record`가 같으면 써 버리지 않고, 다르면 지난 일. 등록을 말하지 않는 허브에는 이전 판정 |
| 허브 전환 | 새 허브는 빈 근거에서 시작하고, 요청 상태가 넘어가지 않는다 |
| 응답 유실 + 다른 기기의 제거 (두 `AppModel`) | "알 수 없음"이 사라지고 이 기기에는 알림이 없다. 다시 등록된 뒤에도 나타나지 않고, 목록 제거와 삭제가 새 등록에 정상으로 제공되며, 새 확인은 새 `request_id`다 |
| 응답 유실 + 새 등록 / + 삭제(release) | 끝난다 |
| 응답 유실 + 허브의 침묵(빈 목록, 기록 없음) / 같은 등록이 다시 목록에 | 그대로 "알 수 없음". "다시 확인"은 **같은 `request_id`**로 나간다 |
| 요청이 가는 중에 끝난 경우, 늦은 응답 | 늦게 온 응답(성공이든 거절이든)은 아무것도 바꾸지 않는다 |
| snapshot이 응답보다 먼저 | 한 번만 알린다 |
| 거절(실패 안내) | 읽을 때까지 남는다(새 등록이 목록에 올라도: "그사이 다시 등록되어…"). 그 Base가 목록에 없어지면 사라지고 다시 나타나지 않는다 |
| 앱 재실행 | 새 controller에는 이전 요청이 없다 |
| 확인창을 열어 둔 동안의 재등록 | 확인창이 잡아 둔 등록(`PowerBaseForgetConfirmation`)으로 요청한다. 화면이 지금 내놓는 등록이 아니다 |
| 목록에서 빠진 Base의 삭제 작업 | "삭제 미확인"(`removedFromListUnconfirmed`). 허브의 `list_removed`로도, 0.4.0의 `kept_removal_id`로도 같다. "삭제 완료"·"삭제 중"·"결과 확인 불가"와 다른 제목·문구, 요청 목록에 남고, 허브가 결과를 오래 받지 못한 뒤에만 "삭제 확인"을 제공 |
| 이전 등록의 작업과 새 등록 | 어떤 상태의 이전 작업도 새 등록의 삭제 버튼을 막지 않고, 새 등록 자신의 작업을 가리지 않는다 |

**검사가 실제로 잡는지.** `tools/mutate_app.py`: 앱 저장소의 사본에서 규칙을 하나씩 뺀 변형 43가지
(`1.3.0`의 20가지 가운데 지금도 적용되는 것과 이번의 것). **43가지 모두에서 test가 실패하고, 변형마다 처음 실패한
test가 뺀 규칙에 대한 것이다** (`logs/mutations_app.txt`).

### 전체 실행

| 대상 | 범위 | 결과 |
|---|---|---|
| iPhone 13 mini 시뮬레이터 (iOS 27.0), ko | 전체 | 1,254개: 통과 1,231, 실패 0, 건너뜀 23 |
| iPhone 16 Pro Max 시뮬레이터 (iOS 27.0), ko | 전체 | 1,254개: 통과 1,231, 실패 0, 건너뜀 23 |
| iPad Air 11-inch (M4) 시뮬레이터 (iPadOS 27.0), ko | 전체 | 첫 실행: 1,254개 중 **실패 1**(아래). 단독으로 다시: 통과 1,231, 실패 0, 건너뜀 23 |
| Mac Catalyst, ko | 전체 | 1,254개: 통과 1,223, 실패 0, 건너뜀 31 |
| 세 시뮬레이터 각각, en / es | 문구·관리·삭제·목록 제거 23개 class | 각 238개: 통과 237, 실패 0, 건너뜀 1(ko에서만 도는 번역 검사) |
| iPhone 13 mini·16 Pro Max, ko | 새 test 36개가 든 일곱 class(74개)를 세 번 더 | 여섯 번 모두 74개 통과 |
| Swift package `PowerBaseBLEKit` (`swift test`) | 전체 | 94개: 실패 0, 건너뜀 28(상호운용 harness가 필요한 것) |
| `Scripts/test_pogo_app_version.py` | | 181개, 실패 0. `check`: 여섯 타깃이 `1.3.1 (14)`을 쓴다 |

전체 test 수는 `1.3.0 (13)`의 1,218개에서 36개 늘었다.

**iPad 첫 실행의 실패 1개.** `PowerBaseSetupQRFollowUpTests.testCancellingTheFilePanelEndsItsScanAndTheSameFileCanBeChosenAgain`
("condition not met within 10.0 seconds"). 실제 이미지 파일을 읽고 10초를 기다리는 QR 입력 test이고, 이번 변경이 건드린
코드가 아니다. 그 실행은 허브 변형 실행·허브 회귀·앞선 시뮬레이터 실행 여섯 묶음에 바로 이어 돌았다(load average 300
이상). 다른 작업 없이 iPad에서 전체를 다시 돌린 실행은 실패 0이고, 그 class만 세 번 돌린 실행도 각각 23개 통과다
(`logs/full_ipad_ko_rerun.*`, `logs/qr_followup_ipad_ko_[123].*`). 원인을 더 조사하지는 않았다. 첫 실행의 기록은 지우지
않았다(`logs/full_ipad_ko.*`).

건너뛴 test는 렌더링(환경 변수가 있을 때만), ko에서만 도는 검사, Catalyst에서 하지 않는 실제 백그라운드 전환 등이다.
통과로 세지 않았다.

### 렌더링 (화면을 실제로 그려 확인)

`tools/run_renders.sh`: 관리 화면의 "허브 목록에서 제거" 여섯 상태와 관련 상태, **새 상태 둘**("삭제 미확인",
"삭제 미확인" + 허브가 결과를 오래 받지 못한 뒤의 "삭제 확인"), 목록 제거 확인창과 삭제 확인창(시스템이 실제로 띄운
것), 알림, 센서 카드(`1.2.1 (12)`의 간격), 삭제 요청 목록(새 항목 "삭제 미확인" 포함)·기기 추가, 등록 화면의 찾기
상태 여섯, 설정. 각각 기본·어두운 화면·가장 큰 글자 크기.

| 기기 | ko | en | es |
|---|---|---|---|
| iPhone 13 mini (좁은 화면) | 8개 test 통과, PNG 210 | 8개 통과, PNG 230 | 8개 통과, PNG 238 |
| iPhone 16 Pro Max | 8개 통과, PNG 175 | 8개 통과, PNG 194 | 8개 통과, PNG 189 |
| iPad Air 11-inch | 8개 통과, PNG 176 | 8개 통과, PNG 186 | 8개 통과, PNG 194 |
| Mac Catalyst | 8개 통과, PNG 116 | — | — |

열 번의 실행 모두 첫 실행에서 통과했다(모두 1,908장, 결과 디렉터리의 `render/`).

**직접 열어 본 것 34장** (파일마다 무엇을 봤는지: 결과 디렉터리의 `render_viewed.txt`):

- iPhone 13 mini, ko (14장): "삭제 미확인" 기본·어두운 화면·가장 큰 글자 크기 네 쪽 전부, "삭제 미확인 + 삭제 확인"
  기본·어두운 화면, "결과 확인 불가"(대조), 삭제 요청 목록, 센서 카드, 목록 제거 제공 화면과 그 확인창, 이전 등록
  방식의 Base.
- iPhone 16 Pro Max, ko (3장): "삭제 미확인 + 삭제 확인", 삭제 요청 목록(가장 큰 글자 크기), 센서 카드(가장 큰 글자 크기).
- iPad, ko (2장): "삭제 미확인 + 삭제 확인", 삭제 요청 목록.
- en (5장): 13 mini의 "Removal Unconfirmed" 기본·가장 큰 글자 크기와 삭제 요청 목록, 16 Pro Max의 "Removal
  Unconfirmed", iPad의 삭제 요청 목록.
- es (7장): 13 mini의 "Eliminación sin confirmar" 기본·가장 큰 글자 크기, 삭제 요청 목록(기본, 가장 큰 글자 크기 두
  쪽), 16 Pro Max의 확인창(대기 중 삭제 문장 포함), iPad의 "Eliminación sin confirmar".
- Mac Catalyst, ko (3장): "삭제 미확인 + 삭제 확인", 삭제 요청 목록, 넓은 창의 기기 화면.

본 것에서는 겹침·잘림이 없었다. "삭제 미확인"은 "삭제 완료"·"삭제 중"·"결과 확인 불가"와 제목·문구·기호(회색 물음표)가
다르고, 목록에서도 따로 보인다. 가장 큰 글자 크기의 좁은 화면에서 en "Uncon-firmed", es "Elimina-ción"처럼 시스템이
낱말을 나눠 줄을 바꾸며, 카드 안에 들어간다. **나머지 1,874장은 열어 보지 않았다.**

### 빌드와 산출물

| | 결과 |
|---|---|
| iOS Simulator Debug·Release, Mac Catalyst Debug·Release (서명 없는 빌드) | 넷 다 성공. 경고 수는 `1.3.0 (13)`·`1.2.1 (12)`와 같다(84·16·42·8). `check_release_enrollment_surface.sh`와 `verify-bundle` 통과 |
| 서명된 기기용 Release 빌드(`pogo_app_version.py build`) | 성공. `manifest-verify --match-current-tree --expect-version 1.3.1`, `verify-bundle --expect-identity`, `check_release_enrollment_surface.sh release` 통과(각각 종료 코드 0). 빌드 입력 376개의 SHA-256이 빌드 전후 같다(`logs/build_inputs_{before,after}.sha256`) |
| 산출물 | `~/esp-builds/pogoforget2_20261010_app_device_release_signed/artifact/PogoHome.app`, `manifest.json` SHA-256 `f2cbddb5f4620672fbb5e1becd7c05d9789d10b47bafb44e36639af6d4192d0b`(파일 60개), 실행 파일 SHA-256 `b50662ba448b4c6bf560c2001ae3ef5b4cf0ef1634e38420dd77b4ca9d5a1684`. Release, `generic/platform=iOS`, development, `deployed=false`, `hardware_verified=false` |
| 앱·위젯·Watch 앱·Watch 위젯 | 넷 다 `1.3.1 (14)`(설치 확인 도구가 번들마다 읽었다) |
| 서명 재검사 (`logs/app_candidate_codesign_recheck.log`) | 이 Mac의 일반 로그인 shell에서 `codesign --verify --deep --strict --verbose=2`: `valid on disk`, `satisfies its Designated Requirement`, 종료 코드 0. 내장 번들 넷도 각각 0. 인증 경로는 Apple Development → Apple Worldwide Developer Relations Certification Authority → Apple Root CA. 신뢰 설정은 바꾸지 않았다 |
| 다른 도구의 재검사가 본 `CSSMERR_TP_NOT_TRUSTED` | 같은 후보·같은 명령을 **검사 프로세스가 `trustd`에 닿지 못하게 한 채**(`sandbox-exec`로 그 조회만 막음) 돌리면 그 오류가 그대로 나온다(종료 코드 1). 바로 뒤 일반 shell에서는 다시 0이다. 곧 그 오류는 그런 환경에서 인증 경로를 평가하지 못한 것이고, 이 후보의 서명이 깨졌다는 뜻이 아니다. 그 검토의 환경을 직접 본 것은 아니므로 "같은 증상을 이렇게 만들 수 있다"까지가 확인한 것이다 |
| 프로파일 | **이전 후보와 같은 프로파일이다**(Xcode가 새로 만들지 않았다). iPhone 앱·위젯: 2026-10-12 02:23 UTC, Watch 앱·위젯: 2026-10-12 02:22 UTC에 만료(한국 시간 10월 12일 11:22). 빌드 시점부터 약 1.8일. 그 뒤에는 새 빌드가 필요하고 그것은 새 산출물이다. iPhone 앱·위젯의 프로파일에 기기 2대, Watch 앱·위젯에 1대(대수만 읽었다) |
| 설치 확인 도구((14)용 사본, 준비물의 `tools/`) | 자체 시험 24개 실패 0, `candidate` 종료 코드 0, `candidate --at 2026-10-12T03:00:00Z`는 만료로 1. 자체 시험을 경로 없이 처음 돌렸을 때는 기본 경로가 이전 후보를 가리켜 6개가 실패했다: 도구의 기본 경로를 이 후보로 고쳤고, 그 뒤 경로를 준 실행과 주지 않은 실행 모두 24개 통과다 |

### 하지 않은 것

- **실제 기기 전부**: iPhone 13 mini, iPhone 16 Pro Max, 두 대를 함께 쓰는 것, Watch. 설치도 실행도 하지 않았다.
- 두 실제 iPhone이 이 앱의 프로파일에 들어 있는지: 확인하지 못했다(프로파일의 기기 대수 2만 읽었다). 확인 방법은
  준비물의 `tools/app_install_check.py device <앱>`이다(기기를 연결해야 하므로 실행하지 않았다. 가짜 `xcrun`으로 한 자체
  시험만 있다). UDID는 출력하지 않는다.
- 실제 허브(0.4.1)와의 통신: 허브의 답은 스크립트이고 snapshot은 허브가 쓰는 형식 그대로 적은 JSON이다.
- 확인창이 열려 있는 동안 목록이 바뀌는 것을 **화면에서** 재현한 것은 아니다: 확인창이 등록을 잡아 두는 값
  (`PowerBaseForgetConfirmation`)과 요청이 그 등록으로 나가는 것을 test했고, 화면이 그 값을 쓰는 것은 코드로 확인했다.
- `DevicesView`가 controller에 목록의 Base들을 넘기는 한 줄: test는 같은 인자로 controller를 직접 부른다.
- VoiceOver의 실제 음성, Watch·위젯의 실제 화면.
- 끝난 삭제 작업(`completed`)의 기록은 허브에서 10분 뒤 사라진다. 마지막 Power Base를 다른 기기가 **삭제**하는 동안
  이 앱이 10분 넘게 백그라운드에 있었다면, 돌아와서 옛 센서를 "복구 중"으로 보여 준다(앱을 다시 실행하면 사라진다).
  목록 제거에는 허브 0.4.1의 수정이 들어갔고, 삭제 쪽은 이번에 고치지 않았다. (2026-10-11에 덧붙임: `1.3.2 (15)`와
  허브 0.4.2에서 고쳤다. "앱을 다시 실행하면 사라진다"를 해결책으로 삼지 않는다. 위 "목록 제거 후속 수정 2".)

## 허브 목록에서 제거 (2026-10-10, `1.3.0 (13)`)

돌아오지 않는 Power Base를 연결된 허브의 목록에서 지우는 "허브 목록에서 제거"를 넣었다(펌웨어 저장소
`docs/power-base-management.md` 13절, Linux bridge 0.4.0). 삭제와 다른 동작이고, 앱의 어느 화면도 그것을 "삭제 완료"로
표시하지 않는다. 함께: "다시 쓰려면" → "다시 사용하려면"(남은 두 곳). `1.2.1 (12)`의 센서 카드 간격이 들어 있다.
허브 쪽 규칙의 검증은 펌웨어 저장소 `docs/validation-status.md` "허브 목록에서 제거 (2026-10-10)"에 있다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 허브·보드·iPhone에 접근하지 않았다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.1 (12)`, 소스 지문 `68eacecb8174f94d2382352b012b433f590954392e1c9d4e2ed3f10efba0f9df`. status 134줄(미추적 60), stage 0, index SHA-256 `e8dc6c3b…a3580`: 작업 지시가 적은 값과 같았다 |
| 작업 후 | `1.3.0 (13)`, 소스 지문 `4044aa16197e20e8f9b09c5ed03346433acf35efb5b0aee6d12c71519a1fce0b`, 빌드 식별자 `05375341f70d+dirty.4044aa16197e` |
| 도구 | Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임 |
| 시뮬레이터 | "PogoHome iPhone 13 mini"(iPhone 13 mini, iOS 27.0), "iPhone 16 Pro Max"(iOS 27.0), "iPad Air 11-inch (M4)"(iPadOS 27.0), Mac Catalyst(이 Mac) |
| 출력 | `~/esp-builds/pogoforget_20261010_results`(로그·렌더링·diff·변형 결과), `~/esp-builds/pogoforget_20261010_app_device_release_signed`(산출물). `1.2.1 (12)` 이하의 산출물은 그대로다 |

### 무엇으로 시험했나

- **허브의 말은 실제 허브의 JSON이다.** snapshot(`record`, `power_base_forgets` 포함)과 목록 제거의 답은 허브의
  `BuildSnapshotJson()`·`ForgetRecordJson()`이 쓰는 형식 그대로 적었고, 실제 `LiveSensorDataSource` →
  `PogoSnapshotMapper` → `AppModel`(방이 설정된 상태) → `PowerBaseRemovalController` → 관리 화면이 읽는 값
  (`PowerBaseManagementPresentation.state`)까지 지난다.
- **요청에 대한 허브의 답은 스크립트다**(`FakeRemovalHub`). 허브가 실제로 언제 거절하는지는 펌웨어 저장소에서 실제
  허브 코드로 시험했다. 여기서는 각 답을 앱이 무엇으로 만드는지를 본다.
- **두 번째 iPhone은 두 번째 `AppModel`과 controller다**(각자의 연결, 각자의 자격증명). 한 기기가 한 일은 허브의
  snapshot으로만 다른 기기에 닿는다. 실제 기기 두 대가 아니다.

새 test 47개(`PowerBaseForgetTests.swift` 32개, `AppModelPowerBaseForgetTests.swift` 15개):

| 요구한 경우 | 본 것 |
|---|---|
| 허브의 JSON부터 화면 판단까지 | 마지막 오프라인 Base를 목록에서 제거 → 답 → 다음 snapshot: Base·센서 없음, 삭제 작업 없음, 요청 카드 없음, `isRegistryRecovering` 아님 |
| 성공·실패·미확인, 재요청 | 거절(온라인, 다시 등록됨, 목록에 없음, 등록 진행 중, 용량, 권한 등)은 읽을 때까지 표시되고 아무것도 숨기지 않는다. 응답 유실은 "알 수 없음"이고 **같은 `request_id`**로 다시 보낸다 |
| 다른 탭·화면 닫힘 | 응답을 잃은 뒤 snapshot에 그 `request_id`의 기록이 오면 관리 화면 없이도 끝나고, 알림은 탭이 화면에 올 때까지 기다린다 |
| 앱 재실행 | 이미 제거된 뒤 시작한 앱: 허브가 보여 주는 그대로이고 아무것도 알리지 않는다 |
| 허브 전환, 늦은 응답 | 이전 허브의 늦은 답은 새 허브의 화면·알림을 바꾸지 않고, 새 허브에는 새 요청이 간다 |
| 마지막 Base 제거와 빈 목록 | 허브가 기록으로 설명한 빈 목록은 붙잡아 두지 않는다. 기록이 없는 빈 목록은 이전처럼 붙잡아 둔다 |
| 재등록 뒤 과거 표시 | 다시 등록된 Base는 이전 목록 제거 기록이 남아 있어도 정상 표시되고 삭제할 수 있으며, 그 기록은 그 뒤의 빈 목록을 설명하지 못한다 |
| 삭제와 목록 제거의 구별 | 알림 문구·아이콘, 화면 문구, 이벤트 종류가 다르다. `pending` 삭제는 취소된다고 말하고, 명령이 나간 삭제는 "결과 확인 불가"로 계속 보인다 |
| capability 없는 허브 | `record`·`power_base_forgets`가 없는 허브(0.3.0 이하): 보이지 않고 아무것도 보내지 않으며 삭제는 그대로다 |
| Base 2개, 모듈 이동, 방 지정 | 다른 Base와 그 센서, 옮겨 간 센서의 이름·방 지정이 그대로다 |
| 두 기기 | 한 기기의 제거가 다른 기기(관리 화면을 열어 둔 상태)에 반영되고 그쪽에는 알림이 없다. 다른 기기의 오래된 확인은 그 등록의 `record`로 나가고 `stale_record`로 거절된 뒤 새 등록이 그대로 보인다. 두 기기는 각자의 토큰과 `request_id`를 쓴다 |
| Watch·위젯 | 목록 제거 뒤의 `AppModel.snapshot`이 비어 있는 것까지 봤고(둘은 그 snapshot에서 만들어진다), 기존 Watch·위젯 test는 전체 실행에 들어 있다. 실제 Watch·위젯 화면은 보지 않았다 |

**검사가 실제로 잡는지.** 앱 저장소의 사본에서 규칙을 하나씩 뺀 변형 20가지 가운데 19가지에서 새 test가 실패한다
(`logs/mutations_app.txt`): 목록 제거를 근거로 쓰지 않음, 이전 기록을 다시 근거로 씀, 재요청이 새 요청이 됨, 응답 유실을
거절로 봄, 다른 허브의 늦은 답 적용, 다른 요청의 기록으로 내 요청을 끝냄, 다른 기기의 제거를 알림, "삭제 완료"로 알림,
허브 전환 뒤 요청 유지, 온라인·센서 온라인·capability 없음·현재 상태 모름·삭제 진행 중에 제공, 모르는 상태를
`removed_from_hub`로 읽음, 모든 404를 "목록에 없음"으로 읽음, 알림 문구가 삭제 완료와 같음, `record`를 읽지 않음, 방
적용 때 기록 유실. 잡히지 않은 하나는 "한 번만 알림" 장치였는데, 열린 요청이 있을 때만 그 경로에 닿으므로 중복이었다:
그 장치를 지웠다.

### 전체 실행

| 대상 | 범위 | 결과 |
|---|---|---|
| iPhone 13 mini 시뮬레이터 (iOS 27.0), ko | 전체 | 1,218개: 통과 1,195, 실패 0, 건너뜀 23 |
| iPhone 16 Pro Max 시뮬레이터 (iOS 27.0), ko | 전체 | 1,218개: 통과 1,195, 실패 0, 건너뜀 23 |
| iPad Air 11-inch (M4) 시뮬레이터 (iPadOS 27.0), ko | 전체 | 1,218개: 통과 1,195, 실패 0, 건너뜀 23 |
| Mac Catalyst, ko | 전체 | 1,218개: 통과 1,187, 실패 0, 건너뜀 31 |
| 세 시뮬레이터 각각, en / es | 문구·관리·삭제·목록 제거 20개 class | 각 202개: 실패 0, 건너뜀 1(ko에서만 도는 번역 검사) |
| iPhone 13 mini·16 Pro Max, ko | 새 test 47개를 세 번 더 | 여섯 번 모두 47개 통과 |
| 최종 트리(아래 "렌더링 도구의 수정" 뒤)에서 다시: iPhone 13 mini·16 Pro Max, ko 전체 | | 각 1,218개: 통과 1,195, 실패 0, 건너뜀 23 |
| Swift package `PowerBaseBLEKit` (`swift test`) | 전체 | 94개: 실패 0, 건너뜀 28(상호운용 harness가 필요한 것) |
| `Scripts/test_pogo_app_version.py` | | 181개, 실패 0. `check`: 여섯 타깃이 `1.3.0 (13)`을 쓴다 |

건너뛴 test는 렌더링(환경 변수가 있을 때만), ko에서만 도는 검사, Catalyst에서 하지 않는 실제 백그라운드 전환 등이다.
통과로 세지 않았다.

### 렌더링 (화면을 실제로 그려 확인)

`tools/run_renders.sh`: 관리 화면의 "허브 목록에서 제거" 여섯 상태와 관련 상태 셋, 목록 제거 확인창과 삭제 확인창(시스템이
실제로 띄운 것), 알림(삭제 완료 / 목록에서 제거됨 / 둘 함께), 센서 카드, 목록·기기 추가, 등록 화면의 찾기 상태 여섯,
설정. 각각 기본·어두운 화면·가장 큰 글자 크기.

| 기기 | ko | en | es |
|---|---|---|---|
| iPhone 13 mini | 첫 실행 8개 중 1개 실패(아래) → 다시: 8개 통과, PNG 186 | 8개 test 통과, PNG 199 | 8개 통과, PNG 211 |
| iPhone 16 Pro Max | 첫 실행 1개 실패(아래) → 다시: 8개 통과, PNG 154 | 8개 통과, PNG 172 | 8개 통과, PNG 167 |
| iPad Air 11-inch | 첫 실행 1개 실패(아래) → 다시: 8개 통과, PNG 160 | 8개 통과, PNG 169 | 8개 통과, PNG 175 |
| Mac Catalyst | 8개 통과, PNG 107 | — | — |

**렌더링 도구의 수정.** ko의 첫 실행에서 `testRenderForgetConfirmationDialog`가 가장 큰 글자 크기에서 실패했다: 목록이
화면에 온 줄만 만들기 때문에 한 번 끝으로 옮겨서는 마지막 구역의 버튼에 닿지 못했고, 확인창이 뜨지 않았다. 제품 코드의
문제가 아니라 그리는 도구의 문제다: 끝이 더 움직이지 않을 때까지 옮기도록 고쳤고(`PowerBaseProductRenderingTests.render`),
그 뒤의 실행(en·es 전부, ko 재실행)은 통과했다. 이 수정은 전체 test 실행 **뒤에** 들어갔으므로 최종 트리에서 전체를 한 번
더 돌렸다(위 표).

**직접 열어 본 것**: iPhone 13 mini — ko 확인창(기본), ko 관리 화면(삭제 대기 + 목록 제거, 두 쪽), ko 알림(둘 함께),
ko 설정 전체, ko 확인창(가장 큰 글자 크기 첫 쪽), es 관리 화면(어두운 화면), en "알 수 없음"; iPhone 16 Pro Max — ko 센서
카드, es 확인창(대기 중 삭제 문장 포함), en 확인창(가장 큰 글자 크기 첫 쪽); iPad — ko 확인창(기본). 겹침·잘림이 없었다. 가장 큰 글자 크기의 확인창은 시스템의 좁은 창 안에서
스크롤되며(삭제 확인창과 같다), 그 쪽들도 그려 두었다. **나머지 장은 열어 보지 않았다.**

설정 탭: 긴 설명은 이미 줄어 있고 뜻이 빠진 곳을 찾지 못했다. 사용자 화면에 "Linux PC"는 없다("OTBR(조각보 허브)"로
돼 있다. DEBUG 전용 등록 시험 화면의 "Linux Bridge"는 그대로 두었다). 고친 것은 없다.

### 빌드와 산출물

| | 결과 |
|---|---|
| iOS Simulator Debug·Release, Mac Catalyst Debug·Release (서명 없는 빌드) | 넷 다 성공. 경고 수는 `1.2.1 (12)`와 같다(84·16·42·8). `check_release_enrollment_surface.sh`와 `verify-bundle` 통과 |
| 서명된 기기용 Release 빌드(`pogo_app_version.py build`) | 성공. `manifest-verify --match-current-tree --expect-version 1.3.0`, `verify-bundle --expect-identity`, `check_release_enrollment_surface.sh release`, `codesign --verify --deep --strict` 통과. 빌드 입력 375개가 빌드 전후 같다 |
| 산출물 | `~/esp-builds/pogoforget_20261010_app_device_release_signed/artifact/PogoHome.app`, `manifest.json` SHA-256 `5de92cbffafa6bd1b8522691069af986ddc27cbe16ffe82747b4e2c6e9936fce`, 실행 파일 SHA-256 `a8a394196c4f23b1003c21ef025028ffd3ec02847517daf504ae4781673afc27`. development, `deployed=false`, `hardware_verified=false` |
| 앱·위젯·Watch 앱·Watch 위젯 | 넷 다 `1.3.0 (13)`(설치 확인 도구가 번들마다 읽었다) |
| 프로파일 | 서명 유효. 2026-10-12 02:22 UTC(한국 시간 10월 12일 11:22)에 만료. iPhone 앱·위젯의 프로파일에 기기 2대, Watch 앱·위젯에 1대(대수만 읽었다) |
| 설치 확인 도구((13)용 사본, 준비물의 `tools/`) | 자체 시험 24개 실패 0, `candidate` exit 0 |

### 하지 않은 것

- **실물 전부.** 설치, 실행, 실제 허브(0.4.0은 Linux에서 빌드된 적도 없다), 실제 Power Base, 실제 iPhone 13 mini와
  iPhone 16 Pro Max, 두 기기의 동시 사용, 실제 백그라운드 전환, VoiceOver의 실제 음성.
- 두 실제 기기가 이 앱의 프로파일에 들어 있는지: 확인하지 못했다(대수만 읽었다). 확인 방법은 준비물의
  `tools/app_install_check.py device`.
- Watch 시뮬레이터, 위젯의 실제 화면.
- iPad·Mac Catalyst의 en·es 렌더링 일부(위 표의 "—").
- 관리 화면에 남는 "알 수 없음": 응답을 잃은 뒤 그 Base가 다른 기기의 요청으로 제거되고 **다시 등록되면**, 이 기기의
  관리 화면에는 이전 요청의 "알 수 없음"이 다시 보인다("다시 확인"을 누르면 허브가 `stale_record`로 답하고 안내가 바뀐다).
  잘못된 동작은 아니지만 정리하지 않았다. (2026-10-10에 덧붙임: `1.3.1 (14)`에서 정리했다. 위 "목록 제거 후속 수정"의 "응답
  유실 + 다른 기기의 제거".)

## 기기 탭 센서 카드의 간격 (2026-10-10, `1.2.1 (12)`)

기기 탭의 조각보 센서 카드에서 센서 이름 바로 밑에 방 이름이 붙어 있던 것을 떼었다. 이름과 방 이름 사이 6pt,
방·연결 관계·상태 사이 2pt. `DevicesView.swift`의 `DeviceCard`에서 그 줄들의 위쪽 여백으로 주었고(카드 전체의
spacing은 0 그대로), 글자 크기 설정을 따라 커진다(`@ScaledMetric`, caption 기준). 문구, 줄 수 제한, 아이콘, 색,
VoiceOver의 이름·값 수식어, 카드의 동작은 고치지 않았다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.1 (11)`, 소스 지문 `a9d80f305af6ac0b8e396b82e4757a97578cc290654c4b8cf627011abed944f8`. status 133줄(미추적 60), stage 0, index SHA-256 `e8dc6c3b…a3580`. 작업 지시가 적은 값과 모두 같았다 |
| 작업 후 | `1.2.1 (12)`, 소스 지문 `68eacecb8174f94d2382352b012b433f590954392e1c9d4e2ed3f10efba0f9df`, 빌드 식별자 `05375341f70d+dirty.68eacecb8174` |
| 도구 | Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임, 시뮬레이터 "PogoHome iPhone 13 mini" |
| 출력 | `~/esp-builds/pogoappcard_20261010_results`(로그·렌더링·diff·설치 확인 도구의 (12)용 사본), `~/esp-builds/pogoappcard_20261010_app_device_release_signed`(산출물). `1.2.1 (11)` 이하의 산출물은 그대로다 |

### 그림으로 본 것

새 렌더링 `AdaptiveScreenRenderingTests/testRenderDeviceCards`: 실제 `AppRootView`의 기기 탭을 test host의 창에
그린다. test가 만든 센서 7개(이름 한 줄·두 줄·잘리는 긴 이름, 긴 방 이름, 방 미지정, 연결 관계 한 줄·두 줄·없음,
온라인·오프라인·Power Base 연결 끊김)이고, 화면 폭은 iPhone 13 mini다(창은 화면보다 길게 잡았다).

| | 결과 |
|---|---|
| 수정 전 소스, ko·en·es | 각 1개 test 통과, PNG 7·7·8장. 이름과 방 이름이 붙어 있는 것이 그대로 보인다 |
| 처음 시도(텍스트를 VStack 둘로 묶음) | **버렸다.** 연결 관계 두 줄이 한 줄로 잘리고 가장 큰 글자 크기에서 이름 위에 빈 자리가 생겼다(ko·es 렌더링) |
| 최종 소스, ko·en·es, 밝은 화면·어두운 화면·가장 큰 글자 크기 | 각 1개 test 통과, PNG 7·7·8장. **직접 열어 본 것**: ko·en의 밝은 화면, es의 어두운 화면, ko·es의 가장 큰 글자 크기 일부, 수정 전과 나란히 놓은 그림 2장. 줄 수와 줄바꿈이 수정 전과 같고 겹침·잘림이 없다 |
| 카드 높이(밝은 화면의 그림에서 잰 값) | 연결 관계 줄이 있는 카드 +10pt, 없는 카드 +8pt. 최소 높이에 못 미치던 카드(ko의 한 줄 이름 카드)는 +3.5pt |
| 기존 렌더링 `testRenderTabsAndSheets`, ko·en·es | 각 1개 test 통과, PNG 30장씩. 기기 탭(실제 화면 크기)의 ko 밝은 화면과 es 어두운 화면을 열어 봤다 |
| 실제 `DevicesView`를 띄우는 `PowerBaseRemovalCompletionScreenTests`, ko | 15개, 실패 0 |
| Mac Catalyst, ko: 같은 렌더링 | 1개 test 통과, PNG 12장. 좁은 창(카드 배치)의 어두운 화면을 열어 봤다 |

### 빌드와 산출물

| | 결과 |
|---|---|
| iOS Simulator Debug·Release, Mac Catalyst Debug·Release (서명 없는 빌드) | 넷 다 성공. `check_release_enrollment_surface.sh`와 `verify-bundle` 통과 |
| `Scripts/test_pogo_app_version.py` | 181개, 실패 0. `check`: 여섯 타깃이 `1.2.1 (12)`를 쓴다 |
| 서명된 기기용 Release 빌드(`pogo_app_version.py build`) | 성공. `manifest-verify --match-current-tree --expect-version 1.2.1`, `verify-bundle --expect-identity`, `check_release_enrollment_surface.sh release`, `codesign --verify --deep --strict` 통과. 빌드 입력 373개가 빌드 전후 같다 |
| 산출물 | `~/esp-builds/pogoappcard_20261010_app_device_release_signed/artifact/PogoHome.app`, `manifest.json` SHA-256 `d236d18d95ab682c1944fdb356565448f5f4abd82ea37957909466f852671bca`. development, `deployed=false`, `hardware_verified=false` |
| 프로파일 | 2026-10-12 02:22 UTC(한국 시간 10월 12일 11:22)에 만료된다. 그 뒤에는 새 빌드가 필요하다 |

### 하지 않은 것

- 실물 전부(설치, 실행, 실제 허브·보드). iPad 시뮬레이터, 전체 test 묶음, Watch.
- VoiceOver의 실제 음성과 접근성 트리의 읽기. 카드의 이름·값 수식어는 diff에서 바뀌지 않았다는 것만 확인했다.
- 렌더링의 나머지 장(en·es의 가장 큰 글자 크기 대부분, 어두운 화면의 ko·en)은 열어 보지 않았다.

## 삭제 확인창의 문구 한 문장 (2026-10-09, `1.2.1 (11)`)

Power Base 삭제 확인창의 마지막 문장을 "다시 쓰려면 새로 등록해야 합니다."에서 **"다시 사용하려면 새로 등록해야
합니다."**로 바꿨다. 바뀐 것은 `PowerBaseManagementPresentation.swift`의 `confirmRegisterAgain` 원문과
`Localizable.xcstrings`의 그 키 하나다. 영어·스페인어 번역, comment, 문장이 나오는 조건, 코드의 동작은 그대로다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.1 (10)`, 소스 지문 `84515000eeb8a6f1599be141decf2e7bcd7b65723310d17b80b5c6ba62aac0c3`, 빌드 식별자 `05375341f70d+dirty.84515000eeb8`. status 133줄(미추적 60), stage 0. 작업 지시의 `baseline.json`(파일 379개의 SHA-256)과 모두 일치 |
| 작업 후 | `1.2.1 (11)`, 소스 지문 `a9d80f305af6ac0b8e396b82e4757a97578cc290654c4b8cf627011abed944f8`, 빌드 식별자 `05375341f70d+dirty.a9d80f305af6` |
| 도구 | Xcode 27.0, iOS 27.0 SDK·시뮬레이터 런타임, 시뮬레이터 "PogoHome iPhone 13 mini" |
| 출력 | `~/esp-builds/pogoappword_20261009_results`(보고서·로그·렌더링·diff·설치 확인 도구의 (11)용 사본), `~/esp-builds/pogoappword_20261009_app_device_release_signed`(산출물). `1.2.1 (10)` 이하의 산출물은 그대로다 |

### 실행한 것

| 검사 | 결과 |
|---|---|
| 관련 test, iPhone 시뮬레이터, ko: `PowerBaseSetupPresentationTests`, `PowerBaseAutomaticRemovalTests`, `LocalizationCatalogTests`, `AppModelPowerBaseManagementTests` | 65개, 실패 0, 건너뜀 0. 새 test는 만들지 않았다. 이 문장을 값으로 고정한 test는 없고(상수 `confirmRegisterAgain`을 참조한다), 카탈로그에 영어·스페인어 번역이 있는지는 ko 실행의 `testEveryWordOfTheProductScreensIsTranslatedToEnglishAndSpanish`가 본다 |
| 같은 test, en / es | 각 65개, 실패 0, 건너뜀 1(위의 번역 검사는 ko에서만 실행된다) |
| 카탈로그 | 이전 키는 없고 새 키의 en "To use it again, you’ll need to register it anew.", es "Para volver a usarla, tendrás que registrarla de nuevo."가 이전과 같다. 파일의 diff는 키 한 줄이다 |
| 버전 도구 `Scripts/test_pogo_app_version.py` | 181개, 실패 0. `check`: 여섯 타깃이 `Version.xcconfig`의 `1.2.1 (11)`을 쓴다 |
| 확인창 렌더링(`PowerBaseProductRenderingTests/testRenderDeleteConfirmationDialog`, 실제 `confirmationDialog`) | ko 16장, en 21장, es 22장. **직접 열어 본 것은 3장**: ko 기본 크기와 가장 큰 글자 크기의 마지막 쪽에 "다시 사용하려면 새로 등록해야 합니다."가 보이고 잘리지 않는다. en 기본 크기는 이전 문장 그대로다 |
| 서명된 기기용 Release 빌드(`pogo_app_version.py build`) | 성공. `manifest-verify --match-current-tree --expect-version 1.2.1`, `verify-bundle --expect-identity`, `check_release_enrollment_surface.sh release`, `codesign --verify --deep --strict` 통과. 빌드 입력 373개가 빌드 전후 같다 |

### 하지 않은 것

- 실물 전부(설치, 실행, 실제 허브·보드). iPad·Mac Catalyst의 test와 렌더링, 전체 test 묶음, Watch.
- en·es 렌더링의 나머지와 ko의 나머지 13장은 열어 보지 않았다(문장이 바뀌지 않은 언어이거나 같은 문장의 다른 상태다).

## 삭제 완료 안내의 후속 수정 (2026-10-09, `1.2.1 (10)`)

`1.2.1 (9)`의 검토에서 나온 세 가지다. ① 아직 읽지 못한 이전 완료 기록을 방금 한 삭제 요청의 완료로 오인, ② 한
보고에 완료가 여럿이면 하나만 전달, ③ 완료 안내가 앱이 보이지 않는 동안 지나가 버릴 수 있음(검토에서는 코드상의
공백으로 지적됐다). 내용은 [`CHANGELOG.md`](../CHANGELOG.md) "수정"의 첫 항목.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 Bluetooth·보드·허브를 쓰지
않았다. 세 가지 모두 실물에서 본 것이 아니라 검토와 Mac의 test에서 나온 것이다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.1 (9)`, 소스 지문 `ab75fc50fe65ea9ca454cd55f7e46a8058df6935a908c952cef04ec1b3362a0a`, 빌드 식별자 `05375341f70d+dirty.ab75fc50fe65`. status 132줄(미추적 59), stage 0. 검토 자료의 `baseline.json`(파일 378개의 SHA-256)과 모두 일치 |
| 작업 후 | `1.2.1 (10)`, 소스 지문 `84515000eeb8a6f1599be141decf2e7bcd7b65723310d17b80b5c6ba62aac0c3`, 빌드 식별자 `05375341f70d+dirty.84515000eeb8` |
| 도구 | macOS 26.6.2, Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK(`iphoneos27.0`, Watch는 `watchos27.0`)·시뮬레이터 런타임. 시뮬레이터 "PogoHome iPhone 13 mini", "iPad (A16)" |
| 출력 | `~/esp-builds/pogoappux2_20261009_results`(보고서·로그·수정 전 재현·렌더링·diff·후속 안내), `~/esp-builds/pogoappux2_20261009_app_device_release_signed`(산출물). `1.2.0 (8)`, `1.2.1 (9)` 산출물은 그대로다 |

펌웨어·허브 저장소는 읽기만 했고 한 파일도 바뀌지 않았다.

### 수정 전 재현 (`1.2.1 (9)` 소스, 앱의 실제 controller와 실제 화면)

검토의 재현은 소스 사본에서 `@Observable`을 뺀 대역이었다. 여기서는 `1.2.1 (9)` 소스에 test 파일만 더해 실행했다.
출력의 `repro_before_fix/`에 그 test 소스와 결과가 있다(이 test들은 `(9)`의 API로 쓴 것이라 지금 트리에는 없다. 같은
시나리오가 새 API로 아래 "test"에 들어 있다).

| | 수정 전 결과 |
|---|---|
| ① 요청을 보내는 중에 목록 조회가 같은 Base의 이전 `completed`만 돌려줌 (실제 `PowerBaseRemovalController`, 응답을 붙잡아 둠) | **실패**: 요청이 아직 `requesting`인데 이전 작업 ID로 완료가 기록됨 |
| ① 같은 순서, 실제 `PowerBaseManagementSheet`를 띄운 채 | **실패**: 삭제를 요청만 한 Base의 시트가 닫힘 |
| ② 두 Base의 진행 중을 본 뒤 한 보고에서 둘 다 `completed` (두 순서) | **실패**: 한 Base만 전달되고, 같은 보고를 다시 줘도 나머지는 나오지 않음 |
| ② 같은 보고, 각 Base의 시트를 띄운 채 (시트 2 × 순서 2) | **실패**: 목록의 마지막이 아닌 Base의 시트가 닫히지 않음 |
| ③ 안내가 떠 있는 채 앱을 **실제로** 백그라운드로 보냄 (시뮬레이터) | **실패**: 백그라운드에 있는 동안 안내의 시간이 다 지나감(닫힘 호출 1회) |

### 수정

- **① 인과.** `PowerBaseRemovalCompletions`가 Base로 요청을 기다리던 것(`willRequest`)을 없앴다. 완료는 작업 ID로만
  묶인다: 진행 중인 것을 본 그 ID이거나, 허브가 이 기기의 요청(`POST …/power-base-removals`)이나 확인
  (`POST …/receipt`)에 답하며 준 그 ID다(`observeAnswer`). 응답 자체가 `completed`인 경우, 목록이 먼저 그 작업을
  `completed`로 보여 준 뒤 응답이 온 경우(응답이 더 오래된 말 "pending"이어도)는 응답이 올 때 한 번 알린다.
  **남는 한계:** 응답을 잃었고 진행 중인 것도 못 본 작업이 완료로 나타나면 알리지 않는다. 허브의 `completed`
  원본과 목록 정리(그 Base와 요청 행이 빠짐)는 그대로다.
- **② 전달.** controller가 완료를 하나의 칸(`completion`)에 덮어쓰던 것을, 순서 번호가 붙은 사건 목록
  (`completionEvents`, 덧붙이기만 함)과 안내 대기열(`PowerBaseRemovalNotices`)로 나눴다. 관리 시트는 자기가 열릴 때의
  번호를 기억하고, **그 뒤에 기록된 자기 Base의 완료**에 닫힌다(지금 떠 있는 안내와 무관). 안내는 대기 중인 것을
  한꺼번에 한 줄씩 보여 주고, VoiceOver에는 하나씩 요청한다.
- **③ 표시 시점.** 완료는 허브의 말이 올 때 기록한다(앱이 어디에 있든). 안내를 보여 주고, VoiceOver에 알리고,
  5초를 세는 것은 `DevicesView`가 "지금 화면에 있다"고 판단할 때만이다: `scenePhase == .active`, 창의 선택된 탭이
  기기 탭, 기기 탭 위에 시트 없음. 그 조건이 깨지면 떠 있던 안내는 대기열 맨 앞으로 돌아가고(시간을 세던 task는
  취소된다), 다시 화면에 오면 **처음부터** 보여 주고 다시 알린다. 끝까지 보여 준(또는 사용자가 눌러 닫은) 안내는
  다시 나오지 않는다. 관리 시트도 `scenePhase == .active`일 때 닫힌다.
- 다른 허브로 바꾸면 사건 목록과 안내 대기열을 비운다(번호는 이어진다). 허브의 완료 판정, 원본 snapshot,
  `PowerBaseReleaseEvidence`, 재등록 뒤의 표시 판정(`removal(for:in:answered:)`)은 바꾸지 않았다.

### test (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, 전체 `PogoHomeTests` (`-testLanguage ko`) | **1,169개 중 통과 1,148, 실패 0, 건너뜀 21**(환경 변수가 있어야 도는 렌더링 harness들). `1.2.1 (9)`의 1,144개에서 25개 늘었다 |
| 같은 시뮬레이터, 삭제·문구 관련 14개 클래스 (`en`, `es`) | 각각 159개 중 통과 157, 실패 0, 건너뜀 2(한국어 실행 전용 test 둘) |
| iPad (A16) 시뮬레이터, 같은 14개 클래스 (`ko`) | 159개 중 통과 159, 실패 0 |
| Mac Catalyst, 관련 24개 클래스 (`ko`) | 272개 중 통과 264, 실패 0, 건너뜀 8: 실제 백그라운드 전환 4개와 실제 탭 화면 1개(아래), 빌드 상세 렌더링, 심벌 폭 측정, iOS 전용 잘림 재현 |
| 버전 도구 `Scripts/test_pogo_app_version.py` | 181개, 실패 0. `check`: 여섯 타깃이 `Version.xcconfig`의 `1.2.1 (10)`을 쓴다 |

완료 안내의 test는 49개다(`(9)`에서 24개): 완료 판정 8, 안내 대기열 3, 흐름 19, 실제 화면 15, 실제 scene 전환 4.

- **①**: 판정 단위 3개(응답이 이름을 댄 작업은 언제 완료되든 / 같은 Base의 이전 완료는 요청의 완료가 아님 / 응답도
  진행 상태도 없으면 알리지 않음), 흐름 3개(응답 보류 중 이전 완료를 읽어도 무소식이고 새 작업의 완료만 알림 /
  응답이 바로 `completed`, 목록이 응답보다 빠른 경우 / 응답 분실 + 진행 상태 미관측은 무소식이지만 목록은 허브를
  따름), 화면 1개(요청 중인 Base의 시트가 열려 있고, 새 작업이 완료되면 닫힘).
- **②**: 판정 단위 1개(세 작업, 세 순서), 흐름 1개(두 순서: 둘 다 순서대로 기록되고 두 시트 모두 닫히는 조건,
  함께 표시, 반복 보고·목록·늦은 응답에 중복 없음), 화면 2개(시트 2 × 순서 2에서 시트가 닫힘 / 기기 탭에 한
  안내가 두 Base를 한 줄씩, VoiceOver 요청 2회).
- **③, 실제 scene 전환(iOS 시뮬레이터, `PowerBaseRemovalRealSceneTests`)**: test host인 앱을 `-[UIApplication suspend]`로
  실제로 백그라운드에 보내고 `LSApplicationWorkspace`로 다시 연다(둘 다 test 코드에서만 쓰는 비공개 호출).
  `UIApplication.applicationState`가 `.background`/`.active`가 되는 것을 확인하고, 화면에는 UIKit의 실제 전환 알림에서
  얻은 phase를 준다. `AppModel`은 `PogoHomeApp`이 하듯 phase에 맞춰 멈추고 시작한다.
  - foreground에서 요청(응답 보류) → 백그라운드 → 요청의 응답과 목록의 `completed`가 백그라운드에서 도착 → 완료는
    기록되지만 안내·VoiceOver 요청 0, 시트 열린 채, 안내 시간(1.2초)보다 오래(1.8초) 있어도 그대로 → 복귀 → 시트
    닫힘, 안내 표시, VoiceOver 요청 1회 → 제 시간 뒤 사라짐 → 다시 나갔다 와도 재안내 없음.
  - 안내가 떠 있는 도중 백그라운드 → 대기열로 돌아감, 안내 시간(3초)보다 오래(3.5초) 있어도 소진되지 않음 →
    복귀 → 처음부터 다시(1.5초 뒤에도 떠 있고, 복귀 2.5초 뒤 이후에 사라짐), VoiceOver 요청은 모두 2회 → 그 뒤로는
    전환·반복 보고에도 없음.
  - "삭제 확인"의 `completed` 응답이 백그라운드에서 도착 → 시트는 복귀 때 닫힘.
  - 도우미 자체: 앱이 실제로 나갔다 돌아온다.
- **③, 가려진 동안(화면 test, phase는 `.active`로 줌)**: 다른 Base의 관리 시트가 기기 탭을 덮은 동안 완료 → 안내
  시간보다 오래 기다려도 무소식, 덮은 시트는 닫히지 않음, 시트를 닫으면 1회 / 다른 탭이 선택된 동안 → 같은 방식 /
  앱의 실제 탭 화면(`AppRootView`)에서 설정 탭으로 간 뒤 완료, 5.5초 뒤 기기 탭으로 돌아오면 안내가 있음 / 완료된
  Base의 시트가 닫힌 뒤 그 안내가 뜸.
- **허브 변경·화면 이탈**: 요청 보류 중 다른 허브로 바꾸고 그 허브에서 같은 Base의 시트를 연 뒤 이전 허브의
  `completed` 응답이 도착 → 사건 0, 안내 0, 시트 열린 채 / 이전 허브에서 받아 두고 아직 못 보여 준 안내는 허브를
  바꾸면 버림 / 시트를 닫고 다른 Base의 시트를 연 뒤 응답 도착 → 열린 시트는 그대로, 닫으면 안내 1회 / 완료 뒤에
  연 시트(재등록한 Base)는 같은 완료가 다시 보고돼도 열려 있음.
- **그대로 통과하던 것**: 재등록 뒤 이전 완료가 삭제를 막지 않음(`PowerBaseReenrolledAfterRemovalTests` 7개),
  온라인 한 번의 요청 → 안내 → 목록 정리, 오프라인 대기·취소, 수동 확인과 결과 확인 불가, 앱 재시작 무소식,
  목록·snapshot의 순서와 중복, 재등록 뒤 허브 재시작에서 센서·방 유지, 기존 `PowerBaseReleaseEvidence` test 전부.

대기: 새 test는 응답 보류(`FakeRemovalHub.hold/release`)와 조건 polling(`waitUntil`)으로 맞춘다. 실제로 시간을
보내는 곳은 "시간이 소진되지 않는다"를 보이기 위한 것뿐이다(안내 시간을 0.4~3초로 줄이고 그보다 조금 더 기다린다.
앱의 실제 5초를 쓰는 곳은 실제 탭 화면 test 하나, 5.5초). 작업 중 한 번 실패한 것: 내 test의 준비 순서(기기 탭이
첫 snapshot을 controller에 넘기기 전에 완료를 보낸 것). 탭이 넘겼다는 것(`reportedSource`)을 기다리게 고쳤다.

### 렌더링

완료 안내만 바뀌었다(한 Base, 두 Base). `render/<기기>-<언어>/`: iPhone 13 mini ko·en·es, iPad ko, Mac Catalyst ko,
각각 밝은·어두운 화면과 가장 큰 글자 크기. **30장을 만들었고 직접 열어 본 것은 5장**이다(iPhone ko 두 Base 기본·가장
큰 글자, en 두 Base 어두운 화면, es 두 Base 가장 큰 글자, Catalyst ko 두 Base 어두운 화면). 줄바꿈은 되고 잘림은
없다. 가장 큰 글자 크기에서 두 Base의 안내는 iPhone 13 mini 화면 높이의 절반 넘게 차지한다(5초 동안).

### 빌드와 산출물

서명 없는 빌드 다섯(Debug·Release × iOS Simulator, Debug × iOS 기기, Debug·Release × Mac Catalyst): 모두 성공,
`check_release_enrollment_surface.sh` debug/release 통과, `verify-bundle`로 `1.2.1 (10)`.

설치 후보(`Scripts/pogo_app_version.py build --configuration Release --destination 'generic/platform=iOS'`).
**개발 빌드다**(커밋하지 않은 트리, Release 구성, 서명됨). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pogoappux2_20261009_app_device_release_signed/artifact/PogoHome.app` |
| 버전 | `1.2.1`, 빌드 번호 `10`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.2.1 (10)` |
| 빌드 식별자 | `05375341f70d+dirty.84515000eeb8` (개발, dirty) |
| 소스 지문 | `84515000eeb8a6f1599be141decf2e7bcd7b65723310d17b80b5c6ba62aac0c3` |
| manifest SHA-256 | `92edf536267cef1a8bc81df4d828a45261ac8dd94ccb80a884a60bce0a7927e1` |
| 실행 파일 SHA-256 | `f38eba4b2a7977f1f371dbc50f750ebae93757b9b1c467f4dd811855398a0d89` |
| toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), `Release-iphoneos`, SDK `iphoneos27.0`/`watchos27.0`, 최소 OS 26.0 |
| 빌드 입력 | 373개 파일의 SHA-256이 빌드 전후 같다. manifest의 `inputs_unchanged_during_build: true` |
| 대조 | `manifest-verify --match-current-tree --expect-version 1.2.1` 통과(번들 60개 파일), `verify-bundle --expect-identity` 통과, release 경계 검사 통과 |
| 상태 | manifest의 `deployed: false`, `hardware_verified: false` |
| 서명 | `codesign --verify --deep --strict` 유효. 앱·위젯·Watch 앱·Watch 위젯 각각 유효하고 서명 인증서가 그 프로파일의 것이다 |
| 프로파일 | **2026-10-12 02:22 UTC에 만료**(가장 이른 것). iPhone 쪽 프로파일에 기기 2대, Watch 쪽 1대. 어느 기기인지는 확인하지 않았다. 인증서 자체의 만료일은 따로 읽지 않았다 |

`1.2.0 (8)`(manifest `928e3b90…01cc07`)과 `1.2.1 (9)`(manifest `3df4654d…25c3c4`) 산출물은 바이트 그대로이고 자체
무결성 검증을 통과한다.

### 하지 않은 것

| 항목 | 상태 |
|---|---|
| iPhone에 설치·실행, 실제 허브·보드·Bluetooth | **미실행** |
| 실제 iPhone의 백그라운드 전환 | **미실행.** 시뮬레이터에서 앱을 실제로 백그라운드에 보냈다 되돌렸다. 기기는 백그라운드의 앱을 곧 멈춘다: 그사이 온 응답은 앱이 다시 돌 때 처리되고, 그때 완료가 기록되며 안내는 화면에 온 뒤다(같은 경로). 멈춘 동안 끊긴 요청은 실패로 끝나고 복귀 뒤 snapshot이 상태를 준다 |
| VoiceOver의 실제 음성, 시트가 닫히는 도중의 음성 | 미실행. 안내 요청이 나가는 시점과 횟수만 확인했다(요청 함수를 test에서 바꿔 끼웠다) |
| 도중에 가려진 안내를 다시 알리는 것이 VoiceOver 사용자에게 어떻게 들리는가 | 미확인. 정책으로 정한 것이다: 끝까지 보여 주지 못한 안내는 다시 보여 주고 다시 알린다 |
| Mac Catalyst에서의 실제 백그라운드 전환, 창이 활성이 아닐 때 | 미실행. Catalyst에서는 그 test를 건너뛴다. 코드상으로는 창의 phase가 `.active`가 아닌 동안 안내와 시트 닫기가 기다린다 |
| 응답을 잃고 진행 상태도 못 본 삭제의 완료 안내 | 하지 않는다(위 "남는 한계") |
| iPad·Catalyst의 전체 test, en·es의 iPad·Catalyst 렌더링, Watch 시뮬레이터 | 미실행 |
| 펌웨어·Linux 전체 시험 | 재실행하지 않았다(그쪽 코드는 바뀌지 않았다) |

## 재등록 뒤 삭제 차단 수정과 설명 정리 (2026-10-09, `1.2.1 (9)`)

세 가지를 한 빌드에 넣었다. ① 삭제가 완료된 Power Base를 다시 등록했을 때, 허브에 남아 있는 이전 삭제 기록
때문에 '삭제 완료'로 표시되고 다시 삭제할 수 없던 것의 수정, ② 삭제가 끝났을 때 한 번 안내하고 관리 화면을
닫고 목록에서 내리는 것, ③ 삭제 확인창·삭제 상태·설정 탭의 설명 정리와 허브 이름의 통일("허브", 처음 한 번
"OTBR(조각보 허브)"). 내용은 [`CHANGELOG.md`](../CHANGELOG.md) "수정"의 처음 세 항목.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 Bluetooth·보드·허브를 쓰지
않았다. 결함 자체는 사용자가 iPhone의 `1.2.0 (8)`에서 반복해 재현하고 알려 준 것이다(아래 "사용자 실물 보고").
**이 빌드가 실물 시험을 통과했다는 기록은 없다.**

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.0 (8)`, 소스 지문 `381c32dbfc93148485d57345796ccef1f12eb653aef2256a0ebe84ce101f8512`, 빌드 식별자 `05375341f70d+dirty.381c32dbfc93`. 변경 파일 122개(추적 66, 미추적 56), stage 0. 지시문과 함께 받은 `baseline.json`의 파일별 SHA-256 375개와 모두 일치 |
| 작업 후 | `1.2.1 (9)`, 소스 지문 `ab75fc50fe65ea9ca454cd55f7e46a8058df6935a908c952cef04ec1b3362a0a`, 빌드 식별자 `05375341f70d+dirty.ab75fc50fe65` |
| 도구 | macOS 26.6.2, Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임. 시뮬레이터 "PogoHome iPhone 13 mini"(375×812pt), "iPad (A16)" |
| 출력 | `~/esp-builds/pogoappux_20261009_results`(보고서·로그·렌더링·이번 변경만의 diff·후속 안내), `~/esp-builds/pogoappux_20261009_app_device_release_signed`(산출물). `1.2.0 (8)` 산출물은 그대로다 |

펌웨어·허브 저장소는 읽기만 했고 한 파일도 바뀌지 않았다.

### ① 결함: 재현, 원인, 수정

- **허브의 계약(읽어서 확인. 펌웨어 저장소 `docs/pogohome-api-v1.md`, `linux/matter_bridge/app/api/src/power_base_management.cpp`).**
  삭제 작업은 한 등록(EUI-64 + 등록 세대)에 묶인다. `completed`가 되면 허브는 그 등록의 키를 버리고, 그 보드를
  차단한 채 목록에서 내리며, 차단은 **새 등록 세대가 활성화될 때만** 풀린다. 끝난 작업은 10분 동안 snapshot의
  `power_base_removals`와 `GET /api/v1/power-base-removals`에 남고, 그사이 같은 보드가 다시 등록돼도 `completed`
  그대로다. 새 삭제 요청은 진행 중인 작업이 없으면 새 작업으로 받는다. 즉 **허브는 재등록한 Base의 삭제를 막지
  않는다.** 이 보관 기간은 바꾸지 않았다.
- **재현(수정 전 소스).** `PowerBaseReenrolledAfterRemovalTests` 7개를 `1.2.0 (8)` 소스(test 파일만 추가)에서
  실행: **7개 모두 실패**(`logs/repro_before_fix.summary.json`). 허브의 JSON을 실제 `LiveSensorDataSource`·
  `PogoSnapshotMapper`·`AppModel`·`PowerBaseRemovalController`에 흘려 넣고, 화면이 읽는 값과 실제 SwiftUI 화면이
  VoiceOver에 내놓는 글을 본다. 실패 내용이 실물 보고와 같다: 기기 목록의 Base 행이 `Power Base ··b3c4, 연결됨 ·
  모듈 2/2개 온라인, 삭제 완료`, 관리 화면에 '삭제 완료' 설명이 있고 "Power Base 삭제" 버튼이 없음, 판정
  `removalExists`. 온라인·오프라인 새 등록, 앱을 새로 시작한 첫 snapshot, 목록 조회 응답이 먼저/나중인 경우,
  이전 작업이 남은 채 새 삭제를 요청한 경우가 들어 있다.
- **원인.** `PowerBaseManagementPresentation.availability`와 `badge`가 `.completed`를 진행 중인 작업과 똑같이
  다뤘고, 그 작업이 **지금 목록에 있는 Base의 것인지**를 묻는 곳이 없었다.
- **수정.** `PowerBaseRemoval.concernsPowerBase(listedByHub:)`와 `PowerBaseRemovalController.removal(for:in:answered:)`
  (순수 함수): 완료 작업은 허브가 그 Base를 싣지 않는 동안에만 그 Base의 작업이다. 시각·온라인 여부·허용치를
  쓰지 않는다. 진행 중인 작업이 있으면 그것이 언제나 보여 줄 작업이다(허브는 진행 중인 작업이 없을 때만 새
  작업을 만든다). `HomeSnapshot`, `AppModel`, `PowerBaseReleaseEvidence`는 바꾸지 않았다: 허브가 보낸 작업
  목록과 센서 보존 판정은 그대로다.

### ② 완료 안내와 정리

- `PowerBaseRemovalCompletions`(값 타입, 시각 비교 없음): 앱이 **진행 중인 것을 본** 작업이 `completed`가 되는
  변화만 한 번 알린다. 처음부터 `completed`로 읽은 작업, 다시 보고된 `completed`, 뒤늦게 온 이전 응답 뒤의
  `completed`, 취소·대체로 끝난 작업, 같은 Base의 새 작업이 진행 중일 때 나타난 이전 작업의 완료는 알리지 않는다.
  이 기기가 삭제를 요청한 직후 처음 보는 작업이 이미 `completed`인 경우(응답을 잃었고 허브가 더 빨랐다)는 알린다.
  허브가 바뀌면 처음부터다.
- 기기 탭(`DevicesView`)이 snapshot의 작업 목록을 첫 snapshot부터 controller에 넘긴다(목록의 행이 아니라 탭에
  붙였다). 안내는 탭 아래의 `PowerBaseRemovalCompletionNotice`(5초, 누르면 닫힘, VoiceOver 안내 게시), 관리 시트는
  자기 Base의 완료에만 닫힌다. "삭제 확인" 화면은 허브의 `completed` 응답을 controller에 넘기고 같은 길로 닫힌다.
- 배경에서 끝난 작업의 규칙은 하나다: 이 실행에서 진행 중인 것을 봤으면 돌아와서 한 번 알리고, 아니면(앱을
  새로 시작했으면) 알리지 않는다. 어느 쪽이든 목록에는 남지 않는다.

### test (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, 전체 `PogoHomeTests` (`-testLanguage ko`) | **1,144개 중 통과 1,123, 실패 0, 건너뜀 21**(환경 변수가 있어야 도는 렌더링 harness들). `1.2.0 (8)`의 1,110개에서 34개 늘었다 |
| 같은 시뮬레이터, 문구·삭제 관련 12개 클래스 (`en`, `es`) | 각각 134개 중 통과 132, 실패 0, 건너뜀 2(한국어 원문으로 번역을 찾는 test 둘: 한국어 실행 전용) |
| iPad (A16) 시뮬레이터, 같은 12개 클래스 (`ko`) | 134개 중 통과 134, 실패 0 |
| Mac Catalyst, 관련 22개 클래스 (`ko`) | 247개 중 통과 244, 실패 0, 건너뜀 3(빌드 상세 렌더링, 심벌 폭 측정, iOS 전용 잘림 재현) |
| 버전 도구 `Scripts/test_pogo_app_version.py` | 181개, 실패 0. `check`: 여섯 타깃이 `Version.xcconfig`의 `1.2.1 (9)`를 쓴다 |

새 test 34개:

- `PowerBaseReenrolledAfterRemovalTests`(7): 위 재현. 수정 후 통과.
- `PowerBaseRemovalCompletionsTests`(5): 어떤 완료가 소식인가(위 ②의 규칙 하나하나).
- `PowerBaseRemovalCompletionFlowTests`(15): 온라인 Base의 요청 한 번 → 안내 한 번 → 목록에서 사라짐 / 오프라인
  대기와 취소 / 오프라인 Base가 돌아와 삭제됨 / 수동 확인(released)과 결과 확인 불가에서의 수동 확인, 그 뒤 정리 /
  앱 재시작 뒤 무소식 / foreground 복귀 때 한 번, 두 번째 복귀 때 무소식 / 목록 조회와 snapshot의 순서·중복·뒤늦은
  이전 응답 / 목록 조회 실패 / 요청 응답 분실 / 거절된 요청 / 이전 작업의 늦은 응답이 새 작업을 덮지도 닫지도
  않음 / snapshot이 따라잡은 응답이 나중에 되살아나지 않음 / 다른 허브는 처음부터, 이전 허브의 늦은 응답 무시 /
  재등록 뒤 허브 재시작(빈 목록)에서 센서·방 지정·이름 유지.
- `PowerBaseRemovalCompletionScreenTests`(4): 실제 `PowerBaseManagementSheet`를 `.sheet`로 띄워 자기 Base의 완료에
  닫히고(released에서는 열려 있음), 이전 완료 기록·다른 Base의 완료에는 열려 있음 / 실제 `DevicesView`에서 "삭제 중"
  행 → 요청 목록 → 안내 한 번, 행 없음 / 안내가 Base 이름과 함께 한 요소로 읽히고 스스로 사라짐.
- `PowerBaseAutomaticRemovalTests`에 확인창이 모든 분기에서 한 문단 두세 문장임을 보는 test 1개, 렌더링 harness 2개
  (확인창, 안내).

기존 test 가운데 고친 것: "최근 삭제한 Power Base" 묶음과 1시간 표시를 전제한 단언(완료 작업은 이제 목록에
없다), 확인창이 '삭제 완료'·'삭제 중'을 이름으로 말한다는 단언(이제 분기별 한 문장), 내부 용어 금지 목록에
"등록 해제", "가입 정보"와 en/es의 같은 말을 더했다. 등록 결과 두 문장은 줄였다가 되돌렸다: 기존 test가
"보드는 초기화하지 않았습니다"가 그 문장에 있기를 요구한다.

고정 대기: 새 test의 동기화는 기존 `waitUntil`(조건 polling)이다. 화면 test는 SwiftUI가 접근성 트리를 만들
시간으로 0.6초를 쉬고, "시트가 닫히지 않는다"를 보는 한 곳에서 0.4초, 이전 허브의 늦은 응답을 기다리는 한
곳에서 0.06초를 쉰다(기존 test와 같은 방식).

### 렌더링 (화면을 실제로 그려 확인)

`render/<기기>-<언어>/`. 바뀐 화면만: 관리 시트 5개 상태, 삭제 확인창 3개 분기, 완료 안내, "삭제 확인" 3개 상태,
기기 목록의 Base 행과 요청 목록, 기기 추가 시트, 설정 탭. 밝은·어두운 화면과 가장 큰 글자 크기, 끝까지
스크롤하며 한 화면씩.

| | PNG |
|---|---|
| iPhone 13 mini: ko / en / es | 99 / 114 / 119 |
| iPad (A16): ko / en | 85 / 92 |
| Mac Catalyst: ko / en | 57 / 58 |

합계 624장. **직접 열어 본 것은 23장**이다: iPhone ko의 확인창(기본·어두운·가장 큰 글자), 안내(기본·가장 큰
글자), 관리 시트 2개 상태, "삭제 확인", Base 행과 요청 목록, 기기 추가, 설정 탭 전체 / en·es의 확인창, 관리
시트, es 설정 탭 전체, es 가장 큰 글자의 관리 시트 / iPad ko·en / Catalyst ko의 관리 화면, 안내, 설정. 본 것:
확인창의 가장 긴 분기가 기본 글자 크기에서 ko 9줄·es 15줄로 스크롤 없이 들어간다 / 가장 큰 글자 크기에서는
확인창 안에서 스크롤해 끝까지 읽힌다 / 안내는 가장 큰 글자에서 네 줄로 줄바꿈되고 잘리지 않는다 / 설정 탭과
관리 시트에 잘림·겹침이 없다.

본 것 그대로의 한계: 확인창은 iOS가 그리는 창이다. 가장 큰 글자 크기의 렌더링은 창이 뜬 뒤에 글자 크기를
덮어쓴 것이라 버튼 글자가 실제 기기와 다를 수 있다. **Mac Catalyst의 확인창은 그림에 없다**(별도의 창으로
뜬다. test는 창이 제시됐다는 것만 본다). VoiceOver는 접근성 트리의 글로 확인했고 실제 음성으로 듣지 않았다.

### 빌드와 산출물

| 빌드 (서명 없음) | 결과 |
|---|---|
| Debug · iOS Simulator / Release · iOS Simulator | 성공. `check_release_enrollment_surface.sh` debug / release 통과 |
| Debug · iOS 기기 | 성공. surface(debug) 통과 |
| Debug · Mac Catalyst / Release · Mac Catalyst | 성공. surface debug / release 통과 |

다섯 번들 모두 `verify-bundle`: 앱과 내장 번들이 `1.2.1 (9)`.

설치 후보: `GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`. **개발 빌드다**(커밋하지 않은 트리, Release 구성, 서명됨). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pogoappux_20261009_app_device_release_signed/artifact/PogoHome.app` |
| 버전 | `1.2.1`, 빌드 번호 `9`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.2.1 (9)` |
| 빌드 식별자 | `05375341f70d+dirty.ab75fc50fe65` (개발, dirty) |
| 소스 지문 | `ab75fc50fe65ea9ca454cd55f7e46a8058df6935a908c952cef04ec1b3362a0a` |
| manifest SHA-256 | `3df4654d266d34446afac10e17a3514398efa66d63aa54b87d9febfe0725c3c4` |
| 실행 파일 SHA-256 | `6529ca55af6ca2d339bcf7e99c08486567a6f5c50caa0eb30dc26407722a6dff` |
| toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), `Release-iphoneos` |
| 빌드 입력 | 372개 파일의 SHA-256이 빌드 전후 같다. manifest의 `inputs_unchanged_during_build: true` |
| 대조 | `manifest-verify --match-current-tree --expect-version 1.2.1` 통과, `verify-bundle --expect-identity` 통과, `check_release_enrollment_surface.sh … release` 통과 |
| 상태 | manifest의 `deployed: false`, `hardware_verified: false` |
| 서명 | `codesign --verify --deep --strict` 유효. 앱·위젯·Watch 앱·Watch 위젯 각각 유효하고 서명 인증서가 그 프로파일의 것이다 |
| 프로파일 | **2026-10-12 02:22 UTC에 만료**(가장 이른 것. iPhone 앱 프로파일은 02:23). 기기 2대(Watch 쪽 1대)가 들어 있다. 어느 기기인지는 확인하지 않았다. 인증서 자체의 만료일은 따로 읽지 않았다 |

`1.2.0 (8)` 산출물(`pogoappsearch_20261008_app_device_release_signed`, manifest `928e3b90…01cc07`)은 바이트 그대로이고
자체 무결성 검증도 통과한다. 지금의 트리와는 더 이상 일치하지 않는다(그것이 맞다).

### 사용자 실물 보고 (이 저장소에서 실행한 검증이 아니다)

2026-10-08, 앱 `1.2.0 (8)` + Power Base 0.2.0 + Linux bridge 0.2.0의 조합으로 사용자가 실물에서 시험하고 알려 준
것이다. 이 빌드(`1.2.1 (9)`)의 결과가 아니고, 여기서 다시 실행하지 않았다. 온라인 자동 삭제, 오프라인 대기·취소,
허브 재시작 뒤의 삭제, 자동 확인이 닿지 않은 뒤의 수동 확인은 완료됐다는 보고였고, **재등록 직후 이전 '삭제
완료' 표시와 삭제 버튼 차단, 기록 만료 뒤 버튼 복귀**가 반복해서 재현됐다는 보고가 이 수정의 출발점이다.

### 하지 않은 것

| 항목 | 상태 |
|---|---|
| iPhone에 설치·실행 | **미실행** |
| 실제 허브가 완료 기록을 내보내는 10분 동안의 재등록 Base 표시·삭제 버튼 | **미실행.** 허브의 JSON은 스크립트다(형식은 허브 코드와 문서에서 읽었다) |
| 실제 삭제가 끝났을 때의 안내와 시트 닫힘, "삭제 확인" 뒤의 닫힘 | **미실행** |
| VoiceOver가 안내를 실제로 읽는가, 시트가 닫히는 중에도 읽는가 | 미실행. 안내 게시 코드와 접근성 트리의 글만 확인했다 |
| 실제 기기의 가장 큰 글자 크기 확인창 | 미실행. 시뮬레이터 렌더링(위 한계)으로 확인했다 |
| Mac Catalyst의 확인창 모양 | 미확인 |
| Watch 앱 화면 | 바꾼 문구가 Watch 화면에 없다(설정의 Watch 설명은 iPhone 화면이다). Watch 시뮬레이터는 실행하지 않았다 |
| 펌웨어·Linux 전체 시험 | 재실행하지 않았다(그쪽 코드는 바뀌지 않았다) |

## 아이콘 잘림 수정과 자동 검색 (2026-10-08, `1.2.0 (8)`)

두 가지를 한 빌드에 넣었다. ① 가장 큰 글자 크기에서 목록 아이콘이 잘리던 것의 수정, ② "Power Base 추가"와
"다른 허브에 연결하기"에 들어오면 주변 보드 찾기를 스스로 시작하는 것. 내용은
[`CHANGELOG.md`](../CHANGELOG.md)의 "수정"·"추가" 첫 항목.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하거나 실행하지 않았고, 실제 Bluetooth·보드·허브를 쓰지
않았다. 실물에서 본 것은 `1.1.1 (6)`의 화면 한 장(잘린 아이콘)뿐이고, 실물에서 QR 입력이 통과했다는 기록도
`1.1.1 (6)`의 것이다. **이 빌드가 실물 시험을 통과했다는 기록은 없다.**

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.2.0 (7)`, 소스 지문 `553da7e84bb24e911c5df0b627bc92655d571f0398811980bc0cef064b6216df`, 빌드 식별자 `05375341f70d+dirty.553da7e84bb2`. 변경 파일 119개(추적 65, 미추적 54), stage 0 |
| 작업 후 | `1.2.0 (8)`, 소스 지문 `381c32dbfc93148485d57345796ccef1f12eb653aef2256a0ebe84ce101f8512`, 빌드 식별자 `05375341f70d+dirty.381c32dbfc93` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임, 시뮬레이터 "PogoHome iPhone 13 mini"(375×812pt) |
| 출력 | `~/esp-builds/pogoappsearch_20261008_results`(로그·렌더링·후속 안내), `…_app_device_release_signed`(산출물). 기존 `1.2.0 (7)` 산출물은 그대로다 |

펌웨어 저장소는 읽기만 했고 한 파일도 바뀌지 않았다.

### ① 아이콘: 재현, 원인, 수정

- **재현.** 수정하지 않은 `1.2.0 (7)` 소스의 "Power Base 추가" 화면을 iPhone 13 mini 시뮬레이터에서 가장 큰
  글자 크기(`accessibilityExtraExtraExtraLarge`)로 그리면 "주변에서 Power Base 찾기" 왼쪽 파형 아이콘의
  오른쪽이 잘린다(`render/before/iphone-ko-setup-start-axxl-p2.png`). 사용자가 보낸 화면과 같다.
- **원인(측정).** 아이콘 열은 `@ScaledMetric(relativeTo: .body)`의 `24pt`였고, 아이콘은 `Text(Image(systemName:))`로
  본문 글자 크기에 맞춰 그렸다. 글자 크기별로 실제 폭을 쟀다(`render/before/sheet-icon-widths.tsv`):

  | 본문 글자 | 17pt(기본) | 19pt | 23pt | 33pt | 53pt(가장 큼) |
  |---|---|---|---|---|---|
  | 열 (24pt를 `.body`로 scale) | 24.0 | 26.3 | 31.7 | 43.7 | **67.7** |
  | `dot.radiowaves.left.and.right` | 24.3 | 28.0 | 33.3 | 48.0 | **77.3** |

  열은 글자 스타일의 metric 곡선(가장 큰 크기에서 2.8배)을 따르고 심벌은 글자의 point size(3.2배)를 따른다.
  폭이 모자란 열에 놓인 `Text`가 심벌을 자른다. 19pt(xL)부터 어긋나고 가장 큰 크기에서 9.6pt가 모자란다.
  같은 이유로 `wifi.exclamationmark`(70.0), `powerplug.fill`, `camera`, `desktopcomputer.trianglebadge.exclamationmark`
  (85.3)도 잘렸다. **Mac Catalyst에서는 재현되지 않는다**(창이 Dynamic Type으로 글자를 키우지 않는다).
- **수정.** `SheetIconColumn`(`DesignSystem/SheetRowLayout.swift`): 기준 심벌 하나를 그 줄의 글자로 보이지 않게
  그려 열의 폭으로 삼고, 열은 `fixedSize`로 자기가 그리는 것보다 좁아지지 않는다. `SheetIconRow`와
  `SheetNumberedStep`이 이 열을 쓴다. 글자 크기를 낮추거나 Dynamic Type을 끄지 않았다. 아이콘은 VoiceOver에서
  숨기고(이전과 같다), 단계의 번호는 숨기지 않는다(이전과 같다).

### ② 자동 검색: 어디서 무엇을 결정하나

- 결정은 두 controller가 한다(`PowerBaseEnrollmentBLEController`, `PowerBaseLocalResetController`의 "Automatic
  search"). 화면은 화면 단위의 `onAppear`/`onDisappear`와 scene phase를 전할 뿐이고, 목록의 행에는 아무것도 붙이지
  않았다(행에 있던 "Bluetooth가 켜지면 다시 찾기" 처리도 controller로 옮겼다).
- 자동으로 시작되는 것은 `activate()`(Bluetooth 사용 시작)와 검색뿐이다. `start`, `verify`, `confirmReset`을
  부르는 경로는 추가하지 않았다.
- 조건: 화면이 보임 + foreground + phase `idle`(+ "Power Base 추가"는 쓸 수 있는 허브). 한 번의 등장에 한 번.
  백그라운드에서는 검색을 쉬고, 돌아오면 `resumeScanning()`으로 목록을 지우지 않고 이어 간다(새 provider
  메서드). 화면을 실제로 떠나면(잠깐 사라졌다 돌아오는 것은 제외) 끝낸다.
- "삭제 확인" 화면과 DEBUG "BLE 등록 시험"은 `automaticSearch`를 켜지 않았다: 이전 그대로 버튼으로 찾는다.

### test (iPhone 13 mini 시뮬레이터, 최종 트리)

| 대상 | 결과 |
|---|---|
| 전체 `PogoHomeTests` (`-testLanguage ko`) | **1,110개 중 통과 1,091, 실패 0, 건너뜀 19**(환경 변수가 있어야 도는 렌더링 harness들). `1.2.0 (7)`의 1,083개에서 27개 늘었다 |
| 새 `PowerBaseAutomaticSearchTests` (21개) | 진입 시 Bluetooth 사용 시작과 검색 1회 / 옵션이 없으면 시작하지 않음 / 반복 `onAppear`·잠깐 사라졌다 돌아옴에 재시작 없음 / 실제 이탈 시 종료, 재진입 시 새 검색(권한 요청은 다시 없음) / Bluetooth 꺼짐·거부·준비 중 → 켜지면 탭 없이 시작 / 백그라운드에서 등장하면 foreground까지 대기 / 백그라운드에서 쉼, 돌아오면 같은 목록으로 이어 감 / 쓸 수 없는 허브에서는 찾지 않음 / 진행 중·결과 화면·"결과 확인 불가"·초기화 확인 대기·실패 화면 위에서 시작하지 않음 / 그동안 보드 연결 0, 보드 명령 0, 허브 요청 0 / 두 화면을 실제 view로 띄워 진입·백그라운드·복귀·이탈 / 문구(ko 원문과 en·es 번역, 이전 문장 삭제) |
| 새 `SheetIconRowLayoutTests` (5개 + 측정 1개) | 모든 글자 크기 × 행에 쓰는 심벌 43개: 열이 심벌보다 좁지 않음 / 숫자와 진행 표시도 같은 열 / iPhone 13 mini 행 폭(303pt)에서 그린 픽셀로: 심벌이 온전하고(제약 없이 그린 폭과 같음) 글자가 그 오른쪽에서 시작 / **이전 방식의 열은 같은 검사에서 실제로 잘림**(검사가 실패할 수 있음을 보인다) / 버튼이 VoiceOver에서 제목으로 한 번만 읽히고 심벌 이름이 없음, 단계는 번호와 함께 읽힘 |
| 기존 관련 test | `PowerBaseEnrollmentBLEControllerTests`, `PowerBaseLocalResetControllerTests`, QR 화면·배선 test, presentation test 모두 통과(전체 실행에 포함). fake provider 셋에 `resumeScanning()`을 더했다 |
| 버전 도구 `Scripts/test_pogo_app_version.py` | 181개, 실패 0. `check`: 여섯 타깃이 `Version.xcconfig`의 `1.2.0 (8)`을 쓴다 |

수정 전의 실패: 수정하지 않은 소스의 렌더링(위 "재현")과, 새 test 안의 이전 방식 재현(`OldSheetIconRow`: 가장 큰
크기에서 67.0pt 심벌 가운데 62.5pt만 그려짐). 자동 검색은 새 기능이라 "수정 전의 실패"가 없다.

### Mac Catalyst (공용 행 변경의 영향)

`platform=macOS,variant=Mac Catalyst`, 관련 클래스 11개: **154개 중 통과 153, 실패 0, 건너뜀 1**(이전 방식의 잘림
재현: Catalyst에는 그 결함이 없으므로 iOS 전용). 렌더링은 `render/after_catalyst/`(좁은 창·넓은 어두운 창).

### 렌더링 (화면을 실제로 그려 확인)

`render/after/`(iPhone 13 mini 375×812pt, ko·en·es × 밝은 화면·어두운 화면·가장 큰 글자 크기, 끝까지 스크롤하며
한 화면씩): "Power Base 추가"의 21개 상태, "다른 허브에 연결하기"의 10개 상태, 관리 시트 3개, "삭제 확인" 3개.
확인한 것: 파형·재검색·Bluetooth 거부·찾지 못함·일시 정지 심벌이 모두 온전하다 / 아이콘과 여러 줄 글이
겹치지 않는다 / 가장 큰 글자 크기에서도 버튼 문구와 설명이 끝까지 보이고 마지막 줄까지 스크롤된다 / 번호
열이 아이콘 열과 같은 자리다. 본 것 그대로: 가장 큰 글자 크기에서는 글 영역이 좁아 "Bluetooth" 같은 긴 낱말이
낱말 안에서 줄바꿈된다(잘리지는 않는다).

렌더링 harness는 SwiftUI 본문만 그린다. 실제 기기의 탐색 막대·시트 테두리·권한 알림은 그리지 않는다.

### 빌드와 산출물

`GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`. **개발 빌드다**(커밋하지 않은 트리, Release 구성, 서명됨). 어디에도 설치하지 않았다.
Debug 구성은 위 시뮬레이터·Catalyst test의 빌드로 컴파일됐다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pogoappsearch_20261008_app_device_release_signed/artifact/PogoHome.app` |
| 버전 | `1.2.0`, 빌드 번호 `8`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.2.0 (8)` |
| 빌드 식별자 | `05375341f70d+dirty.381c32dbfc93` (개발, dirty) |
| 소스 지문 | `381c32dbfc93148485d57345796ccef1f12eb653aef2256a0ebe84ce101f8512` |
| manifest SHA-256 | `928e3b90edbd179d5859d604b2cf9b5f1b0c54fa0e429d1a17dd5e11cf01cc07` |
| 실행 파일 SHA-256 | `bd12b5ead037dc8399c4525013ce820fe11bea05d37c0203e69d7ec7f00ab43a` |
| toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), `Release-iphoneos` |
| 빌드 입력 | 369개 파일의 SHA-256이 빌드 전후 같다. manifest의 `inputs_unchanged_during_build: true` |
| 대조 | `manifest-verify --match-current-tree` 통과, `verify-bundle --expect-identity` 통과, `check_release_enrollment_surface.sh … release` 통과 |
| 서명 | `codesign --verify --deep --strict` 유효. 앱·위젯·Watch 앱·Watch 위젯 각각 유효하고 서명 인증서가 그 프로파일의 것이다 |
| 프로파일 | **2026-10-12 02:22 UTC에 만료**(가장 이른 것. iPhone 앱 프로파일은 02:23). 기기 2대(Watch 쪽 1대)가 들어 있다. 어느 기기인지는 확인하지 않았다 |

`1.2.0 (7)` 산출물(`pogoauto_20261008_app_device_release_signed`, manifest `8b939149…218920`)은 바이트 그대로이고
자체 무결성 검증도 통과한다. 지금의 트리와는 더 이상 일치하지 않는다(그것이 맞다).

### 하지 않은 것

| 항목 | 상태 |
|---|---|
| iPhone에 설치·실행 | **미실행** |
| 실제 Bluetooth 권한 질문(화면 진입 시), 실제 검색, 실제 보드 발견 | **미실행.** provider는 스크립트다. `CBCentralManager`를 만드는 시점이 화면 진입으로 옮겨졌다는 것은 코드와 fake의 `activate` 횟수로만 확인했다 |
| Bluetooth를 껐다 켜기, 설정에서 권한을 바꾼 뒤 돌아오기 | 미실행. iOS는 권한을 바꾸면 앱을 다시 시작시키는 경우가 있다: 그때는 화면에 새로 들어와야 한다 |
| 백그라운드에서 돌아온 뒤 실제 검색이 이어지는가 | 미실행 |
| QR 카메라·사진 선택에서 돌아왔을 때 실제 기기에서 `onDisappear`가 오는지 | 미실행. 오든 안 오든 다시 시작하지 않도록 했고(유예 시간 안의 복귀), 그 두 경우를 test로 봤다 |
| 실제 기기의 가장 큰 글자 크기 화면 | 미실행. 시뮬레이터 렌더링으로 확인했다 |
| iPad 시뮬레이터 렌더링, en·es의 Catalyst 렌더링 | 미실행(이번 범위는 iPhone 13 mini와 Catalyst ko) |

## Power Base 삭제의 자동 확인 (2026-10-08, `1.2.0 (7)`)

"Power Base 삭제"를 한 번 확인하면 '삭제 완료'까지 사용자가 더 할 일이 없게 한 변경이다. 내용은
[`CHANGELOG.md`](../CHANGELOG.md)의 "추가" 첫 항목, 규약은 펌웨어 저장소 `docs/power-base-management.md`
(2026-10-08 머리말, 4·7절)와 `docs/pogohome-api-v1.md`. 확인을 스스로 보내는 것은 Power Base(펌웨어 0.2.0)이고
받는 것은 허브(0.2.0)다. 그쪽의 검증은 펌웨어 저장소 `docs/validation-status.md` "Power Base 자동 삭제 확인 검증
(2026-10-08)"에 있다. 이 절은 앱이 한 일만 적는다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하지 않았고 실제 허브·보드·BLE를 쓰지 않았다. **test와 빌드가
통과했다는 것은 실물에서 자동 삭제가 된다는 뜻이 아니다.**

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 작업 전 | `1.1.1 (6)`, 소스 지문 `bab2c93fecdd14a85549f97b0c771884f1a9e1a389552216c07a922f6ff0ce65`, 빌드 식별자 `05375341f70d+dirty.bab2c93fecdd`. 변경 파일 118개(추적 65, 미추적 53), stage 0 |
| 작업 후 | `1.2.0 (7)`, 소스 지문 `553da7e84bb24e911c5df0b627bc92655d571f0398811980bc0cef064b6216df`, 빌드 식별자 `05375341f70d+dirty.553da7e84bb2` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임 |

### 앱이 하는 일과 하지 않는 일

- **읽는 것 하나가 늘었다.** 허브의 삭제 작업과 `power_bases[]`의 선택 필드 `erase_confirmation`. 없거나 모르는
  값이면 "허브가 말하지 않음"이고 이전 동작이다.
- **보내는 것은 그대로다.** 삭제 요청 한 번. 앱은 확인을 읽지도 전달하지도 않고(자동 경로에서), 관리 키나 설정
  코드를 받거나 저장하지 않는다.
- **'삭제 완료'는 허브의 `completed`뿐이다.** `released` + `automatic`은 '삭제 중'이고 버튼이 없다. 허브가
  `manual`로 바꾸면(4분 안에 확인이 오지 않았을 때) 이전의 '등록 해제됨 · 삭제 확인 필요'와 "삭제 확인"이 나온다.
- **바꾸지 않은 것.** `AppModel`(마지막 Base 삭제 처리 포함), `PowerBaseReleaseEvidence`, "삭제 확인" 화면과
  controller(인증, foreground, 화면 이탈, 허브 변경, task 취소 규칙), 등록·재등록 화면, BLE 패키지. 이 파일들은
  작업 전과 바이트가 같다.

### test

모두 새 기능의 검사다. 이번에 앱에서 재현한 기존 결함은 없다.

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, Debug 전체 (최종 트리) | **1083개 중 1061 통과, 실패 0, skip 22** (이전 기록 1068개에서 15개 늘었다) |
| 한국어(`-testLanguage ko`), 삭제·관리·문구 5개 클래스 | 79개 중 79 통과, skip 0 (ko → en·es 번역 대조 포함) |
| 스페인어(`-testLanguage es`), 같은 클래스 | 79개 중 78 통과, skip 1(한국어 전용 대조) |
| `Scripts/test_pogo_app_version.py` | 181개 검사, 실패 0 |

새 test 15개:

- `PogoHomeTests/PowerBaseAutomaticRemovalTests.swift` (10개, 새 파일): 허브의 값을 읽는 방법(작업과 Base, 없는 값·
  모르는 값·끝난 작업), `completed` 전의 어떤 조합도 '삭제 완료'가 아닌 것과 '삭제 대기'/'삭제 중' 두 제목,
  "삭제 확인"을 제공하는 조건(자동이면 없음, `manual`·값 없음·결과 확인 불가면 있음), 요청 구역과 완료 기록
  구역의 분리, 확인 대화상자가 허브의 말에 따라 달라지는 것, 사용자 문구에 내부 용어가 없는 것, 허브의 더 나중
  말(`automatic` → `manual`)을 보여 주는 것, 연속 두 번의 요청이 한 번인 것과 답을 받지 못한 요청의 표시.
- `PogoHomeTests/AppModelPowerBaseManagementTests.swift` (5개 추가): 허브의 JSON → 실제 수신 경로 → 실제 `AppModel`
  → 관리 화면의 상태. **마지막 Base**: 요청 한 번 → '삭제 대기' → '삭제 중' → (`released`: Base와 센서가 화면에서
  내려가고, 복구 중으로 보지 않으며, 버튼 없음) → '삭제 완료', 그동안 앱이 보낸 것은 요청 하나뿐. **오프라인 Base**:
  요청이 저장되고 취소 가능, Base가 돌아오면 앱 없이 끝남. **자동 확인이 오지 않음**: 같은 작업이 `manual`이 되면
  "삭제 확인" 제공, 늦게 온 확인으로 완료. **이전 허브·이전 보드**: 값이 없거나 `manual`이면 이전 동작과 이전
  안내 문구. **허브 변경**: 다른 허브로 바꾸면 진행 중이던 작업은 보이지 않는다.

지시서의 시나리오와 앱에서 실행한 곳:

| 시나리오 | 어디서 |
|---|---|
| 온라인 삭제의 정상 완료, 마지막 Base와 센서의 화면 갱신 | `testTheLastBaseGoesFromOneRequestToRemovedWithNothingElseAsked` |
| 오프라인 요청 후 재연결 | `testAnOfflineBaseWaitsAndIsRemovedWhenItComesBack` |
| 통지·응답 유실, 중복 요청 | `testTheSheetShowsTheHubsLaterWordAndOneRequestIsOneJob`, 기존 `PowerBaseRemovalControllerTests` |
| 자동 확인 실패 뒤의 복구 수단 | `testWhenTheBoardsOwnConfirmationDoesNotArriveTheBluetoothConfirmationIsOffered`, 기존 "삭제 확인" test 전체 |
| 신구 허브·펌웨어 | `testAHubOrBoardThatDoesNotSayKeepsTheBluetoothConfirmation`, `testTheHubsWordOnAJobIsReadAndNothingElseIsGuessed` |
| 허브 변경 | `testAnotherHubShowsNothingOfTheJobUnderWay`, 기존 controller test |
| 앱의 background, 화면 이탈 | 자동 경로에서는 앱이 하는 일이 없어 새 규칙이 없다(확인은 Power Base에서 허브로 간다). "삭제 확인"의 foreground·이탈 규칙은 바꾸지 않았고 그 test(`PowerBaseReleaseConfirmationTests`, `…FollowUpTests`)는 전체 실행에서 그대로 통과했다 |

**화면 렌더링.** `PowerBaseProductRenderingTests`에 관리 화면의 `released-automatic` 상태와, 기기 목록의 두
구역(요청 / 최근 삭제)을 더해 ko·en·es로 그렸다(일반, 다크, 가장 큰 글자 크기). 일반 크기의 세 언어 그림을
직접 보았다: '삭제 중'/"Removing"/"Eliminando"와 설명이 잘리지 않고, 버튼이 없으며, 완료된 작업이 "최근 삭제한
Power Base" 아래에 따로 있다. 렌더링은 SwiftUI 본문만 그린다(창의 제목 줄·탭은 없다).

### 빌드와 산출물

`GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`. **개발 빌드다**(커밋하지 않은 트리, Release 구성, 서명됨). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pogoauto_20261008_app_device_release_signed/artifact/PogoHome.app` |
| manifest | 같은 디렉터리의 `manifest.json`, SHA-256 `8b939149734efbb6aa8d36d82f391780a6cf06e646871e4f1f9a6b979e218920`, 파일 60개 |
| 버전 | `1.2.0`, 빌드 번호 `7`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.2.0 (7)` |
| 소스 식별 | commit `05375341f70d93c788b5f08889e312a023f83202`, dirty, 지문 `553da7e8…16df`, 빌드 식별자 `05375341f70d+dirty.553da7e84bb2` |
| 대상 | `Release-iphoneos`, Xcode 27.0 (27A266a), Apple Swift 6.4 |

- `manifest-verify --match-current-tree --expect-version 1.2.0`, `verify-bundle --expect-identity`,
  `check_release_enrollment_surface.sh … release` 통과. `codesign --verify --deep --strict` 종료 코드 0(이 Mac의
  일반 셸. 인증서 신뢰 설정과 Keychain은 바꾸지 않았다).
- 빌드 입력은 367개 파일이다(새 test 파일 1개가 늘었다).
- `~/esp-builds/pogoauto_20261008_app_device_release_signed_superseded_cdbe59243d37/`은 같은 날 렌더링 test를
  고치기 전에 만든 빌드다(빌드 식별자 `…cdbe59243d37`). 앱 본체의 소스는 같지만 지금 트리의 빌드가 아니므로 쓰지
  않는다.
- 이전 산출물(`pbmgmt6_20261008_…`의 `1.1.1 (6)` 등)은 고치지 않았다. 과거 빌드와 그 기록에 `1.2.0`을 붙이지
  않는다.

### 하지 않은 것

- 새 빌드를 iPhone에 설치하고 실행하기. 실제 허브·실제 Power Base로 삭제하기.
- 실제 창에서의 화면 확인(UI test 구동), iPad 시뮬레이터 전체, Mac Catalyst test, `PowerBaseBLEKit`의
  `swift test`(패키지는 바뀌지 않았다).
- 허브가 4분 뒤 `manual`로 바꾸는 것을 실제 시간으로 기다려 보는 것(앱 test에서는 허브의 다음 snapshot으로 줬다).
- Linux 허브 접속, 배포, 서비스 조작. 보드 기록.

## 등록 해제 판정에서 시각 비교를 없앤 수정 (2026-10-08, `1.1.1 (6)`)

`1.1.1 (5)`(아래 절)가 "허브가 이 Base를 등록 해제했는가"를 시각의 차이로 가리던 것을 고쳤다. 변경 내용은
[`CHANGELOG.md`](../CHANGELOG.md)의 "수정" 첫 항목. 제품 버전은 `1.1.1` 그대로, 빌드 번호만 `5`에서 `6`이
됐다. 허브 API, BLE 규약, 저장 형식, 펌웨어·허브 버전은 그대로다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하지 않았고 실제 허브·보드·BLE를 쓰지 않았다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 수정 전 | `1.1.1 (5)`, 소스 지문 `4b928390f36c896b892d4458c7a9133c4700e2ad8429e7fdac40b6c27e3b92a6`, 빌드 식별자 `05375341f70d+dirty.4b928390f36c` |
| 수정 후 | `1.1.1 (6)`, 소스 지문 `bab2c93fecdd14a85549f97b0c771884f1a9e1a389552216c07a922f6ff0ce65`, 빌드 식별자 `05375341f70d+dirty.bab2c93fecdd` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK(`iphoneos27.0`, 24A430)·시뮬레이터 런타임, Python 3.9.6 |
| 펌웨어 저장소 | 읽기만 했다(`docs/power-base-management.md`, `docs/pogohome-api-v1.md`). 작업 전후 변경 목록, 내용 체크섬, index가 같다 |

### 보고된 결함과 실제 경로에서의 재현

검토 도구가 `1.1.1 (5)`의 판정 함수만 떼어 실행해 두 가지를 보고했다. 실제 수신 경로로 다시 확인했다.

| 보고 | 실제 경로(GET·SSE → `AppModel`)에서 | 판단 |
|---|---|---|
| iPhone 시계가 허브보다 30초 빠르면 새 `released`가 근거로 인정되지 않는다 | **재현되지 않았다.** snapshot의 시각은 허브의 `generated_at_unix_ms`이고 작업의 시각도 허브의 것이다. 허브 시계가 이 기기보다 30초 앞·뒤인 test 둘 다 수정 전에 통과했다 | 보고의 전제(서로 다른 시계의 비교)가 실제 경로와 달랐다. 보고한 쪽도 철회했다 |
| 2초 전에 완료된 삭제 + 1초 전에 다시 목록에 나타난 Base → 다음 빈 목록에서 끝난 작업이 새 삭제의 근거가 된다 | **재현됐다.** 센서 2개가 화면에서 내려갔다 | 실제 결함. 다시 등록한 Base의 복구 보호가 깨진다 |

같은 원리(한 시계 안의 "몇 초 이내"로 인과를 정함)에서 나오는 다른 실패도 수정 전에 재현했다: 허브
시각이 한 시간 뒤로 간 뒤의 등록 해제가 근거로 인정되지 않음, 허브가 `released`를 저장한 뒤 30초 동안
Base를 목록에 둔 경우 근거로 인정되지 않음(둘 다 `1.1.1 (4)`의 증상이 남는다).

### 새 판정

`PogoHome/App/PowerBaseReleaseEvidence.swift`(새 파일)가 허브의 snapshot을 받은 순서대로 보고(보류하는
snapshot도 포함), 시각을 전혀 쓰지 않고 다음으로 판정한다.

- 끝난 작업(`released`·`completed`)이 있고 그 Base가 허브의 목록에 없으면, 그 작업이 이유다.
- 다만 앱이 **그 작업이 그 Base의 지금 등록보다 먼저 끝났음을 본** 경우 그 작업은 근거가 아니고, 이후로도
  다시 쓰이지 않는다.
  - Base가 목록에 있는 동안 그 작업이 `completed`로 보였다(삭제 뒤 다시 등록된 것).
  - Base가 목록에 나타난 때(이 허브의 첫 snapshot, 또는 목록에 없다가 다시 나타난 때) 그 작업이 이미
    `released`/`completed`였다.
- Base가 이미 목록에 있는 동안 `released`가 된 작업은 진행 중인 등록 해제이고, 허브가 목록에서 빼는 데
  얼마가 걸리든 근거다.
- 관측 기록은 `AppModel`이 현재 source에 대해 하나 갖고, 다른 허브로 바꿀 때(`clearSourceData`) 버린다.
  같은 허브의 일시 정지(백그라운드)와 주소 변경에서는 유지한다.

근거로 삼은 허브 규칙(펌웨어 저장소 문서): 작업은 한 번의 등록에 대한 것이고 앞으로만 진행한다.
`released`에서 허브가 Base를 `power_bases`에서 뺀다. 다시 등록하면 `completed` 작업은 끝난 뒤 얼마 동안
목록에 남고, `released` 작업은 새 등록이 활성화될 때 `superseded`가 된다.

**확실히 판단하는 경우와 그렇지 않은 경우.**

| 앱이 본 것 | 판단 | 근거 |
|---|---|---|
| Base가 목록에 있고 작업이 진행 중 → 작업 `released`, Base 없음 | 등록 해제 | 같은 작업의 전이를 봤다 |
| 위에서 `released`와 Base가 함께 여러 번 보인 뒤 Base 없음 | 등록 해제 | 진행 중인 해제. 걸린 시간은 보지 않는다 |
| Base가 목록에 있고 그 작업은 없거나 진행 중 → (`released`를 놓침) 작업 `completed`, Base 없음 | 등록 해제 | Base가 목록에 있을 때 끝나지 않았던 작업이 끝났고 Base가 없다 |
| Base와 `completed` 작업이 함께 보임 → 빈 목록 | 유지 | 그 작업은 지금 등록보다 먼저 끝났다 |
| 등록 해제 → Base가 다시 나타남(작업은 `completed` 또는 아직 `released`) → 빈 목록 | 유지 | 끝난 작업을 다시 쓰지 않는다 |
| 위 상태에서 다른 ID의 새 작업이 `released`, Base 없음 | 등록 해제 | 새 작업은 쓰이지 않았다 |
| 첫 snapshot에서 Base와 이미 `released`인 작업이 함께 보임 → Base 없음 | **유지(근거 부족)** | 진행 중인 해제의 한순간인지, 다시 등록됐지만 새 등록이 아직 활성화되지 않은 것인지 알 수 없다 |
| 진행 중이던 작업이 Base가 목록에 있는 채로 `completed` → Base 없음 | **유지(근거 부족)** | 보지 못한 사이의 삭제·재등록인지, 허브가 통지보다 영수증을 먼저 받은 한순간인지 알 수 없다 |
| 작업이 그 밖의 상태, 다른 Base의 작업, 작업 없음, 읽을 수 없는 작업, 작업 목록이 없는 허브 | 유지 | 끝난 작업이 없다 |

"유지(근거 부족)"의 두 경우에 삭제가 실제로 진행 중이었다면 Base와 센서가 "복구 중"으로 남는다. 삭제
작업의 표시와 "삭제 확인" 진입은 이 판정과 무관하게 정상이고, 앱을 다시 시작하면 풀린다. 반대 방향으로
남는 경우: 앱이 보지 못한 사이 등록 해제와 재등록이 있었고 그 작업이 아직 `released`이면(새 등록이
활성화되기 전), Base가 목록에 있는 채로 `released`가 보이므로 진행 중인 해제로 읽히고, 그 뒤 빈 목록에서
센서가 내려간다(허브가 목록을 다시 채우면 돌아온다).

**표시되는 작업.** `PowerBaseRemovalController.removal(for:in:)`도 시각 비교를 없앴다: snapshot이 보여 주는
작업과 허브가 이 기기에 답한 작업이 **같은 ID**일 때만, 상태가 더 진행된 쪽(`isFurtherAlong`)을 쓴다.
다른 작업에 대한 답은 snapshot의 작업을 바꾸지 않고, snapshot에 그 Base의 작업이 없으면 이전처럼 답한
작업을 쓴다. 허브가 이 기기에 답한 작업은 센서 판정의 근거로 쓰지 않는다(snapshot만 쓴다).

### 수정 전의 실패와 수정 후

`AppModelPowerBaseManagementTests`가 21개에서 34개가 됐다(새 13개. 기존 1개는 아래처럼 고쳤다). 판정 규칙의
단위 test `PowerBaseReleaseEvidenceTests` 7개를 더했다. iPhone 18 Pro 시뮬레이터. "수정 전"은 `AppModel.swift`와
`PowerBaseRemovalController.swift`를 `1.1.1 (5)`의 내용으로 되돌리고 새 판정 파일과 그 단위 test를 뺀
상태이고, `AppModelPowerBaseManagementTests.swift`는 수정 후와 같은 파일이다(SHA-256 `51ad7e81…d3ea`).

| `AppModelPowerBaseManagementTests` 34개 | 수정 전 (`1.1.1 (5)`의 판정) | 수정 후 |
|---|---|---|
| 통과 | 24 | 34 |
| 실패 | 10 | 0 |

수정 전에 **실패한 10개**: 완료 직후 다시 등록한 Base(보고된 결함), 끝난 작업의 재사용과 새 작업(전
과정을 본 경우), 보지 못한 삭제·재등록, 처음부터 `released`였던 작업(근거 부족), 허브 시각이 뒤로 간
경우, `released` 뒤 30초 동안 목록에 남은 Base, 표시되는 작업 3개(시각이 뒤로 간 답, 시각이 앞선 예전 답,
다른 작업에 대한 답), 그리고 기존 test 1개(아래).

수정 전에도 **통과한 새 test 4개**(그대로 보고한다): 허브 시계가 이 기기보다 30초 뒤, 30초 앞(위 표의
첫 줄), 두 허브의 관측 기록 분리(`1.1.1 (5)`에는 기록 자체가 없어 섞일 것이 없었다. 새 구현을 지키는
test다), 읽을 수 없는 작업·작업 목록이 없는 허브(호환성. 이전에도 근거가 아니었다).

**고친 기존 test 1개.** `testAnEmptyListWithoutAConfirmedRemovalKeepsTheSensorsWhileTheJobsFollowTheHub`의
마지막 단계는 "10분 전에 완료된 삭제는 근거가 아니다"를 **작업의 나이**로 표현하고 있었다. 나이는 더 이상
기준이 아니므로, 같은 뜻을 앱이 실제로 보는 모습으로 바꿨다: 처음부터 Base와 함께 보인 끝난 작업(다른
ID)이 모든 단계에 들어 있고, 마지막에는 그 작업만, 방금 바뀐 시각으로 남는다. 나머지 단계와 기대값은
그대로다. 이 단계는 수정 전 실패한다(`1.1.1 (5)`는 방금 바뀐 시각의 끝난 작업을 근거로 본다).

**시각은 test가 정한다.** 새 test의 snapshot과 작업은 허브 시계의 값을 직접 적는다(2020년의 임의 시각을
기준으로 초 단위 지정. 이 기기의 시계와 무관하다). 순서는 받은 순서로 정해지고, 고정 대기는 쓰지 않았다
(`lastSyncAt`이 바뀔 때까지 기다린다).

요청된 재현 항목과 test:

| 항목 | test | 수정 전 |
|---|---|---|
| 허브 시각이 30초 과거·미래 | `testAHubClockThirtySecondsBehind…`, `…Ahead…` | 통과 |
| 작업 갱신과 목록 제거 사이가 5초보다 김 | `testAReleaseIsTheReasonHoweverLongTheHubKeepsListingTheBase` | 실패 |
| 과거 `completed` → 재등록 → 빈 목록 | `testARemovalThatCompletedJustBeforeTheBaseWasEnrolledAgain…`, `testAFinishedRemovalIsNotReused…`, `testARemovalAndANewEnrollmentThisAppDidNotSee…` | 실패 |
| 같은 작업의 `accepted` → `released` → `completed` | `testTheLastBaseWithSensorsIsReleasedConfirmedAndCompletedWithoutARelaunch`(기존), 시계 test 둘 | 통과 |
| 다른 작업 ID | `testAFinishedRemovalIsNotReused…ButANewJobCounts`, `testAnAnswerAboutAnotherJobNeverReplacesTheSnapshotsJob` | 실패 |
| 허브 전환 | `testWhatWasSeenOnOneHubIsNoEvidenceOnAnother`, `testAnotherHubDuringRecoveryKeepsNothingOfWhatWasHeld`(기존) | 통과 |
| 오래된 응답 | `testAnOlderAnswerNeverHidesWhatTheSnapshotSaysEvenWithALaterTime`, `testAnAnswerAboutAnotherJobNeverReplacesTheSnapshotsJob` | 실패 |
| 다른 Base의 작업 | 위 기존 test의 "another Base released" 단계, 단위 test `testEachBaseHasItsOwnHistory` | 통과(단위 test는 새 파일) |
| 빈 목록·불완전한 센서의 복구 보호 | 기존 test 2개(`…KeepsTheSensorsWhileTheJobsFollowTheHub`, `testAnOnlineSensorWithoutASample…`) | 앞의 것은 위 설명대로 실패, 뒤의 것은 통과 |
| 허브 시각 보정 | `testAHubClockSetBackDoesNotHideARelease`, `testAnAnswerFurtherAlongIsShownWhateverItsTimeSays` | 실패 |

"허브 시각 보정"은 **그런 시각이 적힌 JSON**으로 확인한 것이다. 실제 허브에서 NTP 보정이나 시계 없는
재부팅을 일으켜 본 것이 아니다.

### 회귀 (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, Debug 전체 | 1068개 중 1046 통과, 실패 0, skip 22 |
| Mac Catalyst, 관련 75개 클래스 | 713개 중 695 통과, 실패 0, skip 18 |
| `Scripts/test_pogo_app_version.py` | 181개 검사, 실패 0 |

- 전체는 이전 기록의 1048개에서 20개 늘었다(13개와 7개).
- 이전 절에서 Catalyst의 첫 실행에 실패하던 기존 test
  (`AppModelDataSourceSwitchTests.testMultipleReplacementsNeverLeaveMoreThanOneLiveConnection`)는 이번에는
  1차 실행에서 통과했다. 재실행하지 않았고, 그 test는 고치지 않았다.
- skip은 이전과 같은 종류다(환경 변수가 필요한 렌더링, 한국어 전용 번역 검사, 실제 망, 새로 만든 QR PNG).
- **실행하지 않은 것:** iPad 시뮬레이터 전체, 한국어 실행(새 문구 없음), Mac Catalyst 전체,
  `PowerBaseBLEKit`의 `swift test`(패키지는 바뀌지 않았다), 화면 렌더링 test.

### 빌드와 산출물

`GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`으로 새 디렉터리에 만들었다. **개발 빌드다**(커밋하지 않은 트리, 빌드 종류
`development`, Release 구성, 서명됨). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pbmgmt6_20261008_app_device_release_signed/artifact/PogoHome.app` |
| manifest | 같은 디렉터리의 `manifest.json`, SHA-256 `34ff360b5b1896e97b25cc3b609e6e79580c3f316207ef2a4f118bf586f110ca`, 파일 60개 |
| 버전 | `1.1.1`, 빌드 번호 `6`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.1.1 (6)` |
| 소스 식별 | commit `05375341f70d93c788b5f08889e312a023f83202`, dirty, 지문 `bab2c93f…ce65`, 빌드 식별자 `05375341f70d+dirty.bab2c93fecdd` |
| 대상 | `Release-iphoneos`, arm64, `iphoneos27.0` SDK(24A430), Xcode 27.0 (27A266a), 최소 iOS 26.0 |

- manifest, 실제 번들(Info.plist를 직접 읽음), 현재 소스의 버전·빌드 번호·빌드 종류·commit·dirty·지문·빌드
  식별자가 같다. `manifest-verify --match-current-tree --expect-version 1.1.1`, `verify-bundle
  --expect-identity`, `check_release_enrollment_surface.sh … release` 통과.
- 빌드 입력 366개 파일(새 소스 1개, 새 test 1개가 늘었다)의 SHA-256 목록이 빌드 전후에 같다. Git index
  파일의 바이트도 작업 전체에서 같다.
- **서명 검사(이 Mac의 일반 셸):** `codesign --verify --deep --strict` 통과(`valid on disk`, `satisfies its
  Designated Requirement`, 종료 코드 0). 위젯, Watch 앱, Watch 위젯 각각도 종료 코드 0. 인증서 신뢰 설정과
  Keychain은 바꾸지 않았다. sandbox 안에서의 `CSSMERR_TP_NOT_TRUSTED`에 대해서는 아래 절의 "서명 검사".
- 프로파일은 2026-10-12에 만료된다. 프로파일에 대상 iPhone이 들어 있는지는 확인하지 않았다.
- 이전 산출물(`pbmgmt_20261007_…`의 `1.1.1 (4)`, `pbmgmt5_20261007_…`의 `1.1.1 (5)`)과 그 결과 디렉터리는
  고치지 않았다(파일 목록과 SHA-256이 작업 전후 같다). `1.1.1 (5)`는 이 절의 결함을 가진 빌드다.

### 하지 않은 것

- 새 빌드를 iPhone에 설치하고 실행하기.
- 실제 허브에서의 삭제, 등록 해제, "삭제 확인"(영수증), 재등록, 그리고 재등록 뒤 허브를 다시 시작했을
  때의 화면.
- 실제 허브 시계의 보정·재부팅. 실제 허브가 `released`를 저장하고 목록을 바꾸기까지의 간격.
- 허브의 구현을 읽어 위 "허브 규칙"이 코드와 일치하는지 확인하는 것(문서만 읽었다).
- Linux 허브 접속, 배포, 서비스 조작. 펌웨어·허브의 빌드와 test(바뀌지 않았다).

## 마지막 Power Base 삭제와 센서 없는 Base 표시의 후속 수정 (2026-10-07, `1.1.1 (5)`)

아래 `1.1.1 (4)` 수정을 조사하며 확인한 두 가지("따로 조사한 것")를 고쳤다. 변경 내용은
[`CHANGELOG.md`](../CHANGELOG.md)의 "수정" 첫 항목. 제품 버전은 `1.1.1` 그대로이고 빌드 번호만 `4`에서
`5`가 됐다. 허브 API, BLE 규약, 저장 형식, 펌웨어·허브 버전은 그대로다.

**이 절의 어떤 것도 실물이 아니다.** 새 빌드를 설치하지 않았고 실제 허브·보드·BLE를 쓰지 않았다.

**이 절의 "등록 해제를 확인한 Base"의 조건 가운데 시각 비교(5초 허용)와, 표시할 작업을 변경 시각으로 고르던
것은 `1.1.1 (6)`에서 없앴다(위 절).** 아래는 `1.1.1 (5)`를 만들 때의 기록이다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 수정 전 | `1.1.1 (4)`, 소스 지문 `88fb331a4a67c40adf2b64ecacad948290fc5596af0c65aec5961b362ac268d3`, 빌드 식별자 `05375341f70d+dirty.88fb331a4a67` |
| 수정 후 | `1.1.1 (5)`, 소스 지문 `4b928390f36c896b892d4458c7a9133c4700e2ad8429e7fdac40b6c27e3b92a6`, 빌드 식별자 `05375341f70d+dirty.4b928390f36c` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK(`iphoneos27.0`, 24A430)·시뮬레이터 런타임, Python 3.9.6 |
| 펌웨어 저장소 | 읽기만 했다. 작업 전후 변경 목록, 내용 체크섬, index가 같다 |

### 원인과 수정

- `AppModel.applyIncoming`은 완전한 센서 목록을 한 번 받은 뒤에는 불완전한 snapshot(센서 0개, 또는 측정값
  없는 온라인 센서)을 통째로 보류한다. `HomeSnapshot.onlineModulesHaveReadings`는 센서가 0개여도 `false`다.
  그래서 마지막 Base가 등록 해제되어 허브의 목록이 비면 그 snapshot의 `released`도 화면에 오지 않았다.
  관리 화면이 허브의 작업 목록을 따로 읽어도 `PowerBaseRemovalController.removal(for:in:)`이 snapshot의
  (예전) 작업을 먼저 썼다.
- 수정한 파일과 내용:
  - `App/AppModel.swift`: 보류하는 동안에도 그 snapshot의 삭제 작업과 관리 지원 여부는 반영한다. 허브가
    등록 해제를 확인한 Base(허브의 작업이 `released`/`completed`, 허브의 목록에 없음, 작업이 화면의
    snapshot보다 뒤에 바뀜. 저장과 목록 변경 사이의 순서 차이는 5초까지 허용)와 그 아래 센서는 화면과
    복구 기준에서 뺀다. 기준이 비면 허브의 빈 목록을 그대로 적용한다. Base 표시용 판정
    `isPowerBaseStateVerified`를 더했다.
  - `Core/Models/HomeHealth.swift`: `HomeHealthEvaluator.isPowerBaseStateVerified`(연결됨, 60초 안에 수신,
    보류 중 아님). `HomeHealthState`와 `evaluate`는 바꾸지 않았다.
  - `Core/PowerBaseManagement/PowerBaseRemovalController.swift`: 같은 Base의 작업은 snapshot의 것과 허브가
    이 기기에 답한 것 가운데 허브가 더 나중에 바꾼 쪽(같으면 snapshot).
  - `Features/Devices/PowerBaseManagementSheet.swift`, `DevicesView.swift`(두 곳), `AddDeviceSheet.swift`:
    Base의 연결 표시가 새 판정을 쓴다. 센서의 표시는 그대로 `health.isCurrentStateVerified`를 쓴다.
    `PowerBaseManagementPresentation.swift`는 주석만.
- 새 문구는 없다(문자열 표는 바뀌지 않았다).

### 수정 전의 실패와 수정 후

이전 작업의 임시 프로브(`~/esp-builds/pbmgmt_20261007_results/05_probe_output.txt`)를 정식 test로 바꿨다.
`AppModelPowerBaseManagementTests`에 9개를 더해 21개가 됐고(기존 12개는 그대로), `HomeHealthEvaluatorTests`에
새 판정의 단위 test 2개를 더했다. iPhone 18 Pro 시뮬레이터.

| `AppModelPowerBaseManagementTests` 21개 | 수정 전 | 수정 후 |
|---|---|---|
| 기존 12개 | 12개 통과 | 12개 통과 |
| 새 9개 | 9개 실패 | 9개 통과 |

- **"수정 전"의 정의.** 새 test가 Base 표시용 판정(`AppModel.isPowerBaseStateVerified`)을 읽으므로 수정 전
  소스로는 컴파일되지 않는다. 수정 전 실행은 `AppModel.swift`와 `PowerBaseRemovalController.swift`를 수정
  전 내용으로 되돌리고, `AppModel`에 그 이름으로 **수정 전에 화면이 쓰던 값**
  (`health.isCurrentStateVerified`)을 돌려주는 한 줄만 둔 상태다. test 파일은 수정 후 실행과 같은 파일이다
  (SHA-256 `4abb9fba…097e`). 실행 뒤 소스를 되돌렸고 최종 지문으로 확인했다.
- 대표 실패: 마지막 Base에서 `accepted`인 채로 `released`가 오지 않음, 보류 중에 만든 작업이 보이지 않음
  (`nil`), 등록 해제된 Base의 센서 2개가 남음, 허브 목록의 `released`보다 snapshot의 `accepted`가 먼저
  쓰임, 센서 없는 Base에서 표시용 판정이 `false`.

**실제 생산 경로.** 이전과 같다: test가 넣는 것은 허브의 snapshot JSON(GET 응답과 SSE 이벤트)과 허브의
작업 목록 응답이고, `LiveSensorDataSource` → `PogoSnapshotMapper` → `AppModel` → `AppModel.snapshot`, 그리고
관리 화면이 쓰는 호출(`PowerBaseHubTarget(appModel:)`, `PowerBaseRemovalController`,
`PowerBaseManagementPresentation`)은 앱이 실행하는 코드다. 화면을 그리지는 않았다.

새 9개가 확인하는 것:

- **센서가 있던 마지막 Base: `accepted` → `released` → `completed`.** 앱을 다시 만들지 않은 채로
  `released`가 화면에 오고, "등록 해제됨 · 삭제 확인 필요"와 "삭제 확인" 진입이 나오며(완료가 아니다), Base와
  센서가 화면에서 내려가고, 기기 목록에 그 작업이 남는다. 복구 중이 아니고, 홈은 "데이터 대기"다(정상이
  아니다). 그 뒤 허브가 `completed`를 알리면 "삭제 완료"가 되고 남은 동작이 없다. **"삭제 확인" 자체
  (Bluetooth로 영수증을 읽어 허브에 전달)는 이 test에서 실행하지 않았다.** 진입 조건과, 허브가 그 뒤
  `completed`를 알렸을 때의 화면까지다.
- **`released`를 놓치고 `completed`를 바로 받은 경우**도 빈 목록이 적용된다(작업이 화면의 snapshot보다
  2초 앞서 저장된 경우 포함).
- **다른 Base의 센서가 복구 중일 때.** 등록 해제된 Base와 그 센서는 내려가고, 다른 Base의 센서는 마지막
  측정값을 유지한 채 "복구 중"이며, `released`와 "삭제 확인"이 보인다. 측정값이 오면 정상으로 돌아온다.
- **기존 보호는 그대로.** 삭제 확인이 없는 빈 목록(허브 재시작)에서는 센서와 마지막 측정값, Base가
  남는다: 작업이 `pending`·`sent`·`accepted`·`cancelled`·`superseded`일 때, 결과를 모르는 `sent`일 때, 작업이
  없을 때, 다른 Base가 `released`일 때, 이 Base의 예전 삭제(10분 전 완료)만 있을 때. 그동안에도 작업은
  허브의 최신 값이고, 취소는 `pending`에만, "삭제 확인"은 결과를 모르는 작업에만 나온다. 어느 경우도
  "삭제 완료"로 표시되지 않는다. 허브가 돌아오면 정상으로 돌아온다.
- **측정값 없는 온라인 센서**는 이전처럼 보류되고(마지막 측정값 유지), 그동안 새로 생긴 작업, 취소된
  작업, 관리 지원 여부(필드가 없어지면 "지원하지 않음", 다시 생기면 삭제 가능)는 허브를 따른다.
- **허브 전환.** 보류 중에 다른 허브로 바꾸면 보류하던 센서, 작업, 지원 여부가 남지 않는다.
- **설정 변경.** 보류 중의 홈 이름·방·센서 이름 편집 뒤에도 보류한 측정값과 작업이 그대로이고, 마지막
  Base가 등록 해제된 뒤의 방 편집 뒤에도 `released`와 "삭제 확인"이 그대로다.
- **허브의 나중 답.** snapshot이 `accepted`인 동안 허브의 작업 목록이 더 나중의 `released`를 주면
  `released`가 보이고, 그 뒤의 snapshot(`completed`)을 예전 답이 되돌리지 않는다.
- **센서가 없는 Base.** 허브에 정상 연결된 상태에서 Base의 표시용 판정은 참이고 관리 화면의 문구는 "상태
  확인 중"이 아니다. 홈의 판정은 `waitingForData`(센서 없음) 그대로다. Base가 끊기면 그것도 사실로
  표시된다. 측정값 없는 센서가 처음 붙으면 Base는 확인됨, 센서는 확인 안 됨이다. 연결이 없으면 둘 다
  확인 안 됨이다.

### 회귀 (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, Debug 전체 | 1048개 중 1026 통과, 실패 0, skip 22 |
| Mac Catalyst, 관련 74개 클래스, 1차 | 693개 중 674 통과, **실패 1**, skip 18 |
| Mac Catalyst, 관련 74개 클래스, 2차 | 693개 중 675 통과, 실패 0, skip 18 |
| `Scripts/test_pogo_app_version.py` | 181개 검사, 실패 0 |

- 전체는 이전 기록의 1037개에서 11개 늘었다(위의 9개와 2개).
- **Catalyst 1차의 실패 1개**는 기존 test
  `AppModelDataSourceSwitchTests.testMultipleReplacementsNeverLeaveMoreThanOneLiveConnection`이다(30ms를
  기다린 뒤 이전 연결의 취소 통지가 처리됐는지 확인한다). 그 클래스만 40번 반복하니 프로세스 시작 직후의
  첫 실행 1번만 실패했다(0.85초 걸림, 나머지 39번은 0.03~0.07초). 클래스를 새 프로세스로 5번씩 실행해
  비교하니 이번 수정이 들어간 `AppModel`에서 5번 중 1번, 수정 전 `AppModel`에서 5번 중 2번 실패했다.
  이번 변경과 무관하게 있는 시점 의존으로 판단했고, 그 test는 고치지 않았다. 원인(무엇이 첫 실행을
  늦추는지)은 조사하지 않았다.
- skip은 이전과 같은 종류다(환경 변수가 필요한 렌더링, 한국어 전용 번역 검사, 실제 망, 새로 만든 QR PNG).
- **실행하지 않은 것:** iPad 시뮬레이터 전체, 한국어 실행(새 문구 없음), Mac Catalyst 전체,
  `PowerBaseBLEKit`의 `swift test`(패키지는 바뀌지 않았다), 화면 렌더링 test(환경 변수 필요).

### 빌드와 산출물

`GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`으로 새 디렉터리에 만들었다. **개발 빌드다**(커밋하지 않은 트리, 빌드 종류
`development`, Release 구성, 서명됨). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pbmgmt5_20261007_app_device_release_signed/artifact/PogoHome.app` |
| manifest | 같은 디렉터리의 `manifest.json`, SHA-256 `d074d177ef7954df460322d43a59f4ad5a769b962fc0902bfd8b32fd5f5e9c36`, 파일 60개 |
| 버전 | `1.1.1`, 빌드 번호 `5`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.1.1 (5)` |
| 소스 식별 | commit `05375341f70d93c788b5f08889e312a023f83202`, dirty, 지문 `4b928390…92a6`, 빌드 식별자 `05375341f70d+dirty.4b928390f36c` |
| 대상 | `Release-iphoneos`, arm64, `iphoneos27.0` SDK(24A430), Xcode 27.0 (27A266a), 최소 iOS 26.0 |

- manifest, 실제 번들(Info.plist를 직접 읽음), 현재 소스의 버전·빌드 번호·빌드 종류·commit·dirty·지문·빌드
  식별자가 같다. `manifest-verify --match-current-tree --expect-version 1.1.1`, `verify-bundle
  --expect-identity`, `check_release_enrollment_surface.sh … release` 통과.
- 빌드 입력 364개 파일의 SHA-256 목록이 빌드 전후에 같다. Git index 파일의 바이트도 작업 전체에서 같다.
- 이전 산출물 `~/esp-builds/pbmgmt_20261007_app_device_release_signed`(`1.1.1 (4)`)와 그 결과 디렉터리는
  고치지 않았다(파일 목록과 SHA-256이 작업 전후 같다). 그 빌드는 이 절의 결함을 가진 빌드다.

### 서명 검사

다른 도구의 재검사에서 `1.1.1 (4)` 산출물의 `codesign --verify --deep --strict`가 `CSSMERR_TP_NOT_TRUSTED`로
실패했다는 보고가 있어, 이 Mac의 일반 셸에서 다시 실행했다.

| 대상 | 조건 | 결과 |
|---|---|---|
| `1.1.1 (4)` 산출물 | 일반 셸 | 통과(`valid on disk`, `satisfies its Designated Requirement`, 종료 코드 0) |
| `1.1.1 (5)` 산출물 | 일반 셸 | 통과(앱, 위젯, Watch 앱, Watch 위젯 각각도 종료 코드 0) |
| 두 산출물 | 시스템 신뢰 데몬(`trustd`)과의 통신만 막은 sandbox | **실패: `CSSMERR_TP_NOT_TRUSTED`** (종료 코드 1) |
| `1.1.1 (4)` 산출물 | Keychain 파일 읽기만 막음 / 빈 HOME / 네트워크만 막음 | 통과 |

- 서명의 인증서 사슬은 Apple Development 인증서 → Apple Worldwide Developer Relations Certification
  Authority(G3) → Apple Root CA이고 세 장 모두 서명에 들어 있다. 인증서는 만료되지 않았다.
- **원인에 대한 판단.** 같은 오류 문구가 "`trustd`에 접근할 수 없는 프로세스"에서만 재현됐으므로, 보고된
  실패는 그 검사를 실행한 환경(시스템 서비스 접근이 막힌 sandbox)이 인증서 신뢰를 평가하지 못한 것으로
  보인다. 그 도구의 실제 실행 환경을 직접 보지는 못했으므로 이것은 재현에 근거한 추정이다. 산출물의
  서명이 깨졌다는 근거는 찾지 못했다.
- 인증서 신뢰 설정과 Keychain은 바꾸지 않았다(읽기만 했다). 개발용 서명이므로 Gatekeeper·공증 검사
  대상이 아니고 실행하지 않았다.
- 프로파일은 Xcode가 관리하는 개발용이고 2026-10-12에 만료된다. 프로파일에 대상 iPhone이 들어 있는지는
  확인하지 않았다(기기 식별값을 읽거나 적지 않았다). 실제 기기가 이 서명을 받아들이는지는 설치해야 알 수
  있다.

### 하지 않은 것

- 새 빌드를 iPhone에 설치하고 실행하기.
- 실제 허브에서 마지막 Power Base를 삭제해 `released`가 화면에 오는지 보기, 실제 "삭제 확인"(Bluetooth로
  영수증 읽기)과 `completed`, 재등록.
- 실제 허브 재시작 중의 화면, 허브가 `released`를 저장한 시각과 목록에서 뺀 시각의 실제 간격.
- 센서 없는 Base의 표시를 실제 화면으로 보기(판정과 문구 선택까지만 확인했다).
- Linux 허브 접속, 배포, 서비스 조작. 펌웨어·허브의 빌드와 test(바뀌지 않았다).

## Power Base 관리의 "지원하지 않음" 오표시 수정 (2026-10-07)

실제 iPhone의 Power Base 관리 화면이, 관리를 지원하는 허브를 "연결된 허브가 앱에서 Power Base를 삭제하는
기능을 지원하지 않습니다"로 표시한 결함의 수정이다. 변경 내용은 [`CHANGELOG.md`](../CHANGELOG.md)의
"수정". 앱은 `1.1.0 (3)`에서 `1.1.1 (4)`가 됐고, 허브 API, BLE 규약, 저장 형식, 펌웨어·허브 버전은
그대로다.

**수정한 앱은 실물에서 확인하지 않았다.** 새 빌드를 iPhone에 설치하지 않았고, 실제 허브·보드·BLE를 쓰지
않았다. 아래의 "현장에서 본 것"은 사용자가 수정 전 빌드로 본 것이다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 수정 전 | `1.1.0 (3)`, 소스 지문 `142ca9bb6ab79d609dc8491a3b0808057be7226243b1784191a8f99bbbd2608e`, 빌드 식별자 `05375341f70d+dirty.142ca9bb6ab7` |
| 수정 후 | `1.1.1 (4)`, 소스 지문 `88fb331a4a67c40adf2b64ecacad948290fc5596af0c65aec5961b362ac268d3`, 빌드 식별자 `05375341f70d+dirty.88fb331a4a67` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK(`iphoneos27.0`, 24A430)·시뮬레이터 런타임, Python 3.9.6 |
| 펌웨어 저장소 | 읽기만 했다(`feature/unified-module-role-manager`, `590e2a11d2cb93f1cbc2b2b0eb094d50ea289a50`). 작업 전후 변경 목록과 내용 체크섬이 같다 |

### 현장에서 본 것과 원인

- 사용자가 Linux에서 조회한 허브: 대상 Base는 `online: true`, `management: supported`이고, snapshot
  최상위에 `power_base_removals`(목록)가 있었다. 같은 때 iPhone(수정 전 빌드)의 관리 화면은 "지원하지
  않음"을 표시했고 삭제 버튼이 없어 삭제 요청은 보내지 못했다.
- `PogoSnapshotMapper.map`은 `power_base_removals`를 읽어 `HomeSnapshot.powerBaseRemovals`와
  `reportsPowerBaseManagement`를 채운다. `AppModel`의 `apply(_:to:)`는 방 설정이 비어 있지 않으면 사용자의
  방과 이름을 입힌 `HomeSnapshot`을 새로 만드는데, 이 두 값을 넘기지 않아 기본값(`[]`, `false`)이 됐다.
  `PowerBaseManagementPresentation.availability`는 `false`를 "허브가 지원하지 않음"으로 판정한다.
- 앱에는 기본 방이 항상 있으므로 기기에서는 모든 snapshot에서 일어난다. 기존 test가 놓친 이유: 해석과
  표시 규칙의 test는 `AppModel`을 거치지 않았고, `AppModel`의 test 대부분은 방 설정 없이(그 경우
  `apply`는 허브의 snapshot을 그대로 돌려준다) 만들어졌다.

수정은 `PogoHome/PogoHome/App/AppModel.swift`의 그 생성에 두 값을 허브의 snapshot에서 그대로 넘기는 두
줄(과 주석)이다. 지원 여부를 켜 두거나 허브 버전으로 추정하는 코드는 없다.

### 수정 전의 실패와 수정 후

새 test `PogoHomeTests/AppModelPowerBaseManagementTests.swift`(12개)를 먼저 적어 수정 전 소스에서 실행했고
(같은 test 파일, 수정 두 줄만 뺀 상태), 수정 후 다시 실행했다. iPhone 18 Pro 시뮬레이터.

| | 수정 전 | 수정 후 |
|---|---|---|
| 12개 | 11개 실패, 1개 통과 | 12개 통과 |
| 대표 실패 | `("hubUnsupported") is not equal to ("available")`, `the hub sent power_base_removals`, `the hub's management is gone after sharing was turned on` | — |
| 통과한 1개 | 관리 필드가 없는 구형 허브는 "지원하지 않음" (수정 전에도 후에도 그래야 한다) | 같다 |

**실제 생산 경로라는 근거.** test가 넣는 것은 허브의 `/api/v1/snapshot` JSON(첫 GET의 응답과 SSE
`snapshot` 이벤트)뿐이고, 스크립트된 것은 전송 계층(`ControllableSensorAPITransport`)과 허브의 설정
API(`FakeSettingsHub`)다. 그 뒤는 앱이 실행하는 코드다: `LiveSensorDataSource` → `PogoSnapshotMapper` →
`AppModel`(수신, 방·이름 적용, 설정 편집, 설정 공유, 허브 전환) → `AppModel.snapshot`. 관리 화면의 상태는
`PowerBaseManagementSheet`가 읽는 것과 같은 호출(`PowerBaseHubTarget(appModel:)`,
`PowerBaseRemovalController.removal(for:in:)`, `PowerBaseManagementPresentation.state`)로 읽는다. 수정한
코드를 test 안에 복제하지 않았다. 화면을 그리지는 않았다.

12개가 확인하는 것:

- 방 설정이 있는 앱 + 지원하는 허브 + `supported` Base → 삭제 가능(`available`), "지원하지 않음" 문구 없음.
- 삭제 목록이 비어 있어도(`[]`) 지원 여부는 유지된다.
- `pending` → `released` → `completed`가 허브가 말한 그대로 온다: `pending`은 "삭제 대기"와 취소,
  `released`는 "등록 해제됨 · 삭제 확인 필요"와 "삭제 확인" 진입(완료가 아니다), `completed`만 "삭제
  완료"이고 남은 동작이 없다. 허브의 목록에서 빠진 Base의 작업이 기기 목록에 남는다. 결과를 모르는
  `sent` 작업에도 "삭제 확인"이 제공된다.
- 최초 수신(GET), 후속 snapshot(SSE), 그리고 홈 이름 변경·방 추가·센서 이름과 방 변경·방 이름 변경·방
  순서 변경·방 삭제 뒤마다 허브의 지원 여부와 삭제 작업이 그대로다.
- 설정 공유: 공유를 켠 직후, 허브를 통한 편집 뒤, 다른 기기의 변경이 도착한 뒤, 공유를 끈 뒤에도 같다.
- `HomeSnapshot`의 저장 값 가운데 방과 모듈을 뺀 전부가 허브의 snapshot과 같다(나중에 추가되는 값이
  같은 식으로 빠지면 실패한다). Watch용 재구성(`applyingConfiguration`)도 같은 결과다.
- 관리 필드가 없는 구형 허브는 "지원하지 않음"이고, 편집이나 새 snapshot으로 지원으로 바뀌지 않는다.
  관리 자격증명 없이 등록된 Base(`unsupported`)와 허브가 아무 말도 하지 않은 Base는 삭제할 수 없다.
  페어링되지 않은 기기에는 "지원하지 않음"이 아니라 페어링 안내가 나온다.
- 허브를 바꾸면 그 즉시(새 허브가 답하기 전에도) 이전 허브의 삭제 작업과 지원 여부가 남지 않고, 원래
  허브로 돌아오면 그 허브가 지금 말하는 것만 보인다.
- 센서가 0개인 Base도 관리 정보와 삭제 작업이 유지된다.

### 회귀 (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, Debug 전체 | 1037개 중 1015 통과, 실패 0, skip 22 |
| Mac Catalyst, AppModel·설정 공유·Power Base·snapshot·Watch 전달·빌드 정보 test 74개 클래스 | 682개 중 664 통과, 실패 0, skip 18 |
| `Scripts/test_pogo_app_version.py` | 181개 검사, 실패 0 |

- 이전 기록의 전체 회귀는 1025개였고, 늘어난 12개가 위의 새 test다. 기존 test의 실패는 없었다.
- skip은 환경 변수가 있어야 도는 렌더링 test, 한국어에서만 도는 번역 검사, 실제 망이 필요한 시험, 새로
  만든 QR PNG가 있어야 도는 판독 시험이다(이번에는 PNG를 만들지 않아 이전 기록보다 skip이 하나 많다).
  이번 변경에는 새 문구가 없다.
- **실행하지 않은 것:** iPad 시뮬레이터 전체 회귀, 한국어 실행, Mac Catalyst 전체, `PowerBaseBLEKit`의
  `swift test`(패키지는 바뀌지 않았다), 반복 실행(새 실패가 없었다).

### 빌드와 산출물

`GIT_OPTIONAL_LOCKS=0 Scripts/pogo_app_version.py build --configuration Release --destination
'generic/platform=iOS' --out …`으로 새 디렉터리에 만들었다(서명 포함). **개발 빌드다**(커밋하지 않은
트리, 빌드 종류 `development`, Release 구성). 어디에도 설치하지 않았다.

| | |
|---|---|
| 산출물 | `~/esp-builds/pbmgmt_20261007_app_device_release_signed/artifact/PogoHome.app` |
| manifest | 같은 디렉터리의 `manifest.json`, SHA-256 `ab2bdb14fdcb2e0e534198d8186dfc8bd120d512b24275a5b155c145a5567424`, 파일 60개 |
| 버전 | `1.1.1`, 빌드 번호 `4`. 번들 안의 위젯, Watch 앱, Watch 위젯도 `1.1.1 (4)` |
| 소스 식별 | commit `05375341f70d93c788b5f08889e312a023f83202`, dirty, 지문 `88fb331a…68d3`, 빌드 식별자 `05375341f70d+dirty.88fb331a4a67` |
| 대상 | `Release-iphoneos`, arm64, `iphoneos27.0` SDK(24A430), Xcode 27.0 (27A266a), 최소 iOS 26.0 |
| 서명 | Apple Development 인증서, Xcode가 관리하는 개발용 프로파일. `codesign --verify --deep --strict` 통과(앱, 위젯, Watch 앱, Watch 위젯). 프로파일 만료 2026-10-12 |

- manifest와 실제 번들을 따로 읽어 대조했다: 버전, 빌드 번호, 빌드 종류, commit, dirty, 소스 지문, 빌드
  식별자가 같다. `manifest-verify --match-current-tree --expect-version 1.1.1`과 `verify-bundle
  --expect-identity` 통과.
- 빌드 입력 364개 파일의 SHA-256 목록이 빌드 전후에 같다(도구의 자체 비교와 별도로 확인). 빌드와 test
  전후에 Git index 파일의 바이트도 같다.
- `Scripts/check_release_enrollment_surface.sh … release` 통과.
- 프로파일에 대상 iPhone이 들어 있는지는 확인하지 않았다(기기 식별값을 읽거나 적지 않았다).
- 이전 산출물과 그 manifest는 고치지 않았다. 이전에 설치된 `1.1.0 (3)`은 이 결함을 가진 빌드다.

### 따로 조사한 것 (고치지 않았다)

(이 두 가지는 같은 날의 `1.1.1 (5)`에서 고쳤다. 위 절. 아래는 `1.1.1 (4)`까지의 동작이다.)

둘 다 위 결함과 원인이 다르다. 한 번 실행하고 지운 임시 test로 실제 `AppModel`의 동작을 관찰했다.

**"상태 확인 중".** 관리 화면의 연결 표시는 `AppModel.health`가 `healthy`나 `attentionNeeded`일 때만
"연결됨/연결 끊김"을 말하고, 아니면 "상태 확인 중"이다(`HomeHealthState.isCurrentStateVerified`). 삭제 관리
값과는 무관하게 정해진다. `false`가 되는 경우는 ① 허브에 센서 모듈이 하나도 없음, ② 연결됨으로 보고된
센서 가운데 측정값이 아직 없는 것이 있음, ③ 허브가 목록을 복구하는 중으로 판단됨, ④ 연결이 끊겼거나
마지막 수신이 60초보다 오래됨이다. ①을 관찰했다: Base 1개(`online: true`), 센서 0개인 허브에 정상
연결된 상태에서 `health = waitingForData`, `isCurrentStateVerified = false`, 표시는 "상태 확인 중"이었다.
센서가 없는 동안 계속 그렇다. 현장 화면이 넷 중 어느 경우였는지는 그때의 센서 수와 연결 상태를 알아야
정할 수 있다. 이 값을 바꾸지 않았다.

**센서가 있던 마지막 Base의 등록 해제.** Base 1개와 센서 2개가 정상 표시되고 삭제 작업이 `accepted`까지
적용된 상태에서, 허브의 다음 snapshot(Base 없음, 센서 없음, 작업 `released`)을 보냈다. `AppModel`은 이를
적용하지 않았다(`isRegistryRecovering = true`, `health = recoveringRegistry`). 화면용 snapshot에는 센서
2개와 Base, `accepted` 작업이 남았고, "삭제 확인"은 제공되지 않았다. 허브의 작업 목록을 직접 읽은 값은
`released`였지만 관리 화면은 snapshot의 값을 먼저 쓴다. 완전한 목록을 받은 뒤에 온 "센서 0개" snapshot을
허브 재시작 중의 일시적인 상태로 보고 보류하는 기존 정책 때문이다. 앱을 새로 시작하면 보류할 기준이
없으므로 센서가 0개인 첫 snapshot이 적용된다(위 ①의 관찰이 그 경우다). 다른 Base의 센서가 남아 있으면
일어나지 않는다(새 test의 `released` 경우가 그렇다).

### 하지 않은 것

- 새 빌드를 iPhone에 설치하고 실행하기, 실제 허브의 snapshot으로 관리 화면 보기.
- 실제 삭제 요청, 등록 해제, 삭제 확인(영수증), 재등록. BLE와 보드를 쓰는 모든 것.
- Linux 허브 접속, 배포, 서비스 조작. 펌웨어·허브의 빌드와 test(바뀌지 않았다).
- 관리 화면을 실제로 그려서 보는 것(상태 계산까지만 확인했다).

## QR 입력 후속 수정 3건 (2026-10-06)

같은 날 구현한 설정 코드 QR 입력(`1.1.0 (3)`)을 검토하면서 재현된 결함 세 가지의 수정이다. 변경 내용은
[`CHANGELOG.md`](../CHANGELOG.md)의 "수정". 제품 버전, QR 형식 버전 `1`, 허브 API, BLE 규약은 그대로다.

**이 절의 어떤 것도 실물이 아니다.** 앱을 기기에 설치하지 않았고 실제 카메라·BLE·보드·허브를 쓰지 않았다.

### 기준

| | |
|---|---|
| 저장소 | `main`, `05375341f70d93c788b5f08889e312a023f83202`, 커밋하지 않은 작업 트리 |
| 수정 전 | `1.1.0 (3)`, 소스 지문 `6b5658a19fa8882f40137fd4885a73e219a77a4f3ac8d536d42ce3ead259ad27`, 빌드 식별자 `05375341f70d+dirty.6b5658a19fa8` |
| 수정 후 | `1.1.0 (3)`, 소스 지문 `5e08223434d995f7814c8afa35c703f88c23025311128a51382a19e7aa194976`, 빌드 식별자 `05375341f70d+dirty.5e08223434d9` |
| 도구 | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4, iOS 27.0 SDK·시뮬레이터 런타임, Python 3.9.6 |
| 펌웨어 저장소 | 읽기만 했다. 네 구성요소 `0.1.0`, 빌드 식별자가 작업 전후 같다 |

### 세 결함과 수정 전의 실패

검토자의 재현 프로그램(`/private/tmp/pogo-qr-review-20261006-repro/Repro.swift`)을 앱의 실제 소스
(`PowerBaseSetupCodeField`, `PowerBaseSetupQRIntake`, `PowerBaseSetupQRCamera`)와 실제 `PowerBaseBLEKit`으로
다시 컴파일해 수정 전 소스에서 실행했다. 결과는 검토자의 `result.txt`와 같았다.

```
manual_edit_preserved: false completion: applied
background_old_result_ignored: false completion: applied
pre_hub_change_picker_result_ignored: false completion: applied
```

같은 세 경우를 XCTest로 먼저 적어 수정 전 소스에서 실행했고, 세 개 모두 실패했다(직접 입력한 내용이 QR
코드로 바뀜, 백그라운드 전의 결과가 `applied`, 허브가 바뀐 뒤 돌아온 선택이 입력됨).

| | 수정 전 | 수정 후 |
|---|---|---|
| 직접 입력·붙여넣기 뒤의 이미지 결과 | 진행 중인 읽기가 남아 있어 입력을 덮어씀 | 사용자의 편집이 그 읽기를 끝낸다. 늦은 성공·실패 결과는 입력 칸도 안내도 바꾸지 않는다 |
| 백그라운드를 다녀온 이미지 결과 | 복귀하면 옛 작업이 다시 유효 | 백그라운드에 들어갈 때 이미지 작업이 끝난다. 복귀 뒤에도 무효이고 "읽기 중단" 안내만 남는다 |
| 선택 창이 열려 있던 동안의 변화 | 작업을 선택 창이 돌아온 뒤에 만들어, 옛 선택이 새 작업이 됨 | 작업을 선택 창을 여는 버튼에서 만든다. 선택·불러오기·판독·입력이 그 작업 번호로 이어지고, 그 사이 무효가 되면 선택은 버려진다 |

### 수정 후

재현 프로그램은 수정 뒤 원래 형태로는 컴파일되지 않는다(이미지 작업을 선택 창 없이 시작하는 호출이
없어졌다). 세 시나리오와 기대값은 그대로 두고 호출만 새 API에 맞췄으며, 세 번째에는 "결과가 돌아온
시점에 작업을 만드는" 예전 순서와 허브 A→B→A를 더했다.

```
manual_edit_preserved: true completion: ignored
background_old_result_ignored: true completion: ignored
pre_hub_change_picker_result_ignored: true completion: ignored answer_taken: false
scan_begun_at_return_time_without_a_picker_answer_ignored: true completion: ignored
picker_open_across_hub_a_b_a_ignored: true completion: ignored answer_taken: false
ordinary_image_scan_entered: true completion: applied repeat: ignored
```

새 test 24개(`PowerBaseSetupQRFollowUpTests` 23개, `PowerBaseSetupQRPickerPresentationTests` 1개)가 확인하는
것. 선택 창과 이미지 불러오기는 스크립트된 가짜이고, 버튼의 동작(`PowerBaseSetupQRRows.begin`)부터 선택
창의 응답을 받는 진입점, 입력 칸까지는 앱이 실행하는 코드다.

- **작업을 언제 만드는가.** 버튼을 누른 직후, 아무것도 고르기 전에 작업과 그 작업의 선택 창이 있다.
  선택 창의 응답은 그 작업에 전달되고, 그 사이 다른 작업이 만들어지지 않는다(작업 번호가 버튼을 누를
  때만 늘어난다). 선택 창이 응답하지 않은 작업에는 결과를 넣을 수 없다.
- **직접 입력.** 이미지를 불러오는 중에 입력하거나 붙여넣으면(이미 있는 글자와 같은 내용을 붙여넣어도)
  그 뒤의 성공·다른 보드·QR 없음·읽을 수 없는 이미지 결과가 모두 무시되고 안내도 생기지 않는다. 입력
  칸이 같은 글자를 다시 쓰는 것은 편집이 아니어서 작업이 이어지고, QR 코드가 들어간 것도 편집으로 보지
  않는다(완료 안내가 남는다). 세 화면의 form 각각에서 같은 결과.
- **백그라운드.** 불러오는 중이든 선택 창이 열려 있든 백그라운드에서 작업이 끝나고, 복귀 뒤 도착한 옛
  결과·옛 선택은 무시된다(선택은 불러오지도 않는다). 새로 고른 것은 입력된다. inactive는 아무것도
  끝내지 않는다. 카메라는 복귀 뒤 새로 켜지고, 멈추기 전 카메라의 늦은 검출은 무시된다.
- **선택 창이 열린 동안.** 허브 변경(A→B, A→B→A), 보드 변경(A→B, A→B→A), 화면 이탈과 복귀, 입력 줄이
  잠시 사라진 경우 모두 돌아온 선택이 버려진다. 불러오는 중에 같은 일이 생겨도 같다.
- **취소와 다시 고르기.** 파일 창을 취소하면 작업이 끝나고, 같은 파일을 다시 고르면(실제 PNG, 실제
  판독 경로) 입력된다. 사진 선택 창을 고르지 않고 닫은 뒤 다시 열 수 있다. 선택 창이 닫혔다는 통지가
  선택보다 먼저 와도 그 선택은 그 작업의 것이다.
- **늦은 callback.** 이전 선택 창의 늦은 닫힘·취소·선택, 이전 스캐너의 늦은 닫힘은 그 뒤에 시작한
  작업을 건드리지 않고, 새 작업의 응답은 정상 입력된다. 정상 입력은 결과가 몇 번 오든 한 번이다.
- **실제 선택 창.** 앱이 그리는 입력 줄을 창에 띄워, 버튼의 동작 뒤 시스템 선택 창(시뮬레이터: 사진
  선택기, Mac Catalyst: 파일 창)이 실제로 뜨고, 허브가 바뀌거나 작업을 닫으면 내려가며, 그동안 아래
  화면이 사라진 것으로 처리되지 않음을 확인. 사진·파일을 고르지는 않았다(test가 시스템 선택 창을
  조작할 수 없다).

### 회귀 (최종 트리)

| 대상 | 결과 |
|---|---|
| iPhone 13 mini 시뮬레이터, Debug 전체 | 1025개 중 1004 통과, 실패 0, skip 21 |
| iPad (A16) 시뮬레이터, Debug 전체 | 1025개 중 1004 통과, 실패 0, skip 21 |
| Mac Catalyst, Power Base·QR·빌드 정보 test 42개 클래스 | 432개 중 416 통과, 실패 0, skip 16 |
| iPhone 13 mini 한국어, QR 11개 클래스와 화면 문구 test | 107개 중 106 통과, 실패 0, skip 1 |
| `PowerBaseBLEKit` `swift test` (debug, release) | 각 94개 실행, 실패 0, skip 27 |

- skip은 환경 변수가 있어야 도는 렌더링·실망 시험, 한국어에서만 도는 번역 검사, ESP-IDF host harness가
  필요한 기존 상호운용 시험이다. 기존 test의 실패는 없었다. 수정 전 전체 회귀는 1001개였고, 늘어난 24개가
  위의 새 test다.
- 기존 QR test(파서, 보드 결합, 늦은 결과, 카메라 순서, 세 화면에서 QR 입력이 연결·보드 명령·허브 요청을
  0회 만든다는 것, 실제 이미지 디코딩)는 새 API에 맞춰 호출만 바꿨고 기대값은 그대로다. 이미지 작업은
  이제 "버튼 → 선택 창의 응답 → 결과"의 순서로 시작한다.
- 실제 이미지 디코딩: 펌웨어 저장소의 생성 도구(바뀌지 않았다)로 공개 가짜 값의 PNG 6개를 새로 만들어
  앱의 ImageIO → Vision 경로로 읽었다(시뮬레이터 두 대와 Mac Catalyst). 시뮬레이터는 Vision의 첫 번째
  검출기, Mac Catalyst는 현재 검출기로 읽는다는 점은 이전 기록과 같다.
- 반복 실행은 하지 않았다(새 실패가 없었다).

### 빌드와 산출물

`Scripts/pogo_app_version.py build … --no-sign`으로 새 디렉터리에 만들었다. **모두 개발 빌드다**(커밋하지
않은 트리, 빌드 종류 `development`, 서명 없음). 어디에도 설치하지 않았다.

| 산출물 (`~/esp-builds/…/artifact`) | 구성 | 대상 | manifest SHA-256 |
|---|---|---|---|
| `pogoqrfix_20261006_app_sim_debug` | Debug | iOS 시뮬레이터 | `0417705acc05272672eae46b8f18255da3764837f00fe0622a74919cbc22ab85` |
| `pogoqrfix_20261006_app_sim_release` | Release | iOS 시뮬레이터 | `81c6543ba5c4db2d29726c22c762cd2fcecec81a1dc5f7fa78ba91362844d271` |
| `pogoqrfix_20261006_app_device_debug` | Debug | iOS 기기 | `e794e13513a1dbe91c997f78e5be2c885fc7c8bcec0926ca4ab6d5f27f6b67a6` |
| `pogoqrfix_20261006_app_device_release` | Release | iOS 기기 | `832113a3ea1cf89f6347fbdd9977023dc45dfd7455fb2a7911d719b559dc9f8d` |
| `pogoqrfix_20261006_app_catalyst_debug` | Debug | Mac Catalyst | `4cbaf7dd0ddb26cce2f163dc7b062c5a8cfd8d22292c43626b73187bea09bf54` |
| `pogoqrfix_20261006_app_catalyst_release` | Release | Mac Catalyst | `355a6ef56b3bf9b43a0709aee544e7cbe17612d0f83b0637d38eb08835553d7c` |

- 여섯 개 모두 버전 `1.1.0`, 빌드 번호 `3`, dirty, 빌드 식별자 `05375341f70d+dirty.5e08223434d9`, 빌드 중
  입력 불변. `manifest-verify --match-current-tree --expect-version 1.1.0`과 `verify-bundle
  --expect-identity` 통과. 번들 안의 앱·위젯·Watch 앱·Watch 위젯은 모두 `1.1.0 (3)`이다.
- `Scripts/check_release_enrollment_surface.sh` 통과(Debug와 Release에 QR 입력 코드가 있고, Release에 DEBUG
  전용 시험 화면·문자열 표·pasteboard 접근이 없으며, 카메라 사용 설명은 앱에만 있다).
- 수정 전의 산출물(`~/esp-builds/pogoqr_20261006_app_*`)과 그 manifest는 고치지 않았다. 자체 무결성
  검증은 계속 통과하고, 현재 트리와의 일치는 통과하지 않는다. 그 산출물은 위 세 결함을 가진 빌드다.

### 하지 않은 것

- 실제 iPhone·iPad·Mac에서 사람이 사진 선택기·파일 창을 열어 고르거나 취소하는 것, 그때 시스템이
  보내는 callback의 실제 순서와 시점. 특히 사진 선택기가 고른 사진을 닫힘 통지와 어떤 순서로 주는지는
  문서에 없어서, 어느 순서든 받아들이도록 만들었을 뿐 실제 순서를 관찰하지는 않았다.
- 선택 창이 떠 있는 채로 실제로 홈 화면에 다녀오기(시스템이 선택 창을 어떻게 다루는지 포함).
- 실제 키보드 입력, 실제 붙여넣기 버튼(시스템의 붙여넣기 허용 과정 포함).
- 실제 카메라, 실제 보드·BLE·허브로 이어지는 등록·재등록·삭제 확인.
- 펌웨어·Linux bridge의 빌드와 test(바뀌지 않았다).

다음 실물 시험에는 펌웨어 저장소 기록의 절차에 다음을 더한다: 사진을 고른 직후(읽는 중)에 코드를 한 글자
입력해 QR 코드가 덮어쓰지 않는지, 선택 창을 연 채 홈에 다녀온 뒤 고른 사진이 입력되지 않고 안내가
나오는지, 선택 창을 취소한 뒤 같은 사진을 다시 골라 입력되는지.
