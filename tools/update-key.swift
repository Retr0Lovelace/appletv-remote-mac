// Release-signing key management for the self-updater (Ed25519, like Sparkle's EdDSA).
// The private key lives only in the login Keychain (generic password, service/account below).
//
//   update-key generate [--force]   create the key, print the base64 public key
//   update-key public               print the base64 public key
//   update-key sign <file>          print the base64 Ed25519 signature of the file's bytes
import Foundation
import CryptoKit
import Security

let service = "com.retr0.appletvremote.update-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func baseQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    var q = baseQuery()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = out as? Data else {
        fail("Keychain read failed (OSStatus \(status))")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("the Keychain item is not a valid Ed25519 private key")
    }
    return key
}

func storeKey(_ key: Curve25519.Signing.PrivateKey, replace: Bool) {
    if replace { SecItemDelete(baseQuery() as CFDictionary) }
    var q = baseQuery()
    q[kSecValueData as String] = key.rawRepresentation
    q[kSecAttrLabel as String] = "Apple TV Remote update signing key (Ed25519)"
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let status = SecItemAdd(q as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Keychain write failed (OSStatus \(status))") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    let force = args.contains("--force")
    if loadKey() != nil && !force {
        fail("a signing key already exists; refusing to overwrite it (use --force to replace it, which breaks updates for installed apps)")
    }
    let key = Curve25519.Signing.PrivateKey()
    storeKey(key, replace: force)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = loadKey() else { fail("no signing key in the Keychain; run: update-key generate") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: update-key sign <file>") }
    guard let key = loadKey() else { fail("no signing key in the Keychain; run: update-key generate") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { fail("cannot read \(args[1])") }
    guard let sig = try? key.signature(for: data) else { fail("signing failed") }
    print(sig.base64EncodedString())
default:
    fail("usage: update-key generate [--force] | public | sign <file>")
}
