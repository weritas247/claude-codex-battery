// UI localization — English (default), Korean, Japanese, Chinese (Simplified/Traditional), Spanish.
// Resolution order: CCB_LANG env → user's saved choice (Settings → Language) → system language → English.
// The choice is also written to ~/.claude/swiftbar/.lang so the SwiftBar widget follows it.
import Foundation

let SUPPORTED_LANGS = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "es"]
let LANG_FILE = "\(STATE_DIR)/.lang"

func normLang(_ raw: String) -> String {
  let l = raw.lowercased()
  if l.hasPrefix("ko") { return "ko" }
  if l.hasPrefix("ja") { return "ja" }
  if l.hasPrefix("es") { return "es" }
  if l.hasPrefix("zh") {
    if l.contains("hant") || l.contains("-tw") || l.contains("-hk") || l.contains("-mo") { return "zh-Hant" }
    return "zh-Hans"
  }
  if l.hasPrefix("en") { return "en" }
  return raw
}

func resolveLang() -> String {
  if let f = ProcessInfo.processInfo.environment["CCB_LANG"] {
    let n = normLang(f)
    if SUPPORTED_LANGS.contains(n) { return n }
  }
  if let saved = UserDefaults.standard.string(forKey: "uiLang"), saved != "auto",
     SUPPORTED_LANGS.contains(saved) { return saved }
  for pref in Locale.preferredLanguages {
    let n = normLang(pref)
    if SUPPORTED_LANGS.contains(n) { return n }
  }
  return "en"
}

var UI_LANG = resolveLang()

// English text is the key; missing entries fall back to English.
private let TR: [String: [String: String]] = [
  "%d%% remaining": [
    "ko": "%d%% 남음", "ja": "残り%d%%", "zh-Hans": "剩余 %d%%", "zh-Hant": "剩餘 %d%%", "es": "%d%% restante",
  ],
  "live · updated just now": [
    "ko": "실시간 · 방금 업데이트", "ja": "ライブ · たった今更新", "zh-Hans": "实时 · 刚刚更新", "zh-Hant": "即時 · 剛剛更新", "es": "en vivo · actualizado ahora",
  ],
  "5h remaining is low and reset is still %@ away": [
    "ko": "5시간 잔여량이 낮고 리셋까지 아직 %@ 남음", "ja": "5時間の残量が少なく、リセットまであと%@", "zh-Hans": "5 小时剩余量较低，距重置仍有 %@", "zh-Hant": "5 小時剩餘量偏低，距重置仍有 %@", "es": "queda poco en 5h y faltan %@ para el reinicio",
  ],
  "reset": [
    "ko": "리셋됨", "ja": "リセット済み", "zh-Hans": "已重置", "zh-Hant": "已重置", "es": "reiniciado",
  ],
  "resets": [
    "ko": "리셋", "ja": "リセット", "zh-Hans": "重置", "zh-Hant": "重置", "es": "reinicia",
  ],
  "usage": [
    "ko": "사용량", "ja": "使用量", "zh-Hans": "用量", "zh-Hant": "用量", "es": "uso",
  ],
  "cached %@ ago — check login/network": [
    "ko": "%@ 전 캐시 — 로그인·네트워크 확인",
    "ja": "%@前のキャッシュ — ログイン/ネットワークを確認",
    "zh-Hans": "%@ 前的缓存 — 请检查登录/网络",
    "zh-Hant": "%@ 前的快取 — 請檢查登入/網路",
    "es": "caché de hace %@ — revisa sesión/red",
  ],
  "rate limited — retrying in %@ (cached %@ ago)": [
    "ko": "요청 제한 — %@ 후 재시도 (%@ 전 캐시)",
    "ja": "レート制限 — %@後に再試行 (%@前のキャッシュ)",
    "zh-Hans": "触发限流 — %@ 后重试（%@ 前的缓存）",
    "zh-Hant": "觸發限流 — %@ 後重試（%@ 前的快取）",
    "es": "límite de solicitudes — reintento en %@ (caché de hace %@)",
  ],
  // ── Stale-data diagnosis and its recovery submenu ──────────────────────────
  "cached %@ ago — live updates are off": [
    "ko": "%@ 전 캐시 — 실시간 조회가 꺼져 있음",
    "ja": "%@前のキャッシュ — ライブ更新がオフ",
    "zh-Hans": "%@ 前的缓存 — 实时更新已关闭",
    "zh-Hant": "%@ 前的快取 — 即時更新已關閉",
    "es": "caché de hace %@ — las actualizaciones en vivo están desactivadas",
  ],
  "cached %@ ago — no login found": [
    "ko": "%@ 전 캐시 — 로그인 정보 없음",
    "ja": "%@前のキャッシュ — ログイン情報が見つかりません",
    "zh-Hans": "%@ 前的缓存 — 未找到登录信息",
    "zh-Hant": "%@ 前的快取 — 找不到登入資訊",
    "es": "caché de hace %@ — no se encontró sesión",
  ],
  "cached %@ ago — login expired, sign in again": [
    "ko": "%@ 전 캐시 — 로그인 만료됨, 다시 로그인 필요",
    "ja": "%@前のキャッシュ — ログインの期限切れ。再ログインが必要です",
    "zh-Hans": "%@ 前的缓存 — 登录已过期，请重新登录",
    "zh-Hant": "%@ 前的快取 — 登入已過期，請重新登入",
    "es": "caché de hace %@ — sesión caducada, inicia sesión otra vez",
  ],
  "cached %@ ago — still rate limited by the server": [
    "ko": "%@ 전 캐시 — 서버가 아직 요청 제한 중",
    "ja": "%@前のキャッシュ — サーバー側のレート制限が継続中",
    "zh-Hans": "%@ 前的缓存 — 服务器仍在限流",
    "zh-Hant": "%@ 前的快取 — 伺服器仍在限流",
    "es": "caché de hace %@ — el servidor sigue limitando",
  ],
  "cached %@ ago — can't reach the server": [
    "ko": "%@ 전 캐시 — 서버에 연결할 수 없음",
    "ja": "%@前のキャッシュ — サーバーに接続できません",
    "zh-Hans": "%@ 前的缓存 — 无法连接服务器",
    "zh-Hant": "%@ 前的快取 — 無法連線伺服器",
    "es": "caché de hace %@ — no se puede contactar el servidor",
  ],
  "Turn live updates back on": [
    "ko": "실시간 조회 다시 켜기", "ja": "ライブ更新を再度オンにする",
    "zh-Hans": "重新开启实时更新", "zh-Hant": "重新開啟即時更新",
    "es": "Reactivar actualizaciones en vivo",
  ],
  "no login": [
    "ko": "로그인 없음", "ja": "ログインなし", "zh-Hans": "无登录", "zh-Hant": "無登入", "es": "sin sesión",
  ],
  "login expired": [
    "ko": "로그인 만료됨", "ja": "ログイン期限切れ", "zh-Hans": "登录已过期",
    "zh-Hant": "登入已過期", "es": "sesión caducada",
  ],
  "rate limited %@": [
    "ko": "요청 제한 %@ 남음", "ja": "レート制限 残り%@", "zh-Hans": "限流中 剩余 %@",
    "zh-Hant": "限流中 剩餘 %@", "es": "limitado %@",
  ],
  "ready": [
    "ko": "사용 가능", "ja": "利用可能", "zh-Hans": "可用", "zh-Hant": "可用", "es": "disponible",
  ],
  "No other login is available to switch to": [
    "ko": "전환할 수 있는 다른 로그인이 없습니다",
    "ja": "切り替えられる他のログインがありません",
    "zh-Hans": "没有其他可切换的登录",
    "zh-Hant": "沒有其他可切換的登入",
    "es": "No hay otra sesión a la que cambiar",
  ],
  "Switch Claude login": [
    "ko": "Claude 로그인 전환", "ja": "Claudeのログインを切り替え",
    "zh-Hans": "切换 Claude 登录", "zh-Hant": "切換 Claude 登入",
    "es": "Cambiar de sesión de Claude",
  ],
  "Sign in to %@…": [
    "ko": "%@ 로그인…", "ja": "%@ にログイン…",
    "zh-Hans": "登录 %@…", "zh-Hant": "登入 %@…",
    "es": "Iniciar sesión en %@…",
  ],
  "Open the menu on hover": [
    "ko": "마우스를 올리면 메뉴 열기", "ja": "ホバーでメニューを開く",
    "zh-Hans": "悬停即打开菜单", "zh-Hant": "滑鼠移過即開啟選單",
    "es": "Abrir el menú al pasar el cursor",
  ],
  "Sign in to a login": [
    "ko": "로그인하기", "ja": "ログインする",
    "zh-Hans": "登录某个账号", "zh-Hant": "登入某個帳號",
    "es": "Iniciar sesión en una cuenta",
  ],
  "Claude Code was not found on this Mac": [
    "ko": "이 Mac에서 Claude Code를 찾을 수 없습니다",
    "ja": "このMacでClaude Codeが見つかりません",
    "zh-Hans": "在这台 Mac 上找不到 Claude Code",
    "zh-Hant": "在這台 Mac 上找不到 Claude Code",
    "es": "No se encontró Claude Code en este Mac",
  ],
  "The sign-in command has been copied to the clipboard — run it in a terminal where the claude CLI is available.": [
    "ko": "로그인 명령을 클립보드에 복사했습니다 — claude CLI를 쓸 수 있는 터미널에서 실행하세요.",
    "ja": "ログインコマンドをクリップボードにコピーしました — claude CLIが使えるターミナルで実行してください。",
    "zh-Hans": "登录命令已复制到剪贴板 — 请在可以使用 claude CLI 的终端中运行。",
    "zh-Hant": "登入指令已複製到剪貼簿 — 請在可使用 claude CLI 的終端機中執行。",
    "es": "El comando de inicio de sesión se copió al portapapeles: ejecútalo en una terminal donde esté disponible la CLI de claude.",
  ],
  "Sign in with the Codex app": [
    "ko": "Codex 앱에서 로그인", "ja": "Codexアプリでログイン",
    "zh-Hans": "在 Codex 应用中登录", "zh-Hant": "在 Codex App 中登入",
    "es": "Iniciar sesión con la app de Codex",
  ],
  "Retry now": [
    "ko": "지금 다시 시도", "ja": "今すぐ再試行",
    "zh-Hans": "立即重试", "zh-Hant": "立即重試", "es": "Reintentar ahora",
  ],
  "Force retry now — may extend the limit": [
    "ko": "강제로 다시 시도 — 제한이 길어질 수 있음",
    "ja": "強制的に再試行 — 制限が延びる可能性があります",
    "zh-Hans": "强制重试 — 可能延长限流时间",
    "zh-Hant": "強制重試 — 可能延長限流時間",
    "es": "Forzar reintento — puede alargar el límite",
  ],
  "Retry while rate limited?": [
    "ko": "요청 제한 중에 다시 시도할까요?", "ja": "レート制限中に再試行しますか？",
    "zh-Hans": "要在限流期间重试吗？", "zh-Hant": "要在限流期間重試嗎？",
    "es": "¿Reintentar durante el límite?",
  ],
  "The server restarts its cooldown on every request made during a limit, so retrying now can keep the numbers stale for longer. Switching to another login is the safer fix.": [
    "ko": "제한이 걸린 동안 요청을 보내면 서버가 대기 시간을 다시 시작하므로, 지금 재시도하면 오히려 더 오래 갱신되지 않을 수 있습니다. 다른 로그인으로 전환하는 편이 안전합니다.",
    "ja": "制限中にリクエストを送るとサーバーが待機時間をリセットするため、今再試行すると更新されない時間がかえって長くなる可能性があります。別のログインに切り替える方が安全です。",
    "zh-Hans": "限流期间的每次请求都会让服务器重新计时，现在重试可能让数据停滞更久。切换到其他登录更安全。",
    "zh-Hant": "限流期間的每次請求都會讓伺服器重新計時，現在重試可能讓資料停滯更久。切換到其他登入更安全。",
    "es": "El servidor reinicia su espera con cada petición hecha durante un límite, así que reintentar ahora puede dejar los datos desactualizados más tiempo. Cambiar de sesión es lo más seguro.",
  ],
  "Retry anyway": [
    "ko": "그래도 재시도", "ja": "それでも再試行",
    "zh-Hans": "仍然重试", "zh-Hant": "仍然重試", "es": "Reintentar igualmente",
  ],
  "Cancel": [
    "ko": "취소", "ja": "キャンセル", "zh-Hans": "取消", "zh-Hant": "取消", "es": "Cancelar",
  ],
  "this block  $%.2f · %@ tokens · $%@/h": [
    "ko": "이번 블록  $%.2f · %@ 토큰 · $%@/h",
    "ja": "現在のブロック  $%.2f · %@ tokens · $%@/h",
    "zh-Hans": "本时段  $%.2f · %@ tokens · $%@/h",
    "zh-Hant": "本時段  $%.2f · %@ tokens · $%@/h",
    "es": "este bloque  $%.2f · %@ tokens · $%@/h",
  ],
  "today by model · $%.0f total": [
    "ko": "오늘 모델별 · 합 $%.0f",
    "ja": "今日のモデル別 · 計 $%.0f",
    "zh-Hans": "今日按模型 · 共 $%.0f",
    "zh-Hant": "今日按模型 · 共 $%.0f",
    "es": "hoy por modelo · total $%.0f",
  ],
  "credits  unlimited": [
    "ko": "크레딧  무제한", "ja": "クレジット 無制限", "zh-Hans": "额度 无限", "zh-Hant": "額度 無限",
    "es": "créditos  ilimitados",
  ],
  "credits  exhausted — buy more or wait for reset": [
    "ko": "크레딧  소진 — 구매 또는 리셋 대기",
    "ja": "クレジット切れ — 購入するかリセットを待つ",
    "zh-Hans": "额度用尽 — 购买或等待重置",
    "zh-Hant": "額度用盡 — 購買或等待重置",
    "es": "créditos agotados — compra más o espera el reinicio",
  ],
  "credits  balance %.0f": [
    "ko": "크레딧  잔액 %.0f", "ja": "クレジット残高 %.0f", "zh-Hans": "额度余额 %.0f",
    "zh-Hant": "額度餘額 %.0f", "es": "créditos  saldo %.0f",
  ],
  "Run Claude Code or Codex and usage will appear here": [
    "ko": "Claude Code나 Codex를 실행하면 사용량이 표시됩니다",
    "ja": "Claude CodeまたはCodexを使うと使用量が表示されます",
    "zh-Hans": "运行 Claude Code 或 Codex 后将显示用量",
    "zh-Hant": "執行 Claude Code 或 Codex 後將顯示用量",
    "es": "Usa Claude Code o Codex y el consumo aparecerá aquí",
  ],
  "⚠️ SwiftBar widget is also running — batteries appear twice": [
    "ko": "⚠️ SwiftBar 위젯도 실행 중 — 배터리가 두 벌 표시됩니다",
    "ja": "⚠️ SwiftBarウィジェットも実行中 — バッテリーが二重に表示されます",
    "zh-Hans": "⚠️ SwiftBar 小组件也在运行 — 电池会显示两次",
    "zh-Hant": "⚠️ SwiftBar 小工具也在執行 — 電池會顯示兩次",
    "es": "⚠️ El widget de SwiftBar también está activo — las baterías se ven dos veces",
  ],
  "Install v%@ update — one click (current v%@)": [
    "ko": "v%@ 업데이트 설치 — 클릭 한 번 (현재 v%@)",
    "ja": "v%@ アップデートをインストール — ワンクリック (現在 v%@)",
    "zh-Hans": "一键安装 v%@ 更新（当前 v%@）",
    "zh-Hant": "一鍵安裝 v%@ 更新（目前 v%@）",
    "es": "Instalar actualización v%@ — un clic (actual v%@)",
  ],
  "Refresh": [
    "ko": "새로고침", "ja": "更新", "zh-Hans": "刷新", "zh-Hant": "重新整理", "es": "Actualizar",
  ],
  "Settings": [
    "ko": "설정", "ja": "設定", "zh-Hans": "设置", "zh-Hant": "設定", "es": "Ajustes",
  ],
  "General": ["ko": "일반", "ja": "一般", "zh-Hans": "通用", "zh-Hant": "一般", "es": "General"],
  "Configure how Claude and Codex usage appears on this Mac.": [
    "ko": "이 Mac에서 Claude와 Codex 사용량을 어떻게 표시할지 설정합니다.",
    "ja": "このMacでClaudeとCodexの使用量をどう表示するか設定します。",
    "zh-Hans": "配置 Claude 和 Codex 用量在这台 Mac 上的显示方式。",
    "zh-Hant": "設定 Claude 與 Codex 用量在這台 Mac 上的顯示方式。",
    "es": "Configura cómo se muestra el uso de Claude y Codex en este Mac.",
  ],
  "Display": ["ko": "표시", "ja": "表示", "zh-Hans": "显示", "zh-Hant": "顯示", "es": "Pantalla"],
  "Appearance": ["ko": "모양", "ja": "外観", "zh-Hans": "外观", "zh-Hant": "外觀", "es": "Apariencia"],
  "Choose the visual style and optional companion shown in the menu bar.": [
    "ko": "메뉴 막대에 표시할 시각 스타일과 동행 캐릭터를 고릅니다.",
    "ja": "メニューバーに表示するビジュアルスタイルと相棒を選びます。",
    "zh-Hans": "选择菜单栏中显示的视觉样式与可选伙伴。",
    "zh-Hant": "選擇選單列中顯示的視覺樣式與可選夥伴。",
    "es": "Elige el estilo visual y el acompañante que aparecen en la barra de menús.",
  ],
  "Limits": ["ko": "한도", "ja": "上限", "zh-Hans": "限额", "zh-Hant": "額度", "es": "Límites"],
  "Integration": ["ko": "연동", "ja": "連携", "zh-Hans": "集成", "zh-Hant": "整合", "es": "Integración"],
  "Integrations": ["ko": "연동", "ja": "連携", "zh-Hans": "集成", "zh-Hant": "整合", "es": "Integraciones"],
  "Optional tools add cost breakdowns and provide quick access to the project.": [
    "ko": "선택 도구를 붙이면 비용 내역을 볼 수 있고 프로젝트로 바로 이동할 수 있습니다.",
    "ja": "オプションのツールを使うとコスト内訳の表示とプロジェクトへの素早いアクセスができます。",
    "zh-Hans": "可选工具可显示费用明细，并快速访问项目。",
    "zh-Hant": "選用工具可顯示費用明細，並快速前往專案。",
    "es": "Las herramientas opcionales añaden desglose de costes y acceso rápido al proyecto.",
  ],
  "Updates": ["ko": "업데이트", "ja": "アップデート", "zh-Hans": "更新", "zh-Hant": "更新", "es": "Actualizaciones"],
  "The app checks for updates once a day. You can review the source and releases on GitHub.": [
    "ko": "앱은 하루에 한 번 업데이트를 확인합니다. 소스와 릴리즈는 GitHub에서 볼 수 있습니다.",
    "ja": "アプリは1日1回アップデートを確認します。ソースとリリースはGitHubで確認できます。",
    "zh-Hans": "应用每天检查一次更新。你可以在 GitHub 上查看源代码与发行版。",
    "zh-Hant": "應用程式每天檢查一次更新。你可以在 GitHub 上查看原始碼與發行版。",
    "es": "La app busca actualizaciones una vez al día. Puedes ver el código y las versiones en GitHub.",
  ],
  "Cat": ["ko": "고양이", "ja": "ネコ", "zh-Hans": "猫", "zh-Hant": "貓", "es": "Gato"],
  "Battery color": ["ko": "배터리 색상", "ja": "バッテリーの色", "zh-Hans": "电池颜色", "zh-Hant": "電池顏色", "es": "Color de la batería"],
  "Custom…": ["ko": "사용자 지정…", "ja": "カスタム…", "zh-Hans": "自定…", "zh-Hant": "自訂…", "es": "Personalizado…"],
  "Show account name": ["ko": "계정 이름 표시", "ja": "アカウント名を表示", "zh-Hans": "显示账户名",
                        "zh-Hant": "顯示帳戶名稱", "es": "Mostrar el nombre de la cuenta"],
  "Hue": ["ko": "색조", "ja": "色相", "zh-Hans": "色相", "zh-Hant": "色相", "es": "Tono"],
  "Saturation": ["ko": "채도", "ja": "彩度", "zh-Hans": "饱和度", "zh-Hant": "飽和度", "es": "Saturación"],
  "Brightness": ["ko": "밝기", "ja": "明るさ", "zh-Hans": "亮度", "zh-Hant": "亮度", "es": "Brillo"],
  "Preview": ["ko": "미리보기", "ja": "プレビュー", "zh-Hans": "预览", "zh-Hant": "預覽", "es": "Vista previa"],
  "Done": ["ko": "완료", "ja": "完了", "zh-Hans": "完成", "zh-Hant": "完成", "es": "Listo"],
  "Default — follows light and dark": [
    "ko": "기본 — 다크/라이트에 맞춰 자동", "ja": "デフォルト — ライト/ダークに追従",
    "zh-Hans": "默认 — 跟随浅色/深色", "zh-Hant": "預設 — 跟隨淺色/深色",
    "es": "Predeterminado — sigue claro y oscuro",
  ],
  "Wide face": [
    "ko": "넓적 얼굴 (볼터치)", "ja": "丸顔 (ほっぺ)", "zh-Hans": "圆脸（腮红）",
    "zh-Hant": "圓臉（腮紅）", "es": "Cara ancha",
  ],
  "Slim face": [
    "ko": "갸름 얼굴", "ja": "細顔", "zh-Hans": "瘦脸", "zh-Hant": "瘦臉", "es": "Cara fina",
  ],
  "Slime": ["ko": "슬라임", "ja": "スライム", "zh-Hans": "史莱姆", "zh-Hant": "史萊姆", "es": "Slime"],
  "Off": ["ko": "끄기", "ja": "オフ", "zh-Hans": "关闭", "zh-Hant": "關閉", "es": "Desactivado"],
  "Battery size": [
    "ko": "배터리 크기", "ja": "バッテリーサイズ", "zh-Hans": "电池大小", "zh-Hant": "電池大小",
    "es": "Tamaño de batería",
  ],
  "Battery size and Cat apply to pixel batteries only.": [
    "ko": "배터리 크기와 고양이는 픽셀 배터리에서만 적용됩니다.",
    "ja": "バッテリーサイズと猫はピクセルバッテリーのみに適用されます。",
    "zh-Hans": "电池大小和猫仅适用于像素电池。",
    "zh-Hant": "電池大小與貓僅適用於像素電池。",
    "es": "El tamaño de la batería y el gato solo se aplican a las baterías pixel.",
  ],
  "Display style": [
    "ko": "표시 방식", "ja": "表示形式", "zh-Hans": "显示样式", "zh-Hant": "顯示樣式",
    "es": "Estilo de pantalla",
  ],
  "Pixel batteries": [
    "ko": "픽셀 배터리", "ja": "ピクセルバッテリー", "zh-Hans": "像素电池", "zh-Hant": "像素電池",
    "es": "Baterías pixel",
  ],
  "Modern batteries": [
    "ko": "일반 배터리 UI", "ja": "標準バッテリーUI", "zh-Hans": "标准电池界面", "zh-Hant": "標準電池介面",
    "es": "Baterías modernas",
  ],
  "Menu bar items": ["ko": "메뉴 막대 표시 항목", "ja": "メニューバー項目", "zh-Hans": "菜单栏项目", "zh-Hant": "選單列項目", "es": "Elementos de la barra"],
  "Modern batteries show the tightest of the selected limits; pixel batteries show one per limit. Claude Fable is off by default.": [
    "ko": "일반 배터리는 선택한 한도 중 가장 빠듯한 값을 보여주고, 픽셀 배터리는 한도마다 하나씩 그립니다. Claude Fable은 기본으로 꺼져 있습니다.",
    "ja": "標準バッテリーは選択した上限のうち最も厳しい値を表示し、ピクセルバッテリーは上限ごとに1つ表示します。Claude Fableは既定でオフです。",
    "zh-Hans": "标准电池显示所选限额中最紧张的一项；像素电池为每个限额各显示一个。Claude Fable 默认关闭。",
    "zh-Hant": "標準電池顯示所選額度中最吃緊的一項；像素電池為每個額度各顯示一個。Claude Fable 預設關閉。",
    "es": "Las baterías modernas muestran el límite más ajustado de los seleccionados; las pixel muestran uno por límite. Claude Fable está desactivado por defecto.",
  ],
  "Claude 5h": ["ko": "Claude 5시간", "ja": "Claude 5時間", "zh-Hans": "Claude 5 小时", "zh-Hant": "Claude 5 小時", "es": "Claude 5 h"],
  "Claude week": ["ko": "Claude 주간", "ja": "Claude 週間", "zh-Hans": "Claude 每周", "zh-Hant": "Claude 每週", "es": "Claude semanal"],
  "Claude Fable": ["ko": "Claude Fable", "ja": "Claude Fable", "zh-Hans": "Claude Fable", "zh-Hant": "Claude Fable", "es": "Claude Fable"],
  "Codex 5h": ["ko": "Codex 5시간", "ja": "Codex 5時間", "zh-Hans": "Codex 5 小时", "zh-Hant": "Codex 5 小時", "es": "Codex 5 h"],
  "Codex week": ["ko": "Codex 주간", "ja": "Codex 週間", "zh-Hans": "Codex 每周", "zh-Hant": "Codex 每週", "es": "Codex semanal"],
  "Big": ["ko": "크게", "ja": "大", "zh-Hans": "大", "zh-Hant": "大", "es": "Grande"],
  "Small": ["ko": "작게", "ja": "小", "zh-Hans": "小", "zh-Hant": "小", "es": "Pequeño"],
  "Language": ["ko": "언어", "ja": "言語", "zh-Hans": "语言", "zh-Hant": "語言", "es": "Idioma"],
  "System default": [
    "ko": "시스템 기본", "ja": "システム標準", "zh-Hans": "跟随系统", "zh-Hant": "跟隨系統",
    "es": "Predeterminado del sistema",
  ],
  "Start at login": [
    "ko": "로그인 시 자동 시작", "ja": "ログイン時に起動", "zh-Hans": "登录时启动",
    "zh-Hant": "登入時啟動", "es": "Iniciar al abrir sesión",
  ],
  "Open ccusage dashboard": [
    "ko": "ccusage 대시보드 열기", "ja": "ccusageダッシュボードを開く", "zh-Hans": "打开 ccusage 面板",
    "zh-Hant": "開啟 ccusage 面板", "es": "Abrir panel de ccusage",
  ],
  "Open GitHub page": [
    "ko": "GitHub 페이지 열기", "ja": "GitHubページを開く", "zh-Hans": "打开 GitHub 页面",
    "zh-Hant": "開啟 GitHub 頁面", "es": "Abrir página de GitHub",
  ],
  "Open Claude usage": ["ko": "Claude 사용량 페이지 열기", "ja": "Claude使用量を開く", "zh-Hans": "打开 Claude 使用量", "zh-Hant": "開啟 Claude 用量", "es": "Abrir uso de Claude"],
  "Open Codex usage": ["ko": "Codex 사용량 페이지 열기", "ja": "Codex使用量を開く", "zh-Hans": "打开 Codex 使用量", "zh-Hant": "開啟 Codex 用量", "es": "Abrir uso de Codex"],
  "Open Claude app": ["ko": "Claude 앱 열기", "ja": "Claudeアプリを開く", "zh-Hans": "打开 Claude 应用", "zh-Hant": "開啟 Claude App", "es": "Abrir app de Claude"],
  "Open Codex app": ["ko": "Codex 앱 열기", "ja": "Codexアプリを開く", "zh-Hans": "打开 Codex 应用", "zh-Hant": "開啟 Codex App", "es": "Abrir app de Codex"],
  "Quit": ["ko": "종료", "ja": "終了", "zh-Hans": "退出", "zh-Hant": "結束", "es": "Salir"],
  "⬇︎ Updating…": [
    "ko": "⬇︎ 업데이트…", "ja": "⬇︎ 更新中…", "zh-Hans": "⬇︎ 更新中…", "zh-Hant": "⬇︎ 更新中…",
    "es": "⬇︎ Actualizando…",
  ],
  "Start automatically at login?": [
    "ko": "로그인 시 자동으로 시작할까요?", "ja": "ログイン時に自動で起動しますか？",
    "zh-Hans": "要在登录时自动启动吗？", "zh-Hant": "要在登入時自動啟動嗎？",
    "es": "¿Iniciar automáticamente al abrir sesión?",
  ],
  "The usage battery will appear in your menu bar every time you start your Mac. You can change this anytime from the menu.": [
    "ko": "맥을 켤 때마다 메뉴바에 사용량 배터리가 자동으로 표시됩니다. 나중에 메뉴에서 언제든 바꿀 수 있습니다.",
    "ja": "Macを起動するたびに使用量バッテリーがメニューバーに表示されます。メニューからいつでも変更できます。",
    "zh-Hans": "每次启动 Mac 时，用量电池都会显示在菜单栏中。之后可随时在菜单中更改。",
    "zh-Hant": "每次啟動 Mac 時，用量電池都會顯示在選單列中。之後可隨時在選單中更改。",
    "es": "La batería de consumo aparecerá en la barra de menús cada vez que inicies tu Mac. Puedes cambiarlo en el menú cuando quieras.",
  ],
  "Start at Login": [
    "ko": "자동 시작", "ja": "起動する", "zh-Hans": "自动启动", "zh-Hant": "自動啟動",
    "es": "Iniciar al abrir sesión",
  ],
  "Later": ["ko": "나중에", "ja": "後で", "zh-Hans": "以后再说", "zh-Hant": "以後再說", "es": "Más tarde"],
  "downloading…": [
    "ko": "다운로드 중…", "ja": "ダウンロード中…", "zh-Hans": "下载中…", "zh-Hant": "下載中…",
    "es": "descargando…",
  ],
  "unzipping…": [
    "ko": "압축 해제 중…", "ja": "展開中…", "zh-Hans": "解压中…", "zh-Hant": "解壓縮中…",
    "es": "descomprimiendo…",
  ],
  "verifying signature…": [
    "ko": "서명 검증 중…", "ja": "署名を検証中…", "zh-Hans": "验证签名中…", "zh-Hant": "驗證簽章中…",
    "es": "verificando firma…",
  ],
  "installing…": [
    "ko": "설치 중…", "ja": "インストール中…", "zh-Hans": "安装中…", "zh-Hant": "安裝中…",
    "es": "instalando…",
  ],
  "download failed": [
    "ko": "다운로드 실패", "ja": "ダウンロード失敗", "zh-Hans": "下载失败", "zh-Hant": "下載失敗",
    "es": "descarga fallida",
  ],
  "unzip failed": [
    "ko": "압축 해제 실패", "ja": "展開失敗", "zh-Hans": "解压失败", "zh-Hant": "解壓縮失敗",
    "es": "descompresión fallida",
  ],
  "signature verification failed": [
    "ko": "서명 검증 실패", "ja": "署名検証失敗", "zh-Hans": "签名验证失败", "zh-Hant": "簽章驗證失敗",
    "es": "verificación de firma fallida",
  ],
  "install failed": [
    "ko": "설치 실패", "ja": "インストール失敗", "zh-Hans": "安装失败", "zh-Hant": "安裝失敗",
    "es": "instalación fallida",
  ],
]

func tr(_ en: String, language: String = UI_LANG) -> String {
  if language == "en" { return en }
  return TR[en]?[language] ?? en
}

func trf(_ en: String, _ args: CVarArg...) -> String {
  String(format: tr(en), arguments: args)
}

func trf(_ en: String, language: String, _ args: CVarArg...) -> String {
  String(format: tr(en, language: language), arguments: args)
}

// Gauge labels padded per language so the Menlo bars line up
func gaugeLabels(language: String = UI_LANG) -> (five: String, week: String) {
  switch language {
  case "ko": return ("5시간", "주간 ")
  case "ja": return ("5時間", "週間 ")
  case "zh-Hans": return ("5小时", "每周 ")
  case "zh-Hant": return ("5小時", "每週 ")
  case "es": return ("5h   ", "sem. ")
  default: return ("5h   ", "week ")
  }
}

// Display names for the Language submenu (each in its own language)
let LANG_DISPLAY: [(code: String, name: String)] = [
  ("en", "English"), ("ko", "한국어"), ("ja", "日本語"),
  ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("es", "Español"),
]
