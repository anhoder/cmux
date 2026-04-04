import XCTest
import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

final class TerminalCmdClickUITests: XCTestCase {
    private struct TerminalGeometry {
        let surfaceId: String
        let windowFrame: CGRect
        let terminalFrameInWindow: CGRect
    }

    private var socketPath = ""
    private var hoverDiagnosticsPath = ""
    private var openCapturePath = ""
    private var fixtureDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        socketPath = "/tmp/cmux-ui-test-terminal-cmd-click-\(UUID().uuidString).sock"
        hoverDiagnosticsPath = "/tmp/cmux-ui-test-terminal-cmd-hover-\(UUID().uuidString).json"
        openCapturePath = "/tmp/cmux-ui-test-terminal-open-\(UUID().uuidString).log"
        fixtureDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-terminal-cmd-click-\(UUID().uuidString)", isDirectory: true)

        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        super.tearDown()
    }

    func testHoldingCommandAfterSelectionSuppresssCommandHoverDispatch() throws {
        let app = launchApp(captureOpenPaths: false, captureHoverDiagnostics: true)
        let geometry = try waitForFocusedTerminalGeometry()
        let token = try seedTerminalFixture(
            surfaceId: geometry.surfaceId,
            fileName: "Cmd Click Fixture.txt"
        )

        XCTAssertTrue(
            waitForTerminalText(surfaceId: geometry.surfaceId, contains: token, timeout: 8.0),
            "Expected terminal to render the escaped path fixture before selecting it"
        )

        let dragStart = accessibilityPoint(in: geometry, xFromLeft: 48, yFromTop: 54)
        let dragEnd = accessibilityPoint(in: geometry, xFromLeft: 240, yFromTop: 54)
        guard let dragSession = beginMouseDrag(fromAccessibilityPoint: dragStart) else {
            XCTFail("Expected raw drag session for terminal selection")
            return
        }
        continueMouseDrag(dragSession, toAccessibilityPoint: dragEnd)
        endMouseDrag(dragSession, atAccessibilityPoint: dragEnd)

        holdCommandKey()

        guard let diagnostics = waitForHoverDiagnostics(timeout: 5.0) else {
            XCTFail("Expected hover diagnostics after holding Command with an active selection")
            return
        }

        let suppressedCount = diagnostics["suppressed_command_hover_count"] as? Int ?? 0
        let forwardedCount = diagnostics["forwarded_command_hover_count"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(
            suppressedCount,
            1,
            "Expected holding Command after selecting text to suppress command hover dispatch. diagnostics=\(diagnostics)"
        )
        XCTAssertEqual(
            forwardedCount,
            0,
            "Expected no command-modified hover dispatch to reach Ghostty while selection is active. diagnostics=\(diagnostics)"
        )

        app.terminate()
    }

    func testCmdClickEscapedPathWithSpacesOpensResolvedFile() throws {
        let app = launchApp(captureOpenPaths: true, captureHoverDiagnostics: false)
        let geometry = try waitForFocusedTerminalGeometry()
        let fileName = "Cmd Click Fixture.txt"
        let token = try seedTerminalFixture(surfaceId: geometry.surfaceId, fileName: fileName)
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path

        XCTAssertTrue(
            waitForTerminalText(surfaceId: geometry.surfaceId, contains: token, timeout: 8.0),
            "Expected terminal to render the escaped path fixture before cmd-clicking it"
        )

        let clickPoint = accessibilityPoint(in: geometry, xFromLeft: 140, yFromTop: 54)
        commandClick(atAccessibilityPoint: clickPoint)

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
            XCTFail("Expected cmd-click capture log after clicking escaped path")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the escaped-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
        )

        app.terminate()
    }

    private func launchApp(captureOpenPaths: Bool, captureHoverDiagnostics: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_TAG"] = "ui-test-terminal-cmd-click"
        if captureOpenPaths {
            app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = openCapturePath
        }
        if captureHoverDiagnostics {
            app.launchEnvironment["CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"] = hoverDiagnosticsPath
        }
        launchAndEnsureForeground(app)

        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")
        _ = socketCommand("activate_app")
        app.activate()
        return app
    }

    @discardableResult
    private func seedTerminalFixture(surfaceId: String, fileName: String) throws -> String {
        let fileURL = fixtureDirectoryURL.appendingPathComponent(fileName)
        try "fixture\n".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            socketCommand("focus_surface \(surfaceId)"),
            "OK",
            "Expected focused terminal before seeding fixture text"
        )
        XCTAssertEqual(
            socketCommand("report_pwd \(fixtureDirectoryURL.path) --panel=\(surfaceId)"),
            "OK",
            "Expected report_pwd to update the terminal cwd for fallback path resolution"
        )
        XCTAssertTrue(
            waitForCondition(timeout: 5.0) { self.socketCommand("is_terminal_focused \(surfaceId)") == "true" },
            "Expected terminal surface to remain focused before UI input"
        )

        let escapedToken = fileName.replacingOccurrences(of: " ", with: "\\ ")
        let blockLine = "\(escapedToken) \(escapedToken) \(escapedToken)"
        let shellCommand = "clear\rfor i in 1 2 3 4 5 6 7 8; do printf '%s\\n' '\(blockLine)'; done\r"

        guard let envelope = socketJSON(
            method: "surface.send_text",
            params: ["surface_id": surfaceId, "text": shellCommand]
        ),
        let ok = envelope["ok"] as? Bool,
        ok else {
            XCTFail("Expected surface.send_text to seed terminal content. response=\(String(describing: socketJSON(method: "surface.send_text", params: ["surface_id": surfaceId, "text": shellCommand])))")
            return escapedToken
        }

        return escapedToken
    }

    private func waitForFocusedTerminalGeometry(timeout: TimeInterval = 12.0) throws -> TerminalGeometry {
        var geometry: TerminalGeometry?
        let matched = waitForCondition(timeout: timeout) {
            guard let envelope = self.socketJSON(method: "debug.terminals", params: [:]),
                  let ok = envelope["ok"] as? Bool,
                  ok,
                  let result = envelope["result"] as? [String: Any],
                  let terminals = result["terminals"] as? [[String: Any]],
                  let terminal = terminals.first(where: { ($0["surface_focused"] as? Bool) == true }) ?? terminals.first,
                  let surfaceId = terminal["surface_id"] as? String,
                  let windowFrame = Self.rect(from: terminal["window_frame"]),
                  let terminalFrame = Self.rect(from: terminal["hosted_view_frame_in_window"]),
                  (terminal["hosted_view_in_window"] as? Bool) == true else {
                return false
            }

            geometry = TerminalGeometry(
                surfaceId: surfaceId,
                windowFrame: windowFrame,
                terminalFrameInWindow: terminalFrame
            )
            return true
        }

        guard matched, let geometry else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected focused terminal geometry from debug.terminals"
            ])
        }
        return geometry
    }

    private func waitForTerminalText(surfaceId: String, contains token: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let text = self.readTerminalText(surfaceId: surfaceId) else { return false }
            return text.contains(token)
        }
    }

    private func readTerminalText(surfaceId: String) -> String? {
        guard let response = socketCommand("read_terminal_text \(surfaceId)"),
              response.hasPrefix("OK ") else {
            return nil
        }
        let encoded = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func waitForCapturedOpenPaths(timeout: TimeInterval) -> [String]? {
        var openedPaths: [String]?
        let matched = waitForCondition(timeout: timeout) {
            guard let contents = try? String(contentsOfFile: self.openCapturePath, encoding: .utf8) else {
                return false
            }
            let lines = contents
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return false }
            openedPaths = lines
            return true
        }
        return matched ? openedPaths : nil
    }

    private func waitForHoverDiagnostics(timeout: TimeInterval) -> [String: Any]? {
        var diagnostics: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.hoverDiagnosticsPath)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["suppressed_command_hover_count"] as? Int ?? 0) > 0 else {
                return false
            }
            diagnostics = object
            return true
        }
        return matched ? diagnostics : nil
    }

    private func accessibilityPoint(
        in geometry: TerminalGeometry,
        xFromLeft: CGFloat,
        yFromTop: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: geometry.windowFrame.minX + geometry.terminalFrameInWindow.minX + xFromLeft,
            y: geometry.windowFrame.minY + geometry.terminalFrameInWindow.maxY - yFromTop
        )
    }

    private func commandClick(atAccessibilityPoint point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            XCTFail("Expected CGEventSource for cmd-click")
            return
        }

        let quartzPoint = quartzPoint(fromAccessibilityPoint: point)
        postKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        postMouseEvent(type: .mouseMoved, at: quartzPoint, flags: .maskCommand, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        postMouseEvent(type: .leftMouseDown, at: quartzPoint, flags: .maskCommand, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        postMouseEvent(type: .leftMouseUp, at: quartzPoint, flags: .maskCommand, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        postKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.10))
    }

    private func holdCommandKey(duration: TimeInterval = 0.25) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            XCTFail("Expected CGEventSource for Command-key hold")
            return
        }

        postKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        postKeyEvent(keyCode: CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.10))
    }

    private struct RawMouseDragSession {
        let source: CGEventSource
    }

    private func beginMouseDrag(
        fromAccessibilityPoint start: CGPoint,
        holdDuration: TimeInterval = 0.15
    ) -> RawMouseDragSession? {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            XCTFail("Expected CGEventSource for raw mouse drag")
            return nil
        }

        let quartzStart = quartzPoint(fromAccessibilityPoint: start)
        postMouseEvent(type: .mouseMoved, at: quartzStart, flags: [], source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        postMouseEvent(type: .leftMouseDown, at: quartzStart, flags: [], source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(holdDuration))
        return RawMouseDragSession(source: source)
    }

    private func continueMouseDrag(
        _ session: RawMouseDragSession,
        toAccessibilityPoint end: CGPoint,
        steps: Int = 20,
        dragDuration: TimeInterval = 0.30
    ) {
        let currentLocation = NSEvent.mouseLocation
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        let clampedSteps = max(2, steps)

        for step in 1...clampedSteps {
            let progress = CGFloat(step) / CGFloat(clampedSteps)
            let point = CGPoint(
                x: currentLocation.x + ((quartzEnd.x - currentLocation.x) * progress),
                y: currentLocation.y + ((quartzEnd.y - currentLocation.y) * progress)
            )
            postMouseEvent(type: .leftMouseDragged, at: point, flags: [], source: session.source)
            RunLoop.current.run(until: Date().addingTimeInterval(dragDuration / Double(clampedSteps)))
        }
    }

    private func endMouseDrag(_ session: RawMouseDragSession, atAccessibilityPoint end: CGPoint) {
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        postMouseEvent(type: .leftMouseUp, at: quartzEnd, flags: [], source: session.source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.20))
    }

    private func postMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        flags: CGEventFlags,
        source: CGEventSource
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            XCTFail("Expected CGEvent for mouse type \(type.rawValue) at \(point)")
            return
        }

        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource
    ) {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            XCTFail("Expected keyboard CGEvent for keyCode \(keyCode)")
            return
        }

        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func quartzPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
        XCTAssertFalse(desktopBounds.isNull, "Expected at least one screen when converting raw mouse coordinates")
        guard !desktopBounds.isNull else { return point }
        return CGPoint(x: point.x, y: desktopBounds.maxY - point.y)
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
        }
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless GUI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }
        if app.state == .runningBackground { return }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request)
    }

    private static func rect(from value: Any?) -> CGRect? {
        guard let payload = value as? [String: Any],
              let x = payload["x"] as? Double,
              let y = payload["y"] as? Double,
              let width = payload["width"] as? Double,
              let height = payload["height"] as? Double else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, addrLen)
                }
            }
            guard connectResult == 0 else { return nil }

            Self.configureSocketTimeouts(fd, timeout: responseTimeout)

            guard let outbound = (line + "\n").data(using: .utf8) else { return nil }
            let writeResult = outbound.withUnsafeBytes { bytes in
                send(fd, bytes.baseAddress, bytes.count, 0)
            }
            guard writeResult >= 0 else { return nil }

            var accumulator = ""
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let readCount = recv(fd, &buffer, buffer.count, 0)
                if readCount <= 0 { break }
                if let chunk = String(bytes: buffer[0..<readCount], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newlineIndex = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newlineIndex])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func configureSocketTimeouts(_ fd: Int32, timeout: TimeInterval) {
            var socketTimeout = timeval(
                tv_sec: Int(timeout.rounded(.down)),
                tv_usec: Int32(((timeout - floor(timeout)) * 1_000_000).rounded())
            )
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }
        }
    }
}
