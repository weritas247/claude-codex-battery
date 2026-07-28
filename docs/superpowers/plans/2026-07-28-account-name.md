# 드롭다운 계정 이름 표시 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 드롭다운의 Claude·Codex 헤더에 로그인된 계정 이름(이메일 로컬파트)을 인라인으로 표시하고, 설정에서 끌 수 있게 한다.

**Architecture:** 계정 조회를 사용량 파이프라인에서 분리한 새 모듈 `app/Account.swift`가 로컬 로그인 파일 두 개(`~/.claude.json`, `~/.codex/auth.json`)를 mtime 캐시와 함께 읽는다. `collectSnapshot()`이 결과를 `Snapshot.accounts`에 담고, `MenuBuilder`는 순수 문자열 조립 함수 두 개로 헤더를 만든다. 네트워크 호출도 새 권한도 추가하지 않는다.

**Tech Stack:** Swift 5 / Cocoa, `swiftc` 단일 컴파일(`app/build.sh`), 테스트는 `--self-test-core` 인프로세스 하네스.

## Global Constraints

- **스펙:** `docs/superpowers/specs/2026-07-28-account-name-design.md`. 이 계획의 모든 결정은 스펙을 따른다.
- **표시 값:** 이메일 로컬파트(`@` 앞). 전체 이메일·도메인은 표시하지 않는다.
- **배치:** 헤더 인라인. 드롭다운에 줄을 추가하지 않는다.
- **길이 제한:** 로컬파트 20자 초과 시 앞 20자 + `…` (결과 21자). 상수 `ACCOUNT_NAME_MAX = 20`.
- **실패 처리:** 모든 실패는 **조용한 생략**. 에러 행·자리표시자·로그를 남기지 않고 계정 조각만 빠진다 (= 현재 출시된 헤더와 동일).
- **비밀 정보:** `access_token` / `refresh_token`은 읽지 않는다. 디코드한 JWT payload를 로그·파일에 쓰지 않는다. JWT 서명은 검증하지 않는다(로컬 자기 파일).
- **범위:** `app/`만 수정. `claude-codex-usage.2m.js`(SwiftBar 플러그인)와 `windows/`는 건드리지 않는다.
- **build.sh:** 수정 금지 — `swiftc … *.swift`로 글로브하므로 새 파일이 자동 포함된다.
- **i18n:** 새 UI 문자열은 `SUPPORTED_LANGS = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "es"]` 6개 언어 전부 필요.

**빌드/테스트 명령 (모든 태스크 공통):**

```bash
cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core
```

이 저장소에는 별도 테스트 러너가 없다. 테스트는 `app/main.swift`의 `runCoreSelfTest()` 안에
`try require(조건, "그룹", "검사이름", "실패 설명")` 형태로 작성하고, 위 명령으로 실행한다.
실패하면 `self-test-core: FAIL: 그룹/검사이름: 설명`을 stderr에 출력하고 exit 1 한다.

베이스라인은 green이다 (`self-test-core: PASS`).

---

### Task 1: 순수 문자열 헬퍼 — 로컬파트 / JWT / 길이 제한

계정 값을 다루는 부작용 없는 함수 3개. 파일시스템 없이 전부 테스트된다.

**Files:**
- Create: `app/Account.swift`
- Modify: `app/main.swift` — `runCoreSelfTest()` 안, `battery-color` 그룹 마지막 줄
  (`print("self-test-core: battery-color PASS")`, 현재 2376행) **바로 다음**에 `account` 그룹을 추가

**Interfaces:**
- Consumes: `jd(_:)`, `jstr(_:)` (`app/Util.swift:153,156`)
- Produces:
  - `let ACCOUNT_NAME_MAX = 20`
  - `func emailLocalPart(_ email: String?) -> String?`
  - `func jwtEmail(_ idToken: String?) -> String?`
  - `func truncateAccount(_ name: String) -> String`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`app/main.swift`의 `print("self-test-core: battery-color PASS")` 다음, `print("self-test-core: PASS")` 앞에 추가:

```swift
  // ── account ──────────────────────────────────────────────────────────────
  // 로컬파트: @ 앞만 취한다. @가 없으면 사용자명 형태 로그인으로 보고 전체를 쓴다.
  try require(emailLocalPart("a@b.com") == "a", "account", "local-part", "@ 앞을 잘라내지 못했다")
  try require(emailLocalPart("noatsign") == "noatsign",
              "account", "local-part-no-at", "@ 없는 값을 통째로 쓰지 않았다")
  try require(emailLocalPart("@x.com") == nil,
              "account", "local-part-empty", "로컬파트가 빈 이메일에서 빈 문자열이 새어나왔다")
  try require(emailLocalPart("") == nil && emailLocalPart(nil) == nil && emailLocalPart("   ") == nil,
              "account", "local-part-blank", "빈 입력이 nil로 수렴하지 않았다")

  // JWT payload 디코드. base64url은 패딩이 없으므로 Data(base64Encoded:)가 그대로는 거부한다.
  // 아래 세 이메일은 payload 바이트 수가 21/20/19 → 필요한 패딩이 각각 0/1/2개다.
  func testJWT(_ payload: String) -> String {
    let b64 = Data(payload.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "header.\(b64).signature"
  }
  try require(jwtEmail(testJWT("{\"email\":\"abc@b.com\"}")) == "abc@b.com",
              "account", "jwt-pad0", "패딩이 필요 없는 payload를 디코드하지 못했다")
  try require(jwtEmail(testJWT("{\"email\":\"ab@b.com\"}")) == "ab@b.com",
              "account", "jwt-pad1", "= 하나가 필요한 payload를 디코드하지 못했다")
  try require(jwtEmail(testJWT("{\"email\":\"a@b.com\"}")) == "a@b.com",
              "account", "jwt-pad2", "== 두 개가 필요한 payload를 디코드하지 못했다")
  try require(jwtEmail(nil) == nil && jwtEmail("only.two") == nil
                && jwtEmail("a.!!!!.c") == nil && jwtEmail(testJWT("not json")) == nil
                && jwtEmail(testJWT("{\"sub\":\"x\"}")) == nil,
              "account", "jwt-reject", "손상된 토큰에서 nil이 아닌 값이 나왔다")

  // 길이 제한: 긴 회사 계정이 헤더를 밀어내 메뉴 폭을 늘리지 않게 한다.
  try require(truncateAccount(String(repeating: "a", count: 25)) == String(repeating: "a", count: 20) + "…",
              "account", "truncate", "25자 로컬파트가 20자 + … 로 잘리지 않았다")
  try require(truncateAccount(String(repeating: "a", count: 20)) == String(repeating: "a", count: 20),
              "account", "truncate-boundary", "정확히 20자인 이름에 …이 붙었다")
  // 한글은 UTF-8에서 3바이트다. 바이트가 아니라 Character 단위로 세야 깨지지 않는다.
  try require(truncateAccount(String(repeating: "가", count: 25)) == String(repeating: "가", count: 20) + "…",
              "account", "truncate-multibyte", "멀티바이트 이름이 문자 단위로 잘리지 않았다")
  print("self-test-core: account PASS")
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `cd app && ./build.sh`

Expected: 컴파일 FAIL — `cannot find 'emailLocalPart' in scope`, `cannot find 'jwtEmail' in scope`, `cannot find 'truncateAccount' in scope`

- [ ] **Step 3: 최소 구현을 작성한다**

`app/Account.swift` 신규 생성:

```swift
// 로그인된 계정 이름 — 드롭다운 헤더에 표시할 이메일 로컬파트를 로컬 로그인 파일에서 읽는다.
// 사용량 API도 키체인도 계정 이메일을 주지 않으므로 (조사 결과는 설계 문서 참고)
// Claude Code / Codex CLI가 남긴 파일이 유일한 출처다. 네트워크 호출은 하지 않는다.
import Foundation

// 긴 회사 계정(firstname.lastname.platform)이 헤더를 밀어내 메뉴 폭을 늘리는 것을 막는다.
let ACCOUNT_NAME_MAX = 20

// "user@host" → "user". @ 없는 값은 사용자명 형태 로그인으로 보고 그대로 쓴다.
func emailLocalPart(_ email: String?) -> String? {
  guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
  let local = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
  return local.isEmpty ? nil : String(local)
}

// id_token의 payload에서 email만 꺼낸다. 서명은 검증하지 않는다 — 우리 앱이 방금 읽은
// 우리 로컬 로그인 파일이고, 검증할 공개키도 없다. 값은 표시용 문자열일 뿐이다.
func jwtEmail(_ idToken: String?) -> String? {
  guard let token = idToken else { return nil }
  let parts = token.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 3 else { return nil }
  // base64url → base64: 문자 치환 후 4의 배수가 되도록 패딩을 채운다.
  var b64 = String(parts[1])
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while b64.count % 4 != 0 { b64 += "=" }
  guard let data = Data(base64Encoded: b64),
        let obj = jd(try? JSONSerialization.jsonObject(with: data)) else { return nil }
  return jstr(obj["email"])
}

// 바이트가 아니라 Character 단위 — 한글/이모지가 중간에서 깨지지 않게 한다.
func truncateAccount(_ name: String) -> String {
  name.count <= ACCOUNT_NAME_MAX ? name : String(name.prefix(ACCOUNT_NAME_MAX)) + "…"
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`

Expected: `self-test-core: account PASS` 가 출력되고 마지막 줄이 `self-test-core: PASS`

- [ ] **Step 5: 커밋한다**

```bash
git add app/Account.swift app/main.swift
git commit -m "feat(account): add email local-part, JWT payload, and length helpers"
```

---

### Task 2: 로그인 파일 조회 + mtime 캐시

Task 1의 헬퍼로 실제 파일 두 개를 읽는다. 경로를 인자로 받게 만들어 임시 파일로 테스트한다.

**Files:**
- Modify: `app/Account.swift` (Task 1에서 만든 파일에 추가)
- Modify: `app/main.swift` — Task 1이 추가한 `account` 그룹 안, `print("self-test-core: account PASS")` **앞**

**Interfaces:**
- Consumes: `emailLocalPart(_:)`, `jwtEmail(_:)`, `truncateAccount(_:)` (Task 1),
  `jd(_:)`, `jstr(_:)`, `readJSONFile(_:)` (`app/Util.swift:153,156,158`), `HOME` (`app/Util.swift:4`)
- Produces:
  - `struct AccountNames { let claude: String?; let codex: String?; static let none: AccountNames }`
  - `func claudeAccountName(path: String = "\(HOME)/.claude.json") -> String?`
  - `func codexAccountName(path: String = "\(HOME)/.codex/auth.json") -> String?`
  - `func accountNames() -> AccountNames`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`app/main.swift`의 `print("self-test-core: account PASS")` **바로 앞**에 추가:

```swift
  // 파일 조회 — 실제 홈 디렉터리를 건드리지 않도록 임시 디렉터리에 픽스처를 쓴다.
  let acctDir = NSTemporaryDirectory() + "ccb-account-test-\(ProcessInfo.processInfo.processIdentifier)"
  try? FileManager.default.createDirectory(atPath: acctDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: acctDir) }
  func writeFixture(_ name: String, _ text: String) -> String {
    let p = acctDir + "/" + name
    try? Data(text.utf8).write(to: URL(fileURLWithPath: p))
    return p
  }

  let claudeGood = writeFixture("claude-good.json",
    "{\"numStartups\":3,\"oauthAccount\":{\"emailAddress\":\"dev.account@example.com\",\"displayName\":\"Dev Account\"}}")
  try require(claudeAccountName(path: claudeGood) == "dev.account",
              "account", "claude-read", "~/.claude.json의 oauthAccount.emailAddress를 읽지 못했다")

  let codexGood = writeFixture("codex-good.json",
    "{\"tokens\":{\"id_token\":\"\(testJWT("{\"email\":\"abc@b.com\"}"))\",\"access_token\":\"SECRET\"}}")
  try require(codexAccountName(path: codexGood) == "abc",
              "account", "codex-read", "~/.codex/auth.json의 id_token에서 이메일을 읽지 못했다")

  // 모든 실패는 조용한 생략으로 수렴한다 — 에러를 던지지 않고 nil을 준다.
  let claudeNoAccount = writeFixture("claude-no-account.json", "{\"numStartups\":3}")
  let claudeBroken = writeFixture("claude-broken.json", "{not json")
  let codexNoToken = writeFixture("codex-no-token.json", "{\"tokens\":{\"access_token\":\"SECRET\"}}")
  try require(claudeAccountName(path: acctDir + "/missing.json") == nil
                && claudeAccountName(path: claudeNoAccount) == nil
                && claudeAccountName(path: claudeBroken) == nil
                && codexAccountName(path: acctDir + "/missing.json") == nil
                && codexAccountName(path: codexNoToken) == nil,
              "account", "read-degrade", "파일이 없거나 손상됐을 때 nil로 수렴하지 않았다")

  // 캐시는 경로별로 분리돼야 한다 — 한 파일의 결과가 다른 파일에 새면 안 된다.
  let claudeOther = writeFixture("claude-other.json",
    "{\"oauthAccount\":{\"emailAddress\":\"someone.else@corp.com\"}}")
  try require(claudeAccountName(path: claudeOther) == "someone.else"
                && claudeAccountName(path: claudeGood) == "dev.account",
              "account", "cache-per-path", "mtime 캐시가 경로를 구분하지 않아 다른 파일의 값을 돌려줬다")
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `cd app && ./build.sh`

Expected: 컴파일 FAIL — `cannot find 'claudeAccountName' in scope`, `cannot find 'codexAccountName' in scope`

- [ ] **Step 3: 최소 구현을 작성한다**

`app/Account.swift` 끝에 추가:

```swift
struct AccountNames {
  let claude: String?
  let codex: String?
  static let none = AccountNames(claude: nil, codex: nil)
}

// ~/.claude.json은 실측 239KB이고 새로고침마다 읽힌다. (mtime, size)가 그대로면 다시 파싱하지
// 않는다. 경로별로 나눠 담아 한 파일의 결과가 다른 파일에 새지 않게 한다.
// 새로고침은 백그라운드 큐에서 도는 반면 메뉴 조립은 메인 스레드라 잠금이 필요하다.
// 캐시는 프로세스 메모리에만 둔다 — 계정 이름을 새 파일에 복제할 이유가 없다.
private final class AccountFileCache {
  private var entries: [String: (mtime: Int, size: Int, value: String?)] = [:]
  private let lock = NSLock()

  func lookup(_ path: String, _ parse: (Any) -> String?) -> String? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let mtime = Int(((attrs?[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    lock.lock()
    defer { lock.unlock() }
    if let hit = entries[path], hit.mtime == mtime, hit.size == size { return hit.value }
    let value = readJSONFile(path).flatMap(parse)
    entries[path] = (mtime, size, value)
    return value
  }
}

private let accountCache = AccountFileCache()

func claudeAccountName(path: String = "\(HOME)/.claude.json") -> String? {
  accountCache.lookup(path) { emailLocalPart(jstr(jd(jd($0)?["oauthAccount"])?["emailAddress"])) }
}

// access_token / refresh_token은 읽지 않는다 — id_token payload만 본다.
func codexAccountName(path: String = "\(HOME)/.codex/auth.json") -> String? {
  accountCache.lookup(path) { emailLocalPart(jwtEmail(jstr(jd(jd($0)?["tokens"])?["id_token"]))) }
}

func accountNames() -> AccountNames {
  AccountNames(claude: claudeAccountName().map(truncateAccount),
               codex: codexAccountName().map(truncateAccount))
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`

Expected: `self-test-core: account PASS`, 마지막 줄 `self-test-core: PASS`

- [ ] **Step 5: 커밋한다**

```bash
git add app/Account.swift app/main.swift
git commit -m "feat(account): read the logged-in account from the local login files"
```

---

### Task 3: 헤더 조립 + `Snapshot.accounts` + 접근성

**Files:**
- Modify: `app/MenuBuilder.swift` — `Snapshot`(8-15행), Claude 헤더(75-80행), Codex 헤더(137-144행)
- Modify: `app/main.swift` — 리텐션 경로의 `Snapshot` 재구성(689-690행), `account` 테스트 그룹

**Interfaces:**
- Consumes: `AccountNames` (Task 2)
- Produces:
  - `func accountSuffix(_ account: String?) -> String`
  - `func claudeHeaderTitle(account: String?, usageWord: String) -> String`
  - `func codexHeaderTitle(plan: String?, limitId: String?, account: String?, usageWord: String) -> String`
  - `func headerAccessibilityLabel(_ base: String, account: String?) -> String`
  - `Snapshot.accounts: AccountNames` (기본값 `.none`)

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`app/main.swift`의 `print("self-test-core: account PASS")` **바로 앞**에 추가:

```swift
  // 헤더 조립 — 파일시스템 없이 정확한 출력 문자열을 단언한다.
  try require(claudeHeaderTitle(account: "dev.account", usageWord: "usage")
                == "Claude Code · dev.account · usage ↗",
              "account", "header-claude", "Claude 헤더에 계정이 인라인으로 붙지 않았다")
  try require(claudeHeaderTitle(account: nil, usageWord: "usage") == "Claude Code · usage ↗",
              "account", "header-claude-none", "계정이 없을 때 Claude 헤더가 현재 형태와 달라졌다")
  try require(codexHeaderTitle(plan: "prolite", limitId: nil, account: "dev.account", usageWord: "usage")
                == "Codex · prolite · dev.account · usage ↗",
              "account", "header-codex", "Codex 헤더가 플랜 뒤에 계정을 붙이지 않았다")
  try require(codexHeaderTitle(plan: nil, limitId: "weekly", account: "abc", usageWord: "usage")
                == "Codex · weekly · abc · usage ↗",
              "account", "header-codex-limit", "plan이 없을 때 limitId 폴백이 깨졌다")
  try require(codexHeaderTitle(plan: nil, limitId: nil, account: "abc", usageWord: "usage")
                == "Codex · abc · usage ↗",
              "account", "header-codex-noplan", "플랜이 전혀 없을 때 점이 겹쳤다")
  try require(codexHeaderTitle(plan: "prolite", limitId: nil, account: nil, usageWord: "usage")
                == "Codex · prolite · usage ↗",
              "account", "header-codex-none", "계정이 없을 때 Codex 헤더가 현재 형태와 달라졌다")
  // 번역된 usage 단어도 그대로 흘러야 한다.
  try require(claudeHeaderTitle(account: "abc", usageWord: "사용량") == "Claude Code · abc · 사용량 ↗",
              "account", "header-i18n", "헤더가 번역된 usage 단어를 쓰지 않았다")
  // VoiceOver 사용자도 어느 계정인지 들을 수 있어야 한다.
  try require(headerAccessibilityLabel("Open Claude usage", account: "abc") == "Open Claude usage — abc"
                && headerAccessibilityLabel("Open Claude usage", account: nil) == "Open Claude usage",
              "account", "header-a11y", "접근성 라벨에 계정이 반영되지 않았다")
  // 새로고침 실패 시 이전 스냅샷을 되살리는 경로에서 계정이 사라지면 안 된다.
  let acctSnap = Snapshot(now: now, usage: usage, block: nil, models: nil, codex: codex,
                          update: (nil, false), accounts: AccountNames(claude: "abc", codex: "xyz"))
  try require(acctSnap.accounts.claude == "abc" && acctSnap.accounts.codex == "xyz",
              "account", "snapshot-field", "Snapshot이 계정을 보관하지 않았다")
  try require(Snapshot(now: now, usage: nil, block: nil, models: nil, codex: nil,
                       update: (nil, false)).accounts.claude == nil,
              "account", "snapshot-default", "accounts 기본값이 .none이 아니다")
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `cd app && ./build.sh`

Expected: 컴파일 FAIL — `cannot find 'claudeHeaderTitle' in scope` 및 `Snapshot`에 `accounts` 인자가 없다는 오류

- [ ] **Step 3: 최소 구현을 작성한다**

**3a.** `app/MenuBuilder.swift`의 `Snapshot`에 필드를 추가한다 (8-15행). `let`이 아니라 `var` +
기본값이어야 기존 14개 생성 지점이 그대로 컴파일된다 — 기본값이 있는 `let`은 memberwise
initializer에서 아예 빠진다:

```swift
struct Snapshot {
  let now: Int
  let usage: ClaudeUsage?
  let block: ClaudeBlock?
  let models: (models: [ModelUse], total: Double)?
  let codex: CodexUsage?
  let update: (latest: String?, hasUpdate: Bool)
  var accounts: AccountNames = .none
}
```

**3b.** `app/MenuBuilder.swift`의 `private let WARN = "#d29922"` 다음에 조립 함수를 추가한다:

```swift
// 헤더 문자열은 순수 함수로 뽑아 파일시스템 없이 테스트한다.
// 계정이 없으면 조각을 통째로 생략한다 — 결과는 계정 기능 이전의 헤더와 정확히 같다.
func accountSuffix(_ account: String?) -> String {
  guard let account, !account.isEmpty else { return "" }
  return " · \(account)"
}

func claudeHeaderTitle(account: String?, usageWord: String) -> String {
  "Claude Code\(accountSuffix(account)) · \(usageWord) ↗"
}

func codexHeaderTitle(plan: String?, limitId: String?, account: String?, usageWord: String) -> String {
  let planSuffix = plan.map { " · \($0)" } ?? limitId.map { " · \($0)" } ?? ""
  return "Codex\(planSuffix)\(accountSuffix(account)) · \(usageWord) ↗"
}

func headerAccessibilityLabel(_ base: String, account: String?) -> String {
  guard let account, !account.isEmpty else { return base }
  return "\(base) — \(account)"
}
```

**3c.** Claude 헤더(75-80행)를 교체한다:

```swift
    let usageTitle = tr("Open Claude usage", language: language)
    let header = row(menu, claudeHeaderTitle(account: snap.accounts.claude,
                                             usageWord: tr("usage", language: language)),
                     size: 13, color: GRAY, action: #selector(AppDelegate.openLink(_:)),
                     target: target, repr: CLAUDE_USAGE_URL)
    header.image = assets.providerImage(for: .claude)
    header.toolTip = usageTitle
    header.setAccessibilityLabel(headerAccessibilityLabel(usageTitle, account: snap.accounts.claude))
```

**3d.** Codex 헤더(137-144행)를 교체한다. 기존 `suffix` 지역 변수는 `codexHeaderTitle`이
흡수하므로 삭제한다:

```swift
    let usageTitle = tr("Open Codex usage", language: language)
    let header = row(menu, codexHeaderTitle(plan: codex.plan, limitId: codex.limitId,
                                            account: snap.accounts.codex,
                                            usageWord: tr("usage", language: language)),
                     size: 13, color: GRAY, action: #selector(AppDelegate.openLink(_:)),
                     target: target, repr: CODEX_USAGE_URL)
    header.image = assets.providerImage(for: .codex)
    header.toolTip = usageTitle
    header.setAccessibilityLabel(headerAccessibilityLabel(usageTitle, account: snap.accounts.codex))
```

**3e.** `app/main.swift` 689-690행 — 새로고침이 실패해 이전 값을 되살리는 경로가 계정을
떨어뜨리지 않게 한다. 이걸 빠뜨리면 네트워크가 끊길 때마다 계정 이름이 사라진다:

```swift
    return Snapshot(now: snapshot.now, usage: usage, block: snapshot.block,
                    models: snapshot.models, codex: codex, update: snapshot.update,
                    accounts: snapshot.accounts)
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`

Expected: `self-test-core: account PASS`, 마지막 줄 `self-test-core: PASS`

- [ ] **Step 5: 커밋한다**

```bash
git add app/MenuBuilder.swift app/main.swift
git commit -m "feat(menu): show the account name inline in the provider headers"
```

---

### Task 4: 설정 토글(기본 켜짐) + 연결 + 6개 언어

여기까지 오면 헤더는 계정을 표시할 수 있지만 `collectSnapshot()`이 아직 채우지 않아 실제로는
비어 있다. 이 태스크가 배선을 완성하고 끄는 수단을 붙인다.

**Files:**
- Modify: `app/Account.swift` — `accountNameVisible` 추가
- Modify: `app/Localization.swift` — `"Show account name"` 6개 언어 (157행 `"Battery color"` 인근 설정 문자열 블록)
- Modify: `app/main.swift` — `collectSnapshot()`(19-27행), Display 탭(1014행 `applyPixelOnlyAvailability()` 다음), `settingsStrings` 배열(2356-2367행), `account` 테스트 그룹

**Interfaces:**
- Consumes: `accountNames()`, `AccountNames.none` (Task 2), `Snapshot.accounts` (Task 3),
  `toggleMetric(_:)` (`app/main.swift:1132`), `tr(_:language:)` (`app/Localization.swift`)
- Produces: `func accountNameVisible(_ stored: Any?) -> Bool`, UserDefaults 키 `showAccountName`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

**1a.** `app/main.swift`의 `print("self-test-core: account PASS")` **바로 앞**에 추가:

```swift
  // 기본은 켜짐이다. bool(forKey:)만 쓰면 키가 없을 때 false가 되어 기본이 꺼짐으로 뒤집힌다.
  try require(accountNameVisible(nil) == true,
              "account", "default-on", "설정 키가 없을 때 계정 이름이 기본으로 켜지지 않았다")
  try require(accountNameVisible(false) == false && accountNameVisible(true) == true,
              "account", "toggle-respected", "저장된 설정값이 무시됐다")
```

**1b.** `app/main.swift`의 `settingsStrings` 배열(2356-2367행)에 새 문자열을 추가한다.
`"Battery color", "Custom…", "Settings",` 줄을 다음으로 바꾼다:

```swift
    "Battery color", "Custom…", "Settings", "Show account name",
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `cd app && ./build.sh`

Expected: 컴파일 FAIL — `cannot find 'accountNameVisible' in scope`

- [ ] **Step 3: 최소 구현을 작성한다**

**3a.** `app/Account.swift` 끝에 추가:

```swift
// 기본 켜짐. 기본값이 있는 설정은 bool(forKey:)로 읽으면 안 된다 — 키가 없을 때 false가 되어
// 기본이 뒤집힌다. 저장값을 인자로 받아 UserDefaults 없이 테스트한다.
func accountNameVisible(_ stored: Any? = UserDefaults.standard.object(forKey: "showAccountName")) -> Bool {
  (stored as? Bool) ?? true
}
```

**3b.** `app/Localization.swift`의 `"Battery color"` 줄(157행) 다음에 추가:

```swift
  "Show account name": ["ko": "계정 이름 표시", "ja": "アカウント名を表示", "zh-Hans": "显示账户名",
                        "zh-Hant": "顯示帳戶名稱", "es": "Mostrar el nombre de la cuenta"],
```

**3c.** `app/main.swift`의 `collectSnapshot()`(19-27행)을 교체한다. 설정이 꺼져 있으면
`accountNames()`를 아예 호출하지 않는다 — 파일도 읽지 않는다:

```swift
func collectSnapshot() -> Snapshot {
  let now = Int(Date().timeIntervalSince1970)
  return Snapshot(now: now,
                  usage: getClaudeUsage(now: now),
                  block: getClaudeBlock(now: now),
                  models: getClaudeModels(),
                  codex: getCodex(now: now),
                  update: getUpdateInfo(now: now),
                  accounts: accountNameVisible() ? accountNames() : .none)
}
```

**3d.** `app/main.swift`의 Display 탭 — `applyPixelOnlyAvailability()`(1014행) **바로 앞**에
체크박스를 추가한다. `pixelNote`는 위쪽 그리드를 설명하는 주석이므로 그 뒤에 붙여 둘을
떼어놓지 않는다:

```swift
    let accountToggle = NSButton(checkboxWithTitle: tr("Show account name"), target: self,
                                 action: #selector(toggleMetric(_:)))
    accountToggle.identifier = NSUserInterfaceItemIdentifier("showAccountName")
    accountToggle.state = accountNameVisible() ? .on : .off
    display.addArrangedSubview(accountToggle)
```

`toggleMetric`(1132행)은 `sender.identifier?.rawValue`를 UserDefaults 키로 그대로 쓰고
`rerender()`를 호출하므로 새 액션 메서드가 필요 없다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`

Expected: `self-test-core: account PASS`와 `self-test-core: battery-color PASS`(i18n 스캔 포함)가
모두 출력되고 마지막 줄이 `self-test-core: PASS`

- [ ] **Step 5: 커밋한다**

```bash
git add app/Account.swift app/Localization.swift app/main.swift
git commit -m "feat(settings): add a Show account name toggle, on by default"
```

---

### Task 5: 실제 앱에서 검증

자체 테스트는 순수 함수와 픽스처만 본다. 이 태스크는 실제 로그인 파일로 헤더가 나오는지,
토글이 실제로 끄는지를 확인한다.

**Files:** 없음 (검증 전용). 문제가 발견되면 해당 태스크로 돌아간다.

- [ ] **Step 1: 계정 이름이 실제 헤더에 나오는지 확인한다**

```bash
cd app && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump-menu | head -12
```

Expected: 첫 줄이 `Claude Code · <로컬파트> · usage ↗`, Codex 헤더가
`Codex · <플랜> · <로컬파트> · usage ↗`

- [ ] **Step 2: 토글을 꺼서 사라지는지 확인한다**

```bash
defaults write com.dennykim.claude-codex-battery-app showAccountName -bool false
cd app && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump-menu | head -12
```

Expected: `Claude Code · usage ↗`, `Codex · <플랜> · usage ↗` — 계정 조각만 사라지고 나머지는 동일

- [ ] **Step 3: 기본 켜짐으로 복귀하는지 확인한다**

```bash
defaults delete com.dennykim.claude-codex-battery-app showAccountName
cd app && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump-menu | head -12
```

Expected: 계정 이름이 다시 나온다 (키가 없을 때 기본 켜짐)

- [ ] **Step 4: 전체 자체 테스트를 다시 돌린다**

```bash
cd app && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core
```

Expected: 마지막 줄 `self-test-core: PASS`

- [ ] **Step 5: 앱을 실행해 드롭다운을 눈으로 확인한다**

```bash
open app/ClaudeCodexBattery.app
```

메뉴바 배터리를 클릭해 헤더에 계정 이름이 보이는지, Settings > Display에
"계정 이름 표시" 체크박스가 있고 끄면 즉시 반영되는지 확인한다.

- [ ] **Step 6: 검증 결과를 기록한다**

문제가 없으면 이 태스크는 커밋 없이 끝난다. 문제가 있으면 원인이 있는 태스크로 돌아가
테스트를 먼저 추가한 뒤 고친다.
