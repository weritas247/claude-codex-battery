# 배터리 채움 색 개인화 + 설정창 불일치 수정

날짜: 2026-07-27

## 배경

메뉴바 배터리의 채움 색은 잔량에 따라 초록 → 앰버 → 빨강으로 자동 전환되며, 값이 모두 코드에
하드코딩되어 있다 (`heatRemain`, `app/BatteryRenderer.swift:231-238`). 사용자가 색을 바꿀 수단은 없다.

동시에 설정창(`showSettings`, `app/main.swift:893-959`)을 감사한 결과 앱의 실제 동작과 어긋나는
지점이 15건 확인됐다. 그중 사용자가 "고장"으로 체감하는 4건을 이번에 함께 고친다.

## 확정된 사양

브라우저 목업으로 후보를 비교해 아래를 확정했다.

| 항목 | 결정 |
|---|---|
| 색을 바꿀 대상 | **채움 색** — 퍼센트 숫자가 얹히는 면. 트랙/판/버튼 배경은 대상이 아니다 |
| 잔량 밴드와의 관계 | **초록 구간만** 사용자 색. 앰버·빨강 경고색은 표준 유지 |
| 선택 범위 | **녹색 계열만** |
| 컨트롤 | **프리셋 견본 + "사용자 지정…"** 하이브리드 |
| 적용 시점 | 즉시 (`rerender()`). OK/Cancel 없음 — 기존 설정과 동일 |

채움 색만 대상으로 삼는 이유: 캡슐 내부의 빈 트랙, 아이콘 판, 메뉴바 버튼 칸은 현재 모두 투명이고
그리는 코드 자체가 없다. 새 레이어를 도입하면 해치 애니메이션(`app/main.swift:439-543`)과의 겹침을
새로 설계해야 한다. 채움 색은 이미 존재하는 색이라 대체만 하면 된다.

앰버·빨강을 제외하는 이유: 두 색은 "위험"이라는 관습적 의미를 갖는다. 개인화 대상에서 빼야
경고 기능이 보존된다. 실사용 화면은 대부분 초록 구간이라 체감 변화는 초록만으로 충분하다.

메뉴바 아이콘은 template image가 아니므로(`app/main.swift:695`에서 `isTemplate = false`)
시스템 틴팅 제약 없이 임의의 RGB가 그대로 표시된다.

## 적용 범위

- 모던·픽셀 **두 표시 모드 모두** 적용 (채움 색은 두 모드가 공유한다)
- 드롭다운 메뉴의 게이지 색(`usageColor`, `app/Util.swift:76-82`)도 **같은 사용자 색을 따른다**
- 소모 빗금 색은 채움 색에서 파생되므로(`activityHatchRGB`, `app/BatteryRenderer.swift:267-273`)
  **자동으로 따라온다** — 별도 작업 없음
- 100%(≥99.5%)의 골드(`goldBase`/`goldHi`, `app/BatteryRenderer.swift:343-344`)는 **대상 아님**
- SwiftBar 플러그인(`claude-codex-usage.2m.js`)과의 색 동기화는 하지 않는다

## 구현 설계

### 1. 저장 (`app/BatteryRenderer.swift`)

| 항목 | 값 |
|---|---|
| 키 | `UserDefaults` `"batteryGreen"` (`displayMode`·`catStyle`과 동일 백엔드) |
| 형식 | `"#RRGGBB"` 문자열 |
| 미설정 | **키 없음 = 현행 동작.** 다크 `#198532` / 라이트 `#2AB046` 자동 분기 |
| 설정됨 | 고른 색 하나를 **다크·라이트 공통**으로 사용 |
| 환경변수 | `CCB_BATTERY_GREEN` — `CCB_CAT_STYLE`(`app/CatSprite.swift:21`)·`CCB_LANG` 관례를 따른다 |

```
func currentBatteryGreen() -> String?     // 환경변수 → UserDefaults → nil
```

값 검증은 **문법만** 한다. `#RRGGBB` 형식이 아니면 `nil`을 반환해 기본 동작으로 폴백한다.
색상(hue)이 녹색 범위인지는 **읽기 시점에 검사하지 않는다** — UI가 녹색만 생성하도록 보장하며,
직접 편집한 값을 몰래 보정하면 "고른 색과 결과가 다른" 혼란이 생긴다.

### 2. 색공간 (`app/Util.swift`)

기존 `hexColor()`(`app/Util.swift:84-91`)는 sRGB `NSColor`를 만드는데 렌더러는 calibrated RGB를
쓴다. 그대로 쓰면 미묘한 색차가 난다. 색공간 변환을 아예 거치지 않는 경로를 새로 둔다.

```
func rgbFromHex(_ hex: String) -> (UInt8, UInt8, UInt8)?   // hex 바이트 → RGB 튜플 (변환 없음)
```

- 픽셀 모드: 튜플을 그대로 캔버스에 쓴다
- 모던 모드: 튜플로 `NSColor(calibratedRed:green:blue:alpha:)`를 만든다

`hexColor()`는 드롭다운 텍스트 색 용도로 그대로 둔다.

### 3. 주입 경로

```
currentBatteryGreen()
  → PresentationConfiguration.batteryGreen: () -> String?      (app/AppPolicy.swift:78-99)
  → heatRemain(band:dark:custom:)                              (app/BatteryRenderer.swift:231-238)
      ├─ band == .green 이고 custom != nil  → rgbFromHex(custom)
      └─ 그 외                              → 현행 하드코딩 값 그대로
```

`PresentationConfiguration`은 이미 렌더링 설정 주입용 seam으로 존재하며 셀프테스트가 fake를
주입하는 통로다. 여기에 필드를 하나 추가하는 것이 이 코드베이스의 정석이다.

적용 지점은 기존 호출부 두 곳뿐이다.

- 픽셀 모드 `app/BatteryRenderer.swift:392`
- 모던 모드 `app/BatteryRenderer.swift:501-503`

**모던 렌더러의 configuration 접근**: `renderModernSummaryImage`는 현재 `configuration`을 인자로
받지 않는다(`app/main.swift:740-743`). 채움 색을 전달하려면 시그니처에 파라미터를 추가한다.
`renderBatteryImage`(픽셀)는 이미 configuration을 받으므로 변경 없다.

**드롭다운**: `usageColor(forRemaining:)`(`app/Util.swift:76-82`)의 green(`#348A45`)도 사용자 색을
따르게 한다. 지금도 메뉴바 초록과 값이 다른데, 사용자 색을 메뉴바에만 적용하면 새로운 불일치를
만드는 셈이다.

**빗금 무효화**: 해치 레이어의 `rebuildKey`는 색 문자열로 만들어진다(`app/main.swift:477`).
색이 바뀌면 키가 달라져 레이어가 정상 재생성되므로 추가 작업이 없다. 이 동작을 테스트로 고정한다.

### 4. 설정 UI (`app/main.swift`)

Display 탭의 `appearance` 그리드(`app/main.swift:932-936`)에 행을 하나 추가한다.

```
Battery color   [기본] [■] [■] [■] [■] [■] │ 사용자 지정…
```

- **첫 칸 "기본"** = 미설정 상태(다크·라이트 자동 분기). 사용자 색을 되돌리는 수단을 겸한다
- 프리셋 5색: `#0F5132` 포레스트 · `#198532` 클래식 · `#34C759` 시스템 그린 ·
  `#00A878` 에메랄드 · `#6FBF4A` 라임
- 선택된 칸은 링으로 표시. 클릭 즉시 저장 + `rerender()`
- 폭은 기존 팝업들과 맞춰 230pt 자리에 넣는다

**사용자 지정 시트**: 표준 `NSSlider` 3개 + 실시간 배터리 미리보기.

| 슬라이더 | 범위 | 비고 |
|---|---|---|
| 색조 | 85°–170° | 연두 ~ 청록. **녹색 이탈이 구조적으로 불가능** |
| 채도 | 0.35–1.00 | |
| 밝기 | 0.25–0.95 | |

색조만 제한하면 나머지 두 축은 자유롭게 열어도 녹색을 벗어나지 않는다. 채도를 고정하지 않는
이유: 프리셋 5색의 채도가 서로 다르므로, 고정하면 시트를 열었을 때 현재 색을 그대로 표현할 수
없고 슬라이더를 건드리지 않아도 색이 튄다. 시트는 **현재 색의 HSB 값으로 초기화**한다.

커스텀 드로잉 없이 표준 컨트롤만 쓴다. 배포 타깃이 macOS 12(`app/build.sh:9`)이므로
13.0+ 전용 API(`NSColorWell.colorWellStyle`)는 쓰지 않는다. `NSColorPanel`도 쓰지 않는다 —
녹색 제한을 걸 수 없어 "고른 색과 결과가 다른" 문제가 생긴다.

### 5. 설정창 수정 4건

#### 5-1. Battery size · Cat이 모던 모드에서 무효 (`app/main.swift:932-936`)

기본 표시 모드는 `modern`인데(`currentDisplayMode()`, `app/BatteryRenderer.swift:174-176`)
모던 렌더러는 `batterySize`·`catStyle`에 도달하지 않는다. 고양이는 `app/main.swift:548`에서
`displayMode() != "modern"` 가드로 명시 차단된다. 그런데 설정 UI는 세 컨트롤을 동일한 활성
상태로 나란히 배치해, 골라도 아무 일이 일어나지 않는다.

- 모던 모드일 때 두 행을 **비활성화**하고 "픽셀 모드 전용" 안내를 `note()`로 붙인다
- Display style 팝업을 바꾸면 **즉시 토글**한다 — `settingsDisplayModeChanged`가 두 컨트롤의
  `isEnabled`와 안내 문구를 갱신한다
- 토글하려면 컨트롤 참조가 필요하므로 `AppDelegate`에 약한 참조를 보관한다
- 렌더러는 건드리지 않는다. 모던 모드에 크기 변형·고양이를 구현하는 것은 이번 범위 밖이다

#### 5-2. 설정창 번역 누락 (`app/Localization.swift:39-230`)

설정창 전용 문자열 13개 중 12개가 `TR` 딕셔너리에 **키 자체가 없어** 전 언어에서 영어로
폴백된다(`tr()`은 `TR[en]?[language] ?? en`, `app/Localization.swift:232-235`). 드롭다운은 100%
번역되어 있어, 한 화면 안에서 언어가 섞인다.

- 누락 12문자열을 6개 언어(`en`/`ko`/`ja`/`zh-Hans`/`zh-Hant`/`es`)로 채운다:
  탭 제목 `General`·`Display`·`Limits`·`Integration`·`Updates`,
  헤딩 `Appearance`·`Integrations`, 설명문 5개
- `ko`만 있는 메트릭 라벨 5개(`Claude 5h`·`Claude week`·`Claude Fable`·`Codex 5h`·`Codex week`,
  `app/Localization.swift:150-151`)에 나머지 4개 언어를 채운다
- 신규 문자열(`Battery color`, 프리셋 이름, `사용자 지정…`, 픽셀 전용 안내)도 6개 언어로 넣는다
- **죽은 항목 제거**: `OK`·`Cancel`(`app/Localization.swift:152` — 설정창에 두 버튼이 없다),
  `Menu bar items…`(말줄임표 버전), 실제 코드와 문구가 다른 미사용 설명문

#### 5-3. 언어를 바꿔도 설정창이 그대로 (`app/main.swift:964`, `:866-877`)

`rerender()`(`app/main.swift:683-685`)는 메뉴와 상태 아이콘만 재생성한다. 설정창의 라벨은
`showSettings()`에서 한 번 만들어진 뒤 재구축되지 않아, 언어를 바꾼 직후 사용자가 보고 있는
화면만 이전 언어로 남는다.

- `showSettings()`에서 탭 뷰 구축부를 `buildSettingsTabs() -> NSTabView`로 분리한다
- 언어 변경 시: 현재 선택된 탭 인덱스를 기억 → 내용 재구축 → 탭 선택 복원
- 창 자체(위치·크기)는 유지한다

#### 5-4. Limits 탭 설명문이 기본 모드에서 거짓 (`app/main.swift:939`)

현재 문구는 "메뉴바에 표시할 한도를 고르세요"인데, 모던 모드의 메뉴바는 프로바이더당 배터리
1개이고 체크된 한도들의 **최솟값**을 보여준다(`providerSummaries`, `app/main.swift:82-83`).
체크를 풀면 항목이 사라지는 게 아니라 숫자가 조용히 올라간다. 1:1 대응은 픽셀 모드에서만
성립한다(`battItems`, `app/main.swift:33-48`).

- 설명문을 실제 동작에 맞게 다시 쓴다: 모던 모드는 **선택된 한도 중 가장 빠듯한 값**을 표시하고,
  픽셀 모드는 선택된 한도마다 배터리를 하나씩 그린다는 점을 명시한다
- `Claude Fable`이 기본 꺼짐이라는 사실(`METRIC_VISIBILITY_DEFAULTS`,
  `app/BatteryRenderer.swift:164-167`)을 안내에 포함한다

## 테스트

`--self-test-core`에 추가한다. 기존 `PresentationConfiguration` fake 주입 패턴(`app/main.swift:1082`
등)을 그대로 재사용한다.

**회귀 방지 (가장 중요)**
- 사용자 색 미설정 시 모든 색이 현행과 **바이트 단위로 동일**할 것.
  `activityHatchRGB(75, dark: true) == (9, 47, 18)`을 검증하는 기존 테스트(`app/main.swift:1761`)가
  수정 없이 통과해야 한다

**신규**
- 사용자 색 주입 시 green 밴드만 바뀌고 **앰버·빨강은 불변**
- 빗금 색이 사용자 색 × 0.35로 따라온다
- 100%(≥99.5%)는 사용자 색과 무관하게 골드 유지
- `rgbFromHex` 왕복 및 형식 오류(`#GGG`, 빈 문자열, `#` 누락) → `nil` 폴백
- 사용자 색 변경 시 해치 레이어 `rebuildKey`가 달라져 레이어가 재생성된다
- 드롭다운 게이지 색이 메뉴바 채움 색과 일치한다
- 모던 모드에서 Battery size·Cat 컨트롤이 비활성, 픽셀 모드에서 활성
- 언어 변경 후 설정창 라벨이 새 언어로 바뀌고 선택된 탭이 유지된다
- `TR` 딕셔너리에 설정창 문자열이 6개 언어 모두 존재한다 (키 누락 검출)

**육안 확인**
- `app/build.sh` 후 실제 메뉴바에서 프리셋·사용자 지정 색 적용, 다크/라이트 전환,
  잔량이 50% 아래로 떨어질 때 앰버로 정상 전환되는지 확인

## 하지 않는 것

- 캡슐 빈 트랙 / 아이콘 판 / 메뉴바 버튼 칸 배경색 — 이번 대상은 채움 색뿐
- 앰버·빨강 경고색 개인화, 밴드 경계(20%/50%) 설정화
- 모던 모드의 배터리 크기 변형·고양이 구현
- macOS 설정창 관례 6종 — `⌘,` 단축키, `⌘W`(메인 메뉴 부재), 창 리사이즈, 창 위치 기억,
  말줄임표 라벨, 툴바형 탭
- 탭 IA 재편 및 중복 제거 — `Open GitHub page` 3중복, 버전 라벨 2중복, 빈 Updates 탭
- 설정창 내 상태·진단 섹션 (마지막 갱신 시각, 로그인 상태, 캐시 지우기, SwiftBar 중복 경고 해소)
- 갱신 주기(`REFRESH_SECONDS`, `app/main.swift:7`)·빗금 파라미터의 설정 노출
- "기본값으로 복원", 설정 저장소 3중 분산(UserDefaults / `STATE_DIR` 파일 / `SMAppService`) 통합
- SwiftBar 플러그인과의 색 동기화

위 항목은 조사에서 확인된 실제 문제이며, 별도 작업으로 남긴다.
