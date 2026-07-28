// The logged-in account name — reads the email local part for the dropdown headers from the
// local login files. Neither the usage API nor the keychain carries the account email (see the
// design doc for the survey), so the files Claude Code / Codex CLI leave behind are the only
// source. Makes no network calls.
import Foundation

// Keeps a long corporate account (firstname.lastname.platform) from pushing the header out and
// widening the whole menu.
let ACCOUNT_NAME_MAX = 20

// "user@host" → "user". A value without an @ is treated as a username-style login and used whole.
func emailLocalPart(_ email: String?) -> String? {
  guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
  let local = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
  return local.isEmpty ? nil : String(local)
}

// Pulls just the email out of an id_token payload. The signature is not verified — this is our own
// local login file that we read moments ago, and there is no public key to verify against. The
// value is a display string, nothing more.
func jwtEmail(_ idToken: String?) -> String? {
  guard let token = idToken else { return nil }
  let parts = token.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 3 else { return nil }
  // base64url → base64: swap the two substituted characters, then pad to a multiple of four.
  var b64 = String(parts[1])
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while b64.count % 4 != 0 { b64 += "=" }
  guard let data = Data(base64Encoded: b64),
        let obj = jd(try? JSONSerialization.jsonObject(with: data)) else { return nil }
  return jstr(obj["email"])
}

// Characters, not bytes — so Hangul and emoji don't break mid-scalar.
func truncateAccount(_ name: String) -> String {
  name.count <= ACCOUNT_NAME_MAX ? name : String(name.prefix(ACCOUNT_NAME_MAX)) + "…"
}

struct AccountNames {
  let claude: String?
  let codex: String?
  static let none = AccountNames(claude: nil, codex: nil)
}

// ~/.claude.json measures 239 KB in practice and is read on every refresh. Unchanged
// (mtime, size) means no reparse. Entries are keyed by path so one file's result can't leak
// into another's. Refreshes run on a background queue while the menu is assembled on the main
// thread, hence the lock. The cache lives in process memory only — no reason to copy an account
// name into a new file on disk.
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

// access_token / refresh_token are never read — only the id_token payload.
func codexAccountName(path: String = "\(HOME)/.codex/auth.json") -> String? {
  accountCache.lookup(path) { emailLocalPart(jwtEmail(jstr(jd(jd($0)?["tokens"])?["id_token"]))) }
}

func accountNames() -> AccountNames {
  AccountNames(claude: claudeAccountName().map(truncateAccount),
               codex: codexAccountName().map(truncateAccount))
}

// On by default. A setting with a non-false default can't be read through bool(forKey:) — a
// missing key would come back false and flip the default. Takes the stored value as an argument
// so it can be tested without touching UserDefaults.
func accountNameVisible(_ stored: Any? = UserDefaults.standard.object(forKey: "showAccountName")) -> Bool {
  (stored as? Bool) ?? true
}
