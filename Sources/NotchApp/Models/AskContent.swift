import Foundation

/// Parsed form of an AskUserQuestion tool call, so the card can render a real
/// question with its options instead of raw JSON.
struct AskContent {
    struct Option: Identifiable {
        let id = UUID()
        let label: String
        let description: String
    }
    struct Question: Identifiable {
        let id = UUID()
        let question: String
        let header: String
        let multiSelect: Bool
        let options: [Option]
    }

    let questions: [Question]

    /// True when we can answer entirely from the notch: a single, single-select
    /// question. (Multi-question / multi-select fall back to Allow + terminal.)
    var isSimple: Bool { questions.count == 1 && !(questions.first?.multiSelect ?? true) }
    var first: Question? { questions.first }

    static func parse(_ input: JSONValue?) -> AskContent? {
        guard case .array(let qs)? = input?["questions"], !qs.isEmpty else { return nil }
        var questions: [Question] = []
        for q in qs {
            let text = q["question"]?.stringValue ?? ""
            let header = q["header"]?.stringValue ?? ""
            var multi = false
            if case .bool(let b)? = q["multiSelect"] { multi = b }
            var options: [Option] = []
            if case .array(let opts)? = q["options"] {
                for o in opts {
                    options.append(Option(
                        label: o["label"]?.stringValue ?? "",
                        description: o["description"]?.stringValue ?? ""))
                }
            }
            questions.append(Question(question: text, header: header, multiSelect: multi, options: options))
        }
        return AskContent(questions: questions)
    }
}
