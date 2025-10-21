import Foundation
import Network

final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.pingrrr.network.monitor")

    private(set) var isReachable: Bool = true
    private var listeners: [UUID: (Bool) -> Void] = [:]

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            if reachable != self.isReachable {
                self.isReachable = reachable
                self.notifyListeners(isReachable: reachable)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        listeners.removeAll()
    }

    func addListener(_ listener: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        listener(isReachable)
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func notifyListeners(isReachable: Bool) {
        listeners.values.forEach { listener in
            listener(isReachable)
        }
    }
}

