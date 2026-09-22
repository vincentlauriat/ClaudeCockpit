import XCTest
@testable import UsageKit

final class UsageAggregatorTests: XCTestCase {
    private let calendar = TestClock.calendar
    /// Wednesday 2026-09-23, 12:00 UTC — ISO week 39 runs Monday the 21st to Sunday the 27th.
    private let now = TestClock.now
    private let home = URL(fileURLWithPath: "/Users/test")

    private let projA = "/Users/test/DevApps/ProjA"
    private let projB = "/Users/test/DevApps/ProjB"

    /// Four turns whose costs are round numbers under the default rates:
    /// 3.00 + 25.00 today, 1.00 yesterday, 3.00 last Tuesday.
    private var events: [UsageEvent] {
        [
            EventFactory.make(
                id: "e1", sessionId: "sess-1", model: "claude-sonnet-5",
                timestamp: TestClock.date("2026-09-23T10:00:00Z"), cwd: projA,
                inputTokens: 1_000_000),
            EventFactory.make(
                id: "e2", sessionId: "sess-1", model: "claude-opus-5",
                timestamp: TestClock.date("2026-09-23T11:00:00Z"), cwd: projA,
                outputTokens: 1_000_000,
                attributionAgent: "executor", attributionSkill: "autopilot"),
            EventFactory.make(
                id: "e3", sessionId: "sess-2", model: "claude-haiku-4-5-20251001",
                timestamp: TestClock.date("2026-09-22T10:00:00Z"), cwd: projB,
                inputTokens: 1_000_000),
            EventFactory.make(
                id: "e4", sessionId: "sess-3", model: "claude-sonnet-5",
                timestamp: TestClock.date("2026-09-15T10:00:00Z"), cwd: projA,
                inputTokens: 1_000_000),
        ]
    }

    private func snapshot(
        _ range: DateRangeFilter = .all,
        models: Set<ModelFamily>? = nil,
        project: String? = nil,
        sessionInfo: [String: SessionInfo] = [:]
    ) -> UsageSnapshot {
        UsageAggregator.snapshot(
            events: events,
            sessionInfo: sessionInfo,
            filters: UsageFilters(models: models, project: project, range: range),
            pricing: .default,
            now: now,
            calendar: calendar,
            home: home)
    }

    func testTotalsOverEverything() {
        let snap = snapshot()
        XCTAssertEqual(snap.totals.turnCount, 4)
        XCTAssertEqual(snap.totals.sessionCount, 3)
        XCTAssertEqual(snap.totals.inputTokens, 3_000_000)
        XCTAssertEqual(snap.totals.outputTokens, 1_000_000)
        XCTAssertEqual(snap.totals.cacheReadTokens, 0)
        XCTAssertEqual(snap.totals.cacheCreationTokens, 0)
        XCTAssertEqual(snap.totals.totalTokens, 4_000_000)
        XCTAssertEqual(snap.totals.estimatedCostUSD, 32.0, accuracy: 1e-9)
        XCTAssertEqual(snap.filteredEventCount, 4)
    }

    /// The snapshot only exposes the filtered *count*, so the ordering every series and
    /// breakdown depends on is asserted against the helper that produces it.
    func testFilteredEventsAreSortedOldestFirst() {
        let ranged = UsageAggregator.rangedEvents(
            events, range: .all, now: now, calendar: calendar)
        XCTAssertEqual(ranged.map(\.id), ["e4", "e3", "e1", "e2"], "sorted oldest first")

        let lastWeek = UsageAggregator.rangedEvents(
            events, range: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(lastWeek.map(\.id), ["e3", "e1", "e2"], "the 15th falls outside the window")
    }

    func testCostAndTokensTodayIgnoreTheRangeFilter() {
        for range in DateRangeFilter.allCases {
            let snap = snapshot(range)
            XCTAssertEqual(snap.costTodayUSD, 28.0, accuracy: 1e-9, "range \(range.rawValue)")
            XCTAssertEqual(snap.tokensToday, 2_000_000, "range \(range.rawValue)")
        }
        // …but they do respect the project filter.
        XCTAssertEqual(snapshot(.all, project: projB).costTodayUSD, 0, accuracy: 1e-9)
    }

    func testRangeFilterSelectsEvents() {
        XCTAssertEqual(snapshot(.today).totals.turnCount, 2)
        XCTAssertEqual(snapshot(.today).totals.estimatedCostUSD, 28.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot(.last7Days).totals.turnCount, 3, "the 15th falls outside the window")
        XCTAssertEqual(snapshot(.last30Days).totals.turnCount, 4)
        XCTAssertEqual(snapshot(.thisMonth).totals.turnCount, 4)
        XCTAssertEqual(snapshot(.prevMonth).totals.turnCount, 0)
    }

    func testModelAndProjectFilters() {
        XCTAssertEqual(snapshot(.all, models: [.opus]).totals.turnCount, 1)
        XCTAssertEqual(snapshot(.all, models: [.sonnet, .haiku]).totals.turnCount, 3)
        XCTAssertEqual(snapshot(.all, models: []).totals.turnCount, 4, "an empty set means every family")
        XCTAssertEqual(snapshot(.all, project: projA).totals.turnCount, 3)
        XCTAssertEqual(snapshot(.all, project: projB).totals.estimatedCostUSD, 1.0, accuracy: 1e-9)
    }

    func testDailySeriesCarriesTokensAndCost() {
        let snap = snapshot()
        XCTAssertEqual(snap.daily.count, 3)
        XCTAssertEqual(snap.daily.map(\.day), [
            TestClock.date("2026-09-15T00:00:00Z"),
            TestClock.date("2026-09-22T00:00:00Z"),
            TestClock.date("2026-09-23T00:00:00Z"),
        ])
        let today = snap.daily[2]
        XCTAssertEqual(today.inputTokens, 1_000_000)
        XCTAssertEqual(today.outputTokens, 1_000_000)
        XCTAssertEqual(today.total, 2_000_000)
        XCTAssertEqual(today.estimatedCostUSD, 28.0, accuracy: 1e-9)
        XCTAssertEqual(UsageSeries.output.value(from: today), 1_000_000)
    }

    func testCostByFamilyIsOrderedByTierAndSkipsUnusedFamilies() {
        let rows = snapshot().costByFamily
        XCTAssertEqual(rows.map(\.family), [.opus, .sonnet, .haiku])
        XCTAssertEqual(rows[0].costUSD, 25.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].costUSD, 6.0, accuracy: 1e-9)
        XCTAssertEqual(rows[2].costUSD, 1.0, accuracy: 1e-9)
    }

    func testBreakdownRowsPerDimension() {
        let snap = snapshot()

        let byProject = snap.breakdown(for: .project)
        XCTAssertEqual(byProject.map(\.label), ["~/DevApps/ProjA", "~/DevApps/ProjB"])
        XCTAssertEqual(byProject[0].turnCount, 3)
        XCTAssertEqual(byProject[0].totalTokens, 3_000_000)
        XCTAssertEqual(byProject[0].estimatedCostUSD, 31.0, accuracy: 1e-9)

        let byAgent = snap.breakdown(for: .agent)
        XCTAssertEqual(byAgent.map(\.label), ["executor", BreakdownDimension.directLabel])
        XCTAssertEqual(byAgent[0].estimatedCostUSD, 25.0, accuracy: 1e-9)
        XCTAssertEqual(byAgent[1].turnCount, 3)

        let bySkill = snap.breakdown(for: .skill)
        XCTAssertEqual(bySkill.map(\.label), ["autopilot", BreakdownDimension.directLabel])
    }

    func testSessionsUseScannedTitlesAndSortNewestFirst() {
        let info = ["sess-1": SessionInfo(title: "Portage d'UsageKit", cwd: projA)]
        let snap = snapshot(.all, sessionInfo: info)

        XCTAssertEqual(snap.sessions.map(\.id), ["sess-1", "sess-2", "sess-3"])
        let first = snap.sessions[0]
        XCTAssertEqual(first.displayName, "Portage d'UsageKit")
        XCTAssertEqual(first.turnCount, 2)
        XCTAssertEqual(first.modelsUsed, ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(first.totalTokens, 2_000_000)
        XCTAssertEqual(first.estimatedCostUSD, 28.0, accuracy: 1e-9)
        XCTAssertEqual(first.firstSeen, TestClock.date("2026-09-23T10:00:00Z"))
        XCTAssertEqual(first.lastSeen, TestClock.date("2026-09-23T11:00:00Z"))
        // No scanned info: the session id's first 8 characters stand in.
        XCTAssertEqual(snap.sessions[1].displayName, "sess-2")
    }

    func testWeeklySessionsThisWeekVersusLastWeek() {
        let snap = snapshot()
        // ISO week 39 opens Monday the 21st: yesterday is index 1, today index 2.
        XCTAssertEqual(snap.sessionsThisWeekByWeekday, [0, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(snap.sessionsThisWeekTotal, 2)
        // Week 38: only Tuesday the 15th.
        XCTAssertEqual(snap.sessionsLastWeekByWeekday, [0, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(snap.sessionsLastWeekTotal, 1)
        XCTAssertEqual(snap.costThisWeekUSD, 29.0, accuracy: 1e-9)
        XCTAssertEqual(snap.costLastWeekUSD, 3.0, accuracy: 1e-9)
    }

    func testHourlyTodayVersusYesterday() {
        let snap = snapshot()
        XCTAssertEqual(snap.hourlyToday.count, 24)
        XCTAssertEqual(snap.hourlyYesterday.count, 24)
        XCTAssertEqual(snap.hourlyToday[10].estimatedCostUSD, 3.0, accuracy: 1e-9)
        XCTAssertEqual(snap.hourlyToday[11].estimatedCostUSD, 25.0, accuracy: 1e-9)
        XCTAssertEqual(snap.hourlyToday[9].estimatedCostUSD, 0, accuracy: 1e-9)
        XCTAssertEqual(snap.hourlyYesterday[10].inputTokens, 1_000_000)
    }

    func testInsightsFlagTheWeekOverWeekCostJump() throws {
        let snap = snapshot()
        let insight = try XCTUnwrap(snap.insights.first)
        XCTAssertEqual(insight.level, .critical)
        guard case .costUp(let fraction) = insight.kind else {
            return XCTFail("expected costUp, got \(insight.kind)")
        }
        // 29.00 versus 3.00 last week.
        XCTAssertEqual(fraction, 26.0 / 3.0, accuracy: 1e-9)
        XCTAssertTrue(insight.text.hasPrefix("Cost is up"))
    }

    func testInsightsFlagUnpricedModelsAndFallBackToNoNotableChange() {
        let unknown = [EventFactory.make(
            model: "gpt-mystery", timestamp: TestClock.date("2026-09-23T10:00:00Z"), cwd: projA,
            inputTokens: 1_000)]
        let snap = UsageAggregator.snapshot(
            events: unknown, filters: UsageFilters(range: .all), pricing: .default,
            now: now, calendar: calendar, home: home)

        XCTAssertEqual(snap.insights.count, 1)
        XCTAssertEqual(snap.insights[0].level, .warning)
        XCTAssertEqual(snap.insights[0].kind, .unpricedModel("gpt-mystery"))

        let empty = UsageAggregator.snapshot(
            events: [], filters: UsageFilters(range: .all), pricing: .default,
            now: now, calendar: calendar, home: home)
        XCTAssertEqual(empty.insights.map(\.kind), [.noNotableChange])
        XCTAssertEqual(empty.totals.turnCount, 0)
    }

    func testPickerOptionsComeFromTheWholeEventSet() {
        // A narrow filter must not shrink the pickers, otherwise you could never widen it back.
        let snap = snapshot(.today, models: [.opus], project: projA)
        XCTAssertEqual(snap.availableProjects, [projA, projB])
        XCTAssertEqual(snap.availableModels, ["claude-haiku-4-5-20251001", "claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(snap.availableModelFamilies, [.opus, .sonnet, .haiku])
    }

    func testMonthlyAndYearlyRollups() {
        let snap = snapshot()
        XCTAssertEqual(snap.monthly.map(\.monthStart), [TestClock.date("2026-09-01T00:00:00Z")])
        XCTAssertEqual(snap.monthly[0].estimatedCostUSD, 32.0, accuracy: 1e-9)
        XCTAssertEqual(snap.yearly.map(\.year), [2026])
        XCTAssertEqual(snap.yearly[0].sessionCount, 3)
    }

    func testEmptySnapshotIsUsableAsAnInitialState() {
        let snap = UsageSnapshot.empty(now: now)
        XCTAssertEqual(snap.totals.turnCount, 0)
        XCTAssertTrue(snap.daily.isEmpty)
        XCTAssertTrue(snap.sessions.isEmpty)
        XCTAssertTrue(snap.breakdown(for: .project).isEmpty)
        XCTAssertEqual(snap.costTodayUSD, 0, accuracy: 1e-9)
    }
}
