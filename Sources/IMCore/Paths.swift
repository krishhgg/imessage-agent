import Foundation

/// Every file system location the bridge, the CLI and install.sh agree on. DESIGN.md sections 1, 3 item 7 and 5.
///
/// `home` is injectable so tests never touch the real home folder. The bridge and CLI use the default.
/// install.sh must compute the same socket path with the same rule (see `resolvedSocketPath()`).
public struct Paths: Sendable, Equatable {
    public enum PathError: Error, Equatable {
        /// Neither the primary nor the fallback socket path fits in `sun_path` (section 1: 104 bytes or less).
        case socketPathTooLong(String)
    }

    /// The user's home folder.
    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

    /// `sun_path` size on macOS, including the terminating NUL. Section 1: "an absolute socket path of 104 bytes or less".
    public static let maxSocketPathBytes = 104

    /// True if `path` plus its NUL terminator fits in `sun_path`.
    public static func socketPathFits(_ path: String) -> Bool {
        path.utf8.count + 1 <= maxSocketPathBytes
    }

    /// `~/Library/Application Support/iMessage Agent`, mode 0700. Holds the policy store, journal, uploads and log.
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/\(AppIdentity.appName)", isDirectory: true)
    }

    /// Primary socket path: `<appSupportDir>/bridge.sock`.
    public var primarySocketPath: String { appSupportDir.appendingPathComponent("bridge.sock").path }

    /// Fallback socket path for long home paths: `~/.imessage-agent/bridge.sock`.
    public var fallbackSocketPath: String { home.appendingPathComponent(".imessage-agent/bridge.sock").path }

    /// The socket path launchd listens on (LaunchAgent `Sockets`, mode 0600). Primary if it fits, else the fallback.
    public func resolvedSocketPath() throws -> String {
        if Paths.socketPathFits(primarySocketPath) { return primarySocketPath }
        if Paths.socketPathFits(fallbackSocketPath) { return fallbackSocketPath }
        throw PathError.socketPathTooLong(primarySocketPath)
    }

    /// Allowlist and foreground-mode store, mode 0600 (section 2, Storage).
    public var policyStoreURL: URL { appSupportDir.appendingPathComponent("policy.json") }

    /// Journal folder (section 3 item 2). States are fsynced before each Apple Event, press or Return.
    public var journalDir: URL { appSupportDir.appendingPathComponent("journal", isDirectory: true) }

    /// Frozen upload copies streamed by the CLI, mode 0700 (section 3 item 7).
    public var uploadsDir: URL { appSupportDir.appendingPathComponent("uploads", isDirectory: true) }

    /// Release-test evidence shipped inside the signed bundle, keyed on macOS major.minor (section 4, Capabilities).
    /// The bridge reads it from `Bundle.main` at run time. This path is the installed location, for doctor output.
    public var evidenceURL: URL { appBundle.appendingPathComponent("Contents/Resources/release-evidence.json") }

    /// Bridge stderr log named in the LaunchAgent plist.
    public var logURL: URL { appSupportDir.appendingPathComponent("bridge.log") }

    /// Staging folder inside Messages' sandbox reach: `~/Pictures/iMessage Agent` (section 3 item 7, S2).
    public var stagingDir: URL { home.appendingPathComponent("Pictures/\(AppIdentity.appName)", isDirectory: true) }

    /// `~/Library/Caches/io.github.krishhgg.imessage-agent`, mode 0700.
    public var cacheDir: URL { home.appendingPathComponent("Library/Caches/\(AppIdentity.bundleID)", isDirectory: true) }

    /// Viewable attachment copies, HEIC converted to JPEG, expiring after 24 h (section 1, `attachment` op).
    public var attachmentCacheDir: URL { cacheDir.appendingPathComponent("attachments", isDirectory: true) }

    /// Hard-coded chat.db path (section 1, SQLite hardening). Only tests pass another path to IMStore.
    public var chatDB: URL { home.appendingPathComponent("Library/Messages/chat.db") }

    /// The only folder `attachment` may return files from (section 1).
    public var messagesAttachmentsDir: URL { home.appendingPathComponent("Library/Messages/Attachments", isDirectory: true) }

    /// AddressBook source databases live under `<this>/<source id>/AddressBook-v22.abcddb` (section 1).
    public var addressBookSourcesDir: URL {
        home.appendingPathComponent("Library/Application Support/AddressBook/Sources", isDirectory: true)
    }

    /// Installed bridge bundle.
    public var appBundle: URL { home.appendingPathComponent("Applications/\(AppIdentity.appName).app", isDirectory: true) }

    /// Installed CLI (section 5).
    public var cliInstallPath: URL { home.appendingPathComponent(".local/bin/\(AppIdentity.cliName)") }

    /// LaunchAgent plist (section 1).
    public var launchAgentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(AppIdentity.launchAgentLabel).plist")
    }

    /// `gui/<uid>/<label>`, the launchctl service target for kickstart (section 1 and doctor).
    public static func launchdServiceTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(AppIdentity.launchAgentLabel)"
    }
}
