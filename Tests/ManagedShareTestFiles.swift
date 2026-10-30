import Foundation

func managedShareFiles(matching predicate: (URL) -> Bool) throws -> [URL] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selfphotos-share")
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    guard let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw CocoaError(.fileReadUnknown)
    }
    return try enumerator.compactMap { $0 as? URL }.filter {
        guard predicate($0) else { return false }
        return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }
}
