import Foundation

/// Signals an adapter can push to the manager outside regular snapshots.
enum AdapterSignal: Sendable {
    /// Something changed on disk / in a process: please refresh me soon.
    case needsRefresh(ProviderKind)
    /// A discrete lifecycle event the manager should record verbatim.
    case event(agentSessionID: String, provider: ProviderKind, kind: AgentEventKind, message: String)
    /// A managed agent's state changed; the adapter's next snapshot reflects it.
    case agentUpdated(ProviderKind)
}

/// Contract every provider integration implements. Adapters are isolated:
/// a thrown error in one never affects the others (the manager catches per adapter).
protocol AgentAdapter: AnyObject, Sendable {
    var kind: ProviderKind { get }

    /// Called once with a sink for asynchronous signals.
    func start(signals: @escaping @Sendable (AdapterSignal) -> Void) async

    /// Detect installation, version and authentication. Cheap enough to call on demand.
    func checkHealth() async -> ProviderHealth

    /// Return the provider's current view of all agents it knows about.
    func snapshot(options: DiscoveryOptions) async throws -> [Agent]

    /// Models offered by the provider for new agents (never hardcoded).
    func availableModels() async -> [ModelOption]

    /// Permission / execution modes the provider documents for new agents.
    func launchModes() -> [ModeOption]

    func launch(_ request: LaunchRequest) async throws -> LaunchResult
    func stop(_ agent: Agent) async throws
    func interrupt(_ agent: Agent) async throws
    func focus(_ agent: Agent) async throws
    func resume(_ agent: Agent) async throws
    func send(_ agent: Agent, message: String) async throws
    func respondToPermission(_ agent: Agent, optionID: String?) async throws

    /// Directories whose changes should trigger a refresh (watched with FSEvents).
    func watchedPaths() -> [String]
    /// Signs that a provider's undocumented local format changed and data may be missing.
    func formatWarnings() -> [String]
}

struct DiscoveryOptions: Sendable {
    var historyWindow: TimeInterval   // include inactive sessions touched within this window
}

struct ModelOption: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct ModeOption: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var detail: String
}

extension AgentAdapter {
    func formatWarnings() -> [String] { [] }
    func interrupt(_ agent: Agent) async throws { throw AgentDeckError.unsupported("\(kind.displayName) does not support interrupting this agent.") }
    func send(_ agent: Agent, message: String) async throws { throw AgentDeckError.unsupported("Sending messages is not supported for this agent.") }
    func respondToPermission(_ agent: Agent, optionID: String?) async throws { throw AgentDeckError.unsupported("Approvals for this agent must be answered in \(kind.displayName).") }
}
