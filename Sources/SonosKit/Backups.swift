import Foundation

/// Bonding layout backup. The format matches the Python sonosctl backups:
/// {created, label, household: {devices, rooms, groups}, zone_group_state}
public struct Backup: Codable, Sendable, Identifiable {
    public var created: String
    public var label: String
    public var household: Household
    public var zoneGroupState: String

    /// File name; filled in when read from disk.
    public var file = ""
    public var id: String { file }

    enum CodingKeys: String, CodingKey {
        case created, label, household, zoneGroupState = "zone_group_state"
    }

    public init(household: Household, label: String, date: Date = .now) {
        created = Self.isoFormatter.string(from: date)
        self.label = label
        self.household = household
        zoneGroupState = household.raw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = try c.decode(String.self, forKey: .created)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        household = try c.decode(Household.self, forKey: .household)
        zoneGroupState = try c.decodeIfPresent(String.self, forKey: .zoneGroupState) ?? ""
        household.raw = zoneGroupState
    }

    public var createdDate: Date? {
        Self.isoFormatter.date(from: created)
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

public struct BackupStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "OpenSonos/Backups", directoryHint: .isDirectory)
    }

    public init(directory: URL = BackupStore.defaultDirectory) { self.directory = directory }

    public func list() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { try? load($0) }
    }

    public func load(_ url: URL) throws -> Backup {
        var b = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        b.file = url.lastPathComponent
        return b
    }

    @discardableResult
    public func save(_ household: Household, label: String) throws -> Backup {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var backup = Backup(household: household, label: label)
        let stamp = backup.created.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-")
        let slug = label.isEmpty ? "" : "-" + label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        backup.file = "\(stamp)\(slug).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(backup).write(to: directory.appending(path: backup.file), options: .atomic)
        return backup
    }

    public func delete(_ backup: Backup) throws {
        try FileManager.default.removeItem(at: directory.appending(path: backup.file))
    }
}
