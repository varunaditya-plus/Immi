import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class PeopleStateDriver {
    var fetch: () async throws -> [PersonDTO] = { [] }
    var rename: (String, String) async throws -> Void = { _, _ in }
    var hide: (String, Bool) async throws -> Void = { _, _ in }
    var fetchDetail: (String) async throws -> PersonDTO = { makePeopleStatePerson($0) }
    private(set) var fetchCount = 0
    private(set) var renames: [(id: String, name: String)] = []
    private(set) var hiddenChanges: [(id: String, value: Bool)] = []
    private(set) var detailIDs: [String] = []

    func all() async throws -> [PersonDTO] {
        fetchCount += 1
        return try await fetch()
    }

    func rename(_ id: String, to name: String) async throws {
        renames.append((id, name))
        try await rename(id, name)
    }

    func setHidden(_ id: String, to value: Bool) async throws {
        hiddenChanges.append((id, value))
        try await hide(id, value)
    }

    func detail(_ id: String) async throws -> PersonDTO {
        detailIDs.append(id)
        return try await fetchDetail(id)
    }
}

final class PeopleStateRepository: PeopleRepository {
    private let driver: PeopleStateDriver

    @MainActor
    init(driver: PeopleStateDriver) {
        self.driver = driver
        super.init(api: APIClient(session: MockSessionManager()))
    }

    override func all(size: Int? = nil) async throws -> [PersonDTO] {
        XCTAssertNil(size, "The People list requests the full result")
        return try await driver.all()
    }

    override func rename(_ id: String, to name: String) async throws {
        try await driver.rename(id, to: name)
    }

    override func setHidden(_ id: String, to value: Bool) async throws {
        try await driver.setHidden(id, to: value)
    }

    override func detail(_ id: String) async throws -> PersonDTO {
        try await driver.detail(id)
    }
}

@MainActor
final class PeopleStateGate<Value> {
    let started = XCTestExpectation(description: "A People request is held")
    private var continuations: [CheckedContinuation<Value, Error>] = []
    private var result: Result<Value, Error>?
    private var didStart = false

    func value() async throws -> Value {
        if !didStart { didStart = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func complete(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let current = continuations
        continuations.removeAll()
        for continuation in current { continuation.resume(with: result) }
    }
}

func makePeopleStatePerson(_ id: String = "person", name: String = "Original", hidden: Bool = false) -> PersonDTO {
    PersonDTO(id: id, name: name, birthDate: nil, thumbnailPath: "thumbnail-\(id)", isHidden: hidden)
}
