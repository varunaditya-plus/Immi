enum LoadingPhase<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

extension LoadingPhase {
    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isLoading: Bool { if case .loading = self { return true }; return false }

    var value: Value? { if case let .loaded(v) = self { return v }; return nil }
    var errorMessage: String? { if case let .failed(m) = self { return m }; return nil }
}
