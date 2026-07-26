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
- 픽셀 표시 모드(`displayMode == "pixel"`): 캡슐 채움 위에 동일한 45° 빗금을 픽셀 단위로 적용
- 드롭다운 메뉴 안의 막대 그래프는 변경하지 않는다
- `reduceMotion`이 켜져 있으면 두 모드 모두 애니메이션 없음 (기존 정책 유지)

## 구현 설계

### 1. 공통 — 빗금 색 헬퍼 (`app/BatteryRenderer.swift`)

`heatRemain(_:dark:)`은 private이므로, 잔량 값에서 빗금 색을 얻는 공개 헬퍼를 추가한다.

```
func activityHatchColor(remain: Double?, dark: Bool) -> RGB   // 파생색 (RGB × 0.35)
```

모던 모드는 `NSColor`가 필요하므로 같은 파일에서 `RGB → NSColor` 변환을 함께 노출한다.
`nil`/빈 잔량은 호출부에서 걸러낸다.

### 2. 모던 모드 — CALayer 오버레이 (`app/main.swift`)

기존 orbit과 같은 레이어 오버레이 방식이라 이미지 재렌더가 없다.

- 프로바이더별 `CALayer` 하나(`hatchLayers[provider]`)
- `contents`: 45° 빗금 한 피치를 그린 타일 `CGImage`. 레이어 폭은 `fill 폭 + 피치`,
  `contentsGravity = .resize` 대신 타일 이미지를 반복 배치한 크기로 생성
- `mask`: fill 사각형(`x+2, y+5, fillW, 14`, 반경 2.5)의 `CAShapeLayer`
- 애니메이션: `position.x`를 피치(9pt)만큼 음의 방향으로 이동, `duration 0.6`, `repeatCount .infinity`, linear
- 잔량/레이아웃이 바뀌면 마스크와 레이어 폭을 다시 계산 (기존 `updateActivityLayers` 호출 경로 그대로 사용)

**좌표 상수 수정**: 현재 activity 레이어는 `itemWidth = 61`을 쓰지만
`renderModernSummaryImage`의 실제 항목 폭은 `iconWidth(13) + iconGap(5) + bodyW(38) + 3 = 59`다.
두 번째 배터리에서 2px 어긋나므로 `59`로 바로잡는다. 빗금은 fill에 정확히 겹쳐야 한다.

### 3. 픽셀 모드 — 렌더 시 픽셀 빗금 (`app/BatteryRenderer.swift`, `app/main.swift`)

`drawCapsule`에 `hatchPhase: Int?`를 추가한다. 캔버스가 픽셀 격자이므로 45°는 다음 한 줄로 떨어진다.

```
if ((px - py + phase) % pitch) < width { cv.set(px, py, hatchColor) }
```

- fill 영역(`x+2 ..< x+2+fw`, `by+2 ..< by+bh-2`) 안에서만 적용
- 픽셀 캔버스는 2x이므로 굵기 2px / 피치 6px을 사용해 모던 모드와 비슷한 밀도를 맞춘다
- `renderBatteryImage(… hatchPhase:)`로 전달하고, 활성 프로바이더의 `BattItem`에만 적용
  (`BattItem.provider`로 판별)

**타이머 통합**: 고양이 프레임 타이머와 빗금 phase 타이머가 각각 `setButtonImage`를 호출하면
서로의 상태를 덮어쓴다. 기존 `catTick`을 "픽셀 모션 틱"으로 확장해 한 틱에서
`catIdx`와 `hatchPhase`를 함께 증가시키고 이미지를 한 번만 그린다.

- 주기: 0.1s (10fps). 피치 6px을 0.6s에 지나가므로 틱당 1px
- 실행 조건: 고양이가 켜져 있거나 활성 프로바이더가 하나 이상일 때
- 인트로/글린트 프레임 재생 중(`animTimer?.isValid == true`)에는 기존 가드대로 skip

### 4. 예외 처리

- **잔량이 매우 적을 때**: fill 폭이 8px(모던) / 6px(픽셀) 미만이면 빗금을 배터리 내부 전체에
  ink 20% 알파로 그린다. 0%에서도 "사용중"이 계속 보인다.
- **100% 골드 글린트**: 픽셀 모드에서 골드 캡슐의 글린트 스윕과 겹치지 않도록,
  글린트 프레임 재생 중에는 빗금 틱을 skip한다 (기존 `catTick` 가드와 동일).
- **비활성 전환 / reduceMotion**: `stopVisualMotion`이 레이어를 정리하는 기존 경로를 그대로 사용하고,
  픽셀 모드는 phase를 0으로 되돌린 정적 이미지를 다시 그린다.

## 테스트

- `--self-test-core`의 기존 activity 검증(`main.swift`의 `motionDelegate.apiActiveProviders` 블록)을
  orbit 레이어 대신 **빗금 레이어 생성/제거** 검증으로 교체
- 픽셀 모드: 동일 입력에 `hatchPhase`만 바꿔 렌더한 두 이미지가 서로 다르고,
  `hatchPhase = nil`이면 기존 이미지와 픽셀 단위로 동일한지 확인
- `reduceMotion = true`에서 두 모드 모두 애니메이션 리소스가 남지 않는지 확인 (기존 검증 확장)
- 육안 확인: `app/build.sh` 후 실제 메뉴바에서 Claude 세션을 돌려 빗금 동작과 잔량 색 전환 확인

## 하지 않는 것

- 드롭다운 메뉴 막대 그래프 애니메이션
- 빗금 파라미터(각도/굵기/속도)의 사용자 설정 노출 — 고정값으로 간다
- 프로바이더별 빗금 색 분리 — 색은 잔량 상태에서만 파생된다
