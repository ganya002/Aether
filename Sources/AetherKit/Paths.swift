import AppKit
import Foundation

enum PathOpener {
    struct LocatedFile {
        var url: URL
        var line: Int?
    }

    /// Resolves a command-clicked token against the pane's working directory.
    static func locate(_ raw: String, cwd: String) -> LocatedFile? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>()[]{}.,;"))
        guard !token.isEmpty else { return nil }

        if let url = URL(string: token), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return LocatedFile(url: url, line: nil)
        }

        var line: Int?
        if let match = token.range(of: #":(\d+)(?::\d+)?$"#, options: .regularExpression) {
            let digits = token[match].dropFirst().prefix { $0.isNumber }
            line = Int(digits)
            token = String(token[..<match.lowerBound])
        }

        let expanded = (token as NSString).expandingTildeInPath
        let path: String
        if expanded.hasPrefix("/") {
            path = expanded
        } else {
            path = (cwd as NSString).appendingPathComponent(expanded)
        }
        let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: standardized) else { return nil }
        return LocatedFile(url: URL(fileURLWithPath: standardized), line: line)
    }

    @discardableResult
    static func open(_ raw: String, cwd: String) -> Bool {
        guard let target = locate(raw, cwd: cwd) else { return false }
        if target.url.isFileURL, let line = target.line, FileManager.default.isExecutableFile(atPath: "/usr/bin/xed") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = ["--line", "\(line)", target.url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return true }
        }
        return NSWorkspace.shared.open(target.url)
    }
}
