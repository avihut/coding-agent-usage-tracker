import SwiftUI
import UsageCore

/// One priced model a person can pick — which harness it belongs to travels
/// with it, because with every vendor's models in one list "Opus 5" and
/// "GPT 5.4" need to say whose they are.
struct PricedModel: Identifiable, Equatable {
    /// The raw model id — also what the simulator prices.
    let id: String
    let display: String
    let family: String
    let harnessID: String
    let harnessName: String
    let style: HarnessStyle

    static func == (a: PricedModel, b: PricedModel) -> Bool { a.id == b.id }
}

/// Pick a model by typing part of its name (v0.101.0, R6 — user-directed:
/// "an option to fuzzy search a model by name in the model selector at bottom
/// of the API cost tab"). A plain `Picker` was fine while one harness's dozen
/// models filled it; spanning every detected harness it becomes a menu of a
/// hundred-odd entries, which is a list to hunt through rather than choose
/// from.
///
/// Empty query: the full list, grouped by harness in the roster's order, so
/// the picker still reads as a menu when nobody types. Typing: ONE ranked
/// list across every harness, with the letters that matched carried in bold
/// — the ranking is the grouping at that point, and re-grouping a ranked list
/// would bury the best answer under a heading.
struct ModelSearchPicker: View {
    let models: [PricedModel]
    @Binding var selection: String

    @State private var open = false
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searching: Bool

    private var chosen: PricedModel? { models.first { $0.id == selection } }

    var body: some View {
        Button {
            query = ""
            highlighted = selection
            open = true
        } label: {
            HStack(spacing: 5) {
                if let chosen {
                    Text(chosen.style.glyph)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(chosen.style.accentColor)
                }
                Text(chosen?.display ?? "Choose a model")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .pointerStyle(.link)
        .accessibilityLabel("Model")
        .accessibilityValue(chosen?.display ?? "none")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            picker
                // A popover sized by its content takes each row's IDEAL
                // width — one long model id would stretch it across the
                // screen (the v0.99.2 lesson), so the width is fixed here.
                .frame(width: 300)
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            field
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            grouped
                        } else {
                            ranked
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
                .onChange(of: highlighted) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .onAppear { searching = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { commit(highlighted) }
                .onChange(of: query) { _, _ in highlighted = visible.first?.id }
            if !query.isEmpty {
                Button {
                    query = ""
                    searching = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Arrows walk the list and Return takes the highlighted row, so the
        // whole picker is reachable without leaving the keyboard. Escape is
        // the popover's own.
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
    }

    @ViewBuilder private var grouped: some View {
        ForEach(harnesses, id: \.self) { harness in
            let mine = models.filter { $0.harnessID == harness }
            if let first = mine.first {
                HStack(spacing: 6) {
                    Text(first.style.glyph)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(first.style.accentColor)
                    Text(first.harnessName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
                ForEach(mine) { model in
                    row(model, matched: [])
                }
            }
        }
    }

    @ViewBuilder private var ranked: some View {
        let hits = FuzzyMatch.rank(query, models) { [$0.display, $0.id] }
        if hits.isEmpty {
            Text("No model matches “\(query)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ForEach(hits, id: \.item.id) { hit in
                // Only the display name is drawn, so offsets into the raw id
                // would underline the wrong letters — highlight nothing then.
                row(hit.item, matched: hit.field == 0 ? hit.match.matched : [])
            }
        }
    }

    private func row(_ model: PricedModel, matched: [Int]) -> some View {
        let isHighlighted = highlighted == model.id
        return Button { commit(model.id) } label: {
            HStack(spacing: 6) {
                Text(model.style.glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.style.accentColor)
                    .frame(width: 12)
                highlightedName(model.display, matched: matched)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.id == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(isHighlighted ? 0.09 : 0))
                    .padding(.horizontal, 5))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .id(model.id)
        .onHover { inside in if inside { highlighted = model.id } }
    }

    /// The typed letters in bold inside the name — what tells a person WHY a
    /// row is where it is in the ranking.
    private func highlightedName(_ name: String, matched: [Int]) -> Text {
        guard !matched.isEmpty else { return Text(name).font(.caption) }
        let hits = Set(matched)
        return Array(name).enumerated().reduce(Text("")) { text, pair in
            let piece = Text(String(pair.element))
                .font(hits.contains(pair.offset) ? .caption.weight(.bold) : .caption)
                .foregroundStyle(hits.contains(pair.offset)
                    ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            return text + piece
        }
    }

    /// What the list is showing right now, in its drawn order.
    private var visible: [PricedModel] {
        query.isEmpty
            ? harnesses.flatMap { harness in models.filter { $0.harnessID == harness } }
            : FuzzyMatch.rank(query, models) { [$0.display, $0.id] }.map(\.item)
    }

    private var harnesses: [String] {
        var seen: [String] = []
        for model in models where !seen.contains(model.harnessID) { seen.append(model.harnessID) }
        return seen
    }

    private func step(_ direction: Int) -> KeyPress.Result {
        let list = visible
        guard !list.isEmpty else { return .ignored }
        guard let current = highlighted, let index = list.firstIndex(where: { $0.id == current })
        else {
            highlighted = list.first?.id
            return .handled
        }
        let next = index + direction
        guard list.indices.contains(next) else { return .handled }
        highlighted = list[next].id
        return .handled
    }

    private func commit(_ id: String?) {
        guard let id, models.contains(where: { $0.id == id }) else { return }
        selection = id
        open = false
    }
}
