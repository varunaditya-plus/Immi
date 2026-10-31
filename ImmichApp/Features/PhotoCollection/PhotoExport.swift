import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoExportOptions: Equatable, Sendable {
    enum Format: String, CaseIterable, Sendable { case automatic, current, mostCompatible }
    var format: Format = .automatic
    var includeLocation = true
}

struct PhotoExportRepresentations: Sendable {
    let fileURL: URL
    let compatibleURL: URL?
    let ownedURLs: [URL]
}

enum PhotoExportError: LocalizedError {
    case unsupportedMedia, conversionFailed, locationRemovalFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: String(localized: "This photo or video format cannot be shared.")
        case .conversionFailed: String(localized: "Could not convert this photo or video for sharing.")
        case .locationRemovalFailed: String(localized: "Could not remove location information from this file.")
        }
    }
}

enum PhotoExportService {
    static func prepare(_ source: URL, options: PhotoExportOptions) async throws -> PhotoExportRepresentations {
        try Task.checkCancellation()
        guard source.isFileURL else { throw PhotoExportError.unsupportedMedia }
        let type = contentType(of: source)
        if type.conforms(to: .image) {
            let operation = Task.detached(priority: .userInitiated) {
                try prepareImage(source, type: type, options: options)
            }
            return try await withTaskCancellationHandler {
                let result = try await operation.value
                do { try Task.checkCancellation(); return result }
                catch { TemporaryMediaStore.remove(result.ownedURLs); throw error }
            } onCancel: { operation.cancel() }
        }
        guard type.conforms(to: .movie) || type.conforms(to: .video) else {
            throw PhotoExportError.unsupportedMedia
        }
        return try await prepareMovie(source, type: type, options: options)
    }

    static func contentType(of url: URL) -> UTType {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) {
            return type
        }
        guard let file = try? FileHandle(forReadingFrom: url) else { return .data }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 64), bytes.count >= 12 else { return .data }
        if String(data: bytes[4..<8], encoding: .ascii) == "ftyp" {
            return String(data: bytes[8..<12], encoding: .ascii) == "qt  " ? .quickTimeMovie : .mpeg4Movie
        }
        if String(data: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(data: bytes[8..<12], encoding: .ascii) == "AVI " { return .avi }
        if ["moov", "mdat", "wide"].contains(String(data: bytes[4..<8], encoding: .ascii) ?? "") {
            return .quickTimeMovie
        }
        return .data
    }

    private static func prepareImage(_ source: URL, type: UTType,
                                     options: PhotoExportOptions) throws -> PhotoExportRepresentations {
        var owned: [URL] = []
        do {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                      CGImageSourceGetStatus(image) == .statusComplete, CGImageSourceGetCount(image) > 0,
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw PhotoExportError.unsupportedMedia }
            }
            if options.format == .mostCompatible, !compatibleImageType(type) {
                let converted = try compatibleImage(source, includeLocation: options.includeLocation)
                return PhotoExportRepresentations(fileURL: converted, compatibleURL: nil, ownedURLs: [converted])
            }
            let current = options.includeLocation ? source : try locationFreeImage(source, type: type)
            if current != source { owned.append(current) }
            if options.format == .current || compatibleImageType(type) {
                return PhotoExportRepresentations(fileURL: current, compatibleURL: nil, ownedURLs: owned)
            }
            let converted = try compatibleImage(current, includeLocation: options.includeLocation)
            owned.append(converted)
            try Task.checkCancellation()
            return PhotoExportRepresentations(fileURL: options.format == .mostCompatible ? converted : current,
                compatibleURL: options.format == .automatic ? converted : nil, ownedURLs: owned)
        } catch {
            TemporaryMediaStore.remove(owned)
            throw error
        }
    }

    private static func compatibleImageType(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .png) || type.conforms(to: .gif)
    }

    private static func locationFreeImage(_ url: URL, type: UTType) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PhotoExportError.unsupportedMedia }
        guard imageHasLocation(source) else { return url }
        guard CGImageSourceGetCount(source) == 1 else { throw PhotoExportError.locationRemovalFailed }
        let file = temporaryURL(for: url, type: type)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else {
            throw PhotoExportError.locationRemovalFailed
        }
        let metadata = filteredMetadata(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        var error: Unmanaged<CFError>?
        // Replacing metadata keeps compressed pixels intact; merging would restore removed source tags.
        guard CGImageDestinationCopyImageSource(destination, source,
            [kCGImageDestinationMetadata: metadata, kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, &error),
            let checked = CGImageSourceCreateWithURL(file as CFURL, nil), !imageHasLocation(checked) else {
            throw PhotoExportError.locationRemovalFailed
        }
        try Task.checkCancellation()
        return try TemporaryMediaStore.adoptShareFile(at: file, suggestedFilename: url.lastPathComponent)
    }

    private static func compatibleImage(_ url: URL, includeLocation: Bool) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PhotoExportError.conversionFailed }
        let alpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let type: UTType = alpha ? .png : .jpeg
        let file = temporaryURL(for: url, type: type)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else {
            throw PhotoExportError.conversionFailed
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        if !includeLocation { properties = locationFreeProperties(properties) }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        CGImageDestinationAddImageAndMetadata(destination, image,
            includeLocation ? metadata : filteredMetadata(metadata), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let checked = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceCreateImageAtIndex(checked, 0, nil) != nil else {
            throw PhotoExportError.conversionFailed
        }
        guard includeLocation || !imageHasLocation(checked) else { throw PhotoExportError.locationRemovalFailed }
        try Task.checkCancellation()
        return try TemporaryMediaStore.adoptShareFile(at: file,
            suggestedFilename: url.deletingPathExtension().lastPathComponent + "." + (type.preferredFilenameExtension ?? "jpg"))
    }

    private static func filteredMetadata(_ metadata: CGImageMetadata?) -> CGMutableImageMetadata {
        let result = metadata.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        var paths: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(result, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            if locationKey(name) || name.lowercased() == "makernote" || !knownMetadataNamespace(namespace) { paths.append(path) }
            return true
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(result, nil, path) }
        return result
    }

    private static func knownMetadataNamespace(_ value: String) -> Bool {
        ["http://ns.adobe.com/tiff/1.0/", "http://ns.adobe.com/exif/1.0/", "http://ns.adobe.com/exif/1.0/aux/",
         "http://ns.adobe.com/photoshop/1.0/", "http://purl.org/dc/elements/1.1/", "http://ns.adobe.com/xap/1.0/",
         "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/", "http://iptc.org/std/Iptc4xmpExt/2008-02-29/",
         "http://ns.apple.com/ImageIO/1.0/"].contains(value)
    }

    private static func locationKey(_ key: String) -> Bool {
        let name = key.lowercased().filter(\.isLetter)
        return name.contains("gps") || ["latitude", "longitude", "altitude", "city", "country", "countrycode",
            "countryprimarylocationcode", "countryprimarylocationname", "provincestate", "state", "sublocation",
            "location", "locationcreated", "locationshown", "locationinformation"].contains(name)
    }

    private static func imageHasLocation(_ source: CGImageSource) -> Bool {
        for index in 0..<CGImageSourceGetCount(source) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any], dictionaryHasLocation(properties) { return true }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
                var found = false
                CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
                    [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
                    if locationKey(name) || name.lowercased() == "makernote" || !knownMetadataNamespace(namespace) { found = true }
                    return true
                }
                if found { return true }
            }
        }
        return false
    }

    private static func locationFreeProperties(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, pair in
            guard !locationKey(pair.key), pair.key.lowercased() != "makernote" else { return }
            result[pair.key] = (pair.value as? [String: Any]).map(locationFreeProperties) ?? pair.value
        }
    }

    private static func dictionaryHasLocation(_ dictionary: [String: Any]) -> Bool {
        dictionary.contains { key, value in
            if locationKey(key) || key.lowercased() == "makernote" { return !(value is NSNull) }
            if let nested = value as? [String: Any] { return dictionaryHasLocation(nested) }
            return false
        }
    }

    private static func prepareMovie(_ source: URL, type: UTType,
                                     options: PhotoExportOptions) async throws -> PhotoExportRepresentations {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw PhotoExportError.unsupportedMedia }
        var owned: [URL] = []
        do {
            if options.format == .mostCompatible, try await !compatibleMovie(asset) {
                let converted = try await exportMovie(asset, source: source, sourceType: type,
                    compatible: true, includeLocation: options.includeLocation)
                return PhotoExportRepresentations(fileURL: converted, compatibleURL: nil, ownedURLs: [converted])
            }
            let removesLocation = options.includeLocation ? false : try await movieHasLocation(asset)
            let current = removesLocation
                ? try await exportMovie(asset, source: source, sourceType: type, compatible: false, includeLocation: false) : source
            if current != source { owned.append(current) }
            let needsConversion = options.format == .current ? false : try await !compatibleMovie(AVURLAsset(url: current))
            if !needsConversion {
                try Task.checkCancellation()
                return PhotoExportRepresentations(fileURL: current, compatibleURL: nil, ownedURLs: owned)
            }
            // Item providers negotiate UTIs, so codec alternatives need distinct containers.
            let container: AVFileType = type == .quickTimeMovie ? .mp4 : .mov
            let compatible = try await exportMovie(AVURLAsset(url: current), source: source, sourceType: type,
                compatible: true, includeLocation: options.includeLocation, compatibleContainer: container)
            owned.append(compatible)
            try Task.checkCancellation()
            return PhotoExportRepresentations(fileURL: options.format == .mostCompatible ? compatible : current,
                compatibleURL: options.format == .automatic ? compatible : nil, ownedURLs: owned)
        } catch { TemporaryMediaStore.remove(owned); throw error }
    }

    private static func compatibleMovie(_ asset: AVAsset) async throws -> Bool {
        if let asset = asset as? AVURLAsset {
            let type = contentType(of: asset.url)
            guard type == .quickTimeMovie || type == .mpeg4Movie else { return false }
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard !videos.isEmpty else { return false }
        for track in videos {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else { return false }
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else { return false }
        }
        return true
    }

    private static func movieHasLocation(_ asset: AVAsset) async throws -> Bool {
        for format in try await asset.load(.availableMetadataFormats) {
            if try await asset.loadMetadata(for: format).contains(where: metadataHasLocation) { return true }
        }
        for track in try await asset.load(.tracks) where track.mediaType == .metadata {
            let descriptions = try await track.load(.formatDescriptions)
            let identifiers = descriptions.flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
            // Unknown timed payloads can carry coordinates; retain only the documented Live Photo timing marker.
            if identifiers.isEmpty || identifiers.contains(where: { $0 != "mdta/com.apple.quicktime.still-image-time" }) { return true }
        }
        return false
    }

    private static func metadataHasLocation(_ item: AVMetadataItem) -> Bool {
        // QuickTime's user-data GPS key is ©xyz, without a searchable location word.
        if item.identifier == .quickTimeUserDataLocationISO6709 { return true }
        if item.keySpace == .quickTimeUserData,
           (item.key as? String == "©xyz" || (item.key as? NSNumber)?.uint32Value == 0xA978797A) { return true }
        let identity = (item.identifier?.rawValue ?? "") + " " + (item.key.map { String(describing: $0) } ?? "")
        return identity.lowercased().contains("location") || identity.lowercased().contains("gps")
            || identity.lowercased().contains("latitude") || identity.lowercased().contains("longitude")
    }

    private static func exportMovie(_ asset: AVAsset, source: URL, sourceType: UTType,
                                    compatible: Bool, includeLocation: Bool,
                                    compatibleContainer: AVFileType = .mov) async throws -> URL {
        guard compatible || sourceType == .quickTimeMovie || sourceType == .mpeg4Movie else {
            throw PhotoExportError.locationRemovalFailed
        }
        let input: AVAsset
        if includeLocation { input = asset }
        else {
            let composition = AVMutableComposition()
            for track in try await asset.load(.tracks) {
                if track.mediaType == .metadata {
                    let identifiers = try await track.load(.formatDescriptions).flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [] }
                    if identifiers.isEmpty || identifiers.contains(where: { $0 != "mdta/com.apple.quicktime.still-image-time" }) { continue }
                }
                guard let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PhotoExportError.locationRemovalFailed
                }
                let range = try await track.load(.timeRange)
                try destination.insertTimeRange(range, of: track, at: range.start)
                if track.mediaType == .video { destination.preferredTransform = try await track.load(.preferredTransform) }
            }
            input = composition
        }
        guard let exporter = AVAssetExportSession(asset: input,
            presetName: compatible ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough) else { throw PhotoExportError.conversionFailed }
        let types = await exporter.compatibleFileTypes
        let preferred: AVFileType = compatible ? compatibleContainer : (sourceType == .quickTimeMovie ? .mov : .mp4)
        guard types.contains(preferred) else { throw PhotoExportError.conversionFailed }
        let file = temporaryURL(for: source, type: preferred == .mov ? .quickTimeMovie : .mpeg4Movie)
        defer { try? FileManager.default.removeItem(at: file) }
        let metadata = try await asset.load(.metadata)
        exporter.metadata = includeLocation ? metadata : AVMetadataItem.metadataItems(from: metadata, filteredBy: .forSharing()).filter { !metadataHasLocation($0) }
        if !includeLocation { exporter.metadataItemFilter = .forSharing() }
        try Task.checkCancellation()
        try await exporter.export(to: file, as: preferred)
        try Task.checkCancellation()
        let result = AVURLAsset(url: file)
        if compatible, try await !compatibleMovie(result) { throw PhotoExportError.conversionFailed }
        if !includeLocation, try await movieHasLocation(result) { throw PhotoExportError.locationRemovalFailed }
        return try TemporaryMediaStore.adoptShareFile(at: file,
            suggestedFilename: source.deletingPathExtension().lastPathComponent + "." + file.pathExtension)
    }

    private static func temporaryURL(for source: URL, type: UTType) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo-export-\(UUID()).\(type.preferredFilenameExtension ?? source.pathExtension)")
    }
}
