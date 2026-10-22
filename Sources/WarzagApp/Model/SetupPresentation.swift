import Foundation
import WarzagCore

/// How one step row looks.
enum StepDisplayStatus: Equatable, Sendable {
    case done
    case active
    /// Waiting for the player: a card above says what to do.
    case needsYou
    case failed
    /// Paused until the internet is back.
    case offline
    /// Not started yet (or waiting for another track).
    case pending
    /// Signing in with a Warframe account instead of Steam.
    case skipped
}

/// Something the player has to do, shown as a card above the tracks.
enum AttentionItem: Equatable, Sendable, Identifiable {
    /// A step waits for the player (`TrackStatus.waitingForUser`).
    case action(SetupTrack, UserAction)
    /// A running step needs the player in another app's window (DE's EULA).
    case live(SetupTrack, Attention)

    var id: String {
        switch self {
        case .action(let track, let action): "action-\(track.rawValue)-\(action.rawValue)"
        case .live(let track, let attention): "live-\(track.rawValue)-\(attention)"
        }
    }

    var track: SetupTrack {
        switch self {
        case .action(let track, _), .live(let track, _): track
        }
    }
}

/// Pure functions from setup state (plus live activity) to what the setup screen shows.
enum SetupPresentation {
    /// The tracks shown as sections, in order; preflight ("This Mac") comes first.
    static let tracks: [SetupTrack] = [.preflight, .engine, .steam, .game]

    static func status(of step: SetupStep, in state: SetupState, activity: TrackActivity?) -> StepDisplayStatus {
        let track = state[step.track]
        if track.status == .skipped { return state.isCompleted(step) ? .done : .skipped }
        if state.isCompleted(step) { return .done }
        guard track.step == step else { return .pending }
        switch track.status {
        case .running: return activity?.attention != nil ? .needsYou : .active
        case .waitingForUser: return .needsYou
        case .failed: return .failed
        case .offline: return .offline
        case .pending: return .pending
        case .done: return .done
        case .skipped: return .skipped
        }
    }

    /// The track's own row: its current step's status, or done/skipped for the whole track.
    static func status(of track: SetupTrack, in state: SetupState, activity: TrackActivity?) -> StepDisplayStatus {
        let current = state[track]
        switch current.status {
        case .done: return .done
        case .skipped: return .skipped
        default: return status(of: current.step, in: state, activity: activity)
        }
    }

    /// Cards for everything that waits for the player, in track order.
    static func attentionItems(in state: SetupState, activities: [SetupTrack: TrackActivity]) -> [AttentionItem] {
        tracks.compactMap { track in
            let current = state[track]
            if current.status == .waitingForUser, let action = current.action { return .action(track, action) }
            if current.status == .running, let attention = activities[track]?.attention { return .live(track, attention) }
            return nil
        }
    }

    /// Done steps over all steps that count (skipped Steam steps do not).
    static func overallFraction(_ state: SetupState) -> Double {
        var done = 0
        var total = 0
        for track in tracks {
            if state[track].status == .skipped { continue }
            for step in track.steps {
                total += 1
                if state.isCompleted(step) { done += 1 }
            }
        }
        return total == 0 ? 0 : Double(done) / Double(total)
    }

    /// Tracks whose step failed (each gets a card with Try Again).
    static func failedTracks(in state: SetupState) -> [SetupTrack] {
        tracks.filter { state[$0].status == .failed }
    }
}
