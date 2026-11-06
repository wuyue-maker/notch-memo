import Foundation

public struct NotebookLoadResult {
    public let notebook: Notebook
    public let recoveredFromBackup: Bool
    public let migrated: Bool
    public var document: TaskDocument { notebook.current.document }
}

public final class NotebookRepository {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("tasks.json") }
    public var backup: URL { directory.appendingPathComponent("tasks.backup.json") }
    public var legacyBackup: URL { directory.appendingPathComponent("tasks.before-notebooks.json") }
    public var multiNoteBackup: URL { directory.appendingPathComponent("tasks.before-multiple-notes.json") }
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    private func preserveMigration(_ data: Data) throws {
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = metadata?["version"] as? Int, version < 3 else { return }
        let destination = version == 1 ? legacyBackup : multiNoteBackup
        if !fm.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
    }

    private func decode(_ url: URL) throws -> (Notebook, Bool) {
        let data = try Data(contentsOf: url)
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = metadata?["version"] as? Int else { throw DocumentError.invalidDocument }
        var notebook: Notebook
        switch version {
        case 1:
            let document = try JSONDecoder().decode(TaskDocument.self, from: data)
            try document.validate()
            notebook = Notebook(document: document, now: document.tasks.map(\.createdAt).min() ?? Date())
        case 2, 3:
            notebook = try JSONDecoder().decode(Notebook.self, from: data)
        default: throw DocumentError.unsupportedVersion(version)
        }
        notebook.version = 3
        try notebook.validate()
        return (notebook, version < 3)
    }

    public func load() throws -> NotebookLoadResult {
        guard fm.fileExists(atPath: file.path) else {
            if fm.fileExists(atPath: backup.path) {
                let (notebook, migrated) = try decode(backup)
                return NotebookLoadResult(notebook: notebook, recoveredFromBackup: true, migrated: migrated)
            }
            return NotebookLoadResult(notebook: Notebook(), recoveredFromBackup: false, migrated: false)
        }
        do {
            let (notebook, migrated) = try decode(file)
            return NotebookLoadResult(notebook: notebook, recoveredFromBackup: false, migrated: migrated)
        } catch DocumentError.unsupportedVersion(let version) {
            throw DocumentError.unsupportedVersion(version)
        } catch {
            guard let (notebook, migrated) = try? decode(backup) else { throw DocumentError.noRecoverableData }
            return NotebookLoadResult(notebook: notebook, recoveredFromBackup: true, migrated: migrated)
        }
    }

    public func save(_ notebook: Notebook) throws {
        try notebook.validate()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            let oldData = try Data(contentsOf: file)
            let decoded: (Notebook, Bool)?
            do {
                decoded = try decode(file)
            } catch DocumentError.unsupportedVersion(let version) {
                throw DocumentError.unsupportedVersion(version)
            } catch { decoded = nil }
            if let (_, migrated) = decoded {
                if migrated {
                    try preserveMigration(oldData)
                }
                try oldData.write(to: backup, options: .atomic)
            } else {
                if let (_, migrated) = try? decode(backup), migrated {
                    try preserveMigration(Data(contentsOf: backup))
                }
                let archive = directory.appendingPathComponent("tasks.unreadable-\(UUID().uuidString).json")
                try oldData.write(to: archive, options: .atomic)
            }
        } else if fm.fileExists(atPath: backup.path),
                  let (_, migrated) = try? decode(backup), migrated {
            try preserveMigration(Data(contentsOf: backup))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(notebook)
        try data.write(to: file, options: .atomic)
        if !fm.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
    }
}
