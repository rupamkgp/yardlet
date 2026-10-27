import Foundation

/// Claude owns the list and executes its tools. This is only a view of successful tool results,
/// never a second task store or an optimistic application of a model's proposed tool input.
struct ClaudeTaskListProjection: Sendable {
    private struct Item: Equatable, Sendable {
        let id: String
        var subject: String
        var status: String
    }

    private var items: [String: Item] = [:]
    private var order: [String] = []
    private static let statuses: Set<String> = ["pending", "in_progress", "completed"]

    mutating func completedTool(name: String, input: JSONValue, result: JSONValue?) -> String? {
        switch name {
        case "TodoWrite":
            guard let todos = input["todos"]?.arrayValue else { return nil }
            let rows = todos.compactMap { todo -> String? in
                guard let subject = todo["content"]?.stringValue,
                      let status = todo["status"]?.stringValue,
                      Self.statuses.contains(status) else { return nil }
                return Self.row(subject: subject, status: status)
            }
            guard rows.count == todos.count else { return nil }
            return rows.isEmpty ? L10n.string("No tasks") : rows.joined(separator: "\n")

        case "TaskCreate":
            guard let id = result?["task"]?["id"]?.stringValue,
                  let subject = result?["task"]?["subject"]?.stringValue else { return nil }
            upsert(Item(id: id, subject: subject, status: "pending"))

        case "TaskGet":
            guard let task = result?["task"], let item = Self.item(task) else { return nil }
            upsert(item)

        case "TaskList":
            guard let tasks = result?["tasks"]?.arrayValue else { return nil }
            let parsed = tasks.compactMap(Self.item)
            guard parsed.count == tasks.count else { return nil }
            items.removeAll()
            order.removeAll()
            for item in parsed { upsert(item) }

        case "TaskUpdate":
            guard result?["success"]?.boolValue == true,
                  let id = result?["taskId"]?.stringValue,
                  id == input["taskId"]?.stringValue,
                  var item = items[id] else { return nil }
            if input["status"]?.stringValue == "deleted" {
                items.removeValue(forKey: id)
                order.removeAll { $0 == id }
            } else {
                let fields = Set(result?["updatedFields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                if fields.contains("subject"), let subject = input["subject"]?.stringValue {
                    item.subject = subject
                }
                if let status = result?["statusChange"]?["to"]?.stringValue,
                   Self.statuses.contains(status) {
                    item.status = status
                } else if fields.contains("status"), let status = input["status"]?.stringValue,
                          Self.statuses.contains(status) {
                    item.status = status
                }
                guard items[id] != item else { return nil }
                items[id] = item
            }

        default:
            return nil
        }
        return order.compactMap { items[$0] }.map {
            Self.row(subject: $0.subject, status: $0.status)
        }.joined(separator: "\n").nonEmptyTaskList
    }

    private mutating func upsert(_ item: Item) {
        if items[item.id] == nil { order.append(item.id) }
        items[item.id] = item
    }

    private static func item(_ value: JSONValue) -> Item? {
        guard let id = value["id"]?.stringValue,
              let subject = value["subject"]?.stringValue,
              let status = value["status"]?.stringValue,
              statuses.contains(status) else { return nil }
        return Item(id: id, subject: subject, status: status)
    }

    private static func row(subject: String, status: String) -> String {
        let marker = switch status {
        case "completed": "☑"
        case "in_progress": "◉"
        default: "☐"
        }
        return "\(marker) \(subject)"
    }
}

private extension String {
    var nonEmptyTaskList: String { isEmpty ? L10n.string("No tasks") : self }
}
