import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in: asks the person's real `gh` about one pull request, read-only (`gh pr view --json`), and
/// prints only its state fields. Set `YARDLET_LIVE_GH_PR` to a pull request's URL, or to a repository
/// folder whose branch has one. Nothing is created, commented, merged or closed, and `gh`'s sign-in
/// and configuration are not touched.
final class TaskPullRequestLiveTests: XCTestCase {
    func testGhSaysAPullRequestsState() async throws {
        var value = ProcessInfo.processInfo.environment["YARDLET_LIVE_GH_PR"] ?? ""
        try XCTSkipIf(value.isEmpty, "Set YARDLET_LIVE_GH_PR to a pull request URL or a repository folder")
        // A file holding the URL, so the URL need not appear in a command line or a log.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), !isDirectory.boolValue {
            value = try String(contentsOfFile: value, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cli = LocalGitHubCLI()
        try XCTSkipIf(cli.executableURL == nil, "gh is not installed")
        let client = GitHubPullRequestClient(cli: cli)
        let answer: GitHubPullRequestClient.Answer
        if value.hasPrefix("https://"), let url = URL(string: value) {
            answer = await client.pullRequest(at: url, in: FileManager.default.temporaryDirectory)
        } else {
            let folder = URL(filePath: value, directoryHint: .isDirectory)
            let branch = try XCTUnwrap(TaskPullRequestSources.branchToAsk(in: folder),
                                       "The folder is not on a feature branch of a GitHub repository")
            answer = await client.pullRequest(forBranch: branch, in: folder)
        }
        printAnswer(answer)
    }

    /// Opt-in: scans every transcript under a Claude config folder's `projects`
    /// (`YARDLET_LIVE_CLAUDE_CONFIG`, e.g. `~/.claude`) the way a task's is scanned, read-only, and
    /// prints only counts: transcripts, those with a `pr-link`, and the bytes the first scans read.
    func testScanningRealTranscriptsReadsLittle() throws {
        let value = ProcessInfo.processInfo.environment["YARDLET_LIVE_CLAUDE_CONFIG"] ?? ""
        try XCTSkipIf(value.isEmpty, "Set YARDLET_LIVE_CLAUDE_CONFIG to a Claude config folder")
        let projects = URL(filePath: value, directoryHint: .isDirectory).appending(path: "projects").resolvingSymlinksInPath()
        var transcripts = 0
        var linked = 0
        var bytesRead = 0
        var totalBytes: Int64 = 0
        let started = Date()
        for folder in try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                let size = Int64(try handle.seekToEnd())
                transcripts += 1
                totalBytes += size
                let scan = try ClaudePullRequestLinkScanner.scan(
                    file: .init(device: 0, inode: UInt64(transcripts)), size: size, previous: nil
                ) { offset, count in
                    bytesRead += count
                    try handle.seek(toOffset: UInt64(offset))
                    return try handle.read(upToCount: count) ?? Data()
                }
                if scan.link != nil { linked += 1 }
            }
        }
        print("live scan: transcripts=\(transcripts) withPrLink=\(linked) readMiB=\(bytesRead >> 20)"
            + " ofMiB=\(totalBytes >> 20) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
    }

    private func printAnswer(_ answer: GitHubPullRequestClient.Answer) {
        switch answer {
        case let .found(pullRequest):
            print("live gh: #\(pullRequest.number) state=\(pullRequest.state?.rawValue ?? "unknown")"
                + " checks=\(pullRequest.checks?.rawValue ?? "none") review=\(pullRequest.review?.rawValue ?? "none")")
            XCTAssertNotNil(pullRequest.state)
        case .none:
            print("live gh: no pull request for the branch")
        case .unavailable:
            print("live gh: unavailable (signed out, offline, or no access)")
        }
    }
}
