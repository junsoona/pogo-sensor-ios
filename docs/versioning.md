# 앱 버전 관리와 빌드 식별

조각보 홈 앱(iOS·iPadOS·Mac Catalyst, Watch 앱, 위젯)의 버전 규칙과 도구다. 펌웨어·허브 저장소의
`docs/versioning.md`와 같은 원칙을 따르고, 소스 지문·빌드 식별자·manifest의 형식도 같다. 체계는
2026-10-06에 도입했다.

## 서로 다른 것들

| 이름 | 예 | Info.plist | 누가 정하나 |
|---|---|---|---|
| 제품 버전 | `1.0.0` | `CFBundleShortVersionString` | 사람이 `Version.xcconfig`를 고친다 |
| 빌드 번호 | `2` | `CFBundleVersion` | 사람이 `Version.xcconfig`를 고친다 |
| 빌드 종류 | `development` / `release` / `unknown` | `PogoBuildKind` | 빌드 도구에 명시한다 |
| 소스 식별 정보 | commit 전체 SHA, dirty, 소스 지문, 빌드 식별자 | `PogoBuildCommit`, `PogoBuildDirty`, `PogoBuildSourceFingerprint`, `PogoBuildID` | 빌드 도구가 계산한다 |
| 빌드 구성 | Debug / Release | — | Xcode |

- **Apple의 두 숫자 필드에는 숫자만 넣는다.** `dev`, `-beta`, Git SHA를 넣지 않는다. 개발 빌드라는
  사실과 소스 위치는 별도의 `PogoBuild*` 키에 있다.
- **Release 구성은 정식 배포가 아니다.** Release 구성으로 컴파일했어도 커밋하지 않은 소스에서
  나왔거나 release 모드로 만들지 않았으면 개발 빌드다.
- **자동으로 오르는 숫자는 없다.** 컴파일할 때 프로젝트 파일이나 버전 파일을 고쳐 쓰는 단계는
  없다(빌드 단계 스크립트도 없다).

## 버전의 단일 원본

```
PogoHome/Config/Version.xcconfig
```

```
MARKETING_VERSION = 1.2.1
CURRENT_PROJECT_VERSION = 10
POGO_BUILD_COMMIT = unknown
POGO_BUILD_DIRTY = unknown
POGO_BUILD_SOURCE_FINGERPRINT = unknown
POGO_BUILD_ID = unknown
POGO_BUILD_KIND = unknown
```

- 프로젝트의 Debug·Release 구성이 이 파일을 기반으로 한다. **앱, Watch 앱, 두 위젯, 테스트 타깃은
  모두 여기서 값을 받는다.** 어느 타깃도 `MARKETING_VERSION`·`CURRENT_PROJECT_VERSION`을 직접
  정하지 않고, 어느 Info.plist도 숫자를 직접 적지 않는다. `Scripts/pogo_app_version.py check`가 이를
  검사한다.
- 이전 표기 `1.0`(빌드 `1`)을 낮추지 않고 `1.0.0`으로 정규화했고, 새 기준 빌드 번호는 `2`다.
  `1.0.0 (2)`는 이 체계의 기준선이며 App Store·TestFlight에 올린 빌드가 아니다.
- 2026-10-06에 설정 코드의 QR 입력을 추가하면서 `1.1.0 (3)`으로 올렸다(기능 추가: MINOR, 빌드 번호는
  다음 숫자). 이것도 개발 빌드만 있는 버전이다. 이 문서의 다른 예(`1.0.0`, `app-v1.0.0-b2`)는 형식을
  보여 주는 예다.
- 2026-10-07에 Power Base 관리 화면이 지원하는 허브를 "지원하지 않음"으로 표시하던 결함을 고치면서
  `1.1.1 (4)`로 올렸다(사용자가 보는 기능은 그대로인 수정: PATCH. iPhone에 다시 설치할 빌드를 만들므로
  빌드 번호는 다음 숫자). 이것도 개발 빌드만 있는 버전이다.
- 같은 날 그 수정의 후속 작업(마지막 Power Base를 삭제할 때 최신 삭제 상태가 화면에 오지 않던 것, 센서가
  없는 Power Base의 "상태 확인 중")을 넣으면서 `1.1.1 (5)`가 됐다. 같은 수정 묶음이라 제품 버전은 그대로이고,
  기기에 전달할 빌드를 새로 만들므로 빌드 번호만 올렸다. `1.1.1 (4)`는 만들기만 하고 설치하지 않은 빌드다.
- 2026-10-08에 `1.1.1 (5)`의 삭제 판정(등록 해제된 Power Base인지를 시각의 차이로 가리던 것)을 고치면서
  `1.1.1 (6)`이 됐다. 같은 수정 묶음이라 제품 버전은 그대로다. `1.1.1 (5)`도 만들기만 하고 설치하지 않았다.
- 같은 날 Power Base 삭제의 자동 확인(삭제를 한 번 확인하면 '삭제 완료'까지 사용자가 더 할 일이 없는 흐름)을
  넣으면서 `1.2.0 (7)`로 올렸다(사용자 기능 추가: MINOR, 빌드 번호는 다음 숫자). 펌웨어 저장소의 Power Base
  0.2.0·Linux bridge 0.2.0과 함께 만든 변경이지만 숫자를 맞춘 것은 아니다. 이것도 개발 빌드만 있는 버전이다.
- 같은 날 가장 큰 글자 크기에서 잘리던 목록 아이콘을 고치고, "Power Base 추가"·"다른 허브에 연결하기"에
  들어오면 주변 보드 찾기를 스스로 시작하게 하면서 `1.2.0 (8)`이 됐다. 제품 버전은 그대로다: `1.2.0`은 아직
  내보내지 않은 개발 후보이고, 이 변경은 그 후보의 찾기 흐름과 접근성을 다듬은 것이며 API·BLE 규약·저장
  형식을 바꾸지 않는다. 기기에 전달할 빌드를 새로 만들므로 빌드 번호만 올렸다. `1.2.0 (7)`은 만들기만 하고
  설치하지 않은 빌드다.
- 2026-10-09에 `1.2.0 (8)`의 결함(재등록한 Power Base가 이전 삭제 기록 때문에 '삭제 완료'로 표시되고 다시
  삭제할 수 없던 것)을 고치고 삭제 완료 뒤의 동선과 설명 문구를 정리하면서 `1.2.1 (9)`로 올렸다(기존 기능의
  결함과 표현·동선의 수정: PATCH. 새 기기에 전달할 빌드를 만들므로 빌드 번호는 다음 숫자). `1.2.0 (8)`은
  iPhone에 설치해 실물 시험에 쓴 빌드다. API·BLE 규약·저장 형식, 펌웨어·허브의 버전은 바꾸지 않았다. 이것도
  개발 빌드만 있는 버전이다.
- 같은 날 `1.2.1 (9)`의 검토에서 나온 삭제 완료 안내의 결함(이전 완료 기록을 새 요청의 완료로 오인, 함께 끝난
  삭제 가운데 하나만 전달)과 백그라운드에서 안내가 지나가 버릴 수 있던 것을 고치면서 `1.2.1 (10)`이 됐다. 같은
  PATCH의 후속 수정이라 제품 버전은 그대로이고, 새 후보를 구별하기 위해 빌드 번호만 올렸다. `1.2.1 (9)`는
  만들기만 하고 설치하지 않은 빌드다.
- 같은 날 삭제 확인창의 문구 한 문장("다시 쓰려면" → "다시 사용하려면")을 바꾸면서 `1.2.1 (11)`이 됐다. 표현만
  고친 같은 PATCH의 후속 수정이라 제품 버전은 그대로이고, 새 후보를 `(10)`과 구별하기 위해 빌드 번호만 올렸다.
  API·BLE 규약·저장 형식은 그대로다.
- 2026-10-10에 기기 탭 센서 카드의 이름과 방 이름 사이 간격을 넓히면서 `1.2.1 (12)`가 됐다. 기존 화면의 모양만
  고친 같은 PATCH의 후속 수정이라 제품 버전은 그대로이고, 새 기기용 후보를 만들므로 빌드 번호만 올렸다.
  API·BLE 규약·저장 형식은 그대로다.
- 같은 날 "허브 목록에서 제거"(돌아오지 않는 Power Base를 연결된 허브의 목록에서 지우는 기능)를 넣으면서
  `1.3.0 (13)`으로 올렸다(사용자 기능 추가: MINOR, 빌드 번호는 다음 숫자). 펌웨어 저장소의 Linux bridge 0.4.0과
  함께 만든 변경이다. 허브 API의 더해진 필드와 경로를 쓰고, 그것이 없는 허브에는 이 기능을 보여 주지 않는다.
  BLE 규약과 앱의 저장 형식은 그대로다. 이것도 개발 빌드만 있는 버전이다.
- 같은 날 그 기능의 독립 검토에서 나온 결함을 고치면서 `1.3.1 (14)`가 됐다(기존 기능의 결함과 표시의 수정:
  PATCH. 새 기기용 후보를 만들므로 빌드 번호는 다음 숫자). 펌웨어 저장소의 Linux bridge 0.4.1과 함께 만든
  변경이다. 허브 API에서 선택 필드 하나(`list_removed`)를 더 읽고, 그것이 없는 허브와도 동작한다. BLE 규약과
  앱의 저장 형식은 그대로다. 이것도 개발 빌드만 있는 버전이다.
- 같은 날 `1.3.1`을 다시 독립 검토해 남은 결함(다른 기기의 **삭제**를 통째로 놓친 기기의 옛 센서)을 고치면서
  `1.3.2 (15)`가 됐다(결함 수정: PATCH. 새 기기용 후보: 다음 빌드 번호. 15는 처음 쓰는 번호다). 펌웨어 저장소의
  Linux bridge 0.4.2와 함께 만든 변경이다. 허브 API에서 선택 필드 하나(`power_base_departures`)를 더 읽고, 그것이
  없는 허브(0.4.1 이하)에는 `1.3.1`과 같이 동작한다 — 그 조합에서는 그 결함이 남는다. 화면·문구·BLE 규약·앱의 저장
  형식은 그대로다. 이것도 개발 빌드만 있는 버전이다.
- 2026-10-11에 `1.3.2`의 독립 검토에서 나온 둘(과거의 삭제 요청이 다시 등록된 Base의 새 등록을 삭제하는 결함,
  오래된 snapshot 응답이 새 상태를 되돌리는 표시 문제)을 고치면서 `1.3.3 (16)`이 됐다(사용자 기능을 유지하는 결함
  수정: PATCH. 새 기기용 후보: 다음 빌드 번호. 16은 처음 쓰는 번호다). 펌웨어 저장소의 Linux bridge 0.5.0과 함께
  만든 변경이고, **이번에는 조합이 달라진다**: 삭제 요청이 확인 당시의 등록을 싣게 됐고(`record`, `removal_serial`,
  `request_id`), 그 요청을 받지 못하는 허브(0.4.2 이하)에는 앱이 삭제를 요청하지 않는다 — 그 허브에서는 "허브를
  업데이트해야 합니다"를 보여 준다. 앱의 버전을 MINOR로 올리지 않은 이유: 앱의 사용자 기능은 늘지도 줄지도 않았고
  (같은 삭제를 더 안전한 요청으로 한다), 허브 쪽 계약의 변화는 허브의 버전(0.4.2 → 0.5.0)이 말한다. 화면에는 응답
  없는 요청의 "다시 요청" 줄과 거부 문구 하나가 늘었다. BLE 규약과 앱의 저장 형식은 그대로다. 이것도 개발 빌드만
  있는 버전이다.
- 같은 날 `1.3.3`의 작업이 찾고 독립 검토가 재현한 결함(실제 연결에서 허브의 event가 적용되지 않고 그 data 줄이
  쌓이는 것)을 고치면서 `1.3.4 (17)`이 됐다(결함 수정: PATCH. 새 기기용 후보: 다음 빌드 번호. 17은 처음 쓰는
  번호다). **앱만의 변경이다**: Linux bridge 0.5.0·Power Base 0.3.0·module 0.1.1·RCP 0.1.0, 허브 API, BLE 규약, 앱의
  저장 형식은 그대로다. 화면과 문구도 그대로이고, 화면이 허브를 따라가는 빠르기만 달라진다(5초 간격의 `GET` →
  허브가 event를 보내는 대로. `GET`은 남아 있다). 이것도 개발 빌드만 있는 버전이다.
- 같은 날 실제 Apple Watch Series 7(arm64_32)에서 Watch 앱이 실행 직후 종료되는 결함(허브의 32비트 unsigned 값
  `removal_serial`의 범위 검사가 32비트 `Int`에서 멈추는 것)을 고치면서 `1.3.5 (18)`이 됐다(결함 수정: PATCH. 새 기기용
  후보: 다음 빌드 번호. 18은 처음 쓰는 번호다 — 기존 산출물의 manifest와 문서, 태그에 없음을 확인했다). **앱만의
  변경이다**: Linux bridge 0.5.0·Power Base 0.3.0·module 0.1.1·RCP 0.1.0, 허브 API(필드 이름·숫자의 뜻·요청 본문), BLE
  규약, 앱의 저장 형식은 그대로다. 그 숫자들을 담는 앱 안의 타입만 64비트 고정 폭이 됐다. 화면과 문구도 그대로다. 이것도
  개발 빌드만 있는 버전이다.
- 2026-11-09에 센서 역할을 바꿔도 이전 보드 이름이 남는 표시 결함을 고치면서 `1.3.6 (19)`로 올렸다.
  기존 동작의 수정이므로 PATCH이며, 새 기기용 빌드를 구별하기 위해 빌드 번호를 18에서 19로 올렸다.
  보드 ID 대신 현재 수신 채널 정보로 기본 이름을 정한다. API가 모델 번호를 보내지 않으므로 종류 이름을 사용하고,
  사용자 지정 이름과 방은 보존한다. API·BLE·저장 형식, 펌웨어·허브 버전은 그대로다. 구현·호스트 검증까지만 완료했고
  전체 앱 빌드·서명 후보·설치는 완료하지 않았다.
- `POGO_BUILD_*`의 기본값은 `unknown`이다. Xcode에서 그냥 빌드한 앱은 소스 식별 정보를 "알 수
  없음"으로 표시한다. 값은 추정하지 않는다.

### 언제 올리나

| 값 | 기준 |
|---|---|
| 빌드 번호 | 다른 사람이나 다른 기기에 전달하는 빌드를 새로 만들 때마다 1 올린다. 줄이거나 재사용하지 않고, 제품 버전이 바뀌어도 되돌리지 않는다 |
| PATCH | 사용자가 보는 기능이 그대로인 수정 |
| MINOR | 기능 추가 |
| MAJOR | 이전 허브·보드와 더는 동작하지 않거나, 저장된 앱 데이터를 이어 쓸 수 없는 변경 |

앱 버전을 올리는 것만으로 허브 API나 BLE 규약의 의미가 바뀌지 않는다. 앱은 허브·보드가 무엇을
지원하는지를 `schema_version`, 선택 필드의 유무, BLE capability로 판단한다. **버전 문자열을 비교해
기능이나 보안을 판단하지 않는다.**

## 소스 식별 정보와 빌드 입력

소스 지문은 앱의 **빌드 입력 전체**(추적하지 않는 새 파일 포함)의 SHA-256이다. 형식은 펌웨어 저장소와
같고 구성요소 이름은 `app`이다.

| 빌드 입력 | 내용 |
|---|---|
| `PogoHome/` | Xcode 프로젝트, 소스, 패키지, 리소스, `Config/Version.xcconfig` |
| `PogoHome/Scripts/pogo_app_version.py` | 빌드 도구. 빌드에 `POGO_BUILD_*`를 넘기고 무엇이 manifest를 받는지 정한다 |

- **빌드 도구 자신이 입력이다.** 도구가 바뀌면 같은 소스에서도 다른 식별 정보가 번들에 들어갈 수
  있다. `Scripts/`의 나머지(release 표면 검사, 도구의 test)는 아무것도 빌드하지 않으므로 입력이
  아니다. 입력은 이름을 하나씩 적는다(`INCLUDED_FILES`).
- 들어가지 않는 것: `.build/`, `.swiftpm/`, `DerivedData/`, `build/`, `xcuserdata/`, `*.xcresult`,
  `__pycache__/`, `.DS_Store`, 로그, 도구가 만드는 `manifest.json`·`SOURCE_INFO.json`. 도구 자신을
  넣는다고 재귀가 생기지 않는다: 도구가 **만드는 것**이 빠져 있기 때문이다.
- **dirty는 지문과 같은 파일 집합으로 판정한다**(`is_input`). 빌드 입력이 HEAD와 정확히 같지 않으면
  dirty다: 수정·stage·삭제·이름 변경·미추적, 그리고 Git이 무시하지만 Xcode가 컴파일하는 파일. Git이
  추적하지만 입력이 아닌 파일은 지문도 dirty도 바꾸지 않는다.
- 빌드 식별자는 `<commit 앞 12자리>[+dirty].<지문 앞 12자리>`.
- Git이 없는 소스 묶음에서는 맨 위의 `SOURCE_INFO.json`이 지금 빌드 입력의 지문과 일치할 때만 원래
  commit을 유지하고, 아니면 `unknown`이다. 빌드 도구만 고쳐도 일치하지 않는다. SHA를 지어내지
  않는다.

2026-10-06의 첫 구현은 `Scripts/` 전체를 지문에서 빼고 있어서, 빌드 도구를 고쳐도 지문과 빌드
식별자가 그대로였다(검토에서 재현). 같은 날 위와 같이 고쳤다. 그 전에 만든 빌드의 식별자는 당시
규칙으로 계산된 값이다.

## 앱에서 확인하기

- **설정 > 앱 정보**: 버전, 빌드 번호.
- **설정 > 앱 정보 > 빌드 상세 정보**: 빌드 종류, 빌드 식별자, 커밋, 소스 상태, 소스 지문. 기록되지
  않은 값은 "알 수 없음".
- 등록 화면 등 일반 화면에는 소스 식별 정보를 넣지 않았다.
- 앱은 허브·Power Base·센서의 버전을 **표시하지 않는다.** 허브의 health가 선택 필드 `build`를 주면
  읽을 수는 있지만(없거나 형식이 달라도 오류가 아니다) 어떤 판단에도 쓰지 않고, 보드의 버전을
  앱으로 보내는 프로토콜은 없다. 추정해서 보여 주지 않는다.

## 도구

```bash
PogoHome/Scripts/pogo_app_version.py versions        # app 1.3.5 (18)
PogoHome/Scripts/pogo_app_version.py check           # 모든 타깃이 Version.xcconfig만 쓰는가
PogoHome/Scripts/pogo_app_version.py identity        # commit, dirty, 지문, 빌드 식별자
PogoHome/Scripts/pogo_app_version.py settings        # 이번 빌드에 넘길 POGO_BUILD_* 값
PogoHome/Scripts/pogo_app_version.py verify-bundle <.app> [--expect-identity]
PogoHome/Scripts/pogo_app_version.py manifest-verify --dir <artifact> [--release] [--match-current-tree]
PogoHome/Scripts/pogo_app_version.py files           # 지문에 들어가는 파일(빌드 입력) 목록
PogoHome/Scripts/pogo_app_version.py source-info --out <저장소 밖>/SOURCE_INFO.json
```

도구는 소스 트리와 Git index를 바꾸지 않고, 버전을 올리지 않으며, 설치·업로드를 하지 않는다.

### 식별 정보가 들어간 빌드

```bash
PogoHome/Scripts/pogo_app_version.py build --configuration Release \
    --destination 'generic/platform=iOS' --out ~/esp-builds/<새 디렉터리> [--no-sign] [--release]
```

1. 프로젝트가 `Version.xcconfig`만 쓰는지 확인한다.
2. 소스 식별 정보를 계산해 `POGO_BUILD_*`를 **이번 xcodebuild 호출의 설정으로만** 넘긴다. 프로젝트
   파일과 xcconfig는 바뀌지 않는다.
3. `--out`은 없거나 비어 있는 저장소 밖 디렉터리여야 한다. DerivedData도 그 안에 만든다.
4. 빌드가 끝나면 소스 식별 정보를 다시 계산한다(같은 입력 집합). 소스든 빌드 도구든 달라졌으면
   그 출력은 어느 한 트리의 빌드가 아니므로 manifest 없이 실패한다.
5. 만들어진 번들의 Info.plist를 읽어, 앱과 그 안의 위젯·Watch 앱이 모두 `Version.xcconfig`의 버전과
   빌드 번호를 말하는지, `PogoBuild*`가 방금 계산한 값인지 확인한다.
6. 번들을 `<out>/artifact/`로 복사하고 `manifest.json`을 쓴 뒤 바로 검증한다(무결성과 현재 트리와의
   일치 둘 다).

`--release`는 소스 범위가 clean이고 commit을 알 때만 받아들인다. 없으면 개발 빌드다.

Xcode에서 직접 빌드해도 버전과 빌드 번호는 같다. 소스 식별 정보만 "알 수 없음"이 된다.

## 빌드 manifest

`artifact/manifest.json` (스키마 `1`): 구성요소 `app`, 버전, 빌드 번호, 빌드 식별자, 빌드 종류,
`source`(commit, dirty, 지문, origin, 빌드 중 입력 불변 여부), `build`(구성, destination, 대상 플랫폼,
Xcode·Swift 버전), `bundle_says`(번들 자신이 말하는 값), `files[]`(번들의 모든 파일의 상대 경로·크기·
SHA-256), `status`(`deployed: false`, `hardware_verified: false`).

위 필드는 모두 필수다. `manifest-verify`는 세 단계로 확인하고, 뒤 단계가 앞 단계를 대신하지 않는다.

1. **형식.** 필수 필드와 그 형식(`build.configuration`은 `Debug` 또는 `Release`,
   `build.target`은 그 구성의 products 디렉터리 이름).
2. **실제 파일과 실제 번들.** 번들의 모든 파일(경로·크기·SHA-256, 목록에 없는 파일 포함). 그리고
   번들의 Info.plist를 **다시 읽어서** 앱과 내장된 위젯·Watch 앱의 버전·빌드 번호, `PogoBuild*`
   (빌드 식별자·종류·commit·dirty·지문), 플랫폼(`DTPlatformName`과 `build.target`)을 manifest와
   대조한다. manifest의 `bundle_says`는 근거로 쓰지 않고, 거기 적힌 내용이 실제 번들과 다르면
   실패다.
3. **호출자의 기대.** `--release`, `--expect-version`은 그 위에 추가로 본다.

**검증했다고 말하지 않는 것.** 번들에서 읽을 수 없는 값은 manifest가 적은 그대로이고 통과 메시지의
"not verified" 줄에 나온다: `build.configuration`(Debug인지 Release인지는 번들에 적혀 있지 않다),
`build.destination`, `build.toolchain`, `created_utc`, `source.origin`,
`source.inputs_unchanged_during_build`. Mac Catalyst와 일반 macOS 빌드도 `DTPlatformName`만으로는
구분되지 않는다.

**두 가지 질문.** 기본 검증은 산출물의 자체 무결성이다(소스 트리가 필요 없다). 그 빌드가 **지금 이
트리**의 빌드인지는 `--match-current-tree`가 따로 답한다. 트리가 바뀌면 이전 산출물은 첫 질문에는 계속
통과하고 둘째에는 통과하지 않는다. 이전 산출물과 manifest는 고치지 않는다.

**manifest는 파일을 설명할 뿐이다.** 설치, TestFlight 업로드, 기기 시험은 별도의 기록에 남긴다.
앱과 펌웨어·허브를 함께 내보낸 조합의 기록은 펌웨어 저장소의 `docs/release-records/`에 한 파일로
두고, 이 저장소의 CHANGELOG가 그 파일 이름을 가리킨다.

## Git과 태그

- 도구와 빌드는 stage·commit·tag·push를 하지 않는다. 검토 뒤 사람이 한다.
- 커밋 전: `CHANGELOG.md`의 `Unreleased`에 적고, 필요하면 `Version.xcconfig`를 고치고,
  `python3 PogoHome/Scripts/test_pogo_app_version.py`와 앱 test를 실행한다.
- 배포 후보: clean 트리에서 `build … --release` → `manifest-verify --release` 통과 → 설치·시험 기록 →
  태그.
- 태그 이름은 `app-v<제품 버전>-b<빌드 번호>`(예 `app-v1.0.0-b2`), release 빌드를 만든 바로 그 커밋에
  annotated 태그로 붙인다. 한 번 붙인 태그는 옮기지 않는다.

## 과거 빌드

2026-10-06 이전의 앱 빌드는 `1.0 (1)`로만 표시됐고 소스 식별 정보가 없다. 분류는 "기존 버전 표기 /
명시 버전 미관리"다. 소급해서 버전을 붙이거나 다시 포장하지 않는다. 기기에 남아 있는 `1.0 (1)`이
어느 커밋의 것인지는 이 저장소에서 알 수 없다.
