import Foundation

/// Brief spans retain their transcript source so flights can match the two endpoints.
struct SummaryLog: Equatable {
    /// The request: the first line of the user's message that began the turn.
    struct Goal: Equatable {
        let itemID: String
        var text: String
    }
    /// A message the user sent while the agent worked (Steer): the agent has it, so the brief says it, on the user's side.
    struct Input: Equatable {
        let itemID: String
        var text: String
        /// Its place in the transcript, to set it among the stretches.
        let order: Int
    }
    struct Stretch: Equatable, Identifiable {
        /// What it came after (the message that started it, or the answer before it), so a stretch keeps its identity
        /// from before its first row, through its thinking, to its answer.
        let id: String
        /// The answer that closed it; nil while it is still running.
        var answerID: String?
        /// Exactly the divider the transcript draws over the answer; nil for an answer with no work before it.
        var workedFor: String?
        /// nil while there is nothing to say yet: no thought, or only one from before the user's latest message. The
        /// brief shows Apple Music's "…" there (2026-10-25, with Astra).
        var narration: Paraphrase?
        /// Its place: its answer's place in the transcript, or last while it runs.
        let order: Int
    }
    /// The row the agent is on now, in the transcript's words ("Thinking", "Running `swift build`").
    struct Activity: Equatable {
        let itemID: String
        var parts: [TranscriptActivityPart]
    }
    enum State: Equatable, Sendable { case running, waiting, asking, failedRunning, failedStopped, done, idle }

    var goal: Goal?
    var inputs: [Input] = []
    var stretches: [Stretch] = []
    var activity: Activity?
    var state: State = .idle

    init() {}

    @MainActor
    init(_ c: Conversation, playful: Bool, lineLimit: Int? = nil) {
        self = c.summarySource.log(c, playful: playful, limit: lineLimit)
    }

    /// Reference reduction, retained for semantic equivalence checks.
    @MainActor
    init(uncached c: Conversation, playful: Bool) {
        let items = c.items
        let turnID = items.last(where: { $0.kind == .user })?.turnID ?? items.last?.turnID
        let turn = items.indices.filter { items[$0].turnID == turnID }
        // A stretch is the work rows up to an answer; the answer closes it. A message sent meanwhile joins the work.
        var start: Int?, thought: Int?, lastInput: Int?, worked = false, opener: String?
        for i in turn {
            let item = items[i]
            if item.rowKind == .user {
                let text = (item.text as NSString).substring(with: TranscriptPresentation.firstLine(of: item.text as NSString))
                if goal == nil { goal = Goal(itemID: item.id, text: text) } else { inputs.append(Input(itemID: item.id, text: text, order: i)) }
                // The stretch is named once, for what it came after; a message sent before its first row joins it.
                if opener == nil { opener = item.id }
                lastInput = i
            } else if TranscriptPresentation.isActivity(item.rowKind) {
                if start == nil { start = i }
                if item.rowKind == .reasoning { thought = i }
                worked = true
            } else if item.rowKind == .assistant {
                if start == nil { start = i }
                // An answer still being written leaves the stretch open.
                guard !TranscriptPresentation.presentation(for: item).isProgress else { continue }
                stretches.append(Stretch(id: "after:" + (opener ?? items[start ?? i].id), answerID: item.id,
                                         workedFor: worked ? TranscriptPresentation.workedFor(index: i, items: items) : nil,
                                         narration: MockBrief.paraphrase(item.text, of: item.id, playful: playful), order: i))
                start = nil; thought = nil; worked = false; opener = item.id
            }
        }
        // Still running, or stopped part way: what it has been thinking about, unless that was before the user's latest
        // word on it, which it has not answered yet.
        if start != nil || (c.running && opener != nil) {
            let fresh = thought.flatMap { t in (lastInput ?? -1) < t ? items[t] : nil }
            stretches.append(Stretch(id: "after:" + (opener ?? items[start ?? 0].id), answerID: nil, workedFor: nil,
                                     narration: fresh.map { MockBrief.paraphrase($0.text, of: $0.id, playful: playful) },
                                     order: Int.max))
        }
        if let i = turn.last(where: { TranscriptPresentation.isActivity(items[$0].rowKind) }) {
            let presentation = TranscriptPresentation.presentation(for: items[i])
            if presentation.isProgress {
                activity = Activity(itemID: items[i].id, parts: TranscriptPresentation.activityParts(items[i], presentation: presentation))
            }
        }
        let work = turn.filter { items[$0].rowKind != .user }
        // What needs the user comes before plain work: a question asked while it runs is still a question.
        state = if !c.approvals.isEmpty { .waiting }
            else if c.error == .stopped { .failedStopped }
            else if c.error == .running { .failedRunning }
            else if c.question != nil || c.userInput != nil { .asking }
            else if c.running { .running }
            else if !work.isEmpty { .done }
            else { .idle }
        // Nothing said yet and not working on it now (stopped, or waiting on the user): no line for it, and no "…"; the
        // note under the last line says why (2026-10-25 review r2: a stopped chat showed "Working" dots for ever).
        if let open = stretches.last, open.answerID == nil, open.narration == nil, state != .running, state != .failedRunning {
            stretches.removeLast()
        }
    }

    /// The stretch still running with nothing to say yet: the brief shows the "…" there.
    var waiting: Bool { stretches.last.map { $0.answerID == nil && $0.narration == nil } ?? false }

    /// The brief's lines, top to bottom: the goal, then the user's later messages and the stretches in the order they
    /// happened (a stretch at its answer, the running one last).
    enum Line: Equatable {
        case goal(Goal), input(Input), stretch(Stretch)
    }
    var lines: [Line] {
        let body = (inputs.map { (order: $0.order, line: Line.input($0)) } + stretches.map { (order: $0.order, line: Line.stretch($0)) })
            .sorted { $0.order < $1.order }
        return (goal.map { [Line.goal($0)] } ?? []) + body.map(\.line)
    }
}

/// A line of the second summary and where its words came from (2026-10-25 discussion). The summary model returns these
/// spans with its line: a word it kept, or one it put in place of a word of the source. Words with no span (the glue
/// between them) are its own. The prototype's spans come from MockBrief.
struct Paraphrase: Equatable {
    struct Span: Equatable {
        enum Kind: Equatable { case same, synonym }
        /// Characters of `text`.
        let range: Range<Int>
        let kind: Kind
        /// The transcript row the word came from, and the word as it reads there.
        let sourceID: String
        let source: String
    }
    var text: String
    var spans: [Span] = []
    /// The source's words the line retells, as the transcript shows them (markup gone): where the line flies from.
    var lead = ""

    /// The characters of `text` a span covers.
    func words(of span: Span) -> String {
        let chars = Array(text)
        guard span.range.lowerBound >= 0, span.range.upperBound <= chars.count else { return "" }
        return String(chars[span.range])
    }
}
