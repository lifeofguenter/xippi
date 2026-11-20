import Foundation

public struct AdHocCommand: Sendable, Hashable {
    public var jid: JID
    public var node: String
    public var name: String?

    public init(jid: JID, node: String, name: String? = nil) {
        self.jid = jid
        self.node = node
        self.name = name
    }
}

public struct AdHocResponse: Sendable, Equatable {
    public enum Status: String, Sendable {
        case executing, completed, canceled
    }

    public enum Action: String, Sendable {
        case execute, cancel, prev, next, complete
    }

    public struct Note: Sendable, Equatable {
        public enum Kind: String, Sendable { case info, warn, error }
        public var type: Kind
        public var text: String
    }

    public var node: String
    public var status: Status
    public var sessionID: String?
    public var form: DataForm?
    public var notes: [Note]
    /// The actions the next step allows.
    public var actions: [Action]
    /// What `execute` means at this step; `.execute` when not given.
    public var defaultAction: Action
    /// The step carried an `<actions/>` element. Without one a step is a single stage, and
    /// execute means complete (XEP-0050 3.4).
    public var listsActions: Bool

    /// The command ran to its end or was cancelled: nothing more can be sent for it.
    public var isFinished: Bool { status != .executing }

    /// What the requester can do at this step besides cancelling, in wizard order (back,
    /// next, finish): the responder's `<actions/>`, or complete alone without them. Nothing
    /// once the command is finished.
    public var allowedActions: [Action] {
        guard !isFinished else { return [] }
        guard listsActions else { return [.complete] }
        return [Action.prev, .next, .complete].filter(actions.contains)
    }

    /// The action the default button sends: the `execute` attribute when it names an action
    /// the step allows (next when the attribute is absent), else complete or next, whichever
    /// is allowed. Nil when neither is, or once the command is finished.
    public var primaryAction: Action? {
        let allowed = allowedActions
        let named = defaultAction == .execute ? (listsActions ? .next : .complete) : defaultAction
        if allowed.contains(named), named != .prev { return named }
        return [Action.complete, .next].first(where: allowed.contains)
    }
}

/// XEP-0050 Ad-Hoc Commands.
public enum AdHoc {
    public static let namespace = "http://jabber.org/protocol/commands"

    /// The commands `jid` offers.
    public static func list(_ jid: JID, via sender: any StanzaSending) async throws(IQError)
        -> [AdHocCommand]
    {
        try await Disco.items(jid, node: namespace, via: sender).compactMap { item in
            item.node.map { AdHocCommand(jid: item.jid, node: $0, name: item.name) }
        }
    }

    /// Runs a step of the command `node`: `.execute` without a session starts it.
    public static func execute(
        _ jid: JID, node: String, action: AdHocResponse.Action = .execute,
        sessionID: String? = nil, form: DataForm? = nil, via sender: any StanzaSending
    ) async throws(IQError) -> AdHocResponse {
        var command = Element(
            "command", namespace: namespace, attributes: ["node": node, "action": action.rawValue])
        command[attribute: "sessionid"] = sessionID
        if let form { command.append(form.element) }
        let result = try await sender.request(.iq(type: .set, to: jid, payload: command))
        guard
            let response = response(from: try result.resultPayload("command", namespace: namespace))
        else { throw .malformedResponse }
        return response
    }

    /// The next step of a running command: `action` with the step's session, and `form` (the
    /// step's form filled in) for next, complete and execute. Back and cancel send no form
    /// (XEP-0050 2.4.2, 2.4.3). An action the step does not allow is refused before anything
    /// is sent (`bad-request`); cancel is allowed until the command is finished.
    public static func perform(
        _ action: AdHocResponse.Action, after step: AdHocResponse, at jid: JID, form: DataForm?,
        via sender: any StanzaSending
    ) async throws(IQError) -> AdHocResponse {
        let allowed =
            action == .cancel ? !step.isFinished : step.allowedActions.contains(action)
        guard allowed else {
            throw .error(
                StanzaError(type: .modify, condition: .badRequest, text: "action not offered"))
        }
        let sendsForm = action != .prev && action != .cancel
        return try await execute(
            jid, node: step.node, action: action, sessionID: step.sessionID,
            form: sendsForm ? form : nil, via: sender)
    }

    /// Reads a `<command/>` answer; nil without a node or with an unknown status.
    public static func response(from command: Element) -> AdHocResponse? {
        guard command.name == "command", command.namespace == namespace,
            let node = command[attribute: "node"],
            let status = command[attribute: "status"].flatMap(AdHocResponse.Status.init)
        else { return nil }
        let notes = command.children("note", namespace: namespace).map {
            AdHocResponse.Note(
                type: $0[attribute: "type"].flatMap(AdHocResponse.Note.Kind.init) ?? .info,
                text: $0.text)
        }
        let actionsElement = command.child("actions", namespace: namespace)
        let actions = (actionsElement?.elements ?? []).compactMap {
            $0.namespace == namespace ? AdHocResponse.Action(rawValue: $0.name) : nil
        }
        return AdHocResponse(
            node: node, status: status, sessionID: command[attribute: "sessionid"],
            form: command.child("x", namespace: DataForm.namespace).flatMap(
                DataForm.init(element:)),
            notes: notes, actions: actions,
            defaultAction: actionsElement?[attribute: "execute"].flatMap(AdHocResponse.Action.init)
                ?? .execute,
            listsActions: actionsElement != nil)
    }
}

// MARK: - Multi-item results

/// A multi-item data form (XEP-0004 3.4) as a table: one column per reported field, one row
/// per item, within `maxColumns` and `maxRows` (the form comes from any entity).
public struct DataFormTable: Sendable, Equatable {
    public static let maxColumns = 64
    public static let maxRows = 2_000

    public struct Column: Sendable, Equatable {
        public var variable: String
        /// The reported field's label, or its `var`.
        public var label: String
        public var type: DataForm.Field.FieldType?
    }

    public var columns: [Column]
    /// One entry per item, with one cell per column: the item's values for that column's
    /// field, empty where the item has none.
    public var rows: [[[String]]]
    /// Columns and rows beyond the bounds, not in the table.
    public var omittedColumns: Int
    public var omittedRows: Int
}

extension DataForm {
    /// The items as a table; nil for a form without items. The columns are the reported
    /// fields (hidden ones left out), or without `<reported/>` the items' fields in the order
    /// they first come. Item fields no column names are not shown. Built in one pass over the
    /// items; compute it once per form, not per view update.
    public var table: DataFormTable? {
        guard !items.isEmpty else { return nil }
        var columns: [DataFormTable.Column] = []
        var seen = Set<String>()
        let source = reported.isEmpty ? Array(items.joined()) : reported
        for field in source {
            guard let variable = field.variable, field.type != .hidden,
                seen.insert(variable).inserted
            else { continue }
            let label = reported.isEmpty ? variable : field.label ?? variable
            columns.append(.init(variable: variable, label: label, type: field.type))
        }
        let shownColumns = Array(columns.prefix(DataFormTable.maxColumns))
        let rows = items.prefix(DataFormTable.maxRows).map { item in
            var values: [String: [String]] = [:]
            for field in item {
                if let variable = field.variable, values[variable] == nil {
                    values[variable] = field.values
                }
            }
            return shownColumns.map { values[$0.variable] ?? [] }
        }
        return DataFormTable(
            columns: shownColumns, rows: rows, omittedColumns: columns.count - shownColumns.count,
            omittedRows: max(items.count - DataFormTable.maxRows, 0))
    }
}

// MARK: - Bounds for remote forms

/// How much of a form from another entity is shown: an ad-hoc step, a result, a disco
/// extension form. Any entity can send one up to the stanza limit.
public enum DataFormBounds {
    public static let maxFields = 500
    public static let maxOptions = 1_000
    public static let maxValues = 1_000
    /// Labels, descriptions, titles, instructions and option labels.
    public static let maxText = 4_096
    /// One value of a field the user sees. Hidden values go back as they came.
    public static let maxValueText = 65_536
}

extension DataForm {
    /// The form within `DataFormBounds`, and how many fields were left out. Items and reported
    /// fields are bounded by `table`.
    public func bounded() -> (form: DataForm, omittedFields: Int) {
        func cut(_ text: String?, _ limit: Int = DataFormBounds.maxText) -> String? {
            guard let text, text.count > limit else { return text }
            return String(text.prefix(limit))
        }
        var copy = self
        copy.title = cut(title)
        copy.instructions = instructions.map { cut($0) ?? "" }
        copy.fields = fields.prefix(DataFormBounds.maxFields).map { field in
            var field = field
            field.label = cut(field.label)
            field.description = cut(field.description)
            field.options = field.options.prefix(DataFormBounds.maxOptions).map {
                Option(label: cut($0.label), value: $0.value)
            }
            if field.type != .hidden {
                field.values = field.values.prefix(DataFormBounds.maxValues).map {
                    cut($0, DataFormBounds.maxValueText) ?? ""
                }
            }
            return field
        }
        return (copy, max(fields.count - DataFormBounds.maxFields, 0))
    }
}
