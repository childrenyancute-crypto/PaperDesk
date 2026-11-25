import AppKit
import SwiftUI
import PaperDeskCore

/// A small, local-only form for writing a real PDF annotation.
///
/// The paper, page and selections are value snapshots supplied by ReaderView
/// when the button is pressed.  Changing pages or making another selection
/// while this sheet is open therefore cannot move the annotation's anchor.
struct ManualAnnotationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let paperID: String
    let paperTitle: String
    let pageIndex: Int
    let selections: [ReadingSelection]

    @StateObject private var form = ManualAnnotationSheetState()

    private var canSave: Bool {
        model.selectedPaper?.id == paperID &&
        !form.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("添加 PDF 批注"))
                        .font(InspectorText.title)
                    Text(paperTitle)
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Label(L("批注位置"), systemImage: "scope")
                        .font(InspectorText.section)
                    Spacer()
                    Text(selections.isEmpty ? L("当前页") : "已固定 \(selections.count) 处")
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                }
                if selections.isEmpty {
                    Text(L("PDF 第 \(pageIndex + 1) 页（未选择文字或图表）", "PDF page \(pageIndex + 1) (no text or figure selected)"))
                        .font(InspectorText.body)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(selections) { selection in
                                selectionSummary(selection)
                            }
                        }
                    }
                    .frame(maxHeight: 138)
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("批注内容"))
                    .font(InspectorText.section)
                TextEditor(text: $form.content)
                    .font(InspectorText.editable)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 115, maxHeight: 210)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                Text(selections.isEmpty
                     ? L("会在当前页放置一个 PDF 评论图标。")
                     : L("会在固定选区添加高亮，并在第一处放置评论图标。"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }

            if let error = form.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                if model.selectedPaper?.id != paperID {
                    Label(L("当前文献已切换，请关闭后重新添加。"), systemImage: "lock.fill")
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("取消")) { dismiss() }
                Button(L("写入 PDF")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 430)
        .font(InspectorText.body)
    }

    @ViewBuilder
    private func selectionSummary(_ selection: ReadingSelection) -> some View {
        let context = selection.context
        HStack(alignment: .top, spacing: 8) {
            Text(selection.label)
                .font(InspectorText.section)
                .foregroundStyle(ReaderPalette.action)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("PDF 第 \(context.pageIndex + 1) 页", "PDF page \(context.pageIndex + 1)"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                if let data = try? model.selectionImage(for: context), let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 56, alignment: .leading)
                        .accessibilityLabel(L("框选区域截图"))
                } else if !context.sourceText.isEmpty {
                    Text(context.sourceText.replacingOccurrences(of: "\n", with: " "))
                        .font(InspectorText.body)
                        .lineLimit(2)
                } else if context.imageRelativePath != nil {
                    Label(L("公式或图表截图已固定"), systemImage: "photo")
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("页面区域已固定"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func save() {
        guard canSave else { return }
        guard model.saveManualPDFAnnotation(
            content: form.content,
            paperID: paperID,
            pageIndex: pageIndex,
            selections: selections
        ) else {
            form.errorMessage = model.errorMessage ?? L("批注写入失败，请稍后重试。")
            return
        }
        dismiss()
    }
}

private final class ManualAnnotationSheetState: ObservableObject {
    @Published var content = ""
    @Published var errorMessage: String?
}
