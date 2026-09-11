import Foundation

// MARK: - What the app tracks

enum RunStatus: String {
    case queued
    case inProgress = "in_progress"
    case completed

    /// GitHub reports queued, waiting, requested and pending; they all mean
    /// "not started yet" as far as a card is concerned.
    init(github status: String?) {
        switch status {
        case "completed": self = .completed
        case "in_progress": self = .inProgress
        default: self = .queued
        }
    }
}

enum ActionState: String {
    case queued
    case running
    case success
    case failure
    case cancelled
    case timedOut = "timed_out"
    case skipped
    case actionRequired = "action_required"
    case neutral

    var isActive: Bool {
        self == .queued || self == .running
    }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .success: "Passed"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .skipped: "Skipped"
        case .actionRequired: "Action needed"
        case .neutral: "Finished"
        }
    }
}

struct TrackedRun: Identifiable, Equatable {
    let key: String
    let repo: String
    let owner: String
    let repoName: String
    let runId: Int
    let workflowId: Int?
    var name: String
    var branch: String?
    var event: String?
    var status: RunStatus
    var conclusion: String?
    var actor: String?
    var startedAt: Date
    var completedAt: Date?
    var duration: TimeInterval?
    var expectedDuration: TimeInterval?
    var currentJob: String?
    var currentStep: String?
    var jobsTotal: Int
    var jobsCompleted: Int
    let url: URL

    var id: String { key }

    var state: ActionState {
        if status != .completed {
            return status == .inProgress ? .running : .queued
        }

        switch conclusion {
        case "success": return .success
        case "failure", "startup_failure": return .failure
        case "cancelled", "stale": return .cancelled
        case "timed_out": return .timedOut
        case "skipped": return .skipped
        case "action_required": return .actionRequired
        default: return .neutral
        }
    }

    /// Everything a card needs to redraw. `now` is passed in separately so
    /// the clock ticking does not count as the run changing.
    var isDone: Bool { status == .completed }
}

// MARK: - Settings

struct Account: Codable, Equatable {
    let login: String
    let name: String?
    let avatarUrl: String
    let scopes: [String]
}

enum ActorMode: String, Codable {
    case all
    case me
    case only
}

struct ActorFilter: Codable, Equatable {
    var mode: ActorMode
    var logins: [String]

    static let everyone = ActorFilter(mode: .all, logins: [])
}

struct RepoSummary: Identifiable, Codable, Equatable {
    let fullName: String
    let owner: String
    let name: String
    let isPrivate: Bool
    let isFork: Bool
    let updatedAt: String

    var id: String { fullName }
}

// MARK: - GitHub's JSON

struct GitHubUser: Decodable {
    let login: String
    let name: String?
    let avatarUrl: String?
}

struct WorkflowRun: Decodable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let event: String?
    let status: String?
    let conclusion: String?
    let workflowId: Int?
    let htmlUrl: String?
    let runStartedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let actor: GitHubUser?
    let triggeringActor: GitHubUser?

    var startedAt: Date { runStartedAt ?? createdAt }

    var whoTriggered: String? {
        triggeringActor?.login ?? actor?.login
    }
}

struct WorkflowRunList: Decodable {
    let workflowRuns: [WorkflowRun]
}

struct JobStep: Decodable {
    let name: String
    let status: String?
}

struct Job: Decodable {
    let id: Int
    let name: String
    let status: String?
    let steps: [JobStep]?
}

struct JobList: Decodable {
    let jobs: [Job]
}

struct Repository: Decodable {
    let fullName: String
    let name: String
    let owner: GitHubUser
    let `private`: Bool?
    let fork: Bool?
    let updatedAt: String?
}
