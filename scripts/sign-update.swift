// Signs a release zip with the key in AETHER_UPDATE_KEY and writes <zip>.sig (base64 Ed25519).
//
//   AETHER_UPDATE_KEY=... /usr/bin/swift scripts/sign-update.swift Aether.app.zip dist/Aether.app/Contents/Info.plist
//
// The Info.plist is the one inside the app being published. If it embeds a public key, the
// signature must verify against it, so a wrong or missing secret fails the release instead of
// shipping an update every copy would reject.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("sign-update: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: sign-update.swift <zip> <Info.plist>")
}
let zip = URL(fileURLWithPath: CommandLine.arguments[1])
let plist = URL(fileURLWithPath: CommandLine.arguments[2])

let info = NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
let embedded = (info["AetherUpdatePublicKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
let secret = (ProcessInfo.processInfo.environment["AETHER_UPDATE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

if secret.isEmpty {
    if !embedded.isEmpty {
        fail("Info.plist embeds an update key but the AETHER_UPDATE_KEY secret is missing.")
    }
    print("sign-update: no AETHER_UPDATE_KEY secret, publishing without a signature.")
    exit(0)
}

guard let raw = Data(base64Encoded: secret), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("AETHER_UPDATE_KEY isn't a key made by scripts/make-update-key.swift.")
}
if !embedded.isEmpty, key.publicKey.rawRepresentation.base64EncodedString() != embedded {
    fail("AETHER_UPDATE_KEY doesn't match AetherUpdatePublicKey in Info.plist.")
}
if embedded.isEmpty {
    print("sign-update: Info.plist has no AetherUpdatePublicKey yet. Signing anyway; installed copies check SHA-256 only.")
}

guard let bytes = try? Data(contentsOf: zip, options: .mappedIfSafe) else {
    fail("couldn't read \(zip.path)")
}
let signature: Data
do {
    signature = try key.signature(for: bytes)
} catch {
    fail("couldn't sign: \(error)")
}
guard key.publicKey.isValidSignature(signature, for: bytes) else {
    fail("the new signature didn't verify")
}
let output = zip.appendingPathExtension("sig")
do {
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: output)
} catch {
    fail("couldn't write \(output.path)")
}
print("sign-update: wrote \(output.lastPathComponent)")
