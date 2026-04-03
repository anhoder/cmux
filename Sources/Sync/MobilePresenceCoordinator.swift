import AppKit
import Combine
import Foundation

@MainActor
final class MobilePresenceCoordinator {
    private let heartbeatPublisher: MobileHeartbeatPublisher?
    private let authChangePublisher: AnyPublisher<Void, Never>?

    private var tabManager: TabManager?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var publishInFlight = false
    private var needsRepublish = false

    @MainActor
    init(
        authProvider: (any MachineSessionAuthProvider)? = nil,
        authChangePublisher: AnyPublisher<Void, Never>? = nil,
        heartbeatPublisher: MobileHeartbeatPublisher? = nil
    ) {
        if let authProvider {
            self.heartbeatPublisher = heartbeatPublisher ?? MobileHeartbeatPublisher(authProvider: authProvider)
        } else {
            self.heartbeatPublisher = heartbeatPublisher
        }
        self.authChangePublisher = authChangePublisher
    }

    func start(tabManager: TabManager) {
        guard heartbeatPublisher != nil else { return }
        guard self.tabManager !== tabManager else { return }
        self.tabManager = tabManager
        cancellables.removeAll()
        workspaceCancellables.removeAll()

        authChangePublisher?
            .sink { [weak self] in
                self?.schedulePublish()
            }
            .store(in: &cancellables)

        tabManager.$tabs
            .sink { [weak self] workspaces in
                self?.rewireWorkspaceObservers(workspaces: workspaces)
                self?.schedulePublish()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.schedulePublish()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.schedulePublish()
            }
            .store(in: &cancellables)

        startHeartbeatTimerIfNeeded()
    }

    func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        cancellables.removeAll()
        workspaceCancellables.removeAll()
    }

    private func rewireWorkspaceObservers(workspaces: [Workspace]) {
        workspaceCancellables.removeAll()
        for workspace in workspaces {
            workspaceCancellables[workspace.id] = workspace.objectWillChange
                .sink { [weak self] _ in
                    self?.schedulePublish()
                }
        }
    }

    private func startHeartbeatTimerIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.schedulePublish()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func schedulePublish() {
        if publishInFlight {
            needsRepublish = true
            return
        }
        publishInFlight = true
        Task { [weak self] in
            await self?.runPublishLoop()
        }
    }

    private func runPublishLoop() async {
        guard let heartbeatPublisher else {
            publishInFlight = false
            return
        }
        while true {
            needsRepublish = false
            do {
                try await heartbeatPublisher.publishNow()
            } catch {}
            if needsRepublish {
                continue
            }
            publishInFlight = false
            break
        }
    }
}
