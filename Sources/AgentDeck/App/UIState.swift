import SwiftUI
import Observation

enum SidebarSection: Hashable {
    case overview, pinned, all, projects, activity, settings, archived
    case project(String)

    var title: String {
        switch self {
        case .overview: return "Agent overview"
        case .pinned: return "Pinned agents"
        case .all: return "All agents"
        case .projects: return "Projects"
        case .activity: return "Activity"
        case .settings: return "Settings"
        case .archived: return "Archived"
        case .project: return "Project"
        }
    }

    var showsAgents: Bool {
        switch self {
        case .overview, .pinned, .all, .project, .archived: return true
        default: return false
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", waiting = "Waiting", completed = "Completed", failed = "Failed"
    var id: String { rawValue }

    func matches(_ s: AgentStatus) -> Bool {
        switch self {
        case .all: return true
        case .active: return s == .working || s == .idle
        case .waiting: return s.isWaiting
        case .completed: return s == .completed
        case .failed: return s == .failed
        }
    }
}

@MainActor
@Observable
final class UIState {
    var section: SidebarSection = .overview
    var filter: StatusFilter = .all
    var providerFilter: ProviderKind?
    var search = ""
    var selection: String?
    var showNewAgent = false
    var newAgentProvider: ProviderKind = .claudeCode
    var searchFocusRequest = 0
    var inspectorCollapsed = false

    func select(_ id: String?) {
        withAnimation(.easeOut(duration: 0.18)) { selection = id }
    }

    func newAgent(_ provider: ProviderKind? = nil) {
        if let provider { newAgentProvider = provider }
        showNewAgent = true
    }
}
