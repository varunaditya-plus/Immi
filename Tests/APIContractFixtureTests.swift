import XCTest
@testable import ImmichApp

final class APIContractFixtureTests: XCTestCase {
    private let decoder = JSONDecoder.immich

    func testPinnedOpenAPIContractMetadata() throws {
        let root = try fixtureObject(named: "immich-openapi-contract-v3")
        XCTAssertEqual(root["sourceCommit"] as? String, "51c2f21497800225e0622d515d0ef463d7af69cc")
        XCTAssertEqual(root["openAPIVersion"] as? String, "3.0.0")
        XCTAssertEqual(root["immichAPIVersion"] as? String, "3.1.0")

        let endpoints = try XCTUnwrap(root["endpointContracts"] as? [String: Any])
        let albumAssets = try XCTUnwrap(endpoints["albumAssets"] as? [String: Any])
        XCTAssertEqual(albumAssets["path"] as? String, "/search/metadata")
        XCTAssertEqual(albumAssets["state"] as? String, "Stable")
        let updatePeople = try XCTUnwrap(endpoints["updatePeople"] as? [String: Any])
        XCTAssertEqual(updatePeople["path"] as? String, "/people")
        XCTAssertEqual(updatePeople["state"] as? String, "Stable")
        let updateAsset = try XCTUnwrap(
            endpoints["updateAssetCompatibility"] as? [String: Any])
        XCTAssertEqual(updateAsset["state"] as? String, "Deprecated")
        XCTAssertEqual(updateAsset["replacementAvailable"] as? Bool, false)

        let contracts = try XCTUnwrap(root["contracts"] as? [String: Any])
        let assetDuration = try XCTUnwrap(
            contracts["AssetResponseDto.duration"] as? [String: Any])
        XCTAssertEqual(assetDuration["jsonType"] as? String, "integer")
        XCTAssertEqual(assetDuration["unit"] as? String, "milliseconds")

        let syncDuration = try XCTUnwrap(
            contracts["SyncAssetV1.duration"] as? [String: Any])
        XCTAssertEqual(syncDuration["jsonType"] as? String, "string")
        XCTAssertEqual(syncDuration["unit"] as? String, "clock")
    }

    func testCurrentCoreResponseFixturesDecode() throws {
        let login = try decoder.decode(LoginResponseDTO.self, from: fixtureData(for: "login"))
        XCTAssertTrue(login.isOnboarded == true)
        XCTAssertEqual(login.profileImagePath, "")

        let user = try decoder.decode(UserResponseDTO.self, from: fixtureData(for: "user"))
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertEqual(user.isAdmin, false)

        let asset = try decoder.decode(AssetResponseDTO.self, from: fixtureData(for: "asset"))
        XCTAssertTrue(asset.isVideo)
        XCTAssertEqual(asset.duration, 95)
        XCTAssertEqual(asset.durationText, "1:35")
        XCTAssertEqual(asset.exifInfo?.city, "Jakarta")

        let album = try decoder.decode(AlbumResponseDTO.self, from: fixtureData(for: "album"))
        XCTAssertEqual(album.assetCount, 0)
        XCTAssertEqual(album.description, "Fixture description")

        let person = try decoder.decode(PersonDTO.self, from: fixtureData(for: "person"))
        XCTAssertNotNil(person.birthDate)

        let memory = try decoder.decode(MemoryDTO.self, from: fixtureData(for: "memory"))
        XCTAssertEqual(memory.data?.year, 2020)

        let search = try decoder.decode(SearchResponseDTO.self, from: fixtureData(for: "search"))
        XCTAssertEqual(search.assets.total, 0)
        XCTAssertNil(search.assets.nextPage)
    }

    func testCurrentServerAndUtilityResponseFixturesDecode() throws {
        let features = try decoder.decode(
            ServerFeaturesDTO.self, from: fixtureData(for: "serverFeatures"))
        XCTAssertTrue(features.map)
        XCTAssertTrue(features.trash)
        XCTAssertTrue(features.ocr)
        XCTAssertTrue(features.realtimeTranscoding)

        let about = try decoder.decode(ServerAboutDTO.self, from: fixtureData(for: "serverAbout"))
        XCTAssertEqual(about.version, "v3.1.0")

        let storage = try decoder.decode(
            ServerStorageDTO.self, from: fixtureData(for: "serverStorage"))
        XCTAssertEqual(storage.diskSizeRaw, 1_099_511_627_776)

        let link = try decoder.decode(SharedLinkDTO.self, from: fixtureData(for: "sharedLink"))
        XCTAssertFalse(link.isAlbum)
        XCTAssertNil(link.expiresAt)

        let marker = try decoder.decode(MapMarkerDTO.self, from: fixtureData(for: "mapMarker"))
        XCTAssertEqual(marker.lat, -6.2)

        let stats = try decoder.decode(AssetStatsDTO.self, from: fixtureData(for: "assetStats"))
        XCTAssertEqual(stats.total, 110)

        let version = try decoder.decode(
            VersionCheckDTO.self, from: fixtureData(for: "versionCheck"))
        XCTAssertEqual(version.releaseVersion, "v3.1.0")

        let status = try decoder.decode(AuthStatusDTO.self, from: fixtureData(for: "authStatus"))
        XCTAssertTrue(status.pinCode)
        XCTAssertFalse(status.isElevated)

        struct BulkResponse: Decodable {
            let results: [BackupRepository.BulkCheckResult]
        }
        let bulk = try decoder.decode(
            BulkResponse.self, from: fixtureData(for: "bulkUploadCheck"))
        XCTAssertEqual(bulk.results.first?.reason, "duplicate")
        XCTAssertEqual(
            bulk.results.first?.assetId,
            "22222222-2222-4222-8222-222222222222")
    }

    func testAssetAndSyncUseTheirDistinctDurationContracts() throws {
        let asset = try decoder.decode(AssetResponseDTO.self, from: fixtureData(for: "asset"))
        XCTAssertEqual(asset.duration, 95)

        let lineData = try fixtureData(for: "syncAssetLine")
        let envelope = try decoder.decode(SyncLineEnvelopeDTO.self, from: lineData)
        let line = try decoder.decode(
            SyncLineDataDTO<SyncAssetV1DTO>.self, from: lineData)
        XCTAssertEqual(envelope.type, "AssetV1")
        XCTAssertEqual(ClockDuration.seconds(fromClock: line.data.duration), 95)
    }

    func testNullablePatchFieldsEncodeNullInsteadOfLegacyFlags() throws {
        let edit = SharedLinkEditDTO(
            description: .some(nil),
            password: .some(nil),
            expiresAt: .some(nil),
            allowUpload: false,
            allowDownload: true,
            showMetadata: true,
            slug: .some(nil))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(edit))
                as? [String: Any])
        XCTAssertTrue(object["description"] is NSNull)
        XCTAssertTrue(object["password"] is NSNull)
        XCTAssertTrue(object["expiresAt"] is NSNull)
        XCTAssertTrue(object["slug"] is NSNull)
        XCTAssertNil(object["changeExpiryTime"])

        let album = AlbumUpdateDTO(albumName: "Renamed", description: .some(nil))
        let albumObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(album))
                as? [String: Any])
        XCTAssertTrue(albumObject["description"] is NSNull)
    }

    // MARK: - Fixtures

    private func fixtureData(for key: String) throws -> Data {
        let root = try fixtureObject(named: "immich-api-responses-v3")
        let value = try XCTUnwrap(root[key], "Missing fixture key: \(key)")
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        let fixtureURL = try XCTUnwrap(url, "Fixture \(name).json is not in the test bundle")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
        return try XCTUnwrap(object as? [String: Any])
    }
}
