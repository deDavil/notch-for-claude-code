import Foundation

/// Persistent "always allow in this project" rules. A rule = (project cwd,
/// tool, pattern) stored as JSON at ~/.config/klavs-notch/rules.json (override:
/// NOTCH_RULES_FILE). Unlike AutoAllowStore these survive app restarts and
/// session ends; scope is the exact working directory, so a rule for one
/// project never leaks into another. Save failures are logged, never thrown —
/// rules are convenience, not a gate.
@MainActor
final class ProjectRuleStore {
    struct Rule: Codable, Hashable {
        let cwd: String
        let tool: String
        let pattern: String
    }

    private(set) var rules: Set<Rule> = []
    private let path: String

    init() {
        if let p = ProcessInfo.processInfo.environment["NOTCH_RULES_FILE"], !p.isEmpty {
            path = p
        } else {
            path = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".config/klavs-notch/rules.json")
        }
        load()
    }

    var count: Int { rules.count }

    func remember(payload: HookPayload) {
        guard let cwd = payload.cwd, !cwd.isEmpty, let tool = payload.toolName else { return }
        rules.insert(Rule(cwd: cwd, tool: tool, pattern: RulePattern.derive(payload)))
        save()
    }

    func matches(_ payload: HookPayload) -> Bool {
        guard let cwd = payload.cwd, let tool = payload.toolName else { return false }
        return rules.contains(Rule(cwd: cwd, tool: tool, pattern: RulePattern.derive(payload)))
    }

    func clearAll() {
        rules.removeAll()
        save()
    }

    /// All rules, stably sorted for display.
    func allRules() -> [Rule] {
        rules.sorted { ($0.cwd, $0.tool, $0.pattern) < ($1.cwd, $1.tool, $1.pattern) }
    }

    /// Revoke a single rule (persists immediately).
    func remove(_ rule: Rule) {
        rules.remove(rule)
        save()
    }

    // MARK: - persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([Rule].self, from: data) else { return }
        rules = Set(decoded)
    }

    private func save() {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(rules.sorted { ($0.cwd, $0.tool, $0.pattern) < ($1.cwd, $1.tool, $1.pattern) })
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("rules.json save failed: \(String(describing: error))")
        }
    }
}
