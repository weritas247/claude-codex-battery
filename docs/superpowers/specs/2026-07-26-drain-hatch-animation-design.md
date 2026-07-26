# 사용중 애니메이션 교체 — 배터리 소모 빗금 (drain hatch)

날짜: 2026-07-26

## 배경

Claude / Codex 세션이 활성일 때 메뉴바 위젯은 프로바이더 아이콘 둘레를 3px 점이 0.9초에 한 바퀴 도는
orbit 애니메이션으로 "사용중"을 표시한다 (`app/main.swift` `updateActivityLayers`).
이 표시는 배터리와 무관한 위치에서 돌아 "지금 사용량이 닳고 있다"는 의미가 전달되지 않는다.

배터리 잔량 자체가 소모되는 느낌을 주는 애니메이션으로 교체한다.

## 확정된 시각 사양

브라우저 목업(후보 A~F, D 세부 변형)으로 비교해 아래 조합을 확정했다.

| 항목 | 값 |
|---|---|
| 형태 | 45° 대각 빗금(반복 패턴)이 잔량 채움 영역 위를 흐름 |
| 방향 | 오른쪽 → 왼쪽 (충전 애니메이션의 역방향 = 소모) |
| 굵기 | 3px (모던 모드 기준, 포인트) |
| 간격 | 굵기 × 3 = 피치 9px |
| 주기 | 0.60s (피치 하나를 지나가는 시간) |
| 색 | **잔량 색에서 자동 파생** — RGB 각 채널 × 0.35, 알파 0.85 |

색을 잔량 색에서 파생하는 이유: 잔량이 초록(≥50%) → 앰버(<50%) → 빨강(<20%)으로 바뀌어도
대비 세기가 일정하게 유지되고, 배터리의 색 신호(traffic light)를 깨지 않는다.
고정 딥그린은 앰버·빨강 위에서 색이 겉돌고, 검정 반투명 고정은 톤이 죽는다.

## 적용 범위

- 모던 표시 모드(`displayMode == "modern"`): orbit 점을 **제거**하고 빗금으로 대체
- 픽셀 표시 모드(`displayMode == "pixel"`): 빗금을 **적용하지 않는다**. 기존 고양이 스프라이트 +
  글린트 애니메이션을 그대로 유지한다.
  - 이유: 픽셀 캡슐 내부는 논리 픽셀 14×6 뿐이라 빗금이 어두운 퍼센트 숫자와 겹쳐 숫자를 읽을 수
    없게 만든다. 실제 메뉴바에서 확인 후 픽셀 모드 빗금을 철회했다.
- 드롭다운 메뉴 안의 막대 그래프는 변경하지 않는다
- `reduceMotion`이 켜져 있으면 두 모드 모두 애니메이션 없음 (기존 정책 유지)

## 구현 설계

### 1. 공통 — 빗금 헬퍼 (`app/BatteryRenderer.swift`)

`heatRemain(_:dark:)`은 private이므로, 잔량 값에서 빗금 색을 얻는 공개 헬퍼를 둔다.

```
func activityHatchRGB(_ remain: Double?, dark: Bool) -> (UInt8, UInt8, UInt8)  // 파생색 (RGB × 0.35)
func emptyHatchRGB(dark: Bool) -> (UInt8, UInt8, UInt8)                       // 저잔량 폴백 톤
func hatchNSColor(_ rgb: (UInt8, UInt8, UInt8), alpha: CGFloat) -> NSColor     // RGB → NSColor
func hatchStripeImage(width:height:color:) -> CGImage?                        // 45° 빗금 타일
func modernValueTextImage(_ value: Double, dark: Bool)                        // "NN%" 글리프 래스터
  -> (image: CGImage, size: CGSize, rasterSize: CGSize)?
```

`modernValueAttributes(dark:)`가 폰트/색의 단일 출처라, 캡슐 이미지와 오버레이 라벨이 같은
글리프를 그린다. `rasterSize`는 픽셀 격자로 올림한 크기 — 레이어를 `size`로 잡으면 기본
`contentsGravity = .resize`가 글리프를 눌러버리므로 레이어 크기는 `rasterSize`를 쓴다.

### 2. 모던 모드 — CALayer 오버레이 (`app/main.swift`)

이미지 재렌더 없이 버튼 레이어 위에 얹는다. 프로바이더당 레이어 두 장:

- **clip** (`activityLayers[provider]`): fill 사각형(`bodyX+2, originY+5, fillW, 14`)에
  `masksToBounds = true`, `cornerRadius = 2.5`. 별도 `CAShapeLayer` 마스크는 쓰지 않는다.
- **stripes** (clip의 서브레이어): `contents`는 `hatchStripeImage`가 그린 45° 빗금 타일.
  폭은 `fill 폭 + 피치`. `anchorPoint = (0, 0.5)` — 리사이즈해도 `position.x`가 0으로 고정돼
  진행 중인 애니메이션의 절대 from/to 값이 그대로 유효하다.
- **label** (`activityTextLayers[provider]`): clip이 캡슐 이미지의 가운데 정렬된 "NN%"를 덮으므로
  같은 글리프를 빗금 **위에** 다시 그린다. x 원점은 `renderModernSummaryImage`와 동일한 중앙 정렬
  계산, 크기는 `rasterSize`.
- 애니메이션: stripes의 `position.x`를 피치(9pt)만큼 음의 방향으로 이동, `duration 0.6`,
  `repeatCount .infinity`. `timingFunction`을 두지 않아 기본 linear.

**재사용 / 리사이즈**: `updateActivityLayers`는 매 refresh마다(`setButtonImage` 포함) 돌기 때문에,
매번 레이어를 새로 만들면 진행 중인 drift가 t=0으로 되돌아간다. clip의 `name`에 **rebuild key**
(빗금 타일이 구워지는 값 = 색 + 알파)만 담고,

- rebuild key가 같고 rect가 달라졌으면 → **in-place 리사이즈**: `clip.frame`, `stripes.frame`,
  `stripes.contents`만 갱신하고 `"drain"` 애니메이션은 그대로 둔다
- rebuild key가 같고 rect도 같으면 → 라벨만 갱신
- rebuild key가 달라졌으면 → 두 레이어 모두 재생성

라벨은 **세 경로 모두에서** 갱신한다. 잔량이 저잔량 폴백 구간에 있으면 rect·색·알파가 모두
잔량과 무관해져 rebuild key와 rect가 동시에 고정되므로, 라벨만 갱신하는 경로가 없으면 옛 숫자가
새 이미지 위에 그대로 남는다.

리사이즈·라벨 갱신은 `CATransaction.setDisableActions(true)` 안에서 한다. 암시적 액션이 켜져 있으면
리사이즈가 슬라이드되고 숫자가 크로스페이드된다.

**좌표 상수 수정**: 기존 activity 레이어는 `itemWidth = 61`을 썼지만
`renderModernSummaryImage`의 실제 항목 폭은 `iconWidth(13) + iconGap(5) + bodyW(38) + 3 = 59`다.
두 번째 배터리에서 2px 어긋나므로 `MODERN_*` 상수를 두 곳이 공유하게 해 바로잡는다.
빗금은 fill에 정확히 겹쳐야 한다.

### 3. 픽셀 모드 — 변경 없음

빗금을 넣지 않으므로 `drawCapsule` / `renderBatteryImage` 시그니처, `catTick`, `restartCatTimer`는
모두 기존 형태를 유지한다. 고양이 타이머는 고양이 프레임만 담당한다.

### 4. 예외 처리

- **잔량이 매우 적을 때**: fill 폭이 6pt 미만이면 빗금을 배터리 내부 전체에 낮은 알파의 플랫한
  톤으로 그린다. 0%에서도 "사용중"이 계속 보인다.
- **비활성 전환 / reduceMotion**: 빗금 레이어는 `updateActivityLayers`가 조정하고,
  `stopVisualMotion` / `clearActivityLayers`가 정리한다. 일반 refresh 주기는 레이어를 재사용해
  진행 중인 drift 애니메이션을 t=0으로 되돌리지 않는다.

## 테스트

- `--self-test-core`의 기존 activity 검증(`main.swift`의 `motionDelegate.apiActiveProviders` 블록)을
  orbit 레이어 대신 **빗금 레이어 생성/제거** 검증으로 교체
- 레이어 재사용(색이 그대로면 동일 인스턴스 유지), 잔량이 바뀔 때의 in-place 리사이즈(같은 인스턴스 +
  `"drain"` 유지), 잔량 저하 시 폴백, 빗금 위 퍼센트 텍스트 레이어의 원점/크기를 검증
- `reduceMotion = true`에서 두 모드 모두 애니메이션 리소스가 남지 않는지 확인 (기존 검증 확장)
- 육안 확인: `app/build.sh` 후 실제 메뉴바에서 Claude 세션을 돌려 빗금 동작과 잔량 색 전환 확인

## 하지 않는 것

- 드롭다운 메뉴 막대 그래프 애니메이션
- 빗금 파라미터(각도/굵기/속도)의 사용자 설정 노출 — 고정값으로 간다
- 프로바이더별 빗금 색 분리 — 색은 잔량 상태에서만 파생된다
