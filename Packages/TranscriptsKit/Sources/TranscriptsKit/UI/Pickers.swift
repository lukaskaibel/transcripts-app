import SwiftUI

/// One row of a picker: a status, a person, a label or a place for issues.
struct PickerItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    /// A second line in a quieter colour, such as why a target is proposed.
    var detail: String?
    var selected = false
    var icon: AnyView
    var shortcut: String?
    /// Shown at the end of the row, such as "Öffentlich".
    var trailing: AnyView? = nil
    /// A section title shown above this row while nothing has been typed.
    var header: String? = nil

    var height: CGFloat { detail == nil ? 32 : 44 }
}

/// Subsequence match: every character of the query appears in order. Higher is better; nil is no match.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !q.isEmpty else { return 0 }
    let t = Array(text.lowercased())
    var score = 0
    var qi = 0
    var streak = 0
    for (ti, character) in t.enumerated() where qi < q.count {
        if character == q[qi] {
            streak += 1
            score += 2 + streak * 2
            if ti == 0 || !t[ti - 1].isLetter && !t[ti - 1].isNumber { score += 6 }
            qi += 1
        } else {
            streak = 0
        }
    }
    guard qi == q.count else { return nil }
    return score - t.count / 8
}

/// A searchable list driven entirely from the keyboard: type to filter, arrows to move, Return to pick.
/// The same control as in Issues for GitHub.
struct PickerList: View {
    var placeholder: String
    var items: [PickerItem]
    /// The key that opens this picker from the list of tasks, shown at the end of the search field.
    var hint: String? = nil
    /// Multi-select pickers stay open after a pick.
    var staysOpen = false
    var width: CGFloat = 260
    var maxRows = 9
    /// A line under the list, such as where the statuses come from.
    var footer: String? = nil
    var onPick: (String) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        let visible = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui)
                    .focused($focused)
                    .focusOnAppear()
                    .accessibilityIdentifier("picker.search")
                if let hint { Keycap(hint) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .onKeyPress(.downArrow) {
                index = min(index + 1, max(visible.count - 1, 0))
                return .handled
            }
            .onKeyPress(.upArrow) {
                index = max(index - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                // Number keys pick directly while nothing has been typed.
                guard query.isEmpty, let item = items.first(where: { $0.shortcut == press.characters }) else { return .ignored }
                pick(item)
                return .handled
            }
            .onSubmit {
                if visible.indices.contains(index) { pick(visible[index]) }
            }
            Rectangle().fill(Theme.popoverBorder).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { position, item in
                            if query.isEmpty, let header = item.header {
                                Text(header)
                                    .font(.tinySemibold)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .frame(height: 24, alignment: .bottom)
                                    .padding(.bottom, 2)
                            }
                            PickerRow(item: item, active: position == index)
                                .id(item.id)
                                .onTapGesture { pick(item) }
                                .onHover { if $0 { index = position } }
                        }
                        if visible.isEmpty {
                            Text("Keine Treffer")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .frame(height: listHeight(visible))
                .onChange(of: index) {
                    if visible.indices.contains(index) { proxy.scrollTo(visible[index].id) }
                }
            }
            if let footer {
                Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                Text(footer)
                    .font(.tiny)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
        }
        .frame(width: width)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .onAppear {
            focused = true
            // Single-choice pickers start on the current value, so Return keeps it.
            if !staysOpen, let current = items.firstIndex(where: \.selected) { index = current }
        }
        .onChange(of: query) { index = 0 }
    }

    private func listHeight(_ visible: [PickerItem]) -> CGFloat {
        guard !visible.isEmpty else { return 32 + 8 }
        var height: CGFloat = 8
        for (position, item) in visible.enumerated() where position < maxRows {
            height += item.height + (query.isEmpty && item.header != nil ? 26 : 0)
        }
        return height
    }

    private var filtered: [PickerItem] {
        guard !query.isEmpty else { return items }
        return items
            .compactMap { item -> (PickerItem, Int)? in
                let score = max(fuzzyScore(query, item.title) ?? -1, item.subtitle.flatMap { fuzzyScore(query, $0) } ?? -1)
                return score >= 0 ? (item, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func pick(_ item: PickerItem) {
        onPick(item.id)
        if !staysOpen { onClose() }
    }
}

struct PickerRow: View {
    var item: PickerItem
    var active: Bool

    var body: some View {
        HStack(alignment: item.detail == nil ? .center : .top, spacing: 10) {
            item.icon
                .frame(width: 18, height: 18)
                .padding(.top, item.detail == nil ? 0 : 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title).lineLimit(1).truncationMode(.tail)
                    if let subtitle = item.subtitle {
                        Text(subtitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                if let detail = item.detail {
                    HStack(spacing: 4) {
                        SparkleMark(size: 8)
                        Text(detail).font(.tiny).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing { trailing }
            if item.selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textBody)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(active ? Theme.textSecondary : Theme.textTertiary)
                    .frame(minWidth: 12, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, item.detail == nil ? 0 : 6)
        .frame(height: item.height)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Theme.popoverSelected : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("picker.row.\(item.id)")
        .debugFrame("picker.row.\(item.id)")
    }
}

/// The four-pointed star that marks what the language model proposed.
struct SparkleMark: View {
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Vorschlag")
    }
}
