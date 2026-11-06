import Foundation

public struct MemoNote: Codable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var document: TaskDocument
    public var completedAt: Date?
    public var title: String?
    public var name: String?

    public var displayName: String { name ?? title ?? "未命名便签" }

    public var archiveName: String { name ?? "未命名便签" }

    public var archiveDateLabel: String {
        // Keep the date recorded at archiving, without its same-day sequence.
        if let date = title?.components(separatedBy: " · ").first, date.count == 10 {
            return date
        }
        guard let completedAt else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: completedAt)
    }

    public init(document: TaskDocument = TaskDocument(), now: Date = Date()) {
        id = UUID()
        createdAt = now
        self.document = document
    }
}

public struct Notebook: Codable, Equatable {
    public var version = 3
    public var current: MemoNote
    public private(set) var ongoing: [MemoNote] = []
    public private(set) var history: [MemoNote] = []

    public var inProgressNotes: [MemoNote] {
        ([current] + ongoing).sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }

    private enum CodingKeys: String, CodingKey { case version, current, ongoing, history }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        current = try values.decode(MemoNote.self, forKey: .current)
        ongoing = try values.decodeIfPresent([MemoNote].self, forKey: .ongoing) ?? []
        history = try values.decode([MemoNote].self, forKey: .history)
    }

    public init(document: TaskDocument = TaskDocument(), now: Date = Date()) {
        current = MemoNote(document: document, now: now)
    }

    @discardableResult
    public mutating func selectInProgress(_ id: UUID) -> Bool {
        if current.id == id { return true }
        guard let index = ongoing.firstIndex(where: { $0.id == id }) else { return false }
        let selected = ongoing[index]
        ongoing[index] = current
        current = selected
        return true
    }

    /// Reuse an empty sheet before allocating another one.
    @discardableResult
    public mutating func createNote(now: Date = Date()) -> UUID {
        if current.document.tasks.isEmpty { return current.id }
        if let empty = ongoing.first(where: { $0.document.tasks.isEmpty }) {
            selectInProgress(empty.id)
        } else {
            ongoing.append(current)
            current = MemoNote(now: now)
        }
        return current.id
    }

    @discardableResult
    public mutating func renameNote(_ id: UUID, name: String) -> Bool {
        let trimmed = name.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if current.id == id { current.name = trimmed; return true }
        if let index = ongoing.firstIndex(where: { $0.id == id }) {
            ongoing[index].name = trimmed
            return true
        }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return false }
        history[index].name = trimmed
        return true
    }

    /// Only a nonempty, fully checked note is eligible. Call after completion settles.
    @discardableResult
    public mutating func archiveCompletedCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !current.document.tasks.isEmpty, current.document.activeTasks.isEmpty else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let date = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        let count = history.filter { $0.title == date || $0.title?.hasPrefix(date + " · ") == true }.count
        current.completedAt = now
        current.title = count == 0 ? date : "\(date) · \(count + 1)"
        history.append(current)
        if let empty = ongoing.firstIndex(where: { $0.document.tasks.isEmpty }) {
            current = ongoing.remove(at: empty)
        } else { current = MemoNote(now: now) }
        return true
    }

    public func validate() throws {
        guard version == 3 else { throw DocumentError.unsupportedVersion(version) }
        for note in [current] + ongoing {
            try note.document.validate()
            guard note.completedAt == nil, note.title == nil else { throw DocumentError.invalidDocument }
        }
        let allNotes = [current] + ongoing + history
        guard Set(allNotes.map(\.id)).count == allNotes.count,
              Set(history.compactMap(\.title)).count == history.count else { throw DocumentError.invalidDocument }
        for note in history {
            try note.document.validate()
            guard note.completedAt != nil, !(note.title ?? "").isEmpty,
                  !note.document.tasks.isEmpty, note.document.activeTasks.isEmpty else { throw DocumentError.invalidDocument }
        }
        guard allNotes.allSatisfy({ note in
            note.name.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        }) else { throw DocumentError.invalidDocument }
    }
}
