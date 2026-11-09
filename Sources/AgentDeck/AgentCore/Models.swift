import Foundation

/// Identifies the tool that executes an agent. New providers add a case here
/// plus an `AgentAdapter` implementation — the dashboard never branches on it
/// except for presentation (name / icon).
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude"
    case cursor = "cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }
}

enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case working
    case idle
    case waitingApproval
    case waitingInput
    case completed
    case failed
    case stopped
    case unknown

    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .waitingApproval: return "Waiting for approval"
        case .waitingInput: return "Waiting for input"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Not running"
        case .unknown: return "Unknown"
        }
    }

    /// The process/session is alive (regardless of what it is doing).
    var isLive: Bool {
        switch self {
        case .working, .idle, .waitingApproval, .waitingInput: return true
        default: return false
        }
    }

    var needsAttention: Bool { self == .waitingApproval || self == .waitingInput || self == .failed }
    /// Done and not running: what "Archive finished" and auto-archive act on. Failed agents stay visible.
    var isFinished: Bool { self == .completed || self == .stopped }
    /// Not doing anything and not needing you: can be archived. Working, waiting and failed agents can't.
    var isArchivable: Bool { isFinished || self == .idle }
    /// Doing something or needing you: an archived agent in this state comes back to the dashboard.
    var isActive: Bool { self == .working || isWaiting }
    var isWaiting: Bool { self == .waitingApproval || self == .waitingInput }

    /// Sort weight: attention first, then working, idle, then finished.
    var sortRank: Int {
        switch self {
        case .waitingApproval: return 0
        case .waitingInput: return 1
        case .failed: return 2
        case .working: return 3
        case .idle: return 4
        case .completed: return 5
        case .unknown: return 6
        case .stopped: return 7
        }
    }
}

/// Managed agents were launched by AgentDeck and can be controlled by it.
/// Discovered agents were found via local integrations and are monitored only
/// (unless the provider exposes a supported control mechanism for them).
enum AgentOwnership: String, Codable, Sendable {
    case managed
    case discovered

    var label: String { self == .managed ? "Managed" : "Monitored" }
}

/// What AgentDeck can actually do with an agent. The UI shows / hides actions
/// strictly from this set so we never claim control we do not have.
struct AgentCapabilities: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let focus = AgentCapabilities(rawValue: 1 << 0)        // bring the hosting app / terminal forward
    static let resume = AgentCapabilities(rawValue: 1 << 1)       // re-open the session (documented resume flag)
    static let stop = AgentCapabilities(rawValue: 1 << 2)         // terminate the session
    static let interrupt = AgentCapabilities(rawValue: 1 << 3)    // cancel the current turn, keep session
    static let sendMessage = AgentCapabilities(rawValue: 1 << 4)  // send follow-up instructions
    static let approve = AgentCapabilities(rawValue: 1 << 5)      // answer permission prompts via the provider's protocol
    static let attachTerminal = AgentCapabilities(rawValue: 1 << 6)
}

enum AgentEventKind: String, Codable, CaseIterable, Sendable {
    case started, resumed, completed, failed, permissionRequested, idle, instruction, stopped, statusChanged, discovered, toolCall, message, info

    var label: String {
        switch self {
        case .started: return "Started"
        case .resumed: return "Resumed"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .permissionRequested: return "Permission"
        case .idle: return "Idle"
        case .instruction: return "Instruction"
        case .stopped: return "Stopped"
        case .statusChanged: return "Status"
        case .discovered: return "Discovered"
        case .toolCall: return "Tool"
        case .message: return "Message"
        case .info: return "Info"
        }
    }

    var symbol: String {
        switch self {
        case .started: return "play.fill"
        case .resumed: return "arrow.clockwise"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .permissionRequested: return "hand.raised.fill"
        case .idle: return "moon.zzz.fill"
        case .instruction: return "text.bubble.fill"
        case .stopped: return "stop.fill"
        case .statusChanged: return "arrow.triangle.swap"
        case .discovered: return "sparkle.magnifyingglass"
        case .toolCall: return "wrench.and.screwdriver.fill"
        case .message: return "bubble.left.fill"
        case .info: return "info"
        }
    }
}

struct AgentEvent: Identifiable, Hashable, Codable, Sendable {
    var id: Int64 = 0
    var agentID: String
    var provider: ProviderKind
    var projectID: String?
    var kind: AgentEventKind
    var message: String
    var date: Date
}

/// A pending permission request surfaced through a provider protocol (ACP).
struct PermissionRequest: Hashable, Sendable {
    struct Option: Hashable, Sendable {
        var id: String
        var name: String
        var kind: String   // allow_once | allow_always | reject_once | reject_always
        var isAllow: Bool { kind.hasPrefix("allow") }
    }
    var requestID: String
    var title: String
    var detail: String?
    var options: [Option]
}

/// Unified agent model. Adapters produce these; the UI only consumes them.
struct Agent: Identifiable, Hashable, Sendable {
    var id: String { "\(provider.rawValue):\(sessionID)" }
    var provider: ProviderKind
    var sessionID: String
    /// Provider-native short handle (e.g. Claude background id), if any.
    var handle: String?
    var title: String
    var model: String?
    var workingDirectory: String?
    var gitBranch: String?
    var status: AgentStatus
    var statusDetail: String?
    var ownership: AgentOwnership
    var capabilities: AgentCapabilities
    var createdAt: Date?
    var startedAt: Date?
    var lastActivity: Date?
    var pid: Int32?
    var kindLabel: String?           // "Interactive", "Background", "ACP", "CLI chat"
    var lastMessage: String?         // short, latest assistant text if exposed
    var pendingPermission: PermissionRequest?
    /// Only set when the provider reports real progress (e.g. ACP plan entries).
    var progress: AgentProgress?
    var currentActivity: String?     // e.g. current tool call title
    /// Name of the app that owns this session's UI ("Claude", "Cursor"), when it is known.
    /// Focus then navigates there instead of a terminal.
    var hostApp: String?
    /// Provider-native id used to open this exact session in `hostApp` (e.g. Claude's `local_…`).
    var hostSessionID: String?
    /// Real usage numbers when the provider records them (never estimated).
    var stats: AgentStats?
    /// When the agent entered its current waiting state (for reminders).
    var waitingSince: Date?

    // Filled by AgentManager.
    var projectID: String?
    var isPinned = false
}

/// Usage numbers read from the provider's own records.
struct AgentStats: Hashable, Sendable {
    var contextPercent: Double?      // Cursor: contextUsagePercent
    var contextTokens: Int?          // Claude: input + cache tokens of the latest turn; Cursor: contextTokensUsed
    var outputTokens: Int?           // Claude: output tokens summed over the recent part of the transcript
    var linesAdded: Int?
    var linesRemoved: Int?
    var filesChanged: Int?
    var isEmpty: Bool { contextPercent == nil && contextTokens == nil && outputTokens == nil && linesAdded == nil && filesChanged == nil }
}

struct AgentProgress: Hashable, Sendable {
    var completed: Int
    var total: Int
    var label: String       // e.g. "3 of 5 plan steps"
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

struct Project: Identifiable, Hashable, Sendable {
    var id: String            // stable: canonical path
    var name: String
    var path: String
    var colorHex: String
    var symbol: String
    var isUserAdded: Bool
    var isHidden: Bool
    var isGitRepository: Bool
    var createdAt: Date
}

/// Health of a provider integration, shown in Settings and the status bar.
struct ProviderHealth: Hashable, Sendable {
    enum State: String, Sendable { case unknown, ok, notInstalled, notAuthenticated, error }
    var state: State = .unknown
    var executablePath: String?
    var version: String?
    var account: String?
    var message: String?
    var appInstalled = false
    var checkedAt: Date?
}

/// Inputs for launching a new agent.
struct LaunchRequest: Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case managed       // Claude: --bg background session; Cursor: ACP session owned by AgentDeck
        case terminal      // interactive session in a terminal window
        case app           // the provider's desktop app (Claude app: new-session link; Cursor app: bridge extension)
        var id: String { rawValue }
    }
    var provider: ProviderKind
    var workingDirectory: String
    var prompt: String
    var title: String?
    var model: String?
    var mode: Mode
    var permissionMode: String?   // provider-specific value (Claude --permission-mode, Cursor ACP mode id)
    var worktree: Bool = false
}

struct LaunchResult: Sendable {
    var sessionID: String?
    var handle: String?
    var commandDescription: String
    var message: String?
}

enum AgentDeckError: LocalizedError {
    case notInstalled(String)
    case unsupported(String)
    case commandFailed(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let s), .unsupported(let s), .commandFailed(let s), .protocolError(let s): return s
        }
    }
}
