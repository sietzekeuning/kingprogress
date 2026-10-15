import AppKit
import Foundation

/// runs.json: what KingProgress knows about the runs in the watched
/// repositories, for other apps on this Mac to read - is the deploy of this
/// commit done yet, and did it pass? The format is in docs/runs.md.
///
/// The file is replaced in one go whenever what it says changes, so a
/// reader never sees half of it, and a distributed notification rings the
/// bell for apps that would rather not poll. It only exists while
/// KingProgress runs, is signed in and is allowed to share.
@MainActor
final class RunStatusFile {
    /// Posted after every change to the file, including its removal. It
    /// carries nothing: the file is the news.
    static let changed = Notification.Name("com.kingprogress.app.runsChanged")

    /// `~/Library/Application Support/KingProgress/runs.json`, unless
    /// `KINGPROGRESS_RUNS_FILE` says otherwise - so a development build can
    /// run next to the installed one without writing over its runs.
    nonisolated static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["KINGPROGRESS_RUNS_FILE"], !path.isEmpty {
            return path
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("KingProgress/runs.json").path
    }

    let path: String
    /// What this copy last put in the file. Nil when it has not written it,
    /// or another copy holds it.
    private var written: Data?
    private var heldByAnotherCopy = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(path: String = RunStatusFile.defaultPath) {
        self.path = path
    }

    func write(runs: [TrackedRun], account: String?) {
        let document = Document(pid: getpid(), account: account, runs: runs.map(SharedRun.init))
        guard let data = try? encoder.encode(document), data != written else {
            return
        }

        // Another copy of KingProgress keeps this file - the installed one,
        // next to a development build. Leave it alone; once that copy quits
        // and takes the file away, the next change lands here.
        if ownedByAnotherCopy() {
            if !heldByAnotherCopy {
                log("the run status is already shared by another copy of KingProgress: \(path)")
                heldByAnotherCopy = true
            }
            written = nil
            return
        }
        heldByAnotherCopy = false

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Written next to the file and renamed over it, so a reader gets the
        // old file or the new one and never half of either. Created 0600
        // from the start: only this user may read their runs.
        let temporary = directory.appendingPathComponent(".runs.json.\(getpid())").path
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            log("could not write the run status: \(String(cString: strerror(errno)))")
            return
        }
        let complete = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
        close(fd)

        guard complete, rename(temporary, path) == 0 else {
            log("could not write the run status: \(String(cString: strerror(errno)))")
            unlink(temporary)
            return
        }

        written = data
        ring()
    }

    /// Takes the file away: KingProgress quits, signs out or stops sharing.
    /// A file another copy keeps is not ours to remove.
    func remove() {
        written = nil
        guard !ownedByAnotherCopy(), unlink(path) == 0 else {
            return
        }
        ring()
    }

    // MARK: - Helpers

    /// Whether the file names a live KingProgress other than this one.
    private func ownedByAnotherCopy() -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value,
              pid != getpid()
        else {
            return false
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func ring() {
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[kingprogress] \(message)\n".utf8))
    }
}

// MARK: - The file's contents

private struct Document: Encodable {
    let version = 1
    /// Which process keeps the file. A reader can check it is still alive;
    /// a file left behind by a crash names one that is not.
    let pid: Int32
    /// Who is signed in, to tell one's own runs from the rest.
    let account: String?
    let runs: [SharedRun]
}

/// A run as other apps see it. Times are whole Unix seconds, durations
/// whole seconds, and whatever is unknown is left out.
private struct SharedRun: Encodable {
    let id: Int
    let repo: String
    let workflow: String
    let branch: String?
    let event: String?
    let sha: String?
    let commit: String?
    let actor: String?
    let state: String
    let startedAt: Int
    let completedAt: Int?
    let duration: Int?
    let expectedDuration: Int?
    let job: String?
    let step: String?
    let jobsTotal: Int?
    let jobsCompleted: Int?
    let url: String

    init(_ run: TrackedRun) {
        id = run.runId
        repo = run.repo
        workflow = run.name
        branch = run.branch
        event = run.event
        sha = run.sha
        commit = run.commitMessage
        actor = run.actor
        state = run.state.rawValue
        startedAt = Int(run.startedAt.timeIntervalSince1970)
        completedAt = run.isDone ? run.completedAt.map { Int($0.timeIntervalSince1970) } : nil
        duration = run.isDone ? run.duration.map { Int($0.rounded()) } : nil
        expectedDuration = run.expectedDuration.map { Int($0.rounded()) }
        job = run.currentJob
        step = run.currentStep
        jobsTotal = run.jobsTotal > 0 ? run.jobsTotal : nil
        jobsCompleted = run.jobsTotal > 0 ? run.jobsCompleted : nil
        url = run.url.absoluteString
    }
}
