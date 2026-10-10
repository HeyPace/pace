//
//  PaceMorningTriageScheduler.swift
//  leanring-buddy
//
//  Proactive morning-brief scheduler. Fires once per weekday at a
//  user-configured local time, gated by `PaceRestraintGate`. When
//  the gate says "stay quiet" the brief is queued to a panel card
//  instead of being spoken; the user can replay or dismiss it from
//  the menu-bar panel.
//
//  Heavyweight source fetching (Calendar / Mail / Reminders / app
//  usage / watch journal) is injected via `inputsProvider` so the
//  scheduler itself stays unit-testable without EventKit, Mail
//  AppleScript, or live retrieval state.
//

import AppKit
import Combine
import Foundation

/// Per-fire context the scheduler hands to its source-fetching
/// closure. Lets the provider read its own clock and (in the live
/// app) hit the retriever / connectors to build typed inputs.
struct PaceMorningTriageContext: Equatable {
    let now: Date
}

@MainActor
final class PaceMorningTriageScheduler: ObservableObject {
    /// When the gate says "stay quiet" or "queue until idle" the brief
    /// is parked here instead of being spoken. The panel renders a
    /// card the user can play later or dismiss.
    @Published private(set) var pendingMorningBriefCard: String?

    /// Date of the most-recently delivered brief. Used to suppress
    /// re-fires on the same local day (a clock change or app restart
    /// shouldn't cause a second brief).
    @Published private(set) var lastBriefDeliveredAt: Date?

    private let retriever: PaceRetriever?
    private let ttsClient: any BuddyTTSClient
    private let inputsProvider: (PaceMorningTriageContext) -> PaceMorningBriefInputs
    private let restraintContextProvider: (PaceMorningTriageContext) -> PaceRestraintContext
    private let currentTimeProvider: () -> Date
    private let calendar: Calendar
    private let paceHistoryRecorder: ((_ userTranscript: String, _ assistantResponse: String, _ now: Date) -> Void)?

    private var hourOfDay: Int = 8
    private var minuteOfHour: Int = 30
    private var scheduledFireTimer: Timer?
    private var isRunning = false
    private var isDelivering = false
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults?
    private let storageKey: String

    private struct StoredState: Codable {
        let lastBriefDeliveredAt: Date?
        let pendingMorningBriefCard: String?
    }

    /// Designated initializer. The two providers are closures so live
    /// callers can wire retriever + connector state, while tests can
    /// hand back deterministic typed inputs.
    init(
        retriever: PaceRetriever?,
        ttsClient: any BuddyTTSClient,
        inputsProvider: @escaping (PaceMorningTriageContext) -> PaceMorningBriefInputs,
        restraintContextProvider: @escaping (PaceMorningTriageContext) -> PaceRestraintContext,
        currentTimeProvider: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        defaults: UserDefaults? = nil,
        storageKey: String = "pace.morningTriage.delivery",
        paceHistoryRecorder: ((_ userTranscript: String, _ assistantResponse: String, _ now: Date) -> Void)? = nil
    ) {
        self.retriever = retriever
        self.ttsClient = ttsClient
        self.inputsProvider = inputsProvider
        self.restraintContextProvider = restraintContextProvider
        self.currentTimeProvider = currentTimeProvider
        self.calendar = calendar
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults?.data(forKey: storageKey),
            let state = try? JSONDecoder().decode(StoredState.self, from: data)
        {
            lastBriefDeliveredAt = state.lastBriefDeliveredAt
            pendingMorningBriefCard = state.pendingMorningBriefCard
        }
        self.paceHistoryRecorder = paceHistoryRecorder
    }

    // MARK: - Configuration

    /// Updates the fire time. Re-arms the timer if it was already
    /// running so a change in Settings takes effect without restart.
    func setFireTime(hourOfDay: Int, minuteOfHour: Int) {
        self.hourOfDay = clampHour(hourOfDay)
        self.minuteOfHour = clampMinute(minuteOfHour)
        if scheduledFireTimer != nil {
            armTimerForNextFire()
        }
    }

    /// Arms the next weekday fire. Idempotent — calling twice keeps a
    /// single live timer. Should be called from `CompanionManager.start()`
    /// only when the user-facing toggle is on.
    func start() {
        isRunning = true
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconcileAfterWake() }
            }
        }
        Task { await reconcileAfterWake() }
    }

    func reconcileAfterWake() async {
        guard isRunning else { return }
        let now = currentTimeProvider()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let currentMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if currentMinute >= hourOfDay * 60 + minuteOfHour,
            !isWeekend(weekday: components.weekday ?? 1),
            lastBriefDeliveredAt.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true
        {
            await handleScheduledFire()
        } else {
            armTimerForNextFire()
        }
    }

    /// Stops future delivery; the readable brief remains until dismissed.
    func stop() {
        isRunning = false
        scheduledFireTimer?.invalidate()
        scheduledFireTimer = nil
    }

    /// User-initiated preview path. Always builds + speaks a brief,
    /// regardless of restraint or weekday/weekend. Useful for tuning
    /// the brief without waiting until tomorrow morning.
    func deliverNowForTesting() async {
        let now = currentTimeProvider()
        let inputs = inputsProvider(PaceMorningTriageContext(now: now))
        let briefText = PaceMorningBriefBuilder.build(inputs)
        pendingMorningBriefCard = briefText
        persistDeliveryState()
        recordPaceHistoryEntry(briefText: briefText, now: now)
        try? await ttsClient.speakText(briefText)
    }

    /// Clears the queued brief card after the user reads or dismisses it.
    func dismissPendingCard() {
        pendingMorningBriefCard = nil
        persistDeliveryState()
    }

    // MARK: - Fire logic (internal — exposed for tests)

    /// Single fire pass. Public so tests can drive the scheduler with
    /// an injected clock without needing a real Timer.
    func handleScheduledFire() async {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        let now = currentTimeProvider()

        // Same-day re-fire suppression. The timer should not re-arm
        // for the same calendar day, but a clock skew or duplicate
        // invocation must not produce two briefs.
        if let lastBriefDeliveredAt,
           calendar.isDate(lastBriefDeliveredAt, inSameDayAs: now) {
            armTimerForNextFire()
            return
        }

        // Weekends skip entirely per PRD scope.
        let weekday = calendar.component(.weekday, from: now)
        if isWeekend(weekday: weekday) {
            armTimerForNextFire()
            return
        }

        let restraintContext = restraintContextProvider(PaceMorningTriageContext(now: now))
        let restraintDecision = PaceRestraintGate.decide(restraintContext)

        let briefInputs = inputsProvider(PaceMorningTriageContext(now: now))
        let briefText = PaceMorningBriefBuilder.build(briefInputs)

        // Persist the readable result and day claim before awaiting speech. A restart
        // keeps the brief and cannot repeat delivery while the old speech is in flight.
        pendingMorningBriefCard = briefText
        lastBriefDeliveredAt = now
        persistDeliveryState()
        recordPaceHistoryEntry(briefText: briefText, now: now)
        switch restraintDecision {
        case .stayQuiet, .queueUntilIdle:
            break
        case .speak:
            try? await ttsClient.speakText(briefText)
        }

        armTimerForNextFire()
    }

    // MARK: - Timer scheduling

    /// Computes the next weekday fire date >= now using the configured
    /// hour/minute and re-arms `scheduledFireTimer`. Weekend matches
    /// are filtered in `handleScheduledFire` so the timer always lands
    /// on a real next slot.
    private func armTimerForNextFire() {
        guard isRunning else { return }
        scheduledFireTimer?.invalidate()
        let now = currentTimeProvider()
        guard let nextFireDate = nextFireDateAfter(now) else { return }
        let secondsUntilFire = nextFireDate.timeIntervalSince(now)
        guard secondsUntilFire > 0 else {
            // Defensive: should not happen because nextDate returns a
            // strictly-future date. If it does, retry in a second.
            scheduledFireTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    await self.handleScheduledFire()
                }
            }
            return
        }
        scheduledFireTimer = Timer.scheduledTimer(
            withTimeInterval: secondsUntilFire,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                await self.handleScheduledFire()
            }
        }
    }

    /// Returns the next Date at the configured hour/minute strictly
    /// after `referenceDate`. Skips weekends so the timer never lands
    /// on a Saturday or Sunday and waste a fire pass.
    func nextFireDateAfter(_ referenceDate: Date) -> Date? {
        var dateComponents = DateComponents()
        dateComponents.hour = hourOfDay
        dateComponents.minute = minuteOfHour
        dateComponents.second = 0

        var candidate = calendar.nextDate(
            after: referenceDate,
            matching: dateComponents,
            matchingPolicy: .nextTime
        )
        // Hard cap so a pathological calendar/locale can't produce an
        // infinite loop. 14 days is more than enough to skip a weekend.
        var safetyCounter = 0
        while let nextCandidate = candidate,
              isWeekend(weekday: calendar.component(.weekday, from: nextCandidate)),
              safetyCounter < 14 {
            candidate = calendar.nextDate(
                after: nextCandidate,
                matching: dateComponents,
                matchingPolicy: .nextTime
            )
            safetyCounter += 1
        }
        return candidate
    }

    private func persistDeliveryState() {
        guard
            let data = try? JSONEncoder().encode(
                StoredState(
                    lastBriefDeliveredAt: lastBriefDeliveredAt, pendingMorningBriefCard: pendingMorningBriefCard))
        else { return }
        defaults?.set(data, forKey: storageKey)
    }

    // MARK: - Helpers

    private func isWeekend(weekday: Int) -> Bool {
        // Calendar's weekday: 1 = Sunday, 7 = Saturday.
        return weekday == 1 || weekday == 7
    }

    private func clampHour(_ rawHour: Int) -> Int {
        return min(max(rawHour, 0), 23)
    }

    private func clampMinute(_ rawMinute: Int) -> Int {
        return min(max(rawMinute, 0), 59)
    }

    /// Writes the spoken brief into `paceHistory` so "what did you tell
    /// me this morning?" answers from local retrieval. The transcript
    /// side is a small canned marker so the document is searchable.
    private func recordPaceHistoryEntry(briefText: String, now: Date) {
        let trimmedBriefText = briefText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBriefText.isEmpty else { return }

        if let paceHistoryRecorder {
            paceHistoryRecorder("morning brief", trimmedBriefText, now)
            return
        }

        // Default path: write straight into the local retriever via the
        // existing recordPaceHistory method. Tests inject a recorder
        // closure so the live retriever is never touched.
        if let liveRetriever = retriever as? PaceLocalRetriever {
            liveRetriever.recordPaceHistory(
                userTranscript: "morning brief",
                assistantResponse: trimmedBriefText,
                now: now
            )
        }
    }
}
