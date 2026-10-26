// Creates the Ed25519 key pair that signs Aether updates. Run it once:
//
//   /usr/bin/swift scripts/make-update-key.swift
//
// The private key is written to a file only you can read. It never goes into the repo.
// The public key goes into Info.plist, so every Aether built afterwards refuses unsigned updates.
import CryptoKit
import Foundation

let defaultPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".aether-update-key").path
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath

if FileManager.default.fileExists(atPath: path) {
    fputs("""
    \(path) already exists. Aether only trusts the key it was built with, so a new key
    would make every installed copy reject updates. Move that file away first if you really mean it.

    """, stderr)
    exit(1)
}

let key = Curve25519.Signing.PrivateKey()
let secret = key.rawRepresentation.base64EncodedString()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

guard FileManager.default.createFile(
    atPath: path,
    contents: Data((secret + "\n").utf8),
    attributes: [.posixPermissions: 0o600]
) else {
    fputs("Couldn't write \(path)\n", stderr)
    exit(1)
}

print("""
Wrote the private key to \(path) (readable only by you). Keep a backup somewhere safe.

1. Give it to GitHub Actions as a secret:

     gh secret set AETHER_UPDATE_KEY --repo ganya002/Aether < \(path)

2. Embed the public key in the app:

     /usr/libexec/PlistBuddy -c "Set :AetherUpdatePublicKey \(publicKey)" Info.plist

3. Commit Info.plist and push to main.

The first release built with the key is still installed through checksum-only checks
by older copies. Every copy built from then on requires a valid signature.
""")
