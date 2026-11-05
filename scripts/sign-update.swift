// Signs app updates (Ed25519, CryptoKit). The private key never goes into the repo.
//   swift scripts/sign-update.swift generate      new key in ~/.config/lightscale/update-signing-key; prints the
//                                                 public key for Updater.publicKey
//   swift scripts/sign-update.swift sign FILE     writes FILE.sig (64 raw bytes)
//   swift scripts/sign-update.swift verify FILE   checks FILE.sig against the key
// LIGHTSCALE_SIGNING_KEY overrides the key file's path. Losing the key means the apps already out there won't take
// updates signed with a new one: keep a backup.
import CryptoKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

let args = CommandLine.arguments.dropFirst()
let keyFile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIGHTSCALE_SIGNING_KEY"]
    ?? (NSHomeDirectory() + "/.config/lightscale/update-signing-key"))

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("no signing key at \(keyFile.path)") }
    return key
}

switch args.first {
case "generate":
    guard !FileManager.default.fileExists(atPath: keyFile.path) else { fail("\(keyFile.path) exists; not replacing it") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print("private key: \(keyFile.path)")
    print("public key:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard let path = args.dropFirst().first else { fail("usage: sign FILE") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    try loadKey().signature(for: data).write(to: URL(fileURLWithPath: path + ".sig"))
    print("wrote \(path).sig")
case "verify":
    guard let path = args.dropFirst().first else { fail("usage: verify FILE") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    let sig = try Data(contentsOf: URL(fileURLWithPath: path + ".sig"))
    guard loadKey().publicKey.isValidSignature(sig, for: data) else { fail("BAD signature") }
    print("signature OK")
default:
    fail("usage: sign-update.swift generate | sign FILE | verify FILE")
}
