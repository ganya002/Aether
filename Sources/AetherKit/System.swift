import Darwin
import Foundation

enum System {
    /// The side-by-side development build. It keeps its own settings, sessions, and control port,
    /// and never updates itself or claims the global hotkey, so it can run next to the real Aether.
    static let isDev: Bool = {
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true { return true }
        return ProcessInfo.processInfo.environment["AETHER_DEV"] == "1"
    }()

    static func userShell() -> String {
        if let password = getpwuid(getuid()), let shell = password.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        for candidate in [ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh", "/bin/bash"].compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/bin/zsh"
    }

    static func home() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func currentDirectory(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let wrote = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard wrote == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer -> String? in
            guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
        guard let path, !path.isEmpty, path != "/" || FileManager.default.fileExists(atPath: path) else {
            return path?.isEmpty == false ? path : nil
        }
        return path
    }

    /// OSC 7 names a host. A directory on another machine (an ssh session) is not a place on this Mac.
    static func normalizeDirectory(_ raw: String?, localHosts: [String] = System.localHostNames) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw), !url.path.isEmpty {
            if let host = url.host, !host.isEmpty, !isLocalHost(host, localHosts: localHosts) {
                return nil
            }
            return url.path
        }
        if raw.hasPrefix("/") { return raw }
        return nil
    }

    static func isLocalHost(_ host: String, localHosts: [String]) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "127.0.0.1" || name == "::1" { return true }
        let short = name.split(separator: ".").first.map(String.init) ?? name
        for local in localHosts {
            let candidate = local.lowercased()
            if candidate == name { return true }
            if (candidate.split(separator: ".").first.map(String.init) ?? candidate) == short { return true }
        }
        return false
    }

    static let localHostNames: [String] = {
        var names: [String] = []
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.append(String(cString: buffer))
        }
        names.append(ProcessInfo.processInfo.hostName)
        return names.filter { !$0.isEmpty }
    }()

    /// The short name of a running process, such as `nvim`.
    static func processName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
            if !name.isEmpty { return name }
        }
        var short = [CChar](repeating: 0, count: 64)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let name = String(cString: short)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// The command a process was started with, like `cargo build`, trimmed to a few words.
    static func commandLine(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return processName(pid: pid) }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return processName(pid: pid) }
        let argc = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var words: [String] = []
        while words.count < Int(argc), index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            words.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        guard let first = words.first else { return processName(pid: pid) }
        var parts = [URL(fileURLWithPath: first).lastPathComponent]
        parts.append(contentsOf: words.dropFirst().prefix(2))
        let text = parts.joined(separator: " ")
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    static func searchPaths() -> [String] {
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/sbin"]
        for extra in extras where !paths.contains(extra) {
            paths.append(extra)
        }
        return paths
    }

    static func executable(named name: String, in paths: [String] = searchPaths()) -> String? {
        for directory in paths {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func installedTools(in paths: [String] = searchPaths()) -> [(name: String, path: String)] {
        let names = [
            "btop", "htop", "top",
            "lazygit", "git",
            "nvim", "vim", "nano",
            "python3", "node",
            "ssh", "docker", "k9s",
            "fzf", "tmux", "claude",
        ]
        return names.compactMap { name in
            guard let path = executable(named: name, in: paths) else { return nil }
            return (name, path)
        }
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(isDev ? "Aether Dev" : "Aether", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        resolved(lhs) == resolved(rhs)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func displayPath(_ path: String) -> String {
        let home = home()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
