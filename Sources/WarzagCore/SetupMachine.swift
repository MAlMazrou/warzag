import Foundation

public enum StepOutcome: Sendable, Equatable {
    case completed
    /// Only the user can unblock this step.
    case needsUser(UserAction)
    /// The step needs the network, which is down.
    case offline
    case failed(SetupFailure)
}

/// Everything that can change setup state. Steps report through `stepStarted`/`stepFinished`; the UI, timers and
/// the network monitor send the rest.
public enum SetupEvent: Sendable, Equatable {
    case stepStarted(SetupStep)
    case stepFinished(SetupStep, StepOutcome)
    /// The user pressed Retry, or an automatic retry came due.
    case retry(SetupTrack)
    /// Every offline track resumes.
    case networkAvailable
    /// The user did (or approved) what a waiting step asked for.
    case userResponded(UserAction)
    /// "Not Now" on Move to Applications.
    case skipRelocation
    /// Sign in with Steam, or with a Warframe account (which skips the Steam track).
    case setLoginMode(LoginMode)
}

/// The first-run state machine as pure functions: no I/O, no clocks, so every transition is unit-testable and
/// the async driver (`SetupOrchestrator`) stays a thin loop around it.
public enum SetupMachine {
    /// Transient failures are retried automatically this many times before the row waits for the user.
    public static let automaticRetryLimit = 3

    public static func reduce(_ state: SetupState, _ event: SetupEvent) -> SetupState {
        var state = state
        switch event {
        case .stepStarted(let step):
            var track = state[step.track]
            guard track.step == step, track.status == .pending, dependenciesMet(step, in: state) else { break }
            track.status = .running
            state[step.track] = track

        case .stepFinished(let step, let outcome):
            var track = state[step.track]
            // Results of steps that were superseded (a skip, a mode switch) are stale and dropped.
            guard track.step == step, track.status == .running else { break }
            switch outcome {
            case .completed:
                track = advance(past: step)
            case .needsUser(let action):
                track.status = .waitingForUser
                track.action = action
            case .offline:
                track.status = .offline
            case .failed(let failure):
                track.status = .failed
                track.failure = failure
                track.attempts += 1
            }
            state[step.track] = track

        case .retry(let trackID):
            var track = state[trackID]
            guard [.failed, .offline, .waitingForUser].contains(track.status) else { break }
            track = rearm(track)
            state[trackID] = track

        case .networkAvailable:
            for trackID in SetupTrack.allCases where state[trackID].status == .offline {
                state[trackID] = rearm(state[trackID])
            }

        case .userResponded(let action):
            if action.isApproval, !state.approvals.contains(action) {
                state.approvals.append(action)
                state.approvals.sort { $0.rawValue < $1.rawValue }
            }
            for trackID in SetupTrack.allCases {
                let track = state[trackID]
                if track.status == .waitingForUser, track.action == action {
                    state[trackID] = rearm(track)
                }
            }

        case .skipRelocation:
            let track = state.preflight
            guard track.step == .checkLocation, track.status != .running else { break }
            state.preflight = advance(past: .checkLocation)

        case .setLoginMode(let mode):
            state.loginMode = mode
            switch mode {
            case .warframeAccount:
                if state.steam.status != .done { state.steam = TrackState(step: state.steam.step, status: .skipped) }
            case .steam:
                if state.steam.status == .skipped { state.steam = TrackState(step: state.steam.step) }
            }
        }
        return state
    }

    /// Steps that may start now: the current step of every pending track whose dependencies are met.
    public static func runnableSteps(in state: SetupState) -> [SetupStep] {
        SetupTrack.allCases.compactMap { trackID in
            let track = state[trackID]
            return track.status == .pending && dependenciesMet(track.step, in: state) ? track.step : nil
        }
    }

    public static func dependenciesMet(_ step: SetupStep, in state: SetupState) -> Bool {
        switch step.track {
        case .preflight:
            return true
        case .engine:
            return state.preflight.status == .done
        case .steam:
            guard state.preflight.status == .done else { return false }
            // Ownership is asked of Steam by wz-steamprobe.exe, a Windows program that needs the engine's prefix.
            return step != .checkLicense || state.engine.status == .done
        case .game:
            guard state.preflight.status == .done else { return false }
            // DE's installer can download early; everything after it runs inside the prefix the engine creates.
            return step == .downloadInstaller || state.engine.status == .done
        }
    }

    /// The state to continue from after Warzag restarts: whatever was in flight or waiting is checked again
    /// (the user may have signed in to Steam, or the network may be back, while Warzag was closed).
    public static func resumed(_ state: SetupState) -> SetupState {
        var state = state
        for trackID in SetupTrack.allCases {
            let track = state[trackID]
            switch track.status {
            case .running, .waitingForUser, .offline, .failed:
                state[trackID] = TrackState(step: track.step)
            case .pending, .done, .skipped:
                break
            }
        }
        return state
    }

    /// When a failed track should retry by itself: 2 s, 8 s, 32 s after transient failures, then never.
    public static func automaticRetryDelay(for track: TrackState) -> Duration? {
        guard track.status == .failed, track.failure?.kind == .transient,
              (1...automaticRetryLimit).contains(track.attempts) else { return nil }
        return .seconds(2 << (2 * (track.attempts - 1)))
    }

    private static func advance(past step: SetupStep) -> TrackState {
        guard let next = step.next else { return TrackState(step: step, status: .done) }
        return TrackState(step: next)
    }

    /// Back to pending on the same step, keeping the failure count so automatic retries back off.
    private static func rearm(_ track: TrackState) -> TrackState {
        TrackState(step: track.step, attempts: track.attempts)
    }
}
