import SwiftUI
import XMPPCore

/// A result form (XEP-0004) with items: its title, instructions and single fields, then the
/// items as a table, one column per reported field. Private values are masked, booleans read
/// Yes or No, and several values of one cell are one per line.
struct DataFormResultView: View {
    let form: DataForm
    let table: DataFormTable

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = form.title {
                Text(title)
                    .font(.appTitle)
            }
            ForEach(Array(form.instructions.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if form.fields.contains(where: { $0.type != .hidden }) {
                FormFieldsSummary(form: DataForm(type: form.type, fields: form.fields))
            }
            DataFormTableView(table: table)
            if table.omittedRows > 0 || table.omittedColumns > 0 {
                Text(Copy.tableOmitted(rows: table.omittedRows, columns: table.omittedColumns))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("form-table-omitted")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form-result")
    }
}

/// The items of a multi-item result as a table.
struct DataFormTableView: View {
    let table: DataFormTable

    /// One item; its place in the result is its identity, and a new result is a new table.
    struct Row: Identifiable {
        let id: Int
        let cells: [[String]]
    }

    var body: some View {
        let rows = table.rows.enumerated().map { Row(id: $0.offset, cells: $0.element) }
        let columns = Array(table.columns.enumerated())
        Table(rows) {
            TableColumnForEach(columns, id: \.offset) { index, column in
                TableColumn(column.label) { row in
                    Text(
                        Self.text(
                            row.cells.indices.contains(index) ? row.cells[index] : [],
                            type: column.type)
                    )
                    .textSelection(.enabled)
                    .lineLimit(nil)
                }
            }
        }
        .frame(minHeight: 160)
        .accessibilityIdentifier("form-table")
    }

    static func text(_ values: [String], type: DataForm.Field.FieldType?) -> String {
        switch type {
        case .textPrivate:
            values.isEmpty ? "" : Copy.hiddenValue
        case .boolean:
            values.first.map { $0 == "1" || $0 == "true" ? Copy.yes : Copy.no } ?? ""
        default:
            values.joined(separator: "\n")
        }
    }
}
