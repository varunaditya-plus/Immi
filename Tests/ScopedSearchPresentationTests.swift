import Network
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class ScopedSearchPresentationTests: SimulatorHostedTestCase {
    private var server: ScopedSearchHTTPServer?
    private var albumID = ""
    private var personID = ""
    private var photoIDs: [String] = []

    override func tearDown() async throws {
        for window in windows { deactivateNativeSearch(in: window.rootViewController) }
        try await super.tearDown()
        server?.stop()
        server = nil
        LocalSnapshot.remove(LocalSnapshot.Key.album(albumID))
        LocalSnapshot.remove(LocalSnapshot.Key.person(personID))
        for id in photoIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
        AlbumCoverStore.shared.invalidate(albumID)
    }

    func testAlbumMenuSearchSeedsTheNativeAlbumTokenAndScopesEveryContinuationPage() async throws {
        let (server, session) = try await fixture()
        let album = AlbumResponseDTO(id: albumID, albumName: "Scoped Album", description: nil, assetCount: 2,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
        let window = try await host(NavigationStack { AlbumDetailView(album: album) }.environment(session as SessionManager))
        try await waitUntil("The original album's actual collection loads its synthetic photos") { self.containsBothPhotos(in: window) }
        let original = try XCTUnwrap(grid(in: window.rootViewController))
        let previousReads = server.metadataRequests.count

        try await activateSearchMenuAction(named: "Search", in: window)

        try await waitUntil("The album's real Search menu opens a tokenized native search field") {
            self.searchField(in: window)?.tokens.count == 1
                && server.metadataRequests.count >= previousReads + 2
        }
        let requests = Array(server.metadataRequests.dropFirst(previousReads))
        XCTAssertEqual(requests.compactMap { $0["page"] as? Int }, [1, 2])
        for request in requests {
            XCTAssertEqual(request["albumIds"] as? [String], [albumID])
            XCTAssertEqual(request["visibility"] as? String, "timeline")
            XCTAssertNil(request["query"])
        }
        XCTAssertEqual(searchField(in: window)?.text, "")

        let presented = try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).first {
            !($0 is UISearchController) && self.searchField(in: $0.view)?.tokens.count == 1
        })
        try await activateAccessibilityButton(named: "Close", in: window, within: presented.view)

        try await waitUntil("Close returns to the original album without replacing its collection") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === presented }
                && self.grid(in: window.rootViewController) === original
        }
        XCTAssertTrue(containsBothPhotos(in: window))
    }

    func testPersonMenuSearchSeedsTheNativePersonTokenAndScopesEveryContinuationPage() async throws {
        let (server, session) = try await fixture()
        let person = PersonDTO(id: personID, name: "Scoped Person", birthDate: nil, thumbnailPath: nil, isHidden: false)
        let repository = PeopleRepository(api: APIClient(session: session))
        let window = try await host(NavigationStack { PersonDetailView(person: person, repo: repository) }
            .environment(session as SessionManager))
        try await waitUntil("The original person's actual collection loads its synthetic photos") { self.containsBothPhotos(in: window) }
        let original = try XCTUnwrap(grid(in: window.rootViewController))
        let previousReads = server.metadataRequests.count

        try await activateSearchMenuAction(named: "Search", in: window)

        try await waitUntil("The person's real Search menu opens a native person token and reads every page") {
            self.searchField(in: window)?.tokens.count == 1 && server.metadataRequests.count >= previousReads + 2
        }
        let requests = Array(server.metadataRequests.dropFirst(previousReads))
        XCTAssertEqual(requests.compactMap { $0["page"] as? Int }, [1, 2])
        for request in requests {
            XCTAssertEqual(request["personIds"] as? [String], [personID])
            XCTAssertEqual(request["visibility"] as? String, "timeline")
            XCTAssertNil(request["query"])
        }

        let presented = try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).first {
            !($0 is UISearchController) && self.searchField(in: $0.view)?.tokens.count == 1
        })
        try await activateAccessibilityButton(named: "Close", in: window, within: presented.view)

        try await waitUntil("Close returns to the same person collection") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === presented }
                && self.grid(in: window.rootViewController) === original
        }
        XCTAssertTrue(containsBothPhotos(in: window))
    }

    func testActualSearchViewerDateSaveRerunsTheCurrentScopeAndRemovesTheNowNonmatchingPhoto() async throws {
        let (server, session) = try await fixture()
        let window = try await host(SearchView(isActive: true, initialTokens: [.date(.year(2020))])
            .environment(session as SessionManager))
        try await waitUntil("The real year-scoped Search loads both photos through its production repository") {
            self.photoCount(in: window) == 2
        }
        searchField(in: window)?.resignFirstResponder()
        let viewer = try await openPhoto(photoIDs[0], in: window)
        try await activateAccessibilityButton(named: "Info", in: window)
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The Search viewer presents its actual date picker") { self.datePicker(in: window) != nil }
        let picker = try XCTUnwrap(datePicker(in: window))
        let saved = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-06-15T12:00:00Z"))
        picker.setDate(saved, animated: false)
        picker.sendActions(for: .valueChanged)
        let previousReads = server.metadataRequests.count

        try await activateAccessibilityButton(named: "Save", in: window)

        try await waitUntil("The actual accepted viewer date save reruns Search's existing filters") {
            server.dateWrites.count == 1 && server.metadataRequests.count > previousReads
        }
        XCTAssertEqual(server.dateWrites.first?.id, photoIDs[0])
        XCTAssertEqual(server.dateWrites.first?.date, saved)
        let bounds = SearchDateRange.year(2020).bounds()
        for request in server.metadataRequests.dropFirst(previousReads) {
            let from = try XCTUnwrap(request["takenAfter"] as? String)
            let to = try XCTUnwrap(request["takenBefore"] as? String)
            XCTAssertEqual(Self.date(from), bounds.from)
            XCTAssertEqual(Self.date(to), bounds.to)
            XCTAssertEqual(request["visibility"] as? String, "timeline")
        }
        try await waitUntil("The photo moved outside 2020 leaves the actual search grid") {
            self.photoCount(in: window) == 1
                && self.grid(in: window.rootViewController)?.revealCell(for: self.photoIDs[0]) == nil
        }
        XCTAssertNotNil(self.grid(in: window.rootViewController)?.revealCell(for: photoIDs[1]))
        XCTAssertEqual(searchField(in: window)?.tokens.count, 1, "Editing metadata must preserve the native year scope")

        try await activateAccessibilityButton(named: "Info", in: window, within: viewer.view)
        try await activateAccessibilityButton(named: "Close", in: window, within: viewer.view)
        try await waitUntil("Closing the edited photo returns to the refreshed year-scoped Search") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === viewer }
                && self.photoCount(in: window) == 1 && self.searchField(in: window)?.tokens.count == 1
        }
        let remainingViewer = try await openPhoto(photoIDs[1], in: window)
        try await activateAccessibilityButton(named: "Info", in: window, within: remainingViewer.view)
        XCTAssertEqual(server.assetDetailRequests.last, photoIDs[1], "The refreshed grid must open the remaining photo's actual metadata")
        try await activateAccessibilityButton(named: "Info", in: window, within: remainingViewer.view)
        try await activateAccessibilityButton(named: "Close", in: window, within: remainingViewer.view)
        try await waitUntil("The remaining photo closes back to the same refreshed native search field") {
            !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === remainingViewer }
                && self.photoCount(in: window) == 1 && self.searchField(in: window)?.tokens.count == 1
        }
        XCTAssertEqual(server.dateWrites.count, 1, "Reopening a result must not repeat the previous date mutation")
    }

    private func openPhoto(_ id: String, in window: UIWindow) async throws -> UIViewController {
        let grid = try XCTUnwrap(grid(in: window.rootViewController))
        let collection = try XCTUnwrap(collection(in: grid.view))
        let path = try XCTUnwrap(grid.revealCell(for: id))
        try await waitUntil("The matching photo's actual accessible grid cell is rendered") { collection.cellForItem(at: path) != nil }
        let cell = try XCTUnwrap(collection.cellForItem(at: path))
        XCTAssertTrue(cell.accessibilityActivate(), "The production cell must open its own photo viewer")
        var viewer: UIViewController?
        try await waitUntil("The actual grid presents its production photo pager") {
            viewer = self.searchPresentedControllers(in: window.rootViewController).first {
                self.pager(in: $0) != nil && !$0.isBeingPresented && $0.view.window != nil
            }
            return viewer != nil
        }
        return try XCTUnwrap(viewer)
    }

    private func fixture() async throws -> (ScopedSearchHTTPServer, MockSessionManager) {
        albumID = UUID().uuidString
        personID = UUID().uuidString
        photoIDs = (0..<2).map { _ in UUID().uuidString }
        let ready = expectation(description: "Synthetic scoped-search loopback server is ready")
        let server = try ScopedSearchHTTPServer(albumID: albumID, personID: personID, photoIDs: photoIDs, ready: ready)
        self.server = server
        await fulfillment(of: [ready], timeout: 3)
        let session = MockSessionManager()
        try session.setServer("http://127.0.0.1:\(try XCTUnwrap(server.port))")
        return (server, session)
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.grid(in: $0) }.first
    }

    private func pager(in controller: UIViewController) -> PhotoPagerController? {
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.pager(in: $0) }.first
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }

    private func photoCount(in window: UIWindow) -> Int {
        guard let grid = grid(in: window.rootViewController), let collection = collection(in: grid.view) else { return 0 }
        return (0..<collection.numberOfSections).reduce(0) { $0 + collection.numberOfItems(inSection: $1) }
    }

    private func containsBothPhotos(in window: UIWindow) -> Bool {
        guard let grid = grid(in: window.rootViewController) else { return false }
        return photoIDs.allSatisfy { grid.revealCell(for: $0) != nil }
    }

    private func searchField(in view: UIView) -> UISearchTextField? {
        if let field = view as? UISearchTextField { return field }
        return view.subviews.lazy.compactMap { self.searchField(in: $0) }.first
    }

    private func datePicker(in view: UIView) -> UIDatePicker? {
        if let picker = view as? UIDatePicker { return picker }
        return view.subviews.lazy.compactMap { self.datePicker(in: $0) }.first
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private final class ScopedSearchHTTPServer: @unchecked Sendable {
    struct DateWrite { let id: String; let date: Date }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScopedSearchPresentationTests.HTTP")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var requests: [[String: Any]] = []
    private var writes: [DateWrite] = []
    private var detailReads: [String] = []
    private let albumID: String
    private let personID: String
    private var photos: [[String: Any]]
    var port: UInt16? { listener.port?.rawValue }
    var metadataRequests: [[String: Any]] { lock.withLock { requests } }
    var dateWrites: [DateWrite] { lock.withLock { writes } }
    var assetDetailRequests: [String] { lock.withLock { detailReads } }

    init(albumID: String, personID: String, photoIDs: [String], ready: XCTestExpectation) throws {
        self.albumID = albumID
        self.personID = personID
        let dates = ["2020-06-15T12:00:00.000Z", "2020-07-15T12:00:00.000Z"]
        photos = zip(photoIDs, dates).map { id, date in
            ["id": id, "type": "IMAGE", "originalFileName": "synthetic.jpg", "fileCreatedAt": date,
             "localDateTime": date, "isFavorite": false, "isArchived": false, "isTrashed": false,
             "visibility": "timeline"]
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case .failed(let error) = state { XCTFail("Scoped-search loopback startup failed: \(error)"); ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let received = accumulated + data
            guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: received) }
                return
            }
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = received[headerEnd.upperBound...]
            guard body.count >= length else { self.receive(connection, accumulated: received); return }
            let request = header.split(separator: "\r\n").first?.split(separator: " ").map(String.init) ?? []
            let object = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
            let response = self.response(method: request.first ?? "", target: request.dropFirst().first ?? "", body: object)
            let payload = Data("HTTP/1.1 \(response.0) Response\r\nContent-Length: \(response.1.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8) + response.1
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(method: String, target: String, body: [String: Any]) -> (Int, Data) {
        lock.withLock {
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            let album: [String: Any] = ["id": albumID, "albumName": "Scoped Album", "assetCount": 2,
                "shared": false, "createdAt": "2020-01-01T00:00:00.000Z"]
            let person: [String: Any] = ["id": personID, "name": "Scoped Person", "isHidden": false]
            let value: Any
            switch path {
            case "/api/search/metadata":
                requests.append(body)
                let page = body["page"] as? Int ?? 1
                let visible = photos.filter { photo in
                    guard let text = photo["fileCreatedAt"] as? String, let date = Self.date(text) else { return false }
                    if let from = body["takenAfter"] as? String, let start = Self.date(from), date < start { return false }
                    if let to = body["takenBefore"] as? String, let end = Self.date(to), date >= end { return false }
                    return true
                }
                let items = visible.indices.contains(page - 1) ? [visible[page - 1]] : []
                value = ["assets": ["items": items, "total": visible.count,
                    "nextPage": page < visible.count ? String(page + 1) as Any : NSNull()]]
            case "/api/search/suggestions": value = []
            case "/api/albums": value = [album]
            case "/api/albums/\(albumID)": value = album
            case "/api/people": value = ["people": [person], "hasNextPage": false]
            case "/api/people/\(personID)": value = person
            default:
                if method == "PUT", let id = path.split(separator: "/").last.map(String.init),
                   let index = photos.firstIndex(where: { $0["id"] as? String == id }),
                   let raw = body["dateTimeOriginal"] as? String, let date = Self.date(raw) {
                    writes.append(DateWrite(id: id, date: date))
                    photos[index]["fileCreatedAt"] = raw
                    value = [:]
                } else if let photo = photos.first(where: { path == "/api/assets/\($0["id"] as? String ?? "")" }) {
                    if let id = photo["id"] as? String { detailReads.append(id) }
                    value = photo
                } else { return (503, Data("{}".utf8)) }
            }
            return (200, (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
