import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumPickerRecoveryTests: SimulatorHostedTestCase {
    func testFailedAlbumRequestShowsAnErrorAndRetryLoadsTheActualPicker() async throws {
        let repository = RecoveringAlbumPickerRepository(api: makeStubAPIClient())
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Recovered album", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        var selected: AlbumResponseDTO?
        let window = try await host(AlbumPickerLoader(onSelect: { selected = $0 }, repository: repository)
            .environment(\.dynamicTypeSize, .accessibility5), style: .dark)
        window.frame.size.width = 320
        window.rootViewController?.view.frame = window.bounds
        let failure = try await renderedText(in: window, containing: "Failed to Load")
        XCTAssertTrue(failure.contains("Failed to Load"), failure)
        XCTAssertFalse(failure.contains("No Albums"), "A failed request cannot claim that the library is empty")
        XCTAssertEqual(repository.reads, 1)
        repository.result = .success([album])

        try await activateAccessibilityButton(named: "Retry", in: window)

        let recovered = try await renderedText(in: window, containing: "Recovered album")
        XCTAssertTrue(recovered.contains("Recovered album"), recovered)
        XCTAssertFalse(recovered.contains("Failed to Load"), recovered)
        XCTAssertEqual(repository.reads, 2)
        var button: NSObject?
        try await waitUntil("The recovered album is an actual selectable picker row") {
            var visited = Set<ObjectIdentifier>()
            button = self.albumButton(in: window, title: album.albumName, visited: &visited)
            return button != nil
        }
        let row = try XCTUnwrap(button)
        if let control = row as? UIControl { control.performPrimaryAction() }
        else { XCTAssertTrue(row.accessibilityActivate()) }
        XCTAssertEqual(selected?.id, album.id)
    }

    func testSuccessfulEmptyAlbumRequestShowsARealEmptyPicker() async throws {
        let repository = RecoveringAlbumPickerRepository(api: makeStubAPIClient())
        repository.result = .success([])
        let window = try await host(AlbumPickerLoader(onSelect: { _ in XCTFail("An empty picker cannot select an album") },
            repository: repository))
        let text = try await renderedText(in: window, containing: "No Albums")
        XCTAssertTrue(text.contains("No Albums"), text)
        XCTAssertFalse(text.contains("Failed to Load"), text)
        XCTAssertFalse(text.contains("Retry"), text)
        XCTAssertEqual(repository.reads, 1)
    }

    func testReturningBeforeACancelledRequestFinishesKeepsTheReplacementPickerAfterLateSuccessOrFailure() async throws {
        for oldRequestFails in [false, true] {
            let repository = CancelledAlbumPickerRepository(api: makeStubAPIClient())
            defer { repository.gate.complete(.success([])) }
            let navigation = AlbumPickerNavigationState()
            let window = try await host(NavigationStack {
                AlbumPickerLoader(onSelect: { _ in XCTFail("This test never selects a photo album") }, repository: repository)
                    .navigationDestination(isPresented: Binding(get: { navigation.isCovered }, set: { navigation.isCovered = $0 })) {
                        Text("Another screen")
                    }
            })
            await fulfillment(of: [repository.gate.started], timeout: 2)
            navigation.isCovered = true
            await fulfillment(of: [repository.cancelled], timeout: 2)
            XCTAssertFalse(repository.returned, "The old request must stay suspended across the return navigation")

            navigation.isCovered = false

            let recovered = try await renderedText(in: window, containing: "Recovered album")
            XCTAssertTrue(recovered.contains("Recovered album"), "The returning picker must replace the still-suspended cancelled request: \(recovered)")
            XCTAssertEqual(repository.reads, 2)
            XCTAssertFalse(repository.returned)
            if oldRequestFails { repository.gate.complete(.failure(URLError(.badServerResponse))) }
            else { repository.gate.complete(.success([])) }
            try await waitUntil("The obsolete request actually completes after the replacement is visible") { repository.returned }

            let retained = try await renderedText(in: window, containing: "Recovered album")
            XCTAssertTrue(retained.contains("Recovered album"), retained)
            XCTAssertFalse(retained.contains("No Albums"), retained)
            XCTAssertFalse(retained.contains("Failed to Load"), retained)
            XCTAssertEqual(repository.reads, 2)
        }
    }

    private func renderedText(in window: UIWindow, containing expected: String) async throws -> String {
        let deadline = Date().addingTimeInterval(4)
        var text = ""
        repeat {
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                .replacingOccurrences(of: "(?<=\\p{L})-\\s+(?=\\p{L})", with: "", options: .regularExpression)
            if text.contains(expected) { break }
        } while Date() < deadline
        return text
    }

    private func albumButton(in object: NSObject, title: String, visited: inout Set<ObjectIdentifier>) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
        if object.accessibilityTraits.contains(.button), !object.accessibilityTraits.contains(.notEnabled),
           object.accessibilityLabel?.hasPrefix(title) == true { return object }
        if let view = object as? UIView {
            for child in view.subviews {
                if let button = albumButton(in: child, title: title, visited: &visited) { return button }
            }
        }
        let children = object.accessibilityElements ?? []
        for case let child as NSObject in children {
            if let button = albumButton(in: child, title: title, visited: &visited) { return button }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                guard let child = object.accessibilityElement(at: index) as? NSObject else { continue }
                if let button = albumButton(in: child, title: title, visited: &visited) { return button }
            }
        }
        return nil
    }
}

private final class RecoveringAlbumPickerRepository: AlbumRepository {
    var result: Result<[AlbumResponseDTO], Error> = .failure(APIError.server(status: 503, message: "Albums unavailable"))
    private(set) var reads = 0

    override func all() async throws -> [AlbumResponseDTO] {
        reads += 1
        return try result.get()
    }
}

@MainActor
@Observable
private final class AlbumPickerNavigationState {
    var isCovered = false
}

private final class CancelledAlbumPickerRepository: AlbumRepository {
    let gate: PeopleStateGate<[AlbumResponseDTO]>
    let cancelled = XCTestExpectation(description: "Leaving the picker cancels its real view task")
    private(set) var reads = 0
    private(set) var returned = false

    @MainActor
    init(api: APIClient) {
        gate = PeopleStateGate<[AlbumResponseDTO]>()
        super.init(api: api)
    }

    override func all() async throws -> [AlbumResponseDTO] {
        reads += 1
        if reads == 1 {
            defer { returned = true }
            return try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: { [cancelled] in
                cancelled.fulfill()
            }
        }
        return [AlbumResponseDTO(id: UUID().uuidString, albumName: "Recovered album", description: nil,
            assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)]
    }
}
