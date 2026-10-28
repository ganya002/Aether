import Foundation
import Testing
@testable import AetherKit

@Test func gitStatusReadsTheCurrentBranch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aether-git-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GitStatus.branch(in: nested.path) == nil)

    let git = root.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitStatus.branch(in: nested.path) == "main")

    try "ref: refs/heads/feature/dense-header\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitStatus.branch(in: nested.path) == "feature/dense-header")

    try "abcdef1234567890\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitStatus.branch(in: nested.path) == "abcdef1")
}

@Test func gitStatusFollowsALinkedGitdir() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aether-gitdir-\(UUID().uuidString)")
    let store = FileManager.default.temporaryDirectory.appendingPathComponent("aether-gitstore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store)
    }
    try "gitdir: \(store.path)\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "ref: refs/heads/worktree\n".write(to: store.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitStatus.branch(in: root.path) == "worktree")
}
