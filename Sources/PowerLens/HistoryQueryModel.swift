import Combine
import Foundation

/// Shared publication rules for both history surfaces. Cancellation is not a
/// database failure; a superseded request cannot publish either data or errors.
@MainActor
final class HistoryQueryModel<Value: Equatable>: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(Value)
        case failed(previous: Value?)
    }

    @Published private(set) var state: State = .loading
    private var generation = 0

    var data: Value? {
        switch state {
        case .loading: nil
        case let .loaded(value): value
        case let .failed(previous): previous
        }
    }

    var hasReadFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    func load(clearBeforeLoad: Bool = false, using loader: @MainActor () async throws -> Value) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let request = generation
        let previous = clearBeforeLoad ? nil : data
        if clearBeforeLoad { state = .loading }
        do {
            let result = try await loader()
            guard !Task.isCancelled, generation == request else { return }
            state = .loaded(result)
        } catch {
            guard !Task.isCancelled, generation == request, !(error is CancellationError) else { return }
            state = .failed(previous: previous)
        }
    }
}
