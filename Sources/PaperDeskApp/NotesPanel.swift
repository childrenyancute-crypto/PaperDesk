import SwiftUI
import PaperDeskCore

/// Browses every note the reader has for the current paper. Accepted notes,
/// AI drafts and original-excerpt drafts share one list so the project card can
/// expose a single 笔记 entry without disturbing the conversation panel.
struct PaperNotesSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = PaperNotesSheetState()

    private var notes: [ReadingNote] { model.notes }

    private var filteredNotes: [ReadingNote] {
        let matched = notes.filter { note in
            switch form.filter {
            case .all: return true
            case .draft: return note.status == "draft"
            case .accepted: return note.status == "accepted"
            }
        }
        return matched.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private var selectedNote: ReadingNote? {
        guard let id = form.selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                noteList
                Divider()
                noteDetail
            }
        }
        .frame(width: 780, height: 540)
        .font(InspectorText.body)
        .onAppear {
            model.refreshNotes()
            selectFirstIfNeeded()
        }
        .onChange(of: form.filter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: form.selectedNoteID) { _, _ in
            form.draft = selectedNote?.content ?? ""
            form.errorMessage = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(L("笔记"), systemImage: "note.text")
                .font(InspectorText.title)
            if let paper = model.selectedPaper {
                Text(paper.title)
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker(L("筛选"), selection: $form.filter) {
                ForEach(PaperNotesSheetState.Filter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(L("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private var noteList: some View {
        if filteredNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("还没有笔记"))
                    .font(InspectorText.section)
                Text(L("在「焦点」里为某条选区添加批注，或让 AI 通过 MCP 写入笔记后会出现在这里。"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 260, alignment: .topLeading)
            .padding(14)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredNotes) { note in
                        noteRow(note)
                    }
                }
                .padding(8)
            }
            .frame(width: 260)
        }
    }

    private func noteRow(_ note: ReadingNote) -> some View {
        Button {
            form.selectedNoteID = note.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kindLabel(note))
                        .font(InspectorText.detailStrong)
                        .foregroundStyle(sourceColor(note))
                    Text(L("第 \(note.pageIndex + 1) 页", "Page \(note.pageIndex + 1)"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if note.status == "draft" {
                        Text(L("待审核"))
                            .font(InspectorText.detail)
                            .foregroundStyle(.orange)
                    }
                }
                Text(note.content.replacingOccurrences(of: "\n", with: " "))
                    .font(InspectorText.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(form.selectedNoteID == note.id ? ReaderPalette.softAction : ReaderPalette.surface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(form.selectedNoteID == note.id ? ReaderPalette.action : ReaderPalette.divider,
                            lineWidth: form.selectedNoteID == note.id ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = selectedNote {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(kindLabel(note))
                        .font(InspectorText.section)
                        .foregroundStyle(sourceColor(note))
                    Text(L("第 \(note.pageIndex + 1) 页 · \(note.status == "draft" ? "待审核" : "已确认") · \(note.source == "ai" ? "AI" : "手动")", "Page \(note.pageIndex + 1) · \(note.status == "draft" ? "Pending review" : "Confirmed") · \(note.source == "ai" ? "AI" : "Manual")"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if !note.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.quote)
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ReaderPalette.divider, lineWidth: 0.5)
                        }
                }
                TextEditor(text: $form.draft)
                    .font(InspectorText.editable)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 190, maxHeight: .infinity)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(ReaderPalette.divider, lineWidth: 0.5)
                    }
                if let error = form.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(InspectorText.detail)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("删除"), role: .destructive) { delete(note) }
                        .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                    Text(L("正在编辑这条笔记"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.tertiary)
                    Button(L("保存")) { save(note) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(form.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
        } else {
            Text(L("选择左侧的一条笔记查看或编辑。"))
                .font(InspectorText.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectFirstIfNeeded() {
        if !filteredNotes.contains(where: { $0.id == form.selectedNoteID }) {
            form.selectedNoteID = filteredNotes.first?.id
        }
    }

    private func save(_ note: ReadingNote) {
        form.errorMessage = nil
        let content = form.draft
        guard model.updateNote(note, content: content) else {
            form.errorMessage = model.errorMessage ?? L("笔记保存失败，请稍后重试。")
            return
        }
        model.statusMessage = L("笔记已更新。")
        if let updated = model.notes.first(where: { $0.id == note.id }) {
            form.draft = updated.content
        }
    }

    private func delete(_ note: ReadingNote) {
        form.errorMessage = nil
        guard model.deleteNote(note) else {
            form.errorMessage = model.errorMessage ?? L("删除失败，请稍后重试。")
            return
        }
        form.selectedNoteID = nil
        selectFirstIfNeeded()
    }

    private func kindLabel(_ note: ReadingNote) -> String {
        switch note.kind {
        case "annotation": return L("批注")
        case "excerpt": return L("原文摘录")
        default: return L("笔记")
        }
    }

    private func sourceColor(_ note: ReadingNote) -> Color {
        note.source == "ai" ? ReaderPalette.action : ReaderPalette.focusManual
    }
}

private final class PaperNotesSheetState: ObservableObject {
    enum Filter: String, CaseIterable {
        case all
        case draft
        case accepted

        var title: String {
            switch self {
            case .all: return L("全部")
            case .draft: return L("待审核")
            case .accepted: return L("已确认")
            }
        }
    }

    @Published var filter: Filter = .all
    @Published var selectedNoteID: String?
    @Published var draft = ""
    @Published var errorMessage: String?
}

/// Edits the per-paper reading goal. The goal lives in the store and is also
/// mirrored to `reading-goal.md` inside the paper project.
struct ReadingGoalSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ReadingGoalSheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(L("阅读目标"), systemImage: "target")
                    .font(InspectorText.title)
                if let paper = model.selectedPaper {
                    Text(paper.title)
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            TextEditor(text: $form.draft)
                .font(InspectorText.editable)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 180, maxHeight: 260)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ReaderPalette.divider, lineWidth: 0.5)
                }
            if let error = form.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L("留空可清除阅读目标"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedPaper == nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .font(InspectorText.body)
        .onAppear { form.draft = model.readingGoal }
    }

    private func save() {
        guard model.selectedPaper != nil else {
            form.errorMessage = L("请先打开一篇文献。")
            return
        }
        form.errorMessage = nil
        model.setReadingGoal(form.draft)
        if let error = model.errorMessage {
            form.errorMessage = error
        } else {
            dismiss()
        }
    }
}

private final class ReadingGoalSheetState: ObservableObject {
    @Published var draft = ""
    @Published var errorMessage: String?
}

