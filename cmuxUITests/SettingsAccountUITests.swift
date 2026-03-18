import AppKit
import Foundation
import XCTest

private func settingsAccountPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class SettingsAccountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSettingsSignInButtonAndSyntheticCallbackShowSignedInState() throws {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-auth-open-\(UUID().uuidString).txt")
        try? FileManager.default.removeItem(at: captureURL)

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_AUTH_STUB"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_AUTH_EMAIL"] = "uitest@cmux.dev"
        app.launchEnvironment["CMUX_UI_TEST_AUTH_TEAM_ID"] = "team_alpha"
        app.launchEnvironment["CMUX_UI_TEST_AUTH_TEAM_NAME"] = "Alpha"
        app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"] = captureURL.path
        app.launch()
        app.activate()

        XCTAssertTrue(
            settingsAccountPollUntil(timeout: 6.0) { app.windows.count >= 2 },
            "Expected Settings window to be visible"
        )

        let signInButton = requireElement(
            candidates: [
                app.buttons["settings.account.signIn"],
                app.buttons["Sign In in Browser"],
            ],
            timeout: 6.0,
            description: "settings account sign in button"
        )
        signInButton.click()

        let openedURL = try XCTUnwrap(waitForCapturedURL(at: captureURL, timeout: 6.0))
        XCTAssertEqual(openedURL.scheme, "https")
        XCTAssertEqual(openedURL.host, "cmux.dev")
        XCTAssertEqual(openedURL.path, "/handler/sign-in")

        let queryItems = URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let afterAuthReturnTo = queryItems.first(where: { $0.name == "after_auth_return_to" })?.value
        XCTAssertEqual(afterAuthReturnTo, "cmux-dev://auth-callback")

        let callbackURL = try XCTUnwrap(
            URL(
                string: "cmux-dev://auth-callback?stack_refresh=refresh-ui&stack_access=%5B%22refresh-ui%22,%22access-ui%22%5D"
            )
        )
        XCTAssertTrue(NSWorkspace.shared.open(callbackURL))

        let signOutButton = requireElement(
            candidates: [
                app.buttons["Sign Out"],
            ],
            timeout: 6.0,
            description: "settings account sign out button"
        )
        XCTAssertTrue(signOutButton.exists)
        XCTAssertTrue(app.staticTexts["uitest@cmux.dev"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 2.0))
    }

    private func waitForCapturedURL(at url: URL, timeout: TimeInterval) -> URL? {
        var capturedURL: URL?
        let found = settingsAccountPollUntil(timeout: timeout) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let parsed = URL(string: raw) else {
                return false
            }
            capturedURL = parsed
            return true
        }
        return found ? capturedURL : nil
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = settingsAccountPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        guard let element = firstExistingElement(candidates: candidates, timeout: timeout) else {
            XCTFail("Expected \(description) to exist")
            return candidates[0]
        }
        return element
    }
}
