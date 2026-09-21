import Foundation

/// Serialises reads of Anthropic's gauge and enforces the rate-limit policy.
///
/// Anthropic limits that endpoint hard, so:
/// - two reads are never closer than `minimumSpacing` (3 min by default);
/// - `refresh(force: true)` — the refresh button — jumps that spacing but never an
///   active 429 backoff (`backoffAfter429`, 15 min by default) nor the `forcedFloor`
///   that keeps a double-tap from hitting the endpoint twice;
/// - a refused call returns the cached snapshot when there is one, and throws
///   `QuotaError.throttled(until:)` only when nothing has ever been read;
/// - a failure never clears `lastSnapshot`: the panel keeps showing the last known
///   figures with their timestamp.
public actor QuotaService {
    private let credentials: any TokenProviding
    private let api: any QuotaFetching
    private let minimumSpacing: TimeInterval
    private let backoffAfter429: TimeInterval
    private let forcedFloor: TimeInterval
    private let clock: @Sendable () -> Date

    /// Last successful read. Survives every failure.
    public private(set) var lastSnapshot: GaugeSnapshot?
    /// Localized description of the last failure, `nil` after a success.
    public private(set) var lastError: String?
    /// Earliest moment a new network read is allowed.
    public private(set) var nextAllowedRefresh: Date = .distantPast
    /// True while `nextAllowedRefresh` comes from a 429, which even `force` respects.
    private var isInBackoff = false
    /// Last moment a network read was attempted, successful or not.
    private var lastAttempt: Date = .distantPast
    /// Coalesces concurrent callers onto the single in-flight read.
    private var inFlight: Task<GaugeSnapshot, Error>?

    public init(credentials: any TokenProviding,
                api: any QuotaFetching,
                minimumSpacing: TimeInterval = 180,
                backoffAfter429: TimeInterval = 900,
                forcedFloor: TimeInterval = 10,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.api = api
        self.minimumSpacing = minimumSpacing
        self.backoffAfter429 = backoffAfter429
        self.forcedFloor = forcedFloor
        self.clock = clock
    }

    @discardableResult
    public func refresh(force: Bool = false) async throws -> GaugeSnapshot {
        if let inFlight { return try await inFlight.value }

        let now = clock()
        if !isAllowed(force: force, now: now) {
            if let lastSnapshot { return lastSnapshot }
            throw QuotaError.throttled(until: nextAllowedRefresh)
        }

        lastAttempt = now
        let task = Task { try await self.performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// The refresh button jumps the 3-minute spacing, but never the 429 backoff and
    /// never the 10-second floor that a double-tap would otherwise cross.
    private func isAllowed(force: Bool, now: Date) -> Bool {
        if isInBackoff, now < nextAllowedRefresh { return false }
        if force { return now.timeIntervalSince(lastAttempt) >= forcedFloor }
        return now >= nextAllowedRefresh
    }

    private func performRefresh() async throws -> GaugeSnapshot {
        do {
            let token = try credentials.accessToken()
            let snapshot = try await api.fetch(token: token)
            lastSnapshot = snapshot
            lastError = nil
            isInBackoff = false
            nextAllowedRefresh = clock().addingTimeInterval(minimumSpacing)
            return snapshot
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case QuotaError.rateLimited(let retryAfter) = error {
                isInBackoff = true
                nextAllowedRefresh = clock()
                    .addingTimeInterval(max(retryAfter ?? 0, backoffAfter429))
            } else {
                isInBackoff = false
                nextAllowedRefresh = clock().addingTimeInterval(minimumSpacing)
            }
            throw error
        }
    }

    /// Cached snapshot without touching the network — for a view that just needs a value.
    public func snapshot() -> GaugeSnapshot? { lastSnapshot }
}
