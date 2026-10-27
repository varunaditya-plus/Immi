import Photos
import XCTest
@testable import ImmichApp

final class LocalSpaceSafetyTests: XCTestCase {
    private let digest = "a9993e364706816aba3e25717850c26c9cd0d89d"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testOriginalPhotoAndVideoAreSupported() {
        XCTAssertEqual(LocalSpaceSafety.resourceRoles(for: version()), [.primary: PHAssetResourceType.photo.rawValue])
        XCTAssertEqual(LocalSpaceSafety.resourceRoles(for: version(video: true, types: [.video])),
            [.primary: PHAssetResourceType.video.rawValue])
    }

    func testLivePhotoRequiresBothOriginalResources() {
        XCTAssertEqual(LocalSpaceSafety.resourceRoles(for: version(live: true, types: [.photo, .pairedVideo])),
            [.primary: PHAssetResourceType.photo.rawValue, .motion: PHAssetResourceType.pairedVideo.rawValue])
        XCTAssertNil(LocalSpaceSafety.resourceRoles(for: version(live: true)))
        XCTAssertNil(LocalSpaceSafety.resourceRoles(for: version(live: true, types: [.pairedVideo])))
    }

    func testEditedAndAdditionalOriginalResourcesAreNotEligible() {
        for types: [PHAssetResourceType] in [
            [.photo, .adjustmentData], [.photo, .fullSizePhoto],
            [.photo, .alternatePhoto], [.photo, .adjustmentBasePhoto],
            [.video, .fullSizeVideo], [.photo, .pairedVideo, .adjustmentData],
            [.fullSizePhoto, .fullSizePairedVideo],
        ] {
            XCTAssertNil(LocalSpaceSafety.resourceRoles(for:
                version(video: types.contains(.video), live: types.contains(.pairedVideo)
                    || types.contains(.fullSizePairedVideo), types: types)))
        }
    }

    func testUnknownResourceCannotBeSilentlyDiscarded() {
        let original = version()
        let unknown = LocalAssetVersion(createdAt: original.createdAt, modifiedAt: original.modifiedAt,
            isFavorite: false, isVideo: false, isLivePhoto: false, pixelWidth: 100, pixelHeight: 100,
            duration: 0, resources: original.resources + [
                LocalSpaceResourceDescriptor(type: 999, filename: "unknown.bin", contentType: "public.data"),
            ])
        XCTAssertNil(LocalSpaceSafety.resourceRoles(for: unknown))
    }

    func testCutoffFavoritesAlbumAndMediaKeepRules() {
        let oldPhoto = state(version())
        XCTAssertTrue(LocalSpaceSafety.isEligible(oldPhoto, rules: LocalSpaceRules(cutoff: date.addingTimeInterval(1))))
        XCTAssertFalse(LocalSpaceSafety.isEligible(oldPhoto, rules: LocalSpaceRules(cutoff: date)))
        XCTAssertFalse(LocalSpaceSafety.isEligible(state(version(favorite: true)),
            rules: LocalSpaceRules(keepFavorites: true)))
        XCTAssertTrue(LocalSpaceSafety.isEligible(state(version(favorite: true)), rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.isEligible(state(version(), keptAlbum: true), rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.isEligible(oldPhoto, rules: LocalSpaceRules(keepPhotos: true)))
        XCTAssertTrue(LocalSpaceSafety.isEligible(oldPhoto, rules: LocalSpaceRules(keepVideos: true)))
        XCTAssertFalse(LocalSpaceSafety.isEligible(state(version(video: true, types: [.video])),
            rules: LocalSpaceRules(keepVideos: true)))
    }

    func testUnchangedReviewedBatchCanBeDeleted() {
        let photo = candidate(id: "photo", version: version())
        let live = candidate(id: "live", version: version(live: true, types: [.photo, .pairedVideo]),
            checksums: [.primary: digest, .motion: digest])
        XCTAssertTrue(LocalSpaceSafety.canDelete([photo, live], current: [
            state(photo.version, id: photo.id), state(live.version, id: live.id),
        ], rules: LocalSpaceRules(cutoff: date.addingTimeInterval(1))))
    }

    func testChangedVersionAbortsTheWholeBatch() {
        let first = candidate(id: "first", version: version())
        let second = candidate(id: "second", version: version())
        let changed = version(modified: date.addingTimeInterval(1))
        XCTAssertFalse(LocalSpaceSafety.canDelete([first, second], current: [
            state(first.version, id: first.id), state(changed, id: second.id),
        ], rules: LocalSpaceRules()))
    }

    func testNewlyProtectedAlbumMembershipAbortsDeletionWithoutAssetDateChange() {
        let reviewed = candidate(id: "photo", version: version())
        XCTAssertFalse(LocalSpaceSafety.canDelete([reviewed], current: [
            state(reviewed.version, id: reviewed.id, keptAlbum: true),
        ], rules: LocalSpaceRules(keepAlbumIDs: ["protected-album"])))
    }

    func testMissingOrDuplicateAssetsCannotBecomeAPartialDeletion() {
        let reviewed = candidate(id: "photo", version: version())
        XCTAssertFalse(LocalSpaceSafety.canDelete([reviewed], current: [], rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.canDelete([reviewed, reviewed], current: [state(reviewed.version)],
            rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.canDelete([reviewed], current: [state(reviewed.version), state(reviewed.version)],
            rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.canDelete([], current: [], rules: LocalSpaceRules()))
    }

    func testIncompleteOrMalformedChecksumEvidenceIsRejected() {
        let original = version()
        XCTAssertFalse(LocalSpaceSafety.canDelete([candidate(version: original, checksums: [:])],
            current: [state(original)], rules: LocalSpaceRules()))
        XCTAssertFalse(LocalSpaceSafety.canDelete([candidate(version: original, checksums: [.primary: "cached-value"])],
            current: [state(original)], rules: LocalSpaceRules()))
        let live = version(live: true, types: [.photo, .pairedVideo])
        XCTAssertFalse(LocalSpaceSafety.canDelete([candidate(version: live)],
            current: [state(live)], rules: LocalSpaceRules()))
    }

    func testIncrementalPhotoKitChunksProduceKnownSHA1() async {
        let checksum = LocalSpaceChecksumState()
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(checksum.begin(continuation))
            checksum.append(Data("a".utf8))
            checksum.append(Data("bc".utf8))
            checksum.finish(error: nil)
            checksum.finish(error: URLError(.cancelled))
        }
        XCTAssertEqual(value, digest)
    }

    func testResourceReadFailureDoesNotProduceDeletionEvidence() async {
        let checksum = LocalSpaceChecksumState()
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(checksum.begin(continuation))
            checksum.append(Data("abc".utf8))
            checksum.finish(error: URLError(.notConnectedToInternet))
            checksum.finish(error: nil)
        }
        XCTAssertNil(value)
    }

    func testEmptySuccessfulResourceReadDoesNotProduceDeletionEvidence() async {
        let checksum = LocalSpaceChecksumState()
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(checksum.begin(continuation))
            checksum.append(Data())
            checksum.finish(error: nil)
        }
        XCTAssertNil(value)
    }

    func testCancellationBeforeAndDuringResourceReadCompletesOnce() async {
        let before = LocalSpaceChecksumState()
        before.cancel()
        let beforeValue = await withCheckedContinuation { continuation in
            XCTAssertFalse(before.begin(continuation))
        }
        XCTAssertNil(beforeValue)

        let during = LocalSpaceChecksumState()
        let duringValue = await withCheckedContinuation { continuation in
            XCTAssertTrue(during.begin(continuation))
            during.append(Data("abc".utf8))
            during.cancel()
            during.append(Data("late".utf8))
            during.finish(error: nil)
        }
        XCTAssertNil(duringValue)
    }

    func testCancelledTransactionCannotAuthorizeNativeDeletion() {
        let cancelled = LocalSpaceDeletionTransaction()
        cancelled.cancel()
        var registered = false
        XCTAssertFalse(cancelled.authorize(["photo"]) { registered = true })
        XCTAssertFalse(registered)
        XCTAssertNil(cancelled.authorizedIDs)

        let current = LocalSpaceDeletionTransaction()
        XCTAssertTrue(current.authorize(["photo"]) { registered = true })
        XCTAssertTrue(registered)
        XCTAssertEqual(current.authorizedIDs, ["photo"])
        // After a submitted transaction succeeds, its result still needs local
        // mapping cleanup even if the surrounding UI task was then cancelled.
        current.cancel()
        XCTAssertEqual(current.authorizedIDs, ["photo"])
    }

    private func version(
        modified: Date? = nil, favorite: Bool = false, video: Bool = false,
        live: Bool = false, types: [PHAssetResourceType] = [.photo]
    ) -> LocalAssetVersion {
        LocalAssetVersion(createdAt: date, modifiedAt: modified ?? date, isFavorite: favorite,
            isVideo: video, isLivePhoto: live, pixelWidth: 100, pixelHeight: 100, duration: video ? 1 : 0,
            resources: types.map { LocalSpaceResourceDescriptor(type: $0.rawValue,
                filename: "resource-\($0.rawValue)", contentType: "public.data") })
    }

    private func state(_ version: LocalAssetVersion, id: String = "photo", keptAlbum: Bool = false) -> LocalSpaceAssetState {
        LocalSpaceAssetState(id: id, version: version, isInKeptAlbum: keptAlbum)
    }

    private func candidate(
        id: String = "photo", version: LocalAssetVersion, checksums: [LocalSpaceResource: String]? = nil
    ) -> LocalSpaceCandidate {
        LocalSpaceCandidate(id: id, version: version, resourceChecksums: checksums ?? [.primary: digest])
    }
}
