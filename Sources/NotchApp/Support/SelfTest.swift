import Foundation

/// Dependency-free self-tests (XCTest isn't available under Command Line Tools).
/// Run with `NOTCH_SELFTEST=1 swift run NotchApp`; exits 0 on pass, 1 on failure.
/// Covers the risk-bearing pure logic + the arbiter's first-wins/queue behavior.
enum SelfTest {
    private static var failures = 0

    static func run() -> Never {
        testJSONValueRoundTrip()
        testPermissionAllowEchoesInput()
        testPermissionDenyCarriesMessage()
        testPreToolUseAllow()
        testNoOpinionEmpty()
        testToolSummary()
        testSessionLabel()
        testDiffEngine()
        testEditProducesDiff()
        testAskParsing()
        testAnswerInjection()
        testExitPlanMode()
        MainActor.assumeIsolated {
            testFirstWinsIdempotent()
            testQueueFIFORouting()
            testClientDropped()
            testAutoAllowShortCircuits()
            testAutoAllowClearedOnStop()
            testAutoAllowSessionScoped()
            testSessionRegistry()
            testDecisionLogRecord()
        }
        if failures == 0 {
            print("SELFTEST: all passed")
            exit(0)
        } else {
            print("SELFTEST: \(failures) FAILED")
            exit(1)
        }
    }

    // MARK: helpers

    private static func check(_ cond: Bool, _ name: String) {
        if cond { print("  PASS \(name)") }
        else { print("  FAIL \(name)"); failures += 1 }
    }

    private static func payload(_ json: String) -> HookPayload {
        try! JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
    }

    private static func obj(_ data: Data?) -> [String: Any] {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return o
    }

    // MARK: pure logic

    private static func testJSONValueRoundTrip() {
        let src = #"{"command":"echo hi","n":3,"flag":true,"nested":{"a":[1,"x",null]}}"#
        let v = try! JSONDecoder().decode(JSONValue.self, from: Data(src.utf8))
        let out = try! JSONEncoder().encode(v)
        let r = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
        check(r?["command"] as? String == "echo hi" && r?["n"] as? Int == 3 && r?["flag"] as? Bool == true,
              "JSONValue round-trip fidelity")
    }

    private static func testPermissionAllowEchoesInput() {
        let p = payload(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push","description":"d"}}"#)
        let hso = obj(HookResponse.body(for: .allow, payload: p))["hookSpecificOutput"] as? [String: Any]
        let d = hso?["decision"] as? [String: Any]
        let updated = d?["updatedInput"] as? [String: Any]
        check(hso?["hookEventName"] as? String == "PermissionRequest"
              && d?["behavior"] as? String == "allow"
              && updated?["command"] as? String == "git push",
              "PermissionRequest allow echoes updatedInput")
    }

    private static func testPermissionDenyCarriesMessage() {
        let p = payload(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#)
        let hso = obj(HookResponse.body(for: .deny(reason: "nope"), payload: p))["hookSpecificOutput"] as? [String: Any]
        let d = hso?["decision"] as? [String: Any]
        check(d?["behavior"] as? String == "deny" && d?["message"] as? String == "nope" && d?["updatedInput"] == nil,
              "PermissionRequest deny carries message")
    }

    private static func testPreToolUseAllow() {
        let p = payload(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        let hso = obj(HookResponse.body(for: .allow, payload: p))["hookSpecificOutput"] as? [String: Any]
        check(hso?["hookEventName"] as? String == "PreToolUse"
              && hso?["permissionDecision"] as? String == "allow"
              && hso?["decision"] == nil,
              "PreToolUse allow uses permissionDecision")
    }

    private static func testNoOpinionEmpty() {
        let p = payload(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#)
        check(HookResponse.body(for: .noOpinion, payload: p) == nil, "noOpinion → empty body")
    }

    private static func testToolSummary() {
        let s1 = ToolSummary.make(from: payload(#"{"tool_name":"Bash","tool_input":{"command":"npm test"}}"#))
        let s2 = ToolSummary.make(from: payload(#"{"tool_name":"Edit","tool_input":{"file_path":"/a/b/main.swift"}}"#))
        check(s1.detail == "npm test" && s1.icon == "terminal" && s2.title.contains("main.swift"),
              "ToolSummary renders Bash + Edit")
    }

    private static func testSessionLabel() {
        check(payload(#"{"cwd":"/Users/x/ai-system","session_id":"abcdef123"}"#).sessionLabel == "ai-system",
              "sessionLabel from cwd basename")
    }

    private static func testDiffEngine() {
        // one line changed in the middle; prefix/suffix are context
        let d = TextDiff.lines(old: "a\nb\nc", new: "a\nB\nc")
        let removed = d.filter { $0.kind == .removed }.map { $0.text }
        let added = d.filter { $0.kind == .added }.map { $0.text }
        check(removed == ["b"] && added == ["B"] && TextDiff.stat(d) == "+1 −1",
              "TextDiff isolates the changed line")
    }

    private static func testEditProducesDiff() {
        let p = payload(#"{"tool_name":"Edit","tool_input":{"file_path":"/a/main.swift","old_string":"let x = 1","new_string":"let x = 2"}}"#)
        let s = ToolSummary.make(from: p)
        let hasRemoved = (s.diff ?? []).contains { $0.kind == .removed && $0.text == "let x = 1" }
        let hasAdded = (s.diff ?? []).contains { $0.kind == .added && $0.text == "let x = 2" }
        check(hasRemoved && hasAdded && s.title.contains("main.swift"),
              "Edit tool produces a diff")
    }

    private static func testAskParsing() {
        let p = payload(#"""
        {"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tabs or spaces?","header":"Style","multiSelect":false,"options":[{"label":"Tabs","description":"use tabs"},{"label":"Spaces","description":"use spaces"}]}]}}
        """#)
        let s = ToolSummary.make(from: p)
        let ok = s.ask?.isSimple == true
            && s.ask?.first?.question == "Tabs or spaces?"
            && s.ask?.first?.options.map { $0.label } == ["Tabs", "Spaces"]
        check(ok, "AskUserQuestion parses question + options")
    }

    private static func testExitPlanMode() {
        // The plan must be extracted decoded (real newlines), not re-encoded JSON.
        let p = payload(##"{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Title\n\n- step one\n- step two"}}"##)
        let s = ToolSummary.make(from: p)
        check(s.plan == "# Title\n\n- step one\n- step two"
              && s.plan?.contains("\n") == true
              && s.title == "Implementation plan",
              "ExitPlanMode extracts the decoded plan markdown")
    }

    private static func testAnswerInjection() {
        // Decision.answer must merge into tool_input.answers, keyed by question text.
        let p = payload(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?"}]}}"#)
        let body = HookResponse.body(for: .answer(["Q?": "Spaces"]), payload: p)
        let hso = obj(body)["hookSpecificOutput"] as? [String: Any]
        let decision = hso?["decision"] as? [String: Any]
        let updated = decision?["updatedInput"] as? [String: Any]
        let answers = updated?["answers"] as? [String: Any]
        check(decision?["behavior"] as? String == "allow"
              && answers?["Q?"] as? String == "Spaces"
              && updated?["questions"] != nil,
              "answer injects answers + preserves questions")
    }

    // MARK: arbiter (MainActor)

    @MainActor private static func makeStore() -> RequestStore {
        RequestStore(settings: AppSettings(port: 0, token: nil, virtualNotch: true,
                                           answerTimeout: 999, autoDecision: nil))
    }

    @MainActor private static func testFirstWinsIdempotent() {
        let store = makeStore()
        var count = 0
        let id = store.enqueue(payload: payload(#"{"tool_name":"Bash","session_id":"s"}"#)) { _ in count += 1 }!
        let first = store.resolve(id: id, decision: .allow, source: .notch)
        let second = store.resolve(id: id, decision: .deny(reason: "x"), source: .telegram)
        check(first && !second && store.pending.isEmpty && count == 1,
              "first-wins resolve is idempotent (parked response written once)")
    }

    @MainActor private static func testQueueFIFORouting() {
        let store = makeStore()
        var aCalled = false, bCalled = false
        let idA = store.enqueue(payload: payload(#"{"tool_name":"Bash","session_id":"A"}"#)) { _ in aCalled = true }!
        _ = store.enqueue(payload: payload(#"{"tool_name":"Bash","session_id":"B"}"#)) { _ in bCalled = true }!
        let frontIsA = store.frontRequest?.id == idA
        store.resolve(id: idA, decision: .allow, source: .notch)
        check(frontIsA && aCalled && !bCalled && store.pending.count == 1 && store.frontRequest?.sessionId == "B",
              "queue is FIFO and routes to the right session")
    }

    @MainActor private static func testClientDropped() {
        let store = makeStore()
        var called = false
        let id = store.enqueue(payload: payload(#"{"tool_name":"Bash","session_id":"s"}"#)) { _ in called = true }!
        store.clientDropped(id: id)
        check(store.pending.isEmpty && !called, "clientDropped removes without responding")
    }

    @MainActor private static func testAutoAllowShortCircuits() {
        let store = makeStore()
        let auto = AutoAllowStore()
        store.autoAllow = auto
        auto.remember(payload: payload(#"{"tool_name":"Bash","session_id":"s","tool_input":{"command":"git status"}}"#))
        var body: Data? = nil
        var called = false
        let id = store.enqueue(payload: payload(#"{"tool_name":"Bash","session_id":"s","tool_input":{"command":"git push"}}"#)) { called = true; body = $0 }
        let d = (obj(body)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        check(id == nil && store.pending.isEmpty && called && d?["behavior"] as? String == "allow",
              "auto-allow short-circuits (never enqueues)")
    }

    @MainActor private static func testAutoAllowClearedOnStop() {
        let auto = AutoAllowStore()
        auto.remember(payload: payload(#"{"tool_name":"Bash","session_id":"s","tool_input":{"command":"ls"}}"#))
        let before = auto.matches(payload(#"{"tool_name":"Bash","session_id":"s","tool_input":{"command":"ls -la"}}"#))
        auto.clearSession("s")
        let after = auto.matches(payload(#"{"tool_name":"Bash","session_id":"s","tool_input":{"command":"ls"}}"#))
        check(before && !after, "auto-allow cleared on session stop")
    }

    @MainActor private static func testAutoAllowSessionScoped() {
        let auto = AutoAllowStore()
        auto.remember(payload: payload(#"{"tool_name":"Bash","session_id":"s1","tool_input":{"command":"ls"}}"#))
        check(!auto.matches(payload(#"{"tool_name":"Bash","session_id":"s2","tool_input":{"command":"ls"}}"#)),
              "auto-allow is session-scoped")
    }

    @MainActor private static func testDecisionLogRecord() {
        let p = payload(#"{"session_id":"s1","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"git push"}}"#)
        let req = PendingRequest(payload: p, receivedAt: Date().addingTimeInterval(-7)) { _ in }
        let allow = DecisionLog.record(request: req, decision: .allow, source: .telegram)
        let drop = DecisionLog.record(request: req, decision: nil, source: .clientDropped)
        let answer = DecisionLog.record(request: req, decision: .answer(["Q?": "Tabs"]), source: .notch)
        check(allow["decision"] as? String == "allow"
              && allow["source"] as? String == "telegram"
              && allow["session"] as? String == "proj"
              && (allow["latency_s"] as? Int ?? -1) >= 6
              && drop["decision"] as? String == "dropped"
              && answer["decision"] as? String == "answer"
              && (answer["answers"] as? [String: String])?["Q?"] == "Tabs",
              "DecisionLog record format (allow/dropped/answer + latency)")
    }

    @MainActor private static func testSessionRegistry() {
        let reg = SessionRegistry()
        reg.noteEvent(payload(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#))
        reg.noteEvent(payload(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/proj"}"#))
        let working = reg.sessions.first?.displayState == .working && reg.sessions.first?.label == "proj"
        // A pending approval outranks the working base state.
        reg.incPending(payload(#"{"session_id":"s","tool_name":"Bash"}"#))
        let waiting = reg.sessions.first?.displayState == .waitingApproval && reg.aggregate == .waitingApproval
        reg.decPending(payload(#"{"session_id":"s","tool_name":"Bash"}"#))
        let backToWorking = reg.sessions.first?.displayState == .working
        // Stop → idle; SessionEnd → removed.
        reg.noteEvent(payload(#"{"hook_event_name":"Stop","session_id":"s"}"#))
        let idle = reg.sessions.first?.displayState == .idle
        reg.noteEvent(payload(#"{"hook_event_name":"SessionEnd","session_id":"s"}"#))
        let gone = reg.sessions.isEmpty
        check(working && waiting && backToWorking && idle && gone,
              "SessionRegistry state machine (start→work→approval→work→idle→end)")
    }
}
