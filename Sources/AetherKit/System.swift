import Darwin
import Foundation

enum System {
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

    static func normalizeDirectory(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw), !url.path.isEmpty {
            return url.path
        }
        if raw.hasPrefix("/") { return raw }
        return nil
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

    static func executable(named name: String) -> String? {
        for directory in searchPaths() {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func installedTools() -> [(name: String, path: String)] {
        let names = [
            "btop", "htop", "top",
            "lazygit", "git",
            "nvim", "vim", "nano",
            "python3", "node",
            "ssh", "docker", "k9s",
            "fzf", "tmux", "claude",
        ]
        return names.compactMap { name in
            guard let path = executable(named: name) else { return nil }
            return (name, path)
        }
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Aether", isDirectory: true)
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
