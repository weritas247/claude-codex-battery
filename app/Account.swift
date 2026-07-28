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
