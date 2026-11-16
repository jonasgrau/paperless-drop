import Foundation
import Testing

@MainActor
@Suite("SettingsModel", .timeLimit(.minutes(1)))
struct SettingsModelTests {
    let system = FakeSystem()

    func makeModel(_ setup: (inout FakeSystem.State) -> Void = { _ in }) -> SettingsModel {
        system.set(setup)
        return SettingsModel(services: system.services(), version: AppVersion(short: "0.1.2", build: "4"))
    }

    // MARK: - Start

    @Test("starts from the saved address and login state; the token is looked up separately")
    func startup() async {
        let model = makeModel {
            $0.address = "https://saved.example.com"
            $0.loginStatus = .enabled
            $0.token = "t"
        }

        #expect(model.address == "https://saved.example.com")
        #expect(model.launchAtLogin == true)
        #expect(model.hasToken == false) // not asked yet: creating the model never touches the Keychain
        await model.refreshTokenState()
        #expect(model.hasToken == true)
    }

    @Test("a starting address can be given, for previews")
    func givenAddress() {
        system.set { $0.address = "https://saved.example.com" }
        let model = SettingsModel(services: system.services(), version: AppVersion(short: "1", build: "1"),
                                  address: "https://other.example.com")

        #expect(model.address == "https://other.example.com")
    }

    // MARK: - Save

    nonisolated static let badAddresses: [(String, ServerAddress.Problem)] = [
        ("", .empty),
        ("   ", .empty),
        ("http://paperless.example.com", .insecure),
        ("ftp://paperless.example.com", .notAnAddress),
    ]

    @Test("an unusable address is refused before anything is saved or sent", arguments: badAddresses)
    func refusesBadAddress(input: String, problem: ServerAddress.Problem) async {
        let model = makeModel()
        model.address = input
        model.token = "secret"

        await model.save()

        #expect(model.feedback == .error(problem.message))
        #expect(system.log.isEmpty)
        #expect(model.token == "secret") // what was typed is kept
    }

    @Test("a pasted address is cleaned up, shown cleaned up, and saved")
    func normalizesAndStores() async {
        let model = makeModel { $0.token = "t" }
        model.address = "  paperless.example.com/dashboard "

        await model.save()

        #expect(model.address == "https://paperless.example.com")
        #expect(system.current.address == "https://paperless.example.com")
    }

    @Test("a typed token is saved trimmed, the field is cleared, and the connection is checked, in that order")
    func savesTokenThenChecks() async {
        let model = makeModel()
        model.address = "https://paperless.example.com"
        model.token = "  secret \n"

        await model.save()

        #expect(system.log == ["store address https://paperless.example.com", "save token", "check connection"])
        #expect(system.current.token == "secret")
        #expect(model.token.isEmpty)
        #expect(model.hasToken == true)
        #expect(model.feedback == .success("Connected – Paperless 3.4.2 · 189 documents"))
    }

    @Test("with a token already stored, an empty token field leaves it alone")
    func keepsStoredToken() async {
        let model = makeModel { $0.address = "https://paperless.example.com"; $0.token = "old" }
        await model.refreshTokenState()

        await model.save()

        #expect(system.log == ["store address https://paperless.example.com", "check connection"])
        #expect(system.current.token == "old")
        #expect(model.feedback == .success("Connected – Paperless 3.4.2 · 189 documents"))
    }

    @Test("without any token the address is saved and the missing token is named")
    func missingToken() async {
        let model = makeModel { $0.address = "https://paperless.example.com" }

        await model.save()

        #expect(model.feedback == .error("Address saved – the API token is still missing"))
        #expect(system.log == ["store address https://paperless.example.com"]) // no connection attempt
    }

    @Test("when the Keychain refuses, the file is not checked and the typed token stays")
    func keychainRefuses() async {
        let model = makeModel {
            $0.address = "https://paperless.example.com"
            $0.saveTokenSucceeds = false
        }
        model.token = "secret"

        await model.save()

        #expect(model.feedback == .error("Couldn't save the token to the Keychain"))
        #expect(model.token == "secret")
        #expect(model.hasToken == false)
        #expect(system.log.contains("check connection") == false)
    }

    @Test("a failed check shows the error's own message", arguments: [
        PaperlessError.unauthorized,
        PaperlessError.unreachable("The Internet connection appears to be offline."),
        PaperlessError.insecureAddress,
        PaperlessError.badResponse,
    ])
    func failedCheck(error: PaperlessError) async {
        let model = makeModel { $0.address = "https://paperless.example.com"; $0.token = "t"; $0.connection = .failure(error) }
        await model.refreshTokenState()

        await model.save()

        #expect(model.feedback == .error(error.errorDescription ?? ""))
    }

    nonisolated static let connectionTexts: [(String?, Int?, String)] = [
        (nil, nil, "Connected"),
        ("3.4.2", nil, "Connected – Paperless 3.4.2"),
        (nil, 5, "Connected · 5 documents"),
        ("3.4.2", 189, "Connected – Paperless 3.4.2 · 189 documents"),
    ]

    @Test("the success message uses what the server told", arguments: connectionTexts)
    func successText(version: String?, documents: Int?, expected: String) async {
        let model = makeModel {
            $0.address = "https://paperless.example.com"
            $0.token = "t"
            $0.connection = .success((version: version, documents: documents))
        }
        await model.refreshTokenState()

        await model.save()

        #expect(model.feedback == .success(expected))
    }

    // MARK: - Remove the token

    @Test("removing the token deletes it, clears the field and says so")
    func removesToken() async {
        let model = makeModel { $0.token = "t" }
        await model.refreshTokenState()
        model.token = "half typed"

        await model.removeToken()

        #expect(system.current.token == nil)
        #expect(model.hasToken == false)
        #expect(model.token.isEmpty)
        #expect(model.feedback == .info("Token removed from the Keychain"))
    }

    @Test("when the Keychain refuses to remove it, the token still counts as stored")
    func removeRefused() async {
        let model = makeModel { $0.token = "t"; $0.deleteTokenSucceeds = false }
        await model.refreshTokenState()

        await model.removeToken()

        #expect(model.hasToken == true)
        #expect(model.feedback == .error("Couldn't remove the token from the Keychain"))
    }

    // MARK: - Open at login

    @Test("switching on registers the login item")
    func loginOn() {
        let model = makeModel()

        model.setLaunchAtLogin(true)

        #expect(model.launchAtLogin == true)
        #expect(model.loginNote == nil)
        #expect(system.log == ["login true"])
    }

    @Test("when macOS wants approval, the switch stays on and a note says where")
    func loginNeedsApproval() {
        let model = makeModel { $0.loginNeedsApproval = true }

        model.setLaunchAtLogin(true)

        #expect(model.launchAtLogin == true)
        #expect(model.loginNote == "Allow Paperless Drop in System Settings → General → Login Items")
    }

    @Test("when registering fails, the switch goes back to what the system says")
    func loginFails() {
        let model = makeModel { $0.loginError = "Operation not permitted" }

        model.setLaunchAtLogin(true)

        #expect(model.launchAtLogin == false)
        #expect(model.loginNote == "Couldn't change the login item: Operation not permitted")
    }

    @Test("switching off unregisters, and the old note disappears")
    func loginOff() {
        let model = makeModel { $0.loginNeedsApproval = true }
        model.setLaunchAtLogin(true)
        system.set { $0.loginStatus = .enabled }

        model.setLaunchAtLogin(false)

        #expect(model.launchAtLogin == false)
        #expect(model.loginNote == nil)
    }

    @Test("setting the same value again does nothing")
    func loginUnchanged() {
        let model = makeModel()

        model.setLaunchAtLogin(false)

        #expect(system.log.isEmpty)
    }

    // MARK: - Updates

    @Test("the update check reports each outcome", arguments: [
        (Result<UpdateChecker.Outcome, UpdateChecker.CheckError>.success(.upToDate), SettingsModel.UpdateStatus.upToDate),
        (.success(.available(.init(version: "0.2.0", url: URL(string: "https://github.com/x/y/releases/tag/v0.2.0")!))),
         .available(.init(version: "0.2.0", url: URL(string: "https://github.com/x/y/releases/tag/v0.2.0")!))),
        (.failure(.rateLimited), .failed(UpdateChecker.CheckError.rateLimited.errorDescription ?? "")),
    ])
    func updateOutcomes(result: Result<UpdateChecker.Outcome, UpdateChecker.CheckError>, expected: SettingsModel.UpdateStatus) async {
        let model = makeModel { $0.updates = result }

        await model.checkForUpdates()

        #expect(model.updateStatus == expected)
        #expect(system.log == ["check updates 0.1.2"]) // asked with the running version
        #expect(model.isCheckingForUpdates == false)
    }

    // MARK: - Small things

    @Test("the site link exists only for a usable address")
    func siteURL() {
        let model = makeModel()

        model.address = "paperless.example.com/dashboard"
        #expect(model.siteURL == URL(string: "https://paperless.example.com"))

        model.address = "http://paperless.example.com"
        #expect(model.siteURL == nil)

        model.address = ""
        #expect(model.siteURL == nil)
    }

    nonisolated static let feedbackAnnouncements: [(SettingsModel.Feedback, String?)] = [
        (.checking, nil),
        (.success("Connected"), "Connected"),
        (.error("Invalid API token – check Settings"), "Invalid API token – check Settings"),
        (.info("Token removed from the Keychain"), "Token removed from the Keychain"),
    ]

    @Test("VoiceOver announces results but not the running check", arguments: feedbackAnnouncements)
    func feedbackAnnouncement(feedback: SettingsModel.Feedback, spoken: String?) {
        #expect(feedback.announcement == spoken)
    }

    nonisolated static let updateAnnouncements: [(SettingsModel.UpdateStatus, String?)] = [
        (.checking, nil),
        (.upToDate, "You're up to date."),
        (.available(.init(version: "0.2.0", url: URL(string: "https://github.com/x/y")!)), "Version 0.2.0 is available."),
        (.failed("Can't reach GitHub"), "Can't reach GitHub"),
    ]

    @Test("update results are announced too", arguments: updateAnnouncements)
    func updateAnnouncement(status: SettingsModel.UpdateStatus, spoken: String?) {
        #expect(status.announcement == spoken)
    }
}
