# 드롭다운에 계정 이름 표시

날짜: 2026-07-28

## 배경

드롭다운은 어느 계정의 사용량인지 알려주지 않는다. Claude 헤더는 `Claude Code · usage ↗`,
Codex 헤더는 `Codex · prolite · usage ↗`로 제공자와 플랜만 있다 (`app/MenuBuilder.swift:75`, `:139`).

두 사용량 수치 모두 **계정 단위**로 집계된다. 회사 계정과 개인 계정을 오가거나, 로그인이 의도치
않게 바뀐 상황에서 지금 화면의 83%가 어느 계정의 83%인지 확인할 방법이 없다.

## 데이터 소스 조사 결과

로컬 파일 실측으로 확인한 사실:

| 후보 | 계정 이메일 |
|---|---|
| Anthropic 사용량 API 응답 (`/api/oauth/usage`) | **없음**. 응답 최상위 키는 `five_hour`, `seven_day`, `limits`, `spend` 등 사용량 필드뿐 |
| 키체인 `Claude Code-credentials` | **없음**. `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType`, `rateLimitTier` |
| `~/.claude.json` → `oauthAccount` | **있음**. `emailAddress`, `displayName`, `organizationName`, `organizationType` |
| `~/.codex/auth.json` → `tokens.id_token` (JWT payload) | **있음**. `email`, `name`, `https://api.openai.com/auth.chatgpt_plan_type` |

따라서 **추가 네트워크 호출도 새 권한도 필요 없다**. 로컬 파싱만 추가한다.

중요한 귀결: Claude 계정 이름의 유일한 출처가 `~/.claude.json`이고, 이 파일은 Claude Code CLI가
만든다. 앱은 키체인 토큰만으로도 동작하므로, CLI를 쓰지 않는 사용자에게는 이 파일이 없을 수 있다.
그 경우 Claude 헤더는 계정 없이 지금 모습 그대로 둔다.

## 확정된 사양

브라우저 목업으로 후보를 비교해 아래를 확정했다.

| 항목 | 결정 |
|---|---|
| 표시 값 | **이메일 로컬파트** (`@` 앞). `dev.account@example.com` → `dev.account` |
| 배치 | **헤더 인라인**. 줄을 추가하지 않는다 |
| 설정 | Settings > Display에 체크박스, **기본 켜짐** |
| 적용 대상 | 네이티브 앱(`app/`)만 |

```
✳ Claude Code · dev.account · usage ↗
  5h    ▕████████████████████▏ 100% remaining  ·  resets 4h 47m  ↗
  week  ▕████████████████▒▒▒▒▏  83% remaining  ·  resets 5d 0h   ↗
  live · updated just now

◎ Codex · prolite · dev.account · usage ↗
  week  ▕████████████████████▏ 100% remaining  ·  resets 7d 0h   ↗
```

로컬파트를 쓰는 이유: 계정 식별에 충분하면서 도메인이 빠져 화면 공유 시 노출이 줄고, 두 제공자에
같은 규칙을 적용할 수 있다. `displayName`은 제공자마다 값이 달라(Claude `Dev Account` vs Codex
`dev.account`) 같은 계정인데 다르게 보인다.

배치를 헤더 인라인으로 하는 이유: 세로 공간을 쓰지 않는다. 대안이던 "상태 줄 병합"은 캐시 경고
(`⚠ cached 3m ago — check login/network`)가 뜨는 순간 계정 이름과 경고 문구가 한 줄에 섞인다 —
로그인을 확인하고 싶은 바로 그 상황에서 가장 읽기 나빠진다.

기본을 켜짐으로 두는 이유: 요청된 기능이 설치 직후 보여야 하고, 끄는 건 방송·발표 직전 한 번이면
된다.

## 적용 범위 밖

- `claude-codex-usage.2m.js` (SwiftBar 플러그인) — 동기화하지 않는다
- `windows/` (실험적 트레이 앱)
- 계정 전환 UI, 다중 계정 동시 표시
- 조직 이름(`organizationName`) 및 플랜 등급 노출 — 헤더 인라인 배치에서는 길이가 감당되지 않는다.
  Codex의 `prolite`는 이미 표시 중이므로 그대로 둔다

## 구현 설계

### 1. 새 모듈 `app/Account.swift`

계정 조회를 사용량 파이프라인과 분리한다.

```swift
struct AccountNames {
  let claude: String?
  let codex: String?
}

func accountNames() -> AccountNames
func emailLocalPart(_ email: String?) -> String?   // 테스트를 위해 internal
func jwtEmail(_ idToken: String?) -> String?       // 테스트를 위해 internal
```

- **Claude**: `~/.claude.json` → `oauthAccount.emailAddress`
- **Codex**: `~/.codex/auth.json` → `tokens.id_token` → JWT payload → `email`

`ClaudeUsage`/`CodexUsage` 구조체에 넣지 않는 이유: `CodexUsage`는 `saveCache()`로 SwiftBar
위젯과 **공유하는 JSON 포맷**에 직렬화된다 (`app/CodexUsage.swift:83-99`). 계정을 넣으면 공유
포맷이 오염되고, 오프라인 캐시 폴백 경로에서 예전 계정 이름이 되살아난다 — 계정을 바꿨을 때
정확히 틀린 값을 보여주게 된다. 계정은 로그인 파일에서, 사용량은 API에서 오고 수명이 다르다.

`MenuBuilder`에서 직접 읽지 않는 이유: `buildMenu`가 순수 함수라는 성질이 깨지고 `--dump-menu`
검증이 실제 홈 디렉터리에 의존하게 된다.

### 2. JWT 디코딩

payload(두 번째 세그먼트)만 base64url 디코드해 JSON으로 읽는다. **서명은 검증하지 않는다** —
우리 앱이 방금 읽은 우리 로컬 로그인 파일이고, 값은 표시용 문자열일 뿐이다. 검증할 공개키도 없다.

base64url → base64 변환이 필요하다: `-`→`+`, `_`→`/`, 길이가 4의 배수가 되도록 `=` 패딩 추가.
`Data(base64Encoded:)`는 패딩 없는 문자열을 거부한다.

`access_token`과 `refresh_token`은 읽지 않는다. 디코드된 payload는 로그에 남기지 않는다.

### 3. mtime 메모 캐시

`~/.claude.json`은 실측 239KB이고 새로고침마다 파싱된다. `(경로, mtime, size)`가 직전과 같으면
이전 결과를 재사용한다. 파일이 바뀔 때만 파싱한다.

캐시는 프로세스 메모리에만 둔다 — 디스크에 쓰지 않는다. 계정 이름을 새 파일에 복제할 이유가 없다.

### 4. `Snapshot` 확장과 헤더 조립

`Snapshot`(`app/MenuBuilder.swift:8-15`)에 `accounts: AccountNames` 추가.
`collectSnapshot()`에서 채운다.

헤더 문자열은 순수 함수 두 개로 뽑아 파일시스템 없이 테스트한다:

```swift
func claudeHeaderTitle(account: String?, usageWord: String) -> String
func codexHeaderTitle(plan: String?, limitId: String?, account: String?, usageWord: String) -> String
```

- 계정이 있으면 제공자·플랜 뒤에 ` · 이름`을 끼운다
- 계정이 없으면 **그 조각만 통째로 생략**한다. 에러 행도 자리표시자도 없다
- Codex의 기존 `plan ?? limitId` 접미사 로직(`app/MenuBuilder.swift:137`)은 그대로 유지하고
  그 뒤에 계정을 붙인다

### 5. 길이 제한

로컬파트가 **20자를 넘으면 앞 20자만 남기고 `…`을 붙인다** (결과는 21자). `firstname.lastname.platform` 같은
회사 계정이 헤더를 밀어내 메뉴 전체 폭을 늘리는 것을 막는다. 자를 때는 문자(Character) 단위로
세어 이모지·한글이 깨지지 않게 한다.

### 6. 설정 `showAccountName`

Settings > Display 탭의 Appearance 섹션에 체크박스 하나. 기존 `toggleMetric`
패턴(`app/main.swift:1132`)을 재사용한다.

기본값이 켜짐이므로 읽기는 `UserDefaults.standard.object(forKey:) == nil ? true : bool(forKey:)`.
`bool(forKey:)`만 쓰면 키가 없을 때 `false`가 되어 기본이 꺼짐이 된다.

꺼져 있으면 `collectSnapshot()`이 `accountNames()`를 **호출하지 않고**
`AccountNames(claude: nil, codex: nil)`을 넣는다 — 파일도 읽지 않는다. 헤더 조립 함수는 이미
`nil`에서 조각을 생략하므로 별도 분기가 필요 없다.

### 7. 접근성

헤더의 accessibility label이 현재 `"Open Claude usage"`다 (`app/MenuBuilder.swift:80`, `:144`).
계정이 있으면 `"Open Claude usage — dev.account"`로 확장한다. VoiceOver 사용자도 어느
계정인지 들을 수 있어야 한다.

### 8. i18n

새 문자열은 `"Show account name"` 하나. 6개 언어 전부 번역하고 `--self-test-core`의
`settingsStrings` 스캔 배열(`app/main.swift:2356-2367`)에 추가해 누락 시 테스트가 깨지게 한다.

계정 이름 자체는 번역 대상이 아니다.

## 오류 처리

모든 실패는 **조용한 생략**으로 수렴한다. 계정 조각이 빠진 헤더는 현재 출시된 헤더와 동일하므로
사용자에게 깨진 상태가 노출되지 않는다.

| 상황 | 동작 |
|---|---|
| `~/.claude.json` 없음 / 읽기 권한 없음 | Claude 계정 생략. Codex는 정상 표시 |
| `oauthAccount` 없음 또는 `emailAddress` 없음 | Claude 계정 생략 |
| `~/.codex/auth.json` 없음 | Codex 계정 생략. Claude는 정상 표시 |
| `id_token` 없음 / 세그먼트 3개 아님 / base64 손상 / JSON 아님 | Codex 계정 생략 |
| 이메일에 `@` 없음 | 문자열 전체를 이름으로 쓴다 (사용자 이름 형태 로그인 대비) |
| 이메일이 빈 문자열 또는 `@`로 시작 | 생략 |
| JSON 파싱 실패 (손상된 파일) | 생략. 예외를 던지지 않는다 |

`id_token`의 만료 여부는 검사하지 않는다. 만료된 토큰의 이메일도 마지막으로 로그인한 계정이며,
그게 사용량 API가 답하고 있는 계정이다.

## 테스트

`--self-test-core`에 `account` 그룹을 추가한다 (`app/main.swift:2381`의 기존 하네스).

| 검사 | 내용 |
|---|---|
| `local-part` | `a@b.com`→`a`, `noatsign`→`noatsign`, `@x.com`→`nil`, `""`→`nil`, `nil`→`nil` |
| `jwt-decode` | 손으로 만든 base64url 토큰에서 email 추출. **패딩이 0/1/2개 필요한 길이 세 가지를 모두 포함**. 세그먼트 2개짜리·base64 아닌 문자열·JSON 아닌 payload는 `nil` |
| `truncate` | 25자 로컬파트 → 20자 + `…`. 20자는 그대로. 한글 로컬파트가 바이트 중간에서 잘리지 않음 |
| `header` | 두 조립 함수에 (계정 있음/없음) × (플랜 있음/`limitId`만/둘 다 없음) 조합의 정확한 출력 문자열 |
| `default-on` | `showAccountName` 키가 없을 때 읽기 헬퍼가 `true`를 반환 |
| `settings-i18n` | 새 문자열이 6개 언어에 모두 존재 (기존 스캔 배열에 편입) |

수동 검증: `--dump-menu`로 실제 계정이 헤더에 나타나는지 확인하고, 설정을 끈 뒤 다시 실행해
사라지는지 확인한다.

## 변경 파일

| 파일 | 변경 |
|---|---|
| `app/Account.swift` | **신규**. 계정 조회, JWT 디코드, 로컬파트 추출, mtime 캐시 |
| `app/MenuBuilder.swift` | `Snapshot`에 `accounts` 추가, 헤더 조립 함수 2개, 접근성 라벨 확장 |
| `app/main.swift` | `collectSnapshot()`에서 계정 채우기, 설정 체크박스, `account` 자체 테스트 그룹 |
| `app/Localization.swift` | `"Show account name"` 6개 언어 |

`app/build.sh`는 손대지 않는다 — `swiftc … *.swift`로 소스를 글로브하므로 새 파일이 자동으로
들어간다.
