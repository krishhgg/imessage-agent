import CryptoKit
import Foundation
import IMCore
import IMStore
import Security

/// One allowed chat (DESIGN.md section 2, Allowed chats). Added only by approving the native dialog.
public struct AllowlistEntry: Hashable, Codable, Sendable {
    public var chat: CanonicalChatID
    /// Label at the time of approval, for `status` and dialogs.
    public var label: String
    public var scope: AllowScope
    public var addedAt: Date

    public init(chat: CanonicalChatID, label: String, scope: AllowScope, addedAt: Date) {
        self.chat = chat
        self.label = label
        self.scope = scope
        self.addedAt = addedAt
    }
}

/// Everything in the tamper-checked store: the allowlist and the foreground-mode setting (section 2, Storage).
public struct PolicyState: Hashable, Codable, Sendable {
    public var version: Int
    public var entries: [AllowlistEntry]
    /// Foreground mode, off by default (section 4). Only `allow --foreground` through the dialog turns it on.
    public var foregroundMode: Bool
    /// Why foreground mode last turned itself off, for `doctor` (section 4).
    public var foregroundOffReason: String?

    public init(version: Int = 1, entries: [AllowlistEntry] = [], foregroundMode: Bool = false,
                foregroundOffReason: String? = nil) {
        self.version = version
        self.entries = entries
        self.foregroundMode = foregroundMode
        self.foregroundOffReason = foregroundOffReason
    }

    public static let empty = PolicyState()
}

/// Why the store isn't trusted. Any of these means nothing is allowed until the user re-approves chats.
public enum TamperReason: String, Hashable, Codable, Sendable {
    case fileChangedOutsideBridge
    case fileMissing
    case fileUnreadable
    case hashMissing
    case hashUnreadable
}

public enum PolicyLoad: Hashable, Sendable {
    case trusted(PolicyState)
    /// Treated as `PolicyState.empty` with foreground mode off.
    case untrusted(TamperReason)
}

/// Keychain item holding the SHA-256 of the store file. Its access list names only the bridge's designated
/// requirement (section 2, Storage). Live: `LiveKeychainHashStore`. Tests: an in-memory fake.
public protocol KeychainHashStoring: AnyObject {
    /// The stored hash, or nil if there is no item. Throws if the item exists but can't be read.
    func readHash() throws -> Data?
    func writeHash(_ hash: Data) throws
    func deleteHash() throws
}

/// A Security framework call on the hash item failed.
public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public var operation: String
    public var status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain \(operation): \(message)"
    }
}

/// Generic-password item `AppIdentity.keychainService` / `AppIdentity.keychainAccount`. Owner: IMPolicy.
///
/// The item lives in the file-based login keychain. The data protection keychain needs an application-identifier
/// entitlement, which a self-signed build can't carry. `writeHash` deletes any existing item and adds a new one whose
/// access list names only the bridge's designated requirement. Any program running as the user can change, delete
/// or plant the item with no dialog. An item another program changed or planted reads `errSecAuthFailed` for the
/// bridge, so the store reads `.hashUnreadable` and allows nothing until the user approves again. Deleting the item
/// while the store file exists gives `.hashMissing`. research/live-tests/2026-11-06.md has the measurements. That
/// fits tamper detection, not tamper proofing (section 2).
///
/// `readHash` turns Keychain dialogs off while it runs. A locked keychain, or an access list that no longer matches
/// the bridge, then fails the read with `errSecInteractionNotAllowed` and the store reads `.hashUnreadable`, instead
/// of a dialog blocking the store lock and the bridge before it serves. `writeHash` and `deleteHash` keep dialogs on,
/// because they run right after the user approves a change.
///
/// Tests never reach the Keychain. They inject an in-memory `KeychainHashStoring`, or give this class a fake read
/// and a fake interaction switch.
public final class LiveKeychainHashStore: KeychainHashStoring {
    public let service: String
    public let account: String
    private let access: ItemAccessMaking = BridgeOnlyAccess()
    private let interaction: KeychainInteractionSwitching
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    public convenience init(service: String = AppIdentity.keychainService,
                            account: String = AppIdentity.keychainAccount) {
        self.init(service: service, account: account, interaction: LegacyKeychainInteraction(),
                  copyMatching: SecItemCopyMatching)
    }

    init(service: String, account: String, interaction: KeychainInteractionSwitching,
         copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) {
        self.service = service
        self.account = account
        self.interaction = interaction
        self.copyMatching = copyMatching
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    public func readHash() throws -> Data? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = interaction.withoutDialogs { copyMatching(query as CFDictionary, &out) }
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { throw KeychainError(operation: "read", status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(operation: "read", status: status)
        }
    }

    public func writeHash(_ hash: Data) throws {
        try deleteHash()
        var query = itemQuery
        query[kSecValueData as String] = hash
        query[kSecAttrLabel as String] = "\(AppIdentity.appName) allowed chats"
        query[kSecAttrAccess as String] = try access.makeAccess(label: "\(AppIdentity.appName) allowed chats")
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(operation: "add", status: status) }
    }

    public func deleteHash() throws {
        // A search list can hold more than one matching item. Delete until none is left.
        for _ in 0..<8 {
            let status = SecItemDelete(itemQuery as CFDictionary)
            switch status {
            case errSecSuccess: continue
            case errSecItemNotFound: return
            default: throw KeychainError(operation: "delete", status: status)
            }
        }
        throw KeychainError(operation: "delete", status: errSecDuplicateItem)
    }
}

/// Builds the access list for a new hash item.
private protocol ItemAccessMaking {
    func makeAccess(label: String) throws -> SecAccess
}

/// An access list whose only trusted application is the calling process, recorded by its designated requirement
/// (bundle id plus certificate root, section 1). The login keychain also gives the item a partition list. A build
/// with no Team ID, like this self-signed one, gets the creating build's code hash there, so only that build can read
/// the item. After each update the store reads `.hashUnreadable`, so the allowlist stays untrusted until the user
/// approves again. Always allow then deletes the old item and adds a new one with no Keychain prompt.
private struct BridgeOnlyAccess: ItemAccessMaking {
    // SecAccess and SecTrustedApplication were deprecated with SecKeychain in macOS 10.10, but nothing replaces them
    // for items in the file-based keychain. The deprecation marker keeps the warning inside this one method.
    @available(macOS, deprecated: 10.10)
    func makeAccess(label: String) throws -> SecAccess {
        var app: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &app)
        guard status == errSecSuccess, let app else { throw KeychainError(operation: "trusted app", status: status) }
        var access: SecAccess?
        status = SecAccessCreate(label as CFString, [app] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw KeychainError(operation: "access", status: status) }
        return access
    }
}

/// The process-wide setting that lets Keychain calls show dialogs. Changing it is safe here because only
/// `PolicyStore` touches the Keychain, and it holds its lock for every call, so no other Keychain call runs while
/// `withoutDialogs` has the setting off.
protocol KeychainInteractionSwitching {
    var isInteractionAllowed: Bool { get }
    func setInteractionAllowed(_ allowed: Bool)
}

extension KeychainInteractionSwitching {
    /// Runs `body` with Keychain dialogs off, then puts back the setting it found.
    func withoutDialogs<T>(_ body: () throws -> T) rethrows -> T {
        let saved = isInteractionAllowed
        setInteractionAllowed(false)
        defer { setInteractionAllowed(saved) }
        return try body()
    }
}

/// `SecKeychainSetUserInteractionAllowed`. `kSecUseAuthenticationUI` applies only to data protection keychain items,
/// so for the file-based login keychain this is the only switch that stops a dialog.
private struct LegacyKeychainInteraction: KeychainInteractionSwitching {
    // Deprecated with SecKeychain in macOS 10.10 and not replaced for the file-based keychain. The markers keep the
    // warnings inside these two members, as in `BridgeOnlyAccess`.
    @available(macOS, deprecated: 10.10)
    var isInteractionAllowed: Bool {
        var allowed: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else { return true }
        return allowed.boolValue
    }

    @available(macOS, deprecated: 10.10)
    func setInteractionAllowed(_ allowed: Bool) {
        _ = SecKeychainSetUserInteractionAllowed(allowed)
    }
}

/// Lets IMForeground and IMBridge read and turn off foreground mode without the whole store.
public protocol ForegroundModeSwitching: AnyObject {
    var isForegroundModeOn: Bool { get }
    /// Turns foreground mode off and records why. Only the dialog turns it back on (section 4).
    func turnForegroundOff(reason: String)
}

/// The 0600 policy file plus its Keychain hash. Tamper detection, not tamper proofing (section 2). Owner: IMPolicy.
///
/// - `load` compares SHA-256 of the file bytes with the Keychain hash. Mismatch, missing or unreadable file or hash
///   gives `.untrusted`, and the bridge then behaves as if the allowlist were empty and foreground mode off.
/// - `save` writes the file atomically with mode 0600, flushes it, then replaces the hash.
/// - A first run with neither file nor hash is `.trusted(.empty)`.
/// - Every read checks the file and the hash again, so a change made while the bridge runs takes effect at once.
/// - A change from an untrusted state starts from `.empty`: re-approving a chat discards the old entries. Only a
///   user-approved change saves; `turnForegroundOff` never re-trusts an untrusted store.
/// - The file is refused when it is a symlink, isn't a regular file, isn't mode 0600 or isn't owned by this user.
///   The bridge never writes one like that, so each counts as `.fileChangedOutsideBridge`.
///
/// Thread safe. One lock covers every load and save, so a reader never sees a file and a hash from different saves.
public final class PolicyStore: ForegroundModeSwitching {
    public let fileURL: URL
    public let keychain: KeychainHashStoring

    /// The only `PolicyState.version` this build reads.
    public static let currentVersion = 1
    /// The store holds a few hundred entries at most. Anything larger is refused unread.
    static let maxFileBytes = 4 * 1024 * 1024

    private let lock = NSLock()
    /// Set by `turnForegroundOff`. Keeps foreground mode off in memory even if the save failed or the store is
    /// untrusted. Cleared by the next successful save.
    private var forcedOffReason: String?

    public init(fileURL: URL, keychain: KeychainHashStoring) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    public func load() -> PolicyLoad {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func save(_ state: PolicyState) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveLocked(state)
    }

    /// Current effective state: the trusted state, or `.empty` when untrusted. Foreground mode reads off after
    /// `turnForegroundOff` even if that save failed.
    public var effective: PolicyState { snapshot().state }

    public func entry(for chat: CanonicalChatID) -> AllowlistEntry? {
        effective.entries.first { $0.chat == chat }
    }

    /// Adds or widens an entry after an "Always allow this chat" or `allow` approval. It never narrows a scope.
    public func allow(_ chat: CanonicalChatID, label: String, scope: AllowScope) throws {
        try mutate { state in
            if let i = state.entries.firstIndex(where: { $0.chat == chat }) {
                state.entries[i].label = label
                state.entries[i].scope = max(state.entries[i].scope, scope)
            } else {
                state.entries.append(AllowlistEntry(chat: chat, label: label, scope: scope, addedAt: Date()))
            }
        }
    }

    public func revoke(_ chat: CanonicalChatID) throws {
        try mutate { state in state.entries.removeAll { $0.chat == chat } }
    }

    /// `allow --foreground` or `revoke --foreground`, after the dialog.
    public func setForegroundMode(_ on: Bool) throws {
        try mutate { state in
            state.foregroundMode = on
            state.foregroundOffReason = nil
        }
    }

    public var isForegroundModeOn: Bool { snapshot().foregroundOn }

    public func turnForegroundOff(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        forcedOffReason = reason
        guard case .trusted(var state) = loadLocked() else { return }
        state.foregroundMode = false
        state.foregroundOffReason = reason
        // On failure `forcedOffReason` stays set, so the mode still reads off.
        try? saveLocked(state)
    }

    // MARK: - Internals

    struct Snapshot {
        var load: PolicyLoad
        /// What the policy acts on: the trusted state, or `.empty` when untrusted.
        var state: PolicyState
        var foregroundOn: Bool
    }

    /// One consistent read of the file and the hash, for `PolicyEngine`.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let load = loadLocked()
        let state = baseStateLocked(load)
        return Snapshot(load: load, state: state, foregroundOn: state.foregroundMode)
    }

    private func baseStateLocked(_ load: PolicyLoad) -> PolicyState {
        var state: PolicyState
        switch load {
        case .trusted(let s): state = s
        case .untrusted: state = .empty
        }
        if let reason = forcedOffReason {
            state.foregroundMode = false
            state.foregroundOffReason = reason
        }
        return state
    }

    private func mutate(_ change: (inout PolicyState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = baseStateLocked(loadLocked())
        change(&state)
        state.version = PolicyStore.currentVersion
        try saveLocked(state)
    }

    private func loadLocked() -> PolicyLoad {
        let file = DurableFile.read(fileURL, maxBytes: PolicyStore.maxFileBytes, requireOwnerOnlyMode: true)
        let data: Data
        switch file {
        case .foreign: return .untrusted(.fileChangedOutsideBridge)
        case .unreadable: return .untrusted(.fileUnreadable)
        case .missing:
            do {
                return try keychain.readHash() == nil ? .trusted(.empty) : .untrusted(.fileMissing)
            } catch {
                return .untrusted(.hashUnreadable)
            }
        case .data(let d): data = d
        }
        let stored: Data?
        do {
            stored = try keychain.readHash()
        } catch {
            return .untrusted(.hashUnreadable)
        }
        guard let stored else { return .untrusted(.hashMissing) }
        guard stored.count == 32 else { return .untrusted(.hashUnreadable) }
        guard Data(SHA256.hash(data: data)) == stored else { return .untrusted(.fileChangedOutsideBridge) }
        guard let state = try? JSONDecoder.wire.decode(PolicyState.self, from: data),
              state.version == PolicyStore.currentVersion else {
            return .untrusted(.fileUnreadable)
        }
        return .trusted(state)
    }

    private func saveLocked(_ state: PolicyState) throws {
        var sorted = state
        sorted.entries.sort { $0.chat.rawValue < $1.chat.rawValue }
        let encoder = JSONEncoder.wire
        encoder.outputFormatting.insert(.prettyPrinted)
        let data = try encoder.encode(sorted)
        // The file first, then the hash. A crash between the two leaves a mismatch, which reads as untrusted.
        try DurableFile.replace(fileURL, with: data)
        try keychain.writeHash(Data(SHA256.hash(data: data)))
        forcedOffReason = nil
    }
}
