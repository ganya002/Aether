import Foundation

/// The current branch (or short hash) for a working tree, from `.git/HEAD`.
enum GitStatus {
    static func branch(in directory: String) -> String? {
        guard let git = gitDirectory(startingAt: directory) else { return nil }
        let head = git.appendingPathComponent("HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heads = "ref: refs/heads/"
        if line.hasPrefix(heads) {
            let name = String(line.dropFirst(heads.count))
            return name.isEmpty ? nil : name
        }
        if line.hasPrefix("ref: ") {
            let name = URL(fileURLWithPath: String(line.dropFirst(5))).lastPathComponent
            return name.isEmpty ? nil : name
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return String(line.prefix(7))
    }

    static func gitDirectory(startingAt directory: String) -> URL? {
        var url = URL(fileURLWithPath: directory)
        let files = FileManager.default
        while true {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return git }
                if let pointed = linkedGitDirectory(at: git, relativeTo: url), files.fileExists(atPath: pointed.path) {
                    return pointed
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    private static func linkedGitDirectory(at file: URL, relativeTo base: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("gitdir:") else { continue }
            let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
        }
        return nil
    }
}
