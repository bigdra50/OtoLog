import Foundation
@testable import OtoLogCore

/// SessionEvent を購読して蓄積する。session.events は単一消費者の想定なので1つだけ attach する。
final class EventCollector: @unchecked Sendable {
    // MARK: Internal

    var events: [SessionEvent] {
        lock.withLock { _events }
    }

    func attach(to stream: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    func detach() {
        task?.cancel()
    }

    // MARK: Private

    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    private var task: Task<Void, Never>?

    private func append(_ event: SessionEvent) {
        lock.withLock { _events.append(event) }
    }
}
