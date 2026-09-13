import CryptoKit
import Foundation

/// Where the library lives on disk, and the file operations on it.
///
/// Everything is under Application Support: not Documents, which is visible in
/// the Files app and synced, and not Caches, which iOS empties under storage
/// pressure. Every folder and file is excluded from iCloud backup.
///
/// Nonisolated: the download delegate calls this from its own queue.
nonisolated enum LocalFiles {
    nonisolated enum Folder: String, Sendable {
        case music = "Music"
        case artwork = "Artwork"
    }

    /// The folder, created and excluded from backup if needed.
    static func directory(_ folder: Folder) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent(folder.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
        return directory
    }

    static func url(_ folder: Folder, _ fileName: String) throws -> URL {
        try directory(folder).appendingPathComponent(fileName, isDirectory: false)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func musicFileName(trackID: String) -> String {
        safeName(trackID) + ".m4a"
    }

    static func coverFileName(albumID: Int) -> String {
        "album-\(albumID).jpg"
    }

    /// Partial files are named "<final name>.<token>.partial".
    static func partialFileName(trackID: String, token: String) -> String {
        musicFileName(trackID: trackID) + "." + token + ".partial"
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func removeIfPresent(_ url: URL) throws {
        if exists(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw APIError.invalidInput("Could not read a file size", detail: "No size reported for \(url.path(percentEncoded: false)).")
        }
        return size
    }

    static func modificationDate(_ url: URL) throws -> Date? {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Lowercase hex SHA-256. The file is memory-mapped rather than read into memory.
    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Free space for user-requested content, in bytes.
    static func availableCapacity() throws -> Int64 {
        let values = try directory(.music).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw APIError.invalidInput("Could not read free space", detail: "iOS did not report the available capacity of the storage volume.")
        }
        return capacity
    }

    static func contents(of folder: Folder) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory(folder),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
    }

    /// Track ids are YouTube video ids and already safe, but a file name must
    /// never be able to escape the folder. Other characters become "~<hex>".
    private static func safeName(_ id: String) -> String {
        var result = ""
        for scalar in id.unicodeScalars {
            let isSafe = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
            result += isSafe ? String(scalar) : "~" + String(scalar.value, radix: 16)
        }
        return result
    }
}
