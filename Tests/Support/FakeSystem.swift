import Foundation
import os

struct FakeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A pretend system for the Settings model: saved address, Keychain, login item, Paperless and GitHub.
/// It records what the model asked it to do, in order, in `log`.
final class FakeSystem: Sendable {
    struct State: Sendable {
        var address = ""
        var token: String?
        var loginStatus = SettingsModel.LoginItemStatus.disabled
        var loginNeedsApproval = false
        var loginError: String?
        var saveTokenSucceeds = true
        var deleteTokenSucceeds = true
        var connection: Result<(version: String?, documents: Int?), PaperlessError> =
            .success((version: "3.4.2", documents: 189))
        var updates: Result<UpdateChecker.Outcome, UpdateChecker.CheckError> = .success(.upToDate)
        var log: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Changes the pretend system between steps of a test, never while the model is running.
    func set(_ change: (inout State) -> Void) {
        var copy = current
        change(&copy)
        let updated = copy
        state.withLock { $0 = updated }
    }
    var current: State { state.withLock { $0 } }
    var log: [String] { current.log }

    func services() -> SettingsModel.Services {
        SettingsModel.Services(
            storedAddress: { self.current.address },
            storeAddress: { value in
                self.state.withLock { $0.address = value; $0.log.append("store address \(value)") }
            },
            hasToken: { self.current.token != nil },
            saveToken: { token in
                self.state.withLock { state in
                    state.log.append("save token")
                    if state.saveTokenSucceeds { state.token = token }
                    return state.saveTokenSucceeds
                }
            },
            deleteToken: {
                self.state.withLock { state in
                    state.log.append("delete token")
                    if state.deleteTokenSucceeds { state.token = nil }
                    return state.deleteTokenSucceeds
                }
            },
            checkConnection: {
                self.state.withLock { $0.log.append("check connection") }
                return try self.current.connection.get()
            },
            checkForUpdates: { version in
                self.state.withLock { $0.log.append("check updates \(version)") }
                return try self.current.updates.get()
            },
            loginItemStatus: { self.current.loginStatus },
            setLaunchAtLogin: { enabled in
                try self.state.withLock { state in
                    state.log.append("login \(enabled)")
                    if let message = state.loginError { throw FakeError(message: message) }
                    state.loginStatus = enabled ? (state.loginNeedsApproval ? .requiresApproval : .enabled) : .disabled
                }
            }
        )
    }
}
