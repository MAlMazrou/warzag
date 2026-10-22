import Foundation
import SteamHostKit
import Testing
import WarzagCore
@testable import WarzagApp

@MainActor
struct SteamCardTests {
    let fixture = AppFixture()

    private func startedModel() async -> AppModel {
        let model = fixture.makeModel()
        await model.launch()
        return model
    }

    @Test func everySignInPhaseHasACardState() {
        #expect(SteamCard.state(for: .notInstalled) == .notInstalled)
        #expect(SteamCard.state(for: .notRunning) == .off)
        #expect(SteamCard.state(for: .starting(firstRun: false)) == .starting)
        #expect(SteamCard.state(for: .signingIn(step: nil, since: nil)) == .signingIn)
        #expect(SteamCard.state(for: .needsCredentials(.ok)) == .signedOut)
        #expect(SteamCard.state(for: .needsCredentials(.other)) == .signedOut)
        #expect(SteamCard.state(for: .needsCredentials(.loggedInElsewhere)) == .signedOutElsewhere)
        #expect(SteamCard.state(for: .unknown) == .signedOut)
        #expect(SteamCard.state(for: .signedIn) == .signedIn)
    }

    @Test func theCardShowsTheSignedInAccount() async {
        let model = await startedModel()
        await model.refreshSteamCard()
        #expect(model.steamCard == SteamCard(state: .signedIn, name: "Test Tenno"))
    }

    @Test func turningSteamOffHidesTheCardAndNeverAsksSteam() async {
        let model = await startedModel()
        await model.refreshSteamCard()
        model.setUseSteam(false)
        #expect(await eventually { model.setup.loginMode == .warframeAccount })
        #expect(model.steamCard == nil)
        await model.refreshSteamCard()
        #expect(model.steamCard == nil)
        #expect(!model.steamHidingAllowed)
        model.steamLogIn()
        #expect(!fixture.steam.calls.contains("logIn"))
    }

    @Test func turningSteamBackOnShowsTheCardAgain() async {
        let model = await startedModel()
        model.setUseSteam(false)
        #expect(await eventually { model.setup.loginMode == .warframeAccount })
        model.setUseSteam(true)
        #expect(await eventually { model.setup.loginMode == .steam && model.steamCard?.state == .signedIn })
        #expect(model.steamHidingAllowed)
    }

    @Test func logInHidesSteamOnceSignedIn() async {
        fixture.steam.set {
            $0.signedIn = false
            $0.card = SteamCard(state: .signedOut)
        }
        let model = await startedModel()
        await model.refreshSteamCard()
        #expect(model.steamCard?.state == .signedOut)
        model.steamLogIn()
        #expect(await eventually { model.steamCard?.state == .signedIn && !model.steamLoggingIn })
        #expect(fixture.steam.calls.contains("logIn"))
        // Hiding follows the sign-in on its own task.
        #expect(await eventually { fixture.steam.calls.contains("hideSteam") })
    }

    @Test func logInLeavesSteamVisibleWhenKeepOutOfSightIsOff() async {
        fixture.steam.set {
            $0.signedIn = false
            $0.card = SteamCard(state: .signedOut)
        }
        let model = await startedModel()
        model.setKeepSteamOutOfSight(false)
        model.steamLogIn()
        #expect(await eventually { model.steamCard?.state == .signedIn && !model.steamLoggingIn })
        #expect(!fixture.steam.calls.contains("hideSteam"))
        #expect(!fixture.settings.settings.keepSteamOutOfSight)
    }

    @Test func logOutAsksSteam() async {
        let model = await startedModel()
        await model.refreshSteamCard()
        model.steamLogOut()
        #expect(await eventually { model.steamCard?.state == .signedOut })
        #expect(fixture.steam.calls.contains("logOut"))
    }

    @Test func keepSteamOutOfSightDefaultsToOnForOlderSettingsFiles() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"schema": 1}"#.utf8))
        #expect(decoded.keepSteamOutOfSight)
        var settings = AppSettings()
        settings.keepSteamOutOfSight = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!roundTrip.keepSteamOutOfSight)
    }
}
