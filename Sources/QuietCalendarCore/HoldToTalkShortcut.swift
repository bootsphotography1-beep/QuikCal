import Foundation

/// Pure hold-to-talk lifecycle. Does not log typed content — only down/up of the
/// configured modifier (or equivalent). Recording starts on press and stops on release;
/// callers then parse → confirm (never silent calendar write).
public enum HoldToTalkPhase: String, Sendable, Equatable {
    case idle
    case holding
    case releasing
}

public enum HoldToTalkTransition: String, Sendable, Equatable {
    case ignore
    case beginHold
    case endHold
}

public struct HoldToTalkStateMachine: Sendable, Equatable {
    public private(set) var phase: HoldToTalkPhase
    public var shortcut: HoldToTalkShortcutKind
    /// When false, presses are ignored (permissions missing or feature disabled).
    public var monitoringEnabled: Bool

    public init(
        phase: HoldToTalkPhase = .idle,
        shortcut: HoldToTalkShortcutKind = .fn,
        monitoringEnabled: Bool = false
    ) {
        self.phase = phase
        self.shortcut = shortcut
        self.monitoringEnabled = monitoringEnabled
    }

    public mutating func handle(modifierMatchesShortcut: Bool, isKeyDown: Bool) -> HoldToTalkTransition {
        guard monitoringEnabled else { return .ignore }
        if isKeyDown {
            guard modifierMatchesShortcut else { return .ignore }
            guard phase == .idle else { return .ignore }
            phase = .holding
            return .beginHold
        } else {
            // Key up / flag cleared for our shortcut.
            guard phase == .holding else { return .ignore }
            if modifierMatchesShortcut {
                // Still holding another conflicting interpretation — keep holding.
                return .ignore
            }
            phase = .releasing
            let end: HoldToTalkTransition = .endHold
            phase = .idle
            return end
        }
    }

    public mutating func forceIdle() {
        phase = .idle
    }
}

/// Maps CG/NS modifier flag bits (as abstract booleans) to shortcut matching.
public enum HoldToTalkMatcher: Sendable {
    public static func matches(
        shortcut: HoldToTalkShortcutKind,
        fnDown: Bool,
        optionDown: Bool,
        commandDown: Bool,
        controlDown: Bool
    ) -> Bool {
        switch shortcut {
        case .fn: return fnDown
        case .option: return optionDown
        case .command: return commandDown
        case .control: return controlDown
        }
    }
}
