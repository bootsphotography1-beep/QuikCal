import Foundation

// MARK: - Compact 4-page onboarding (2026-11-07 owner requirement)
//
// The core first-run flow is now FOUR pages: Welcome → Calendar → Voice
// setup → Ready. Appearance customization lives ONLY in Settings (which
// keeps the shared glass preview). The legacy 7-step enum is FROZEN — its
// raw values never change meaning — and every persisted legacy snapshot
// migrates through an explicit map, so no existing profile is ever reset,
// stranded, or forced to replay.

/// Legacy persisted step model (0.3.x). Raw values are FROZEN forever —
/// they only feed `OnboardingPageMigration` now. Never renumber, never
/// repurpose; new state lives on `OnboardingPage`.
public enum OnboardingStep: Int, Sendable, Codable, CaseIterable, Equatable, Comparable, Hashable {
    case welcome = 0
    case appearance = 1
    case calendarConnection = 2
    case speechPrivacy = 3
    case holdToTalk = 4
    case practiceDraft = 5
    case completion = 6

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .appearance: return "Appearance"
        case .calendarConnection: return "Calendar"
        case .speechPrivacy: return "Speech model"
        case .holdToTalk: return "Hold to talk"
        case .practiceDraft: return "Practice"
        case .completion: return "Ready"
        }
    }

    public var isSkippable: Bool {
        switch self {
        case .welcome, .completion: return false
        case .appearance, .calendarConnection, .speechPrivacy, .holdToTalk, .practiceDraft:
            return true
        }
    }

    public var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    public var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

/// Persisted onboarding flow version. Legacy snapshots (no version field)
/// are v1; the compact 4-page flow writes v2.
public enum OnboardingFlowVersion: Int, Sendable {
    /// Legacy 7-step flow (stepRaw 0–6 semantics).
    case legacySevenStep = 1
    /// Compact 4-page flow (pageRaw 0–3 semantics).
    case compactFourPage = 2
}

/// The compact first-run flow model (2026-11-07). Pages are the ONLY first-run
/// surfaces; appearance/glass customization is Settings-only.
///
/// 2026-11-07 owner correction pass: a DEDICATED Accessibility verification
/// page (`axPermission`, raw 4) sits between Calendar and Voice setup —
/// before any voice practice. Existing raw values 0–3 are FROZEN (persisted
/// v2 snapshots decode them unchanged); the new page takes raw 4, and the
/// FLOW ORDER is explicit (`flowOrder`), not raw arithmetic, so inserting
/// the page renumbers nothing.
public enum OnboardingPage: Int, Sendable, Codable, CaseIterable, Equatable, Comparable, Hashable {
    case welcome = 0
    case calendar = 1
    case voiceSetup = 2
    case ready = 3
    /// Dedicated Accessibility verification step (2026-11-07 owner
    /// correction): its own page BEFORE voice practice. Raw 4 — new
    /// writes only; no pre-existing snapshot ever stored 4.
    case axPermission = 4

    /// The first-run flow order (2026-11-07): raw values stay frozen, the
    /// WALK order is this explicit sequence. UI (step dots, step counter,
    /// resume-card progress) and `Comparable` derive from it.
    public static let flowOrder: [OnboardingPage] = [.welcome, .calendar, .axPermission, .voiceSetup, .ready]

    /// Position in `flowOrder` (0-based). Used instead of raw arithmetic
    /// everywhere the WALK order matters.
    public var flowIndex: Int {
        Self.flowOrder.firstIndex(of: self) ?? 0
    }

    public static func < (lhs: OnboardingPage, rhs: OnboardingPage) -> Bool {
        lhs.flowIndex < rhs.flowIndex
    }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .calendar: return "Calendar"
        case .voiceSetup: return "Voice setup"
        case .ready: return "Ready"
        case .axPermission: return "Accessibility"
        }
    }

    /// Welcome and Ready are the flow's anchors — never skippable. The
    /// capability pages (including the dedicated Accessibility step)
    /// stay explicitly skippable (typing always works).
    public var isSkippable: Bool {
        switch self {
        case .welcome, .ready: return false
        case .calendar, .voiceSetup, .axPermission: return true
        }
    }

    public var next: OnboardingPage? {
        Self.flowOrder.indices.contains(flowIndex + 1)
            ? Self.flowOrder[flowIndex + 1]
            : nil
    }

    public var previous: OnboardingPage? {
        flowIndex > 0 ? Self.flowOrder[flowIndex - 1] : nil
    }
}

/// Explicit, stable legacy→page migration (MANDATORY map, tested for every
/// legacy raw). Unknown legacy raws land safely on Welcome — never a crash,
/// never a strand. Completed profiles never see the flow again (the
/// completion gate is unchanged and separate from this map).
public enum OnboardingPageMigration: Sendable {
    /// The explicit old→new map:
    /// `welcome(0)→welcome`, `appearance(1)→welcome` (Appearance lives in
    /// Settings now), `calendarConnection(2)→calendar`,
    /// `speechPrivacy(3)/holdToTalk(4)/practiceDraft(5)→voiceSetup`
    /// (merged: models + one permission card + Fn practice on ONE page),
    /// `completion(6)→ready`.
    public static func page(forLegacyStepRaw raw: Int) -> OnboardingPage {
        guard let step = OnboardingStep(rawValue: raw) else { return .welcome }
        switch step {
        case .welcome, .appearance:
            return .welcome
        case .calendarConnection:
            return .calendar
        case .speechPrivacy, .holdToTalk, .practiceDraft:
            return .voiceSetup
        case .completion:
            return .ready
        }
    }

    /// Legacy skipped steps migrate to their pages (deduplicated; the
    /// three merged voice pages collapse into one skip).
    public static func skippedPages(forLegacySkippedRaws raws: [Int]) -> Set<OnboardingPage> {
        Set(raws.compactMap { OnboardingStep(rawValue: $0) }.map { page(forLegacyStepRaw: $0.rawValue) })
    }
}

/// Persisted resume cursor for an incomplete first-run (or interrupted replay).
/// Cleared on finish and when Settings starts a fresh replay.
///
/// v2 snapshots carry `versionRaw` + `pageRaw` + `skippedPageRaws`. Legacy
/// snapshots (no version) decode through the explicit migration map — old
/// installs resume on the correct page without any reset.
public struct OnboardingResumeSnapshot: Sendable, Equatable, Codable {
    /// Flow version (nil = legacy v1 payload).
    public var versionRaw: Int?
    /// v2+: current page raw. v1 payloads leave this nil.
    public var pageRaw: Int?
    /// v2+: skipped page raws. v1 payloads leave this nil.
    public var skippedPageRaws: [Int]?
    /// LEGACY v1 field — frozen semantics, only read when version < 2.
    public var stepRaw: Int
    /// LEGACY v1 field — frozen semantics, only read when version < 2.
    public var skippedRaws: [Int]
    public var practiceNote: String
    /// Hold-to-talk guide sub-phase (optional for older snapshots).
    public var holdGuidePhaseRaw: Int?
    public var holdPracticeConfirmed: Bool?
    public var accessibilityRecheckRaw: String?

    public init(
        page: OnboardingPage = .welcome,
        skipped: Set<OnboardingPage> = [],
        practiceNote: String = "",
        holdGuide: HoldToTalkGuideState = HoldToTalkGuideState()
    ) {
        self.versionRaw = OnboardingFlowVersion.compactFourPage.rawValue
        self.pageRaw = page.rawValue
        self.skippedPageRaws = skipped.map(\.rawValue).sorted()
        self.stepRaw = OnboardingStep.welcome.rawValue
        self.skippedRaws = []
        self.practiceNote = practiceNote
        self.holdGuidePhaseRaw = holdGuide.phase.rawValue
        self.holdPracticeConfirmed = holdGuide.practiceConfirmed
        self.accessibilityRecheckRaw = holdGuide.accessibilityRecheck.rawValue
    }

    public var page: OnboardingPage {
        if let versionRaw,
           OnboardingFlowVersion(rawValue: versionRaw) == .compactFourPage {
            if let pageRaw, let page = OnboardingPage(rawValue: pageRaw) {
                return page
            }
            // v2 marker with a corrupt/unknown page raw → safe Welcome.
            return .welcome
        }
        // Legacy v1 payload (or missing version): explicit migration map.
        return OnboardingPageMigration.page(forLegacyStepRaw: stepRaw)
    }

    public var skipped: Set<OnboardingPage> {
        if let versionRaw,
           OnboardingFlowVersion(rawValue: versionRaw) == .compactFourPage {
            if let skippedPageRaws {
                return Set(skippedPageRaws.compactMap(OnboardingPage.init(rawValue:)))
            }
            return []
        }
        return OnboardingPageMigration.skippedPages(forLegacySkippedRaws: skippedRaws)
    }

    public var holdGuide: HoldToTalkGuideState {
        var guide = HoldToTalkGuideState()
        if let holdGuidePhaseRaw, let phase = HoldToTalkGuidePhase(rawValue: holdGuidePhaseRaw) {
            guide.phase = phase
        }
        guide.practiceConfirmed = holdPracticeConfirmed ?? false
        if let accessibilityRecheckRaw,
           let status = HoldPermissionRecheck(rawValue: accessibilityRecheckRaw) {
            guide.accessibilityRecheck = status
        }
        return guide
    }

    public func makeSession(completed: Bool = false) -> OnboardingSessionState {
        OnboardingSessionState(
            page: page,
            skipped: skipped,
            practiceNote: practiceNote,
            completed: completed,
            holdGuide: holdGuide
        )
    }
}

public struct OnboardingSessionState: Sendable, Equatable {
    public var page: OnboardingPage
    public var skipped: Set<OnboardingPage>
    public var practiceNote: String
    public var completed: Bool
    public var holdGuide: HoldToTalkGuideState

    public init(
        page: OnboardingPage = .welcome,
        skipped: Set<OnboardingPage> = [],
        practiceNote: String = "",
        completed: Bool = false,
        holdGuide: HoldToTalkGuideState = HoldToTalkGuideState()
    ) {
        self.page = page
        self.skipped = skipped
        self.practiceNote = practiceNote
        self.completed = completed
        self.holdGuide = holdGuide
    }

    public var resumeSnapshot: OnboardingResumeSnapshot {
        OnboardingResumeSnapshot(
            page: page,
            skipped: skipped,
            practiceNote: practiceNote,
            holdGuide: holdGuide
        )
    }

    public mutating func goNext() {
        guard let next = page.next else {
            completed = true
            return
        }
        page = next
        if page == .ready {
            completed = false
        }
    }

    public mutating func goBack() {
        if let previous = page.previous {
            page = previous
        }
    }

    public mutating func skipCurrent() {
        guard page.isSkippable else { return }
        skipped.insert(page)
        goNext()
    }

    public mutating func finish() {
        page = .ready
        completed = true
    }

    /// Fresh journey for Settings replay (preserves other prefs elsewhere).
    public static func freshReplay() -> OnboardingSessionState {
        OnboardingSessionState()
    }
}

/// Encode/decode resume snapshots for UserDefaults without stranding on
/// unknown pages. Legacy payloads migrate; unknown raws land on Welcome.
public enum OnboardingResumeCodec: Sendable {
    public static func encode(_ snapshot: OnboardingResumeSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    public static func decode(_ data: Data?) -> OnboardingResumeSnapshot? {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode(OnboardingResumeSnapshot.self, from: data) else {
            return nil
        }
        // Unknown / out-of-range page (v2) or step (v1) raws → welcome
        // rather than crash or strand. The computed `page`/`skipped`
        // accessors already apply this (legacy via migration, v2 via the
        // safe-Welcome fallback), so decode only rejects structurally
        // invalid payloads here.
        return decoded
    }
}

/// Practice draft never writes — parse-only preview for onboarding.
public enum PracticeDraftPolicy: Sendable {
    public static func allowsCalendarWrite(isPracticeMode: Bool) -> Bool {
        !isPracticeMode
    }

    /// Explicit gate used by UI / tests: practice path must refuse EventKit/Google writes.
    public static func practiceParseMayWriteToCalendar() -> Bool { false }
}
