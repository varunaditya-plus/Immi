import ImageIO
import LinkPresentation
import Observation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoSharingPresentationTests: SimulatorHostedTestCase {
    private var directory: URL!
    private var files: [URL] = []
    private var mounted: PhotoSharingMountedState?
    private weak var retainedController: PhotoShareViewController?
    private var transports: [URLSession] = []
    private var previousClipboard: [[String: Any]]?
    private var previousClipboardRevision = 0
    private var localMappings: [String] = []
    private var clipboardWrites: [[String: Data]] = []
    private var heldDownloads: [PhotoSharingDownloadGate] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-sharing-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        heldDownloads.forEach { $0.release() }
        heldDownloads.removeAll()
        if let controller = retainedController, controller.presentedViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: false) { continuation.resume() }
            }
        }
        retainedController?.cancelAndCleanup()
        mounted?.content = nil
        try await super.tearDown()
        mounted = nil
        try await waitUntil("The closed photo share composer releases its controller") { self.retainedController == nil }
        transports.forEach { $0.invalidateAndCancel() }
        transports.removeAll()
        TemporaryMediaStore.remove(files)
        if let previousClipboard, UIPasteboard.general.changeCount == previousClipboardRevision + 1 {
            let board = UIPasteboard.general
            let ownsClipboard = !clipboardWrites.isEmpty && board.numberOfItems == clipboardWrites.count
                && clipboardWrites.enumerated().allSatisfy { index, item in
                    item.allSatisfy { type, expected in
                        board.data(forPasteboardType: type, inItemSet: IndexSet(integer: index))?.first == expected
                    }
                }
            if ownsClipboard { UIPasteboard.general.setItems(previousClipboard) }
        }
        previousClipboard = nil
        for localID in localMappings {
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.localIdentifier == localID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
            try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: localID)
        }
        localMappings.removeAll()
        try FileManager.default.removeItem(at: directory)
        MockURLProtocol.reset()
    }

    func testLoadingAStaleComposerRendersNoPhotoOrActionsWhileACurrentContextRendersBoth() throws {
        let original = try image(color: .red)
        let bytes = try Data(contentsOf: original)
        let prepared = try managedCopy(original)
        let id = UUID().uuidString
        let session = try session()
        let oldContext = session.snapshot
        try session.setServer("https://sharing-ui-other.example")
        let currentContext = session.snapshot
        XCTAssertNotEqual(oldContext, currentContext)
        let stale = PhotoShareViewController(urls: [prepared], assetIDs: [id], sourceIDs: [id],
            requestContext: oldContext, session: session, isAllowed: { _ in true }, onFinish: {})
        let current = PhotoShareViewController(urls: [prepared], assetIDs: [id], sourceIDs: [id],
            requestContext: currentContext, session: session, isAllowed: { _ in true }, onFinish: {})
        defer { stale.cancelAndCleanup(); current.cancelAndCleanup() }

        stale.loadViewIfNeeded()
        current.loadViewIfNeeded()

        XCTAssertTrue(views(stale.view).compactMap { $0 as? UIImageView }.allSatisfy { $0.image == nil },
            "Rejected prepared bytes must never populate the loaded view's image hierarchy")
        for identifier in ["photoShare.options", "photoShare.copy", "photoShare.continue", "photoShare.original"] {
            XCTAssertFalse(views(stale.view).contains { $0.accessibilityIdentifier == identifier })
            let control = try button(identifier, in: current.view)
            XCTAssertTrue(control.isEnabled)
            XCTAssertFalse(control.isHidden)
        }
        let preview = try XCTUnwrap(views(current.view).compactMap { ($0 as? UIImageView)?.image }
            .first { !$0.isSymbolImage })
        let pixels = try XCTUnwrap(preview.cgImage)
        XCTAssertEqual([pixels.width, pixels.height], [64, 48],
            "The paired authorized view must load the same real photo, so hiding every preview cannot pass")
        XCTAssertEqual(try Data(contentsOf: prepared), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testActualCheckboxAndCopyKeepDisplayOrderAndBytesAfterShareFilesAreCleaned() async throws {
        let originals = try [UIColor.red, .green, .blue].map { try image(color: $0) }
        let inputs = try originals.map(managedCopy)
        let bytes = try originals.map { try Data(contentsOf: $0) }
        captureClipboard()
        let (controller, window) = try await show(inputs)
        let collection = try XCTUnwrap(views(controller.view).compactMap { $0 as? UICollectionView }.first)
        let middle = IndexPath(item: 1, section: 0)
        collection.scrollToItem(at: middle, at: .centeredHorizontally, animated: false)
        controller.view.layoutIfNeeded()
        try await waitUntil("The middle preview checkbox is rendered") { collection.cellForItem(at: middle) != nil }
        let cell = try XCTUnwrap(collection.cellForItem(at: middle))
        XCTAssertTrue(cell.isSelected)

        XCTAssertTrue(cell.accessibilityActivate(), "Use the actual preview's selection action")
        try await waitUntil("The selected count reflects the checkbox change") {
            self.containsText("2 Photos Selected", in: controller.view)
        }
        try await tap("photoShare.copy", in: controller)
        try await waitUntil("The actual Copy finishes and unmounts its composer") { self.mounted?.finished == true }

        clipboardWrites = [[UTType.png.identifier: bytes[0]], [UTType.png.identifier: bytes[2]]]
        XCTAssertEqual(UIPasteboard.general.numberOfItems, 2)
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier,
            inItemSet: IndexSet([0, 1])), [bytes[0], bytes[2]])
        XCTAssertTrue(inputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try originals.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertNil(presented(UIActivityViewController.self, from: window.rootViewController))
    }

    func testActualLocationAndFormatOptionsProduceAGPSFreeJPEGCopyWithoutChangingTheOriginal() async throws {
        let original = try image(type: .heic, color: .systemPurple, location: true)
        let bytes = try Data(contentsOf: original)
        let input = try managedCopy(original)
        captureClipboard()
        let (controller, window) = try await show([input])

        try await chooseOptions(location: false, format: "Most Compatible", in: controller, window: window)
        XCTAssertEqual(controller.options, .init(format: .mostCompatible, includeLocation: false))
        try await tap("photoShare.copy", in: controller)
        try await waitUntil("The configured Copy finishes") { self.mounted?.finished == true }

        XCTAssertEqual(UIPasteboard.general.numberOfItems, 1)
        let data = try XCTUnwrap(UIPasteboard.general.data(forPasteboardType: UTType.jpeg.identifier,
            inItemSet: IndexSet(integer: 0))?.first)
        clipboardWrites = [[UTType.jpeg.identifier: data]]
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertFalse(metadataPaths(source).contains { $0.lowercased().contains("gps") })
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([output.width, output.height], [64, 48])
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertNotNil(try imageProperties(original)[kCGImagePropertyGPSDictionary as String])
    }

    func testActualSharePresentsTheNativeActivityWithItsConfiguredFilesAndRevocationDismissesIt() async throws {
        let original = try image(type: .heic, color: .purple, location: true)
        let bytes = try Data(contentsOf: original)
        let input = try managedCopy(original)
        let admission = PhotoSharingAdmission()
        let (controller, window) = try await show([input], admission: admission)
        try await chooseOptions(location: false, format: "Most Compatible", in: controller, window: window)

        try await tap("photoShare.continue", in: controller)
        try await waitUntil("The actual Share action presents UIKit's native activity controller") {
            self.presented(UIActivityViewController.self, from: controller) != nil
        }
        let activity = try XCTUnwrap(presented(UIActivityViewController.self, from: controller))
        XCTAssertNotNil(activity.presentingViewController ?? activity.parent?.presentingViewController)
        let converted = try managedShareFiles {
            $0.deletingPathExtension().lastPathComponent == original.deletingPathExtension().lastPathComponent
                && PhotoExportService.contentType(of: $0) == .jpeg
        }
        files += converted
        XCTAssertEqual(converted.count, 1)
        let output = try XCTUnwrap(converted.first)
        XCTAssertNil(try imageProperties(output)[kCGImagePropertyGPSDictionary as String])
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        _ = try await screenshot(window)

        let headerPreview = try XCTUnwrap(views(controller.view).compactMap { $0 as? UIImageView }
            .first { $0.image != nil && $0.image?.isSymbolImage == false })
        admission.allowed = false

        try await waitUntil("Revoking the shared photo dismisses the entire actual sharing presentation") {
            self.mounted?.finished == true && self.presented(UIActivityViewController.self, from: window.rootViewController) == nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(controller.view.isHidden)
        XCTAssertTrue(activity.view.isHidden)
        XCTAssertNil(headerPreview.image)
    }

    func testPublicActivityMetadataHasARealPhotoPreviewAndRejectsRevokedRequests() async throws {
        let original = try image(color: .red)
        let prepared = try managedCopy(original)
        let admission = PhotoSharingAdmission()
        let id = UUID().uuidString
        let controller = PhotoShareViewController(urls: [prepared], assetIDs: [id], session: try session(),
            isAllowed: { _ in admission.allowed }, onFinish: {})
        defer { controller.cancelAndCleanup() }
        controller.loadViewIfNeeded()
        let configuration = controller.activityConfiguration(for: [
            .init(fileURL: prepared, compatibleURL: nil, ownedURLs: []),
        ])
        let title = prepared.deletingPathExtension().lastPathComponent
        XCTAssertEqual(configuration.metadataProvider?(.title) as? String, title)
        let metadata = try XCTUnwrap(configuration.perItemMetadataProvider?(0, .linkPresentationMetadata) as? LPLinkMetadata)
        XCTAssertEqual(metadata.title, title)
        let imageProvider = try XCTUnwrap(metadata.imageProvider)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = imageProvider.loadObject(ofClass: UIImage.self) { value, error in
                if let error { continuation.resume(throwing: error); return }
                guard let image = value as? UIImage, !image.isSymbolImage, let data = image.pngData() else {
                    continuation.resume(throwing: NSError(domain: "PhotoSharingPreview", code: 1)); return
                }
                continuation.resume(returning: data)
            }
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [64, 48])
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertLessThan(pixel[1], 15)
        XCTAssertLessThan(pixel[2], 15)
        XCTAssertNil(configuration.perItemMetadataProvider?(-1, .linkPresentationMetadata))
        XCTAssertNil(configuration.perItemMetadataProvider?(1, .linkPresentationMetadata))
        XCTAssertNil(configuration.metadataProvider?(.messageBody))

        admission.allowed = false

        XCTAssertNil(configuration.metadataProvider?(.title))
        XCTAssertNil(configuration.perItemMetadataProvider?(0, .linkPresentationMetadata))
    }

    func testAutomaticItemProviderLoadsRealHEICAndJPEGRepresentationsWithTheSourceBasename() async throws {
        let source = try image(type: .heic, color: .orange)
        let original = try Data(contentsOf: source)
        let exports = try await PhotoExportService.prepare(source, options: .init())
        files += exports.ownedURLs
        let provider = PhotoShareViewController.itemProvider(for: exports, isAllowed: { true })

        XCTAssertEqual(Set(provider.registeredTypeIdentifiers), [UTType.heic.identifier, UTType.jpeg.identifier])
        XCTAssertEqual(provider.suggestedName, source.deletingPathExtension().lastPathComponent)
        let current = try await load(provider, type: .heic)
        let compatible = try await load(provider, type: .jpeg)

        XCTAssertEqual(current.type, UTType.heic.identifier)
        XCTAssertEqual(current.data, original)
        XCTAssertEqual(compatible.type, UTType.jpeg.identifier)
        XCTAssertNotEqual(compatible.data, original)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(compatible.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertEqual([decoded.width, decoded.height], [64, 48])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(exports.compatibleURL).path))
    }

    func testItemProviderRejectsRevokedAuthorizationBeforeLoadingAnyBytes() async throws {
        let source = try image(color: .cyan)
        let admission = PhotoSharingAdmission()
        let provider = PhotoShareViewController.itemProvider(
            for: .init(fileURL: source, compatibleURL: nil, ownedURLs: []), isAllowed: { admission.allowed })
        admission.allowed = false

        do { _ = try await load(provider, type: .png); XCTFail("A revoked share must not deliver file bytes") }
        catch { XCTAssertFalse((error as NSError).domain.isEmpty) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "A rejected provider does not own the caller's source")
    }

    func testPartialPreparationShowsTheAvailableCountAndHidesUnmappedOriginalExport() async throws {
        let first = try managedCopy(image(color: .red)), second = try managedCopy(image(color: .green))
        let (controller, _) = try await show([first, second], ids: (0..<3).map { _ in UUID().uuidString })

        XCTAssertTrue(containsText("2 Photos Selected", in: controller.view))
        XCTAssertTrue(containsText("Some items could not be prepared. Only the available items are selected.", in: controller.view))
        XCTAssertTrue(try button("photoShare.original", in: controller.view).isHidden)
        XCTAssertTrue(try button("photoShare.continue", in: controller.view).isEnabled)
    }

    func testTurningOffLocationDisablesOriginalAndRejectsItsPreviouslyMountedAction() async throws {
        let current = try managedCopy(image(color: .blue))
        let requests = PhotoSharingRequests()
        requests.unexpected = expectation(description: "No original request is allowed after Location is disabled")
        requests.unexpected?.isInverted = true
        let session = try session()
        let api = api(session, bytes: try Data(contentsOf: current), requests: requests)
        let (controller, window) = try await show([current], session: session, api: api)
        let original = try button("photoShare.original", in: controller.view)
        XCTAssertTrue(original.isEnabled)
        var queued: UIAction?
        original.enumerateEventHandlers { action, _, events, _ in
            if events.contains(.touchUpInside) { queued = action }
        }
        let action = try XCTUnwrap(queued, "Capture the actual registered action before changing the native options")

        try await chooseOptions(location: false, format: nil, in: controller, window: window)
        XCTAssertFalse(original.isEnabled)
        original.sendAction(action)
        await fulfillment(of: [try XCTUnwrap(requests.unexpected)], timeout: 0.25)

        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertNil(presented(UIDocumentPickerViewController.self, from: controller))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testOriginalExportPresentsFilesWithUnmodifiedBytesAndKeepsThemUntilDismantle() async throws {
        let currentSource = try image(color: .blue)
        let originalSource = try image(color: .red, location: true)
        let current = try managedCopy(currentSource)
        let bytes = try Data(contentsOf: originalSource)
        let requests = PhotoSharingRequests()
        let session = try session()
        let filename = "unmodified-\(UUID()).png"
        let api = api(session, bytes: bytes, filename: filename, requests: requests)
        let (controller, _) = try await show([current], session: session, api: api)

        try await tap("photoShare.original", in: controller)
        try await waitUntil("The real original action presents the native Files exporter") {
            self.presented(UIDocumentPickerViewController.self, from: controller) != nil
        }
        let picker = try XCTUnwrap(presented(UIDocumentPickerViewController.self, from: controller))
        XCTAssertNotNil(picker.presentingViewController ?? picker.parent?.presentingViewController)
        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "edited", value: "false")])
        let originals = try managedShareFiles { $0.lastPathComponent == filename }
        files += originals
        XCTAssertEqual(originals.count, 1)
        let exported = try XCTUnwrap(originals.first)
        XCTAssertEqual(try Data(contentsOf: exported), bytes)
        XCTAssertNotEqual(try Data(contentsOf: current), bytes)

        await withCheckedContinuation { continuation in controller.dismiss(animated: false) { continuation.resume() } }
        mounted?.isPresented = false
        try await waitUntil("Dismantling the share cleans both the staged original and current file") {
            !FileManager.default.fileExists(atPath: exported.path) && !FileManager.default.fileExists(atPath: current.path)
        }
        XCTAssertEqual(try Data(contentsOf: originalSource), bytes)
    }

    func testMappedDeviceOriginalUsesItsCanonicalServerIDAndUnmodifiedTransport() async throws {
        let localID = "photo-sharing-ui-\(UUID())/L0/001"
        let serverID = UUID().uuidString
        try seedMapping(localID, serverID: serverID)
        let current = try managedCopy(image(color: .blue))
        let original = try image(color: .red, location: true)
        let bytes = try Data(contentsOf: original)
        let filename = "mapped-original-\(UUID()).png"
        let requests = PhotoSharingRequests()
        let session = try session()
        let api = api(session, bytes: bytes, filename: filename, requests: requests)
        let (controller, _) = try await show([current], ids: [LocalPhotoLibrary.assetID(for: localID)],
            session: session, api: api)

        try await tap("photoShare.original", in: controller)
        try await waitUntil("A mapped device original presents the native Files exporter") {
            self.presented(UIDocumentPickerViewController.self, from: controller) != nil
        }

        XCTAssertEqual(requests.values.count, 1)
        let request = try XCTUnwrap(requests.values.first)
        XCTAssertTrue(try XCTUnwrap(request.url).path.hasSuffix("/assets/\(serverID)/original"))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "edited", value: "false")])
        let outputs = try managedShareFiles { $0.lastPathComponent == filename }
        files += outputs
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(outputs.first)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID)?.assetId, serverID)
    }

    func testPreparedBytesAreRejectedWhenTheirMappingChangesBeforeTheComposerIsCreated() async throws {
        let localID = "photo-sharing-ui-\(UUID())/L0/001"
        let originalServerID = UUID().uuidString, replacementID = UUID().uuidString
        try seedMapping(localID, serverID: originalServerID)
        let source = try image(color: .red)
        let bytes = try Data(contentsOf: source)
        let prepared = try managedCopy(source)
        let displayID = LocalPhotoLibrary.assetID(for: localID)
        let capturedSourceIDs = AssetServerIdentity.exportIDs(for: [displayID])
        XCTAssertEqual(capturedSourceIDs, [originalServerID])
        try SwiftDataManager.shared.upsertBackupRecord(assetID: replacementID, checksum: "", localIdentifier: localID)
        XCTAssertEqual(AssetServerIdentity.exportIDs(for: [displayID]), [replacementID])
        let clipboardRevision = UIPasteboard.general.changeCount
        let requests = PhotoSharingRequests()
        requests.unexpected = expectation(description: "Rejected prepared bytes cannot request an original")
        requests.unexpected?.isInverted = true
        let session = try session()
        let api = api(session, bytes: bytes, requests: requests)
        let state = PhotoSharingMountedState()
        state.content = AnyView(PhotoShareSheet(urls: [prepared], assetIDs: [displayID], sourceIDs: capturedSourceIDs,
            api: api, isAllowed: { _ in true }).environment(session as SessionManager))
        mounted = state

        let window = try await host(PhotoSharingMountedHost(state: state))
        try await waitUntil("A composer whose prepared identity is already stale dismisses itself on presentation") {
            state.finished
        }
        await fulfillment(of: [try XCTUnwrap(requests.unexpected)], timeout: 0.25)

        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertEqual(UIPasteboard.general.changeCount, clipboardRevision)
        XCTAssertNil(presented(PhotoShareViewController.self, from: window.rootViewController))
        XCTAssertNil(presented(UIDocumentPickerViewController.self, from: window.rootViewController))
        XCTAssertNil(presented(UIActivityViewController.self, from: window.rootViewController))
    }

    func testMappingReplacementRevokesAHeldOriginalAndCleansItsLateFile() async throws {
        let localID = "photo-sharing-ui-\(UUID())/L0/001"
        let oldID = UUID().uuidString, newID = UUID().uuidString
        try seedMapping(localID, serverID: oldID)
        let current = try managedCopy(image(color: .blue))
        let download = try image(color: .red, location: true)
        let filename = "late-original-\(UUID()).png"
        let gate = PhotoSharingDownloadGate()
        heldDownloads.append(gate)
        let session = try session()
        let api = PhotoSharingHeldClient(session: session)
        api.handler = { endpoint in
            XCTAssertEqual(endpoint.path, "/assets/\(oldID)/original")
            XCTAssertEqual(endpoint.query, [URLQueryItem(name: "edited", value: "false")])
            await gate.wait()
            return .init(url: download, response: HTTPURLResponse(
                url: URL(string: "https://sharing-ui.example/api/assets/\(oldID)/original")!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "image/png",
                    "Content-Disposition": "attachment; filename=\"\(filename)\""])!)
        }
        let (controller, window) = try await show([current], ids: [LocalPhotoLibrary.assetID(for: localID)],
            session: session, api: api)
        try await tap("photoShare.original", in: controller)
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(api.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))

        try SwiftDataManager.shared.upsertBackupRecord(assetID: newID, checksum: "", localIdentifier: localID)
        try await waitUntil("A changed device mapping revokes the mounted share immediately") { self.mounted?.finished == true }
        gate.release()
        try await waitUntil("A late original from the old mapping is deleted") {
            !FileManager.default.fileExists(atPath: download.path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(try managedShareFiles { $0.lastPathComponent == filename }.isEmpty)
        XCTAssertNil(presented(UIDocumentPickerViewController.self, from: window.rootViewController))
        XCTAssertEqual(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID)?.assetId, newID)
        XCTAssertEqual(api.calls, 1)
        api.handler = nil
    }

    private func seedMapping(_ localID: String, serverID: String) throws {
        XCTAssertNil(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID))
        localMappings.append(localID)
        try SwiftDataManager.shared.linkDeviceAsset(localIdentifier: localID, to: serverID)
        XCTAssertEqual(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID)?.assetId, serverID)
    }

    func testPrivacyRevocationClosesTheMountedComposerAndCleansPreparedFiles() async throws {
        let current = try managedCopy(image(color: .blue))
        let admission = PhotoSharingAdmission()
        _ = try await show([current], admission: admission)

        admission.allowed = false

        try await waitUntil("Live privacy revocation closes the actual composer") { self.mounted?.finished == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testPreparedBytesFromAPreviousServerAreRejectedBeforeTheComposerIsCreated() async throws {
        let original = try image(color: .red)
        let bytes = try Data(contentsOf: original)
        let prepared = try managedCopy(original)
        let id = UUID().uuidString
        let session = try session()
        let generation = LocalSnapshot.generation
        let preparedContext = session.snapshot
        try session.setServer("https://sharing-ui-other.example")
        XCTAssertEqual(LocalSnapshot.generation, generation)
        XCTAssertNotEqual(session.snapshot, preparedContext)
        let requests = PhotoSharingRequests()
        requests.unexpected = expectation(description: "Stale server bytes cannot request an original on another server")
        requests.unexpected?.isInverted = true
        let api = api(session, bytes: bytes, requests: requests)
        let clipboardRevision = UIPasteboard.general.changeCount
        let state = PhotoSharingMountedState()
        state.content = AnyView(PhotoShareSheet(urls: [prepared], assetIDs: [id], sourceIDs: [id],
            requestContext: preparedContext, api: api, isAllowed: { _ in true })
            .environment(session as SessionManager))
        mounted = state

        let window = try await host(PhotoSharingMountedHost(state: state))
        try await waitUntil("Files prepared under a previous server context dismiss instead of being admitted at mount") {
            state.finished
        }
        await fulfillment(of: [try XCTUnwrap(requests.unexpected)], timeout: 0.25)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertEqual(UIPasteboard.general.changeCount, clipboardRevision)
        XCTAssertNil(presented(PhotoShareViewController.self, from: window.rootViewController))
        XCTAssertNil(presented(UIActivityViewController.self, from: window.rootViewController))
        XCTAssertNil(presented(UIDocumentPickerViewController.self, from: window.rootViewController))
    }

    func testServerContextChangeClosesTheMountedComposerWithoutReusingItsFiles() async throws {
        let current = try managedCopy(image(color: .blue))
        let session = try session()
        let generation = LocalSnapshot.generation
        _ = try await show([current], session: session)

        try session.setServer("https://sharing-ui-other.example")

        XCTAssertEqual(LocalSnapshot.generation, generation)
        try await waitUntil("A server-only context change closes the actual composer") { self.mounted?.finished == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testLandscapeBoundsAndLargeTypeKeepEveryActionReachableByScrolling() async throws {
        let current = try managedCopy(image(color: .blue))
        let (controller, window) = try await show([current], size: CGSize(width: 844, height: 390), largeType: true)
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
        try await waitUntil("Landscape content uses an actual vertical scroll view") { scroll.contentSize.height > scroll.bounds.height }

        for id in ["photoShare.options", "photoShare.copy", "photoShare.continue", "photoShare.original", "photoShare.close"] {
            let control = try button(id, in: controller.view)
            let rect = control.convert(control.bounds, to: scroll)
            scroll.scrollRectToVisible(rect.insetBy(dx: -4, dy: -4), animated: false)
            window.layoutIfNeeded()
            let frame = control.convert(control.bounds, to: window)
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(scroll.convert(scroll.bounds, to: window).intersects(frame), "The actual \(id) control must remain reachable")
            XCTAssertTrue(control.isEnabled)
        }
        _ = try await screenshot(window)
    }

    func testMoviePreviewDisplaysAnExtractedFrameRatherThanAGenericPlaceholder() async throws {
        let movie = try TemporaryMediaStore.adoptShareFile(at: await makePagerPlaybackMovie(), suggestedFilename: "preview-\(UUID()).mov")
        files.append(movie)
        let (controller, window) = try await show([movie])

        try await waitUntil("The real movie preview receives its extracted video frame") {
            self.views(controller.view).compactMap { ($0 as? UIImageView)?.image }.contains {
                !$0.isSymbolImage && $0.cgImage?.width == 16 && $0.cgImage?.height == 16
            }
        }
        _ = try await screenshot(window)
    }

    private func show(_ urls: [URL], ids: [String]? = nil, session supplied: MockSessionManager? = nil,
                      api: APIClient? = nil, admission: PhotoSharingAdmission? = nil,
                      size: CGSize = CGSize(width: 390, height: 844), largeType: Bool = false) async throws -> (PhotoShareViewController, UIWindow) {
        let session = try supplied ?? session()
        let state = PhotoSharingMountedState()
        state.content = AnyView(PhotoShareSheet(urls: urls, assetIDs: ids ?? urls.map { _ in UUID().uuidString },
            api: api, isAllowed: { _ in admission?.allowed ?? true }).environment(session as SessionManager))
        mounted = state
        let window = try await host(PhotoSharingMountedHost(state: state))
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        try await waitUntil("The real photo share sheet presents its composer") {
            self.presented(PhotoShareViewController.self, from: window.rootViewController) != nil
        }
        let controller = try XCTUnwrap(presented(PhotoShareViewController.self, from: window.rootViewController))
        retainedController = controller
        if largeType { controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        try await waitUntil("The actual photo share composer loads its controls") {
            self.views(controller.view).contains { $0.accessibilityIdentifier == "photoShare.copy" }
        }
        return (controller, window)
    }

    private func session() throws -> MockSessionManager {
        let session = MockSessionManager()
        try session.setServer("https://sharing-ui.example")
        return session
    }

    private func api(_ session: MockSessionManager, bytes: Data, filename: String = "original.png",
                     requests: PhotoSharingRequests) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        transports.append(transport)
        MockURLProtocol.responseProvider = { request in
            requests.record(request)
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Content-Disposition": "attachment; filename=\"\(filename)\""]), nil)
        }
        return APIClient(session: session, urlSession: transport)
    }

    private func tap(_ id: String, in controller: PhotoShareViewController) async throws {
        try await waitUntil("The actual \(id) button is enabled") {
            self.views(controller.view).compactMap { $0 as? UIButton }.contains {
                $0.accessibilityIdentifier == id && $0.isEnabled && !$0.isHidden && $0.window != nil
            }
        }
        let control = try button(id, in: controller.view)
        control.sendActions(for: .touchUpInside)
    }

    private func chooseOptions(location: Bool, format: String?, in controller: PhotoShareViewController, window: UIWindow) async throws {
        try await tap("photoShare.options", in: controller)
        try await waitUntil("The actual sharing Options form is presented") {
            self.presented(UIHostingController<PhotoShareOptionsView>.self, from: controller) != nil
        }
        let options = try XCTUnwrap(presented(UIHostingController<PhotoShareOptionsView>.self, from: controller))
        try await waitUntil("The native Location switch is rendered") { self.views(options.view).contains { $0 is UISwitch } }
        let toggle = try XCTUnwrap(views(options.view).compactMap { $0 as? UISwitch }.first)
        XCTAssertTrue(toggle.isOn)
        toggle.setOn(location, animated: false)
        toggle.sendActions(for: .valueChanged)
        if let format { try await activateAccessibilityButton(named: format, in: window, within: options.view) }
        try await activateAccessibilityButton(named: "Done", in: window, within: options.view)
        try await waitUntil("Done dismisses Options and applies the native switch value") {
            self.presented(UIHostingController<PhotoShareOptionsView>.self, from: controller) == nil
                && controller.options.includeLocation == location
        }
    }

    private func button(_ id: String, in root: UIView) throws -> UIButton {
        try XCTUnwrap(views(root).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id })
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func containsText(_ text: String, in view: UIView) -> Bool {
        views(view).contains { ($0 as? UILabel)?.text == text }
    }
    private func presented<T: UIViewController>(_ type: T.Type, from controller: UIViewController?) -> T? {
        guard let controller else { return nil }
        if let found = controller as? T { return found }
        if let found = presented(type, from: controller.presentedViewController) { return found }
        return controller.children.lazy.compactMap { self.presented(type, from: $0) }.first
    }

    private func captureClipboard() {
        previousClipboard = UIPasteboard.general.items
        previousClipboardRevision = UIPasteboard.general.changeCount
    }

    private func load(_ provider: NSItemProvider, type: UTType) async throws -> PhotoSharingLoadedFile {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    if let error { throw error }
                    let url = try XCTUnwrap(url)
                    let data = try Data(contentsOf: url)
                    let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let identifier = try XCTUnwrap(CGImageSourceGetType(image) as String?)
                    continuation.resume(returning: PhotoSharingLoadedFile(data: data, type: identifier))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func image(type: UTType = .png, color: UIColor, location: Bool = false) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = directory.appendingPathComponent("\(UUID()).\(type.preferredFilenameExtension!)")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var metadata: [CFString: Any] = [kCGImagePropertyTIFFDictionary:
            [kCGImagePropertyTIFFImageDescription: directory.lastPathComponent]]
        if location {
            metadata[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.3,
                kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.1, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func managedCopy(_ source: URL) throws -> URL {
        let stage = directory.appendingPathComponent("stage-\(UUID())")
        try FileManager.default.copyItem(at: source, to: stage)
        let managed = try TemporaryMediaStore.adoptShareFile(at: stage, suggestedFilename: source.lastPathComponent)
        files.append(managed)
        return managed
    }

    private func imageProperties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func metadataPaths(_ source: CGImageSource) -> [String] {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [] }
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, _ in paths.append(path as String); return true }
        return paths
    }
}

@MainActor
@Observable
private final class PhotoSharingMountedState {
    var content: AnyView?
    var finished = false
    var isPresented = true
    func finish() {
        finished = true
        isPresented = false
        content = nil
    }
}

private struct PhotoSharingMountedHost: View {
    let state: PhotoSharingMountedState
    var body: some View {
        Color.clear.sheet(isPresented: Binding(get: { state.isPresented }, set: { state.isPresented = $0 }),
            onDismiss: { state.finish() }) { state.content }
    }
}

@MainActor
@Observable
private final class PhotoSharingAdmission { var allowed = true }

private struct PhotoSharingLoadedFile: Sendable { let data: Data; let type: String }

private final class PhotoSharingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URLRequest] = []
    var unexpected: XCTestExpectation?
    var values: [URLRequest] { lock.withLock { entries } }
    func record(_ request: URLRequest) {
        lock.withLock { entries.append(request) }
        unexpected?.fulfill()
    }
}

@MainActor
private final class PhotoSharingDownloadGate {
    let started = XCTestExpectation(description: "The unmodified download is held")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class PhotoSharingHeldClient: APIClient {
    var handler: ((Endpoint) async throws -> DownloadedFile)?
    var calls = 0
    override func rawFile(_ endpoint: Endpoint) async throws -> DownloadedFile {
        calls += 1
        return try await XCTUnwrap(handler)(endpoint)
    }
}
