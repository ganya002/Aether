import Foundation
import Security

/// Length-prefixed JSON frames used by the raw TCP transport: a 4 byte big-endian length, then the body.
struct FrameDecoder {
    /// Matches the server, which refuses anything larger.
    static let maxLength = 2 << 20

    enum Failure: Error, Equatable {
        case invalidLength(Int)
    }

    private(set) var buffer = Data()

    mutating func reset() {
        buffer = Data()
    }

    /// Adds bytes from the socket and returns every complete body. A bad length throws and clears the buffer,
    /// because nothing after it can be trusted.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        var cursor = buffer.startIndex
        while buffer.endIndex - cursor >= 4 {
            let length = buffer[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maxLength else {
                buffer = Data()
                throw Failure.invalidLength(length)
            }
            let start = cursor + 4
            guard buffer.endIndex - start >= length else { break }
            bodies.append(Data(buffer[start..<(start + length)]))
            cursor = start + length
        }
        buffer = Data(buffer[cursor...])
        return bodies
    }

    static func frame(_ body: Data) -> Data {
        var frame = Data(capacity: 4 + body.count)
        let n = UInt32(body.count)
        frame.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        frame.append(body)
        return frame
    }
}

enum SecretRead: Equatable {
    case found(String)
    case missing
    /// The keychain is locked or can't ask right now. Worth trying again later.
    case locked
    /// Access was refused, usually because the person clicked Deny.
    case failed
}

protocol SecretStore {
    func read(_ account: String) -> SecretRead
    func write(_ value: String, account: String) -> Bool
    func delete(_ account: String) -> Bool
}

/// Generic passwords in the login keychain. The service is the bundle id, so Aether Dev keeps its own.
struct KeychainStore: SecretStore {
    var service: String

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(_ account: String) -> SecretRead {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        if status == errSecInteractionNotAllowed { return .locked }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            return .failed
        }
        return .found(text)
    }

    func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Aether Cloud"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Keeps the Cloud token out of config.json and session.json. If the keychain will not take it,
/// the token stays in the file rather than being lost.
@MainActor
final class TokenVault {
    static let shared = TokenVault(store: KeychainStore(service: Bundle.main.bundleIdentifier ?? "Aether"))

    static let account = "sessionToken"
    static let backupAccount = "sessionToken.previous"

    private let store: SecretStore
    /// The token the store is known to hold. Nil until it has been read or written.
    private var secured: String?
    private(set) var unreadable = false
    /// The read failed only because the keychain was locked. `retry()` may still get the token.
    private(set) var locked = false

    init(store: SecretStore) {
        self.store = store
    }

    /// Called once at launch with whatever token the JSON files still carried.
    func adopt(fileToken: String) -> String {
        let fileToken = fileToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileToken.isEmpty {
            if store.write(fileToken, account: Self.account) {
                secured = fileToken
            }
            return fileToken
        }
        switch store.read(Self.account) {
        case .found(let token):
            secured = token
            return token
        case .missing:
            secured = ""
            return ""
        case .locked:
            unreadable = true
            locked = true
            return ""
        case .failed:
            unreadable = true
            return ""
        }
    }

    /// Reads the token again after a locked keychain. Nil while it still can't be read.
    func retry() -> String? {
        guard unreadable, locked else { return nil }
        switch store.read(Self.account) {
        case .found(let token):
            secured = token
            unreadable = false
            locked = false
            return token
        case .missing:
            secured = ""
            unreadable = false
            locked = false
            return ""
        case .locked:
            return nil
        case .failed:
            locked = false
            return nil
        }
    }

    /// What Settings shows when the token couldn't be read, or nil when it could.
    var problem: String? {
        guard unreadable else { return nil }
        return locked
            ? "Waiting for the keychain to unlock to sign in to Cloud."
            : "Aether couldn't read your Cloud sign-in from the keychain, so Cloud is off. Allow access when macOS asks, or quit and reopen Aether to be asked again."
    }

    /// The token to write into JSON. Empty whenever the keychain holds it.
    func diskToken(for token: String) -> String {
        if token == secured { return "" }
        if token.isEmpty {
            // Never delete an item we could not read; the person may simply have denied access this time.
            guard !unreadable else { return "" }
            _ = store.delete(Self.account)
            secured = ""
            return ""
        }
        if store.write(token, account: Self.account) {
            secured = token
            unreadable = false
            return ""
        }
        return token
    }

    /// Keeps the token that is about to be replaced, so a mistaken new account is not the end of the old one.
    @discardableResult
    func backup(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return store.write(token, account: Self.backupAccount)
    }

    func previousToken() -> String? {
        if case .found(let token) = store.read(Self.backupAccount), !token.isEmpty { return token }
        return nil
    }
}

extension Settings {
    /// What goes into config.json and session.json.
    @MainActor
    func forDisk(_ vault: TokenVault = .shared) -> Settings {
        var copy = self
        copy.sessionToken = vault.diskToken(for: sessionToken)
        return copy
    }

    var hasCloudAccount: Bool {
        !sessionToken.isEmpty && (!sessionHost.isEmpty || !sessionWS.isEmpty)
    }

    var usesCloud: Bool {
        cloudEnabled && hasCloudAccount
    }
}

extension AppModel {
    /// A token the keychain wouldn't hand over is never treated as "no account". Settings says why
    /// Cloud is off, and a locked keychain is asked again every minute for a while.
    func noteKeychainProblem(attempt: Int = 0) {
        let vault = TokenVault.shared
        guard let problem = vault.problem else { return }
        if attempt == 0 {
            NSLog("Aether: %@", problem)
        }
        SessionHub.shared.setLink(.unavailable(problem))
        guard vault.locked, attempt < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, vault.unreadable else { return }
            if let token = vault.retry() {
                if self.settings.sessionToken.isEmpty {
                    self.updateSettings { $0.sessionToken = token }
                }
                SessionHub.shared.setLink(.idle)
                return
            }
            self.noteKeychainProblem(attempt: attempt + 1)
        }
    }
}
