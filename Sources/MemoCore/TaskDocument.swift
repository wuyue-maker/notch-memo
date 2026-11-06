import Foundation

public struct MemoTask: Codable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(id: UUID = UUID(), text: String, now: Date = Date()) {
        self.id = id
        self.text = text
        createdAt = now
        updatedAt = now
    }
}

public struct DeletedTask: Equatable {
    public let task: MemoTask
    public let activeIndex: Int?
}

public struct TaskDocument: Codable, Equatable {
    public var version = 1
    public private(set) var tasks: [MemoTask] = []
    public private(set) var activeOrder: [UUID] = []

    public init() {}

    public var activeTasks: [MemoTask] {
        let lookup = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return activeOrder.compactMap { lookup[$0] }
    }

    public var completedTasks: [MemoTask] {
        tasks.filter { $0.completedAt != nil }.sorted {
            if $0.completedAt == $1.completedAt { return $0.createdAt > $1.createdAt }
            return $0.completedAt! > $1.completedAt!
        }
    }

    @discardableResult
    public mutating func add(_ text: String, now: Date = Date()) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let task = MemoTask(text: trimmed, now: now)
        tasks.append(task)
        activeOrder.append(task.id)
        return task.id
    }

    @discardableResult
    public mutating func edit(_ id: UUID, text: String, now: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].text = trimmed
        tasks[index].updatedAt = now
        return true
    }

    public mutating func setCompleted(_ id: UUID, _ completed: Bool, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              (tasks[index].completedAt != nil) != completed else { return }
        tasks[index].completedAt = completed ? now : nil
        tasks[index].updatedAt = now
        activeOrder.removeAll { $0 == id }
        if !completed { activeOrder.append(id) }
    }

    public mutating func move(_ id: UUID, before target: UUID?) {
        guard activeOrder.contains(id), target != id else { return }
        if let target, !activeOrder.contains(target) { return }
        activeOrder.removeAll { $0 == id }
        let index = target.flatMap { activeOrder.firstIndex(of: $0) } ?? activeOrder.count
        activeOrder.insert(id, at: index)
    }

    public mutating func reorder(_ order: [UUID]) {
        guard Set(order) == Set(activeOrder), order.count == activeOrder.count else { return }
        activeOrder = order
    }

    public mutating func remove(_ id: UUID) -> DeletedTask? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let deleted = DeletedTask(task: tasks[index], activeIndex: activeOrder.firstIndex(of: id))
        tasks.remove(at: index)
        activeOrder.removeAll { $0 == id }
        return deleted
    }

    public mutating func restore(_ batch: [DeletedTask]) {
        for entry in batch.reversed() where !tasks.contains(where: { $0.id == entry.task.id }) {
            tasks.append(entry.task)
            if entry.task.completedAt == nil {
                activeOrder.insert(entry.task.id, at: min(entry.activeIndex ?? activeOrder.count, activeOrder.count))
            }
        }
    }

    public func validate() throws {
        guard version == 1 else { throw DocumentError.unsupportedVersion(version) }
        let ids = Set(tasks.map(\.id))
        guard ids.count == tasks.count,
              Set(activeOrder).count == activeOrder.count,
              Set(activeOrder) == Set(tasks.filter { $0.completedAt == nil }.map(\.id)),
              tasks.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw DocumentError.invalidDocument }
    }
}

public enum DocumentError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidDocument
    case noRecoverableData

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "数据版本 \(version) 与当前应用不兼容，已停止写入。"
        case .invalidDocument: return "任务文件的内容不完整。"
        case .noRecoverableData: return "任务文件无法读取，原文件已保留。请先检查数据文件。"
        }
    }
}
