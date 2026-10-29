import XCTest
@testable import ImmichApp

final class DTODecodingTests: XCTestCase {
    let decoder = JSONDecoder.immich

    // MARK: - Date strategy

    func testDateStrategyVariants() throws {
        // JSONDecoder.immich must accept fractional ISO8601, plain ISO8601 and date-only.
        let json = #"["2024-01-01T12:00:00.000Z", "2024-01-01T12:00:00Z", "2024-01-01"]"#
        let dates = try decoder.decode([Date].self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates[0], dates[1]) // .000 fraction == no fraction
        // Date-only is midnight UTC of the same day.
        XCTAssertEqual(dates[2], dates[0].addingTimeInterval(-12 * 3600))
    }

    func testInvalidDateThrows() {
        let json = #"["not-a-date"]"#
        XCTAssertThrowsError(try decoder.decode([Date].self, from: json.data(using: .utf8)!))
    }

    // MARK: - Auth / server

    func testLoginResponseDecoding() throws {
        let json = """
        {
            "accessToken": "abc123token",
            "userId": "user-id-123",
            "userEmail": "user@example.com",
            "name": "John Doe",
            "isAdmin": false,
            "shouldChangePassword": false
        }
        """
        let dto = try decoder.decode(LoginResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.accessToken, "abc123token")
        XCTAssertEqual(dto.userId, "user-id-123")
        XCTAssertEqual(dto.userEmail, "user@example.com")
        XCTAssertEqual(dto.name, "John Doe")
        XCTAssertFalse(dto.isAdmin)
        XCTAssertFalse(dto.shouldChangePassword)
    }

    func testServerPingDecoding() throws {
        let dto = try decoder.decode(ServerPingDTO.self, from: #"{"res":"pong"}"#.data(using: .utf8)!)
        XCTAssertEqual(dto.res, "pong")
    }

    func testServerFeaturesDecoding() throws {
        let json = """
        {
            "smartSearch": true,
            "facialRecognition": true,
            "oauth": false,
            "passwordLogin": true,
            "search": true
        }
        """
        let dto = try decoder.decode(ServerFeaturesDTO.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(dto.smartSearch)
        XCTAssertTrue(dto.facialRecognition)
        XCTAssertFalse(dto.oauth)
        XCTAssertTrue(dto.passwordLogin)
        XCTAssertTrue(dto.search)
    }

    func testServerStorageDecoding() throws {
        let json = """
        {
            "diskUse": "1TB",
            "diskSize": "2TB",
            "diskUseRaw": 123,
            "diskSizeRaw": 456,
            "diskUsagePercentage": 50.5
        }
        """
        let dto = try decoder.decode(ServerStorageDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.diskUse, "1TB")
        XCTAssertEqual(dto.diskSize, "2TB")
        XCTAssertEqual(dto.diskUseRaw, 123)
        XCTAssertEqual(dto.diskSizeRaw, 456)
        XCTAssertEqual(dto.diskUsagePercentage, 50.5)
    }

    // MARK: - Users

    func testUserResponseDecoding() throws {
        let json = """
        {
            "id": "user-123",
            "email": "user@example.com",
            "name": "John Doe",
            "profileImagePath": "/path/to/image.jpg",
            "storageLabel": "primary",
            "isAdmin": true
        }
        """
        let dto = try decoder.decode(UserResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.id, "user-123")
        XCTAssertEqual(dto.email, "user@example.com")
        XCTAssertEqual(dto.name, "John Doe")
        XCTAssertEqual(dto.profileImagePath, "/path/to/image.jpg")
        XCTAssertEqual(dto.storageLabel, "primary")
        XCTAssertEqual(dto.isAdmin, true)
    }

    func testUserOptionalFieldsHandling() throws {
        let json = """
        {
            "id": "user-123",
            "email": "user@example.com",
            "name": "John",
            "profileImagePath": null,
            "storageLabel": null
        }
        """
        let dto = try decoder.decode(UserResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertNil(dto.profileImagePath)
        XCTAssertNil(dto.storageLabel)
        XCTAssertNil(dto.isAdmin)
        // Older servers don't send profileChangedAt at all.
        XCTAssertNil(dto.profileChangedAt)
    }

    // MARK: - Profile image

    /// Immich sends an EMPTY STRING, not null, for users who never uploaded one.
    func testHasProfileImageTreatsEmptyPathAsMissing() {
        XCTAssertFalse(makeUser(profileImagePath: "").hasProfileImage)
        XCTAssertFalse(makeUser(profileImagePath: nil).hasProfileImage)
        XCTAssertTrue(makeUser(profileImagePath: "upload/profile/u1/a.jpg").hasProfileImage)
    }

    /// The cache key is what makes a replaced profile picture actually download
    /// again — the endpoint URL itself never changes.
    func testProfileImageCacheKeyChangesWhenProfileChanges() {
        let before = makeUser(profileImagePath: "upload/profile/u1/a.jpg",
                              profileChangedAt: "2026-01-01T00:00:00.000Z")
        let sameAgain = makeUser(profileImagePath: "upload/profile/u1/a.jpg",
                                 profileChangedAt: "2026-01-01T00:00:00.000Z")
        let after = makeUser(profileImagePath: "upload/profile/u1/b.jpg",
                             profileChangedAt: "2026-02-02T00:00:00.000Z")

        XCTAssertEqual(before.profileImageCacheKey, sameAgain.profileImageCacheKey)
        XCTAssertNotEqual(before.profileImageCacheKey, after.profileImageCacheKey)
    }

    /// Fallback for servers that don't send profileChangedAt: the uploaded file
    /// name is random, so it changes on its own.
    func testProfileImageCacheKeyFallsBackToPath() {
        let before = makeUser(profileImagePath: "upload/profile/u1/a.jpg")
        let after = makeUser(profileImagePath: "upload/profile/u1/b.jpg")

        XCTAssertNotEqual(before.profileImageCacheKey, after.profileImageCacheKey)
    }

    private func makeUser(
        profileImagePath: String?,
        profileChangedAt: String? = nil
    ) -> UserResponseDTO {
        let json: [String: Any?] = [
            "id": "user-123",
            "email": "user@example.com",
            "name": "John Doe",
            "profileImagePath": profileImagePath,
            "profileChangedAt": profileChangedAt,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: json.compactMapValues { $0 })
        return try! decoder.decode(UserResponseDTO.self, from: data)
    }

    // MARK: - Assets

    func testAssetResponseDecoding() throws {
        let json = """
        {
            "id": "asset-123",
            "type": "IMAGE",
            "originalFileName": "photo.jpg",
            "fileCreatedAt": "2024-01-01T12:00:00.000Z",
            "isFavorite": true,
            "isArchived": false,
            "isTrashed": false,
            "duration": null,
            "thumbhash": "abc123hash",
            "localDateTime": "2024-01-01T12:00:00.000Z",
            "exifInfo": null,
            "people": null
        }
        """
        let dto = try decoder.decode(AssetResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.id, "asset-123")
        XCTAssertEqual(dto.type, "IMAGE")
        XCTAssertEqual(dto.originalFileName, "photo.jpg")
        XCTAssertTrue(dto.isFavorite)
        XCTAssertFalse(dto.isArchived)
        XCTAssertFalse(dto.isTrashed)
        XCTAssertFalse(dto.isVideo)
        XCTAssertNil(dto.duration)
        XCTAssertNil(dto.durationText)
        XCTAssertEqual(dto.thumbhash, "abc123hash")
    }

    /// Immich mengirim durasi sebagai string jam, bukan angka.
    func testAssetVideoDurationClockString() throws {
        let json = """
        {
            "id": "asset-456",
            "type": "VIDEO",
            "originalFileName": "clip.mov",
            "fileCreatedAt": "2024-01-01T12:00:00.000Z",
            "isFavorite": false,
            "isArchived": false,
            "isTrashed": false,
            "duration": "0:01:35.00000",
            "thumbhash": null,
            "localDateTime": "2024-01-01T12:00:00.000Z",
            "exifInfo": null,
            "people": null
        }
        """
        let dto = try decoder.decode(AssetResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(dto.isVideo)
        XCTAssertEqual(dto.duration, 95)
        XCTAssertEqual(dto.durationText, "1:35")
    }

    /// Kontrak API baru mengirim angka milidetik; nilai domain harus tetap detik.
    func testAssetVideoDurationNumberFallback() throws {
        let json = """
        {
            "id": "asset-457",
            "type": "VIDEO",
            "originalFileName": "clip.mov",
            "fileCreatedAt": "2024-01-01T12:00:00.000Z",
            "isFavorite": false,
            "isArchived": false,
            "isTrashed": false,
            "duration": 95000,
            "thumbhash": null,
            "localDateTime": "2024-01-01T12:00:00.000Z",
            "exifInfo": null,
            "people": null
        }
        """
        let dto = try decoder.decode(AssetResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.duration, 95)
        XCTAssertEqual(dto.durationText, "1:35")
    }

    /// Snapshot offline lama menyimpan angka detik. Decoder non-API tidak boleh
    /// membaginya lagi dengan 1.000 ketika aplikasi diperbarui.
    func testAssetVideoDurationSnapshotNumberRemainsSeconds() throws {
        let asset = makeTestAsset(type: "VIDEO", duration: 95)
        let data = try JSONEncoder.immich.encode(asset)
        let snapshotDecoder = JSONDecoder()
        snapshotDecoder.dateDecodingStrategy = .iso8601

        let decoded = try snapshotDecoder.decode(AssetResponseDTO.self, from: data)

        XCTAssertEqual(decoded.duration, 95)
        XCTAssertEqual(decoded.durationText, "1:35")
    }

    func testExifDTODecoding() throws {
        let json = """
        {
            "make": "Canon",
            "model": "EOS 5D Mark IV",
            "exifImageWidth": 4000,
            "exifImageHeight": 3000,
            "fileSizeInByte": 5242880,
            "dateTimeOriginal": "2024-01-01T12:00:00.000Z",
            "latitude": 40.7128,
            "longitude": -74.0060,
            "city": "New York",
            "state": "NY",
            "country": "USA",
            "lensModel": "EF 24-70mm f/2.8L",
            "fNumber": 2.8,
            "focalLength": 50.0,
            "iso": 100,
            "exposureTime": "1/125"
        }
        """
        let dto = try decoder.decode(ExifDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.make, "Canon")
        XCTAssertEqual(dto.model, "EOS 5D Mark IV")
        XCTAssertEqual(dto.exifImageWidth, 4000)
        XCTAssertEqual(dto.exifImageHeight, 3000)
        XCTAssertEqual(dto.city, "New York")
        XCTAssertEqual(dto.country, "USA")
        XCTAssertEqual(dto.latitude, 40.7128)
        XCTAssertEqual(dto.longitude, -74.0060)
    }

    // MARK: - Albums / people

    func testAlbumResponseDecoding() throws {
        let json = """
        {
            "id": "album-123",
            "albumName": "My Album",
            "description": "A nice album",
            "assetCount": 10,
            "albumThumbnailAssetId": "asset-123",
            "shared": false,
            "createdAt": "2024-01-01T12:00:00.000Z",
            "assets": null
        }
        """
        let dto = try decoder.decode(AlbumResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.id, "album-123")
        XCTAssertEqual(dto.albumName, "My Album")
        XCTAssertEqual(dto.assetCount, 10)
        XCTAssertFalse(dto.shared)
    }

    func testPersonDTODecoding() throws {
        // birthDate is date-only in the API.
        let json = """
        {
            "id": "person-123",
            "name": "John Doe",
            "birthDate": "2000-01-15",
            "thumbnailPath": "/path/to/thumbnail.jpg",
            "isHidden": false
        }
        """
        let dto = try decoder.decode(PersonDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.id, "person-123")
        XCTAssertEqual(dto.name, "John Doe")
        XCTAssertNotNil(dto.birthDate)
        XCTAssertFalse(dto.isHidden)
    }

    // MARK: - Memories (GET /memories returns a bare array)

    func testMemoriesBareArrayDecoding() throws {
        let json = """
        [
            {
                "id": "memory-123",
                "type": "on_this_day",
                "memoryAt": "2024-08-03T00:00:00.000Z",
                "assets": []
            }
        ]
        """
        let memories = try decoder.decode([MemoryDTO].self, from: json.data(using: .utf8)!)

        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].id, "memory-123")
        XCTAssertEqual(memories[0].type, "on_this_day")
        XCTAssertTrue(memories[0].assets.isEmpty)
    }

    // MARK: - Search

    func testSearchResponseDecoding() throws {
        let json = """
        {
            "assets": {
                "items": [
                    {
                        "id": "asset-1",
                        "type": "IMAGE",
                        "originalFileName": "photo1.jpg",
                        "fileCreatedAt": "2024-08-03T10:30:00.000Z",
                        "isFavorite": false,
                        "isArchived": false,
                        "isTrashed": false,
                        "duration": null,
                        "thumbhash": "hash1",
                        "localDateTime": "2024-08-03T10:30:00.000Z",
                        "exifInfo": null,
                        "people": null
                    }
                ],
                "total": 1,
                "nextPage": null
            }
        }
        """
        let dto = try decoder.decode(SearchResponseDTO.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(dto.assets.items.count, 1)
        XCTAssertEqual(dto.assets.total, 1)
        XCTAssertNil(dto.assets.nextPage)
    }

    func testSearchSuggestionsBareArrayDecoding() throws {
        // GET /search/suggestions returns a plain string array.
        let suggestions = try decoder.decode([String].self, from: #"["a","b"]"#.data(using: .utf8)!)
        XCTAssertEqual(suggestions, ["a", "b"])
    }

    // MARK: - Sync stream (JSON Lines: {type, data, ack})

    func testSyncAssetV1LineDecoding() throws {
        let line = """
        {
            "type": "AssetV1",
            "data": {
                "id": "9a8b7c6d-0000-0000-0000-000000000001",
                "ownerId": "9a8b7c6d-0000-0000-0000-000000000002",
                "originalFileName": "IMG_0001.HEIC",
                "checksum": "sVUzS8bZ0dJIeYVPH3EqFw7VNBM=",
                "type": "IMAGE",
                "visibility": "timeline",
                "isFavorite": true,
                "thumbhash": "1QcSHQRnh493V4dIh4eXh1h4kJUI",
                "width": 4032,
                "height": 3024,
                "duration": null,
                "stackId": null,
                "libraryId": null,
                "livePhotoVideoId": null,
                "fileCreatedAt": "2024-01-01T12:00:00.000Z",
                "fileModifiedAt": "2024-01-02T12:00:00.000Z",
                "localDateTime": "2024-01-01T19:00:00.000Z",
                "deletedAt": null
            },
            "ack": "AssetV1|0189f0f0-0000-7000-8000-000000000000"
        }
        """
        let data = line.data(using: .utf8)!

        let envelope = try decoder.decode(SyncLineEnvelopeDTO.self, from: data)
        XCTAssertEqual(envelope.type, "AssetV1")
        XCTAssertEqual(envelope.ack, "AssetV1|0189f0f0-0000-7000-8000-000000000000")

        let payload = try decoder.decode(SyncLineDataDTO<SyncAssetV1DTO>.self, from: data).data
        XCTAssertEqual(payload.id, "9a8b7c6d-0000-0000-0000-000000000001")
        XCTAssertEqual(payload.ownerId, "9a8b7c6d-0000-0000-0000-000000000002")
        XCTAssertEqual(payload.originalFileName, "IMG_0001.HEIC")
        XCTAssertEqual(payload.checksum, "sVUzS8bZ0dJIeYVPH3EqFw7VNBM=")
        XCTAssertEqual(payload.type, "IMAGE")
        XCTAssertEqual(payload.visibility, "timeline")
        XCTAssertTrue(payload.isFavorite)
        XCTAssertEqual(payload.thumbhash, "1QcSHQRnh493V4dIh4eXh1h4kJUI")
        XCTAssertEqual(payload.width, 4032)
        XCTAssertEqual(payload.height, 3024)
        XCTAssertNil(payload.duration)
        XCTAssertNil(payload.stackId)
        XCTAssertNil(payload.libraryId)
        XCTAssertNil(payload.livePhotoVideoId)
        XCTAssertNotNil(payload.fileCreatedAt)
        XCTAssertNotNil(payload.fileModifiedAt)
        XCTAssertNotNil(payload.localDateTime)
        XCTAssertNil(payload.deletedAt)
    }

    func testSyncAssetDeleteV1LineDecoding() throws {
        let line = """
        {
            "type": "AssetDeleteV1",
            "data": { "assetId": "9a8b7c6d-0000-0000-0000-000000000001" },
            "ack": "AssetDeleteV1|0189f0f0-0000-7000-8000-000000000001"
        }
        """
        let data = line.data(using: .utf8)!

        let envelope = try decoder.decode(SyncLineEnvelopeDTO.self, from: data)
        XCTAssertEqual(envelope.type, "AssetDeleteV1")
        XCTAssertEqual(envelope.ack, "AssetDeleteV1|0189f0f0-0000-7000-8000-000000000001")

        let payload = try decoder.decode(SyncLineDataDTO<SyncAssetDeleteV1DTO>.self, from: data).data
        XCTAssertEqual(payload.assetId, "9a8b7c6d-0000-0000-0000-000000000001")
    }

    func testSyncAssetV2LineDecodingUsesMillisecondDuration() throws {
        let line = """
        {
            "type": "AssetV2",
            "data": {
                "id": "9a8b7c6d-0000-0000-0000-000000000001",
                "ownerId": "9a8b7c6d-0000-0000-0000-000000000002",
                "originalFileName": "IMG_0001.MOV",
                "checksum": "sVUzS8bZ0dJIeYVPH3EqFw7VNBM=",
                "type": "VIDEO",
                "visibility": "timeline",
                "isFavorite": false,
                "thumbhash": null,
                "width": 1920,
                "height": 1080,
                "duration": 95450,
                "stackId": null,
                "libraryId": null,
                "livePhotoVideoId": null,
                "fileCreatedAt": "2024-01-01T12:00:00.000Z",
                "fileModifiedAt": "2024-01-02T12:00:00.000Z",
                "createdAt": "2024-01-02T12:00:00.000Z",
                "localDateTime": "2024-01-01T19:00:00.000Z",
                "deletedAt": null,
                "isEdited": false
            },
            "ack": "AssetV2|0189f0f0-0000-7000-8000-000000000000"
        }
        """
        let data = try XCTUnwrap(line.data(using: .utf8))

        let envelope = try decoder.decode(SyncLineEnvelopeDTO.self, from: data)
        XCTAssertEqual(envelope.type, "AssetV2")

        let payload = try decoder.decode(
            SyncLineDataDTO<SyncAssetV2DTO>.self, from: data).data
        XCTAssertEqual(payload.duration, 95_450)
        XCTAssertEqual(Double(payload.duration!) / 1_000, 95.45, accuracy: 0.001)
        XCTAssertFalse(payload.isEdited)
    }

    func testSyncStreamRequestEncoding() throws {
        let body = SyncStreamRequestDTO(types: ["AssetV1", "AssetDeleteV1"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(body)) as? [String: Any]

        XCTAssertEqual(json?["types"] as? [String], ["AssetV1", "AssetDeleteV1"])
        XCTAssertNil(json?["reset"])
    }
}
