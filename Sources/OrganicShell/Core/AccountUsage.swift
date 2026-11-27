import Foundation

/// Values from account/read, never a presentation account or a guessed plan.
struct AccountUsageIdentity: Equatable, Sendable {
    enum Source: String, Sendable { case unknown, live, prototype }
    let source: Source
    let name: String?
    let plan: String?
    static let unknown = Self(source: .unknown, name: nil, plan: nil)
    // DECISIONS #136: mock alone may use the existing prototype identity.
    static let prototype = Self(source: .prototype, name: "Louis L.", plan: "Plus")

    init(source: Source, name: String?, plan: String?) {
        self.source = source; self.name = Self.nonempty(name); self.plan = Self.nonempty(plan)
    }
    init(accountRead: JSONValue) {
        let account = accountRead["account"] ?? accountRead
        self.init(source: account.objectValue == nil ? .unknown : .live,
                  name: account["name"]?.stringValue ?? account["displayName"]?.stringValue ?? account["email"]?.stringValue,
                  plan: account["planType"]?.stringValue ?? account["plan"]?.stringValue)
    }
    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct AccountUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        enum Availability: String, Sendable { case reported, unknown }
        let availability: Availability
        /// Used fraction, never remaining; unknown has no numeric value.
        let used: Double?
        let windowMinutes: Int?
        let resetsAt: Date?
        let limitID: String?
        var reported: Bool { availability == .reported }
        var remaining: Double? { used.map { 1 - $0 } }
        var percentage: String { used.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        var description: String { reported ? percentage : "Not reported" }
        func title(fallback: String) -> String {
            guard let minutes = windowMinutes else { return fallback }
            if minutes % 10_080 == 0 { return "\(minutes / 10_080) week" + (minutes == 10_080 ? "" : "s") }
            if minutes % 1_440 == 0 { return "\(minutes / 1_440) day" + (minutes == 1_440 ? "" : "s") }
            if minutes % 60 == 0 { return "\(minutes / 60) hour" + (minutes == 60 ? "" : "s") }
            return "\(minutes) minutes"
        }
        init(reported: Bool, used: Double?, windowMinutes: Int?, resetsAt: Date?, limitID: String?) {
            let used = reported ? used.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } : nil
            self.availability = used == nil ? .unknown : .reported; self.used = used
            self.windowMinutes = windowMinutes.flatMap { $0 > 0 ? $0 : nil }
            self.resetsAt = resetsAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
            self.limitID = limitID
        }
    }
    let primary: Window
    let secondary: Window
    let identity: AccountUsageIdentity
    let version: UInt64
    var tightest: Window? {
        [primary, secondary].filter(\.reported).max { ($0.used ?? 0) < ($1.used ?? 0) }
    }
    var percentage: String { tightest?.percentage ?? "—" }
}

/// Window owners keep this token and cancel it on disposal. Cancellation is synchronous on the model actor.
@MainActor final class AccountUsageObservation {
    private var removal: (() -> Void)?
    init(_ removal: @escaping () -> Void) { self.removal = removal }
    func cancel() { let action = removal; removal = nil; action?() }
}
