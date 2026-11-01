import SwiftUI
import SwiftData
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsLoadPresentationTests: SimulatorHostedTestCase {
    private var previousAlbums: [AlbumResponseDTO]?
    private var previousPeople: [PersonDTO]?
    private var previousFavorites: [AssetLite]?
    private var directory: URL!
    private var manager: SwiftDataManager!

    override func setUp() async throws {
        try await super.setUp()
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
        previousPeople = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)
        previousFavorites = LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.libraryFavorites)
        [LocalSnapshot.Key.libraryAlbums, LocalSnapshot.Key.libraryPeople, LocalSnapshot.Key.libraryFavorites]
            .forEach { LocalSnapshot.remove($0) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("collections-load-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.libraryAlbums) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryAlbums) }
        if let previousPeople { LocalSnapshot.save(previousPeople, for: LocalSnapshot.Key.libraryPeople) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryPeople) }
        if let previousFavorites { LocalSnapshot.save(previousFavorites, for: LocalSnapshot.Key.libraryFavorites) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryFavorites) }
        let container = manager.modelContainer
        manager = nil
        try container.erase()
        try FileManager.default.removeItem(at: directory)
    }

    func testPartialSuccessDoesNotLabelFailedPeopleEmptyAndActualRetryRecovers() async throws {
        let fixture = fixture()
        fixture.people.result = .failure(APIError.notConnected)
        let window = try await host(LibraryView(isActive: false, viewModel: fixture.model))
        try await waitUntil("The partial response is admitted") { fixture.model.failedSections.contains(.people) }
        XCTAssertTrue(fixture.model.hasLoaded)
        XCTAssertTrue(fixture.model.hasLoadedAlbums)
        XCTAssertFalse(fixture.model.hasLoadedPeople)
        for section in ["Memories", "Pinned", "Albums", "Recent Days"] {
            try await activateAccessibilityButton(named: "Collapse \(section)", in: window)
        }
        let failure = try await renderedText(in: window, containing: "Failed to Load")
        XCTAssertTrue(failure.contains("Failed to Load"), failure)
        XCTAssertFalse(failure.contains("No People"), "An unrelated Albums response cannot establish an empty People section")
        fixture.people.result = .success([])

        try await activateAccessibilityButton(named: "Retry People", in: window)

        try await waitUntil("The retry confirms the actual People result") { fixture.model.hasLoadedPeople }
        let empty = try await renderedText(in: window, containing: "No People")
        XCTAssertTrue(empty.contains("No People"), empty)
        XCTAssertFalse(fixture.model.failedSections.contains(.people))
        XCTAssertEqual(fixture.people.reads, 2)
    }

    func testFailedAlbumSectionHasItsOwnRetryAndKeepsAnUnrelatedSuccessfulSectionInDarkMode() async throws {
        let fixture = fixture()
        fixture.albums.result = .failure(APIError.notConnected)
        let window = try await host(LibraryView(isActive: false, viewModel: fixture.model), style: .dark)
        try await waitUntil("Only album loading has failed") { fixture.model.failedSections.contains(.albums) }
        XCTAssertTrue(fixture.model.hasLoadedPeople)
        XCTAssertFalse(fixture.model.hasLoadedAlbums)
        let failure = try await renderedText(in: window, containing: "Failed to Load")
        XCTAssertTrue(failure.contains("Failed to Load"), failure)
        XCTAssertFalse(failure.contains("No Albums"), failure)
        fixture.albums.result = .success([])

        try await activateAccessibilityButton(named: "Retry Albums", in: window)

        try await waitUntil("The section retry confirms empty albums") { fixture.model.hasLoadedAlbums }
        let empty = try await renderedText(in: window, containing: "No Albums")
        XCTAssertTrue(empty.contains("No Albums"), empty)
        XCTAssertTrue(fixture.model.failedSections.isEmpty)
        XCTAssertEqual(fixture.albums.reads, 2)
        XCTAssertEqual(fixture.people.reads, 1, "Album retry must not refetch successful unrelated sections")
    }

    func testEntirelyFailedLoadRemainsRetryableAndDoesNotConfirmAnyEmptySection() async {
        let fixture = fixture()
        fixture.memories.fails = true
        fixture.albums.result = .failure(APIError.notConnected)
        fixture.people.result = .failure(APIError.notConnected)
        await fixture.model.load()
        XCTAssertFalse(fixture.model.hasLoaded)
        XCTAssertFalse(fixture.model.hasLoadedMemories)
        XCTAssertFalse(fixture.model.hasLoadedAlbums)
        XCTAssertFalse(fixture.model.hasLoadedPeople)
        XCTAssertEqual(fixture.model.failedSections, [.memories, .albums, .sharedAlbums, .people])

        fixture.memories.fails = false
        fixture.albums.result = .success([])
        fixture.people.result = .success([])
        await fixture.model.loadIfNeeded()

        XCTAssertTrue(fixture.model.hasLoadedMemories)
        XCTAssertTrue(fixture.model.hasLoadedAlbums)
        XCTAssertTrue(fixture.model.hasLoadedPeople)
        XCTAssertTrue(fixture.model.failedSections.isEmpty)
    }

    func testPeopleNamesRetainTheirSectionSpacingAtLargestAccessibilitySizeInBothAppearances() async throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let fixture = fixture()
            fixture.people.result = .success([PersonDTO(id: UUID().uuidString, name: "Amy", birthDate: nil,
                thumbnailPath: nil, isHidden: false)])
            let window = try await host(LibraryView(isActive: false, viewModel: fixture.model)
                .environment(\.dynamicTypeSize, .accessibility5), style: style)
            window.frame.size = CGSize(width: 320, height: 2200)
            window.rootViewController?.view.frame = window.bounds
            try await waitUntil("The populated People section has loaded") { fixture.model.hasLoadedPeople }
            window.layoutIfNeeded()
            var personFrame: CGRect?
            var nextHeadingFrame: CGRect?
            try await waitUntil("The real People card and following section heading have layout frames") {
                var personVisited = Set<ObjectIdentifier>()
                var headingVisited = Set<ObjectIdentifier>()
                personFrame = self.accessibilityFrame(named: "Amy", in: window, visited: &personVisited)
                nextHeadingFrame = self.accessibilityFrame(named: "Featured Photos", in: window, visited: &headingVisited)
                return personFrame?.isEmpty == false && nextHeadingFrame?.isEmpty == false
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(nextHeadingFrame).minY - (try XCTUnwrap(personFrame).maxY), 28,
                "The full People card must retain the 30pt section spacing instead of consuming it with its larger caption")
        }
    }

    private func accessibilityFrame(named name: String, in object: NSObject,
                                    visited: inout Set<ObjectIdentifier>) -> CGRect? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
        if object.accessibilityLabel == name, object.accessibilityTraits.contains(.button) {
            return object.accessibilityFrame
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let frame = accessibilityFrame(named: name, in: child, visited: &visited) { return frame }
            }
        }
        for case let child as NSObject in object.accessibilityElements ?? [] {
            if let frame = accessibilityFrame(named: name, in: child, visited: &visited) { return frame }
        }
        let count = object.accessibilityElementCount()
        if (1...500).contains(count) {
            for index in 0..<count {
                guard let child = object.accessibilityElement(at: index) as? NSObject else { continue }
                if let frame = accessibilityFrame(named: name, in: child, visited: &visited) { return frame }
            }
        }
        return nil
    }

    private func fixture() -> (model: LibraryViewModel, albums: CollectionStatusAlbumRepository,
                               people: CollectionStatusPeopleRepository, memories: CollectionStatusMemoriesRepository) {
        let api = makeStubAPIClient()
        let albums = CollectionStatusAlbumRepository(api: api)
        let people = CollectionStatusPeopleRepository(api: api)
        let memories = CollectionStatusMemoriesRepository(api: api)
        return (LibraryViewModel(memoriesRepo: memories, albumRepo: albums, peopleRepo: people,
            searchRepo: SearchRepository(api: api), assetRepo: AssetDetailRepository(api: api),
            dataManager: manager, localPhotos: { [] }), albums, people, memories)
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
            if text.contains(expected) { break }
        } while Date() < deadline
        return text
    }
}

private final class CollectionStatusAlbumRepository: AlbumRepository {
    var result: Result<[AlbumResponseDTO], Error> = .success([])
    private(set) var reads = 0
    override func all() async throws -> [AlbumResponseDTO] { reads += 1; return try result.get() }
}

private final class CollectionStatusPeopleRepository: PeopleRepository {
    var result: Result<[PersonDTO], Error> = .success([])
    private(set) var reads = 0
    override func all(size: Int? = nil) async throws -> [PersonDTO] { reads += 1; return try result.get() }
}

private final class CollectionStatusMemoriesRepository: MemoriesRepository {
    var fails = false
    override func getMemories() async throws -> [MemoryDTO] {
        if fails { throw APIError.notConnected }
        return []
    }
}
