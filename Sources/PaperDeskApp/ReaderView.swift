import AppKit
import Combine
import CoreText
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeskCore

public struct ReaderView: View {
    @ObservedObject public var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewState = ReaderViewState()
    @AppStorage("paperdesk.inspectorWidth") private var preferredInspectorWidth: Double = 310
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.chinese.rawValue

    private let inspectorMinimumWidth: CGFloat = 250
    private let readablePDFMinimumWidth: CGFloat = 350
    private let inspectorDividerWidth: CGFloat = 8

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if viewState.showLibrary {
                    LibrarySidebar(model: model, query: $viewState.libraryQuery, showImporter: $viewState.showImporter)
                        .frame(width: 224)
                    Divider()
                }

                ZStack {
                    if model.document != nil {
                        VStack(spacing: 0) {
                            if viewState.showPDFFind { pdfFindBar }
                            ZStack(alignment: .bottomTrailing) {
                                PDFReaderView(model: model, document: model.document, searchSelection: viewState.pdfMatches.indices.contains(viewState.pdfMatchIndex) ? viewState.pdfMatches[viewState.pdfMatchIndex] : nil)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                FloatingQuestionButton(model: model, questions: model.questions) {
                                    viewState.inspectorTab = 1
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        viewState.showInspector = true
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            StatusBar(model: model)
                        }
                    } else {
                        EmptyReaderView(showImporter: $viewState.showImporter)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(ReaderPalette.canvas)
                .overlay {
                    if viewState.isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(ReaderPalette.action, lineWidth: 2)
                            .padding(18)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self, action: { urls, _ in
                    guard let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
                    model.openPDF(url: url)
                    return true
                }, isTargeted: { targeted in
                    viewState.isDropTargeted = targeted
                })

                if viewState.showInspector {
                    inspectorDivider(availableWidth: geometry.size.width)
                    ReaderInspector(model: model, selectedTab: $viewState.inspectorTab, noteDraft: $viewState.noteDraft, editingNoteID: $viewState.editingNoteID, onEditGoal: {
                        viewState.showReadingGoalSheet = true
                    }, onShowNotes: {
                        viewState.showNotesSheet = true
                    }, onAddManualAnnotation: { selection in
                        beginManualAnnotation(selection: selection)
                    })
                        .frame(width: inspectorWidth(for: geometry.size.width))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(ReaderPalette.buttonTint)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if viewState.showInspector && viewState.inspectorTab == 1 {
                model.refreshExternalConversationTitles()
            }
            model.refreshMCPConnectionState()
            var titleRefreshTick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshMCPConnectionState()
                titleRefreshTick += 1
                if titleRefreshTick >= 6 {
                    titleRefreshTick = 0
                    if viewState.showInspector && viewState.inspectorTab == 1 {
                        model.refreshExternalConversationTitles()
                    }
                }
            }
        }
        .onChange(of: model.selectedPaper?.id) { _, _ in
            model.refreshExternalConversationTitles()
        }
        .onChange(of: viewState.showInspector) { _, isShowing in
            if isShowing && viewState.inspectorTab == 1 {
                model.refreshExternalConversationTitles()
            }
        }
        .onChange(of: viewState.inspectorTab) { _, selectedTab in
            if viewState.showInspector && selectedTab == 1 {
                model.refreshExternalConversationTitles()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { viewState.showLibrary.toggle() } } label: {
                    Label(L("资料库"), systemImage: "sidebar.leading")
                }
                .help(L("显示或隐藏资料库"))
                Button { viewState.showImporter = true } label: { Label(L("导入 PDF"), systemImage: "plus") }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    PaperDeskWordmark(size: 16)
                    if let title = model.selectedPaper?.title {
                        Rectangle()
                            .fill(ReaderPalette.divider)
                            .frame(width: 1, height: 15)
                        Text(title)
                            .font(InspectorText.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.document != nil {
                    Toggle(isOn: $model.formulaCaptureMode) {
                        Label(L("框选公式"), systemImage: "viewfinder")
                    }
                    .toggleStyle(.button)
                    .help(model.formulaCaptureMode ? L("退出公式框选") : L("拖动框选公式或图表"))
                    Button { model.adjustPDFZoom(by: 1.15) } label: { Label(L("放大"), systemImage: "plus.magnifyingglass") }
                    Button { model.adjustPDFZoom(by: 1 / 1.15) } label: { Label(L("缩小"), systemImage: "minus.magnifyingglass") }
                    Button { model.zoomMode = .fitWidth } label: { Label(L("适合宽度"), systemImage: "arrow.left.and.right") }
                        .help(L("随阅读区宽度自动缩放"))
                    Button { viewState.showPDFFind.toggle() } label: { Label(L("查找原文"), systemImage: "magnifyingglass") }
                        .keyboardShortcut("f")
                    Divider()
                    Button { withAnimation(.easeInOut(duration: 0.18)) { viewState.showInspector.toggle() } } label: {
                        Label(L("阅读助手"), systemImage: "sidebar.trailing")
                    }
                }
                Menu {
                    if model.document != nil {
                        Button { model.zoomMode = .fitPage } label: {
                            Label(L("显示整页"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    Button {
                        viewState.inspectorTab = 0
                        withAnimation(.easeInOut(duration: 0.18)) { viewState.showInspector = true }
                    } label: {
                        Label(L("项目与连接"), systemImage: "folder.badge.gearshape")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button {
                        viewState.showConnectionSheet = true
                    } label: {
                        Label(L("连接 MCP 客户端"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Picker(L("AI 正文读取范围"), selection: $model.scope) {
                        ForEach(ContextScope.allCases, id: \.self) { value in
                            Text(L(value.title)).tag(value)
                        }
                    }
                    Toggle(L("允许 AI 读取手写笔记"), isOn: $model.shareNotesWithAI)
                    Toggle(L("允许 AI 标记 PDF 原文", "Allow AI to highlight PDF sources"), isOn: $model.allowsAICitationMarks)
                    Toggle(L("连接 AI 时自动核实参考文献", "Verify references automatically when an AI client is connected"), isOn: $model.autoVerifyReferences)
                    Button {
                        model.reindexReferences()
                    } label: {
                        Label(L("重建参考文献索引", "Rebuild reference index"), systemImage: "book.closed")
                    }
                    .disabled(model.selectedPaper == nil || model.referenceIndexingPaperIDs.contains(model.selectedPaper?.id ?? ""))
                    Divider()
                    Picker(L("界面语言"), selection: $language) {
                        ForEach(AppLanguage.allCases) { value in
                            Text(value.menuTitle).tag(value.rawValue)
                        }
                    }
                    Divider()
                    Button { viewState.showInfoSheet = true } label: {
                        Label(L("文献信息"), systemImage: "info.circle")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button { model.revealCurrentPDF() } label: {
                        Label(L("在 Finder 中显示 PDF"), systemImage: "doc")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button { model.exportAnnotatedPDF() } label: {
                        Label(L("导出批注 PDF"), systemImage: "doc.richtext")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button { model.exportReadingRecords() } label: {
                        Label(L("导出阅读记录 JSON"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button { model.exportMarkdown() } label: {
                        Label(L("导出 Markdown"), systemImage: "doc.plaintext")
                    }
                    .disabled(model.selectedPaper == nil)
                    Button { model.backupLibrary() } label: {
                        Label(L("备份资料库"), systemImage: "externaldrive")
                    }
                } label: {
                    Label(L("更多"), systemImage: "ellipsis.circle")
                }
            }
        }
        .font(InspectorText.body)
        .fileImporter(isPresented: $viewState.showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.openPDF(url: url) }
        }
        .sheet(isPresented: $viewState.showInfoSheet) {
            PaperInfoSheet(model: model)
        }
        .sheet(isPresented: $viewState.showConnectionSheet) {
            ConnectionConfigurationSheet(model: model)
        }
        .sheet(item: $model.projectNamePrompt, onDismiss: { model.cancelProjectNamePrompt() }) { prompt in
            ProjectNameSheet(model: model, prompt: prompt)
        }
        .sheet(isPresented: $viewState.showManualAnnotationSheet) {
            if let paperID = viewState.manualAnnotationPaperID {
                ManualAnnotationSheet(
                    model: model,
                    paperID: paperID,
                    paperTitle: viewState.manualAnnotationPaperTitle,
                    pageIndex: viewState.manualAnnotationPageIndex,
                    selections: viewState.manualAnnotationSelections
                )
            } else {
                Text(L("请先打开一篇文献。"))
                    .font(InspectorText.body)
                    .padding(24)
            }
        }
        .sheet(isPresented: $viewState.showNotesSheet) {
            PaperNotesSheet(model: model)
        }
        .sheet(isPresented: $viewState.showReadingGoalSheet) {
            ReadingGoalSheet(model: model)
        }
        .onChange(of: model.selectedPaper?.id) { _, _ in
            viewState.noteDraft = ""
            viewState.editingNoteID = nil
            viewState.pdfMatches = []
            viewState.pdfMatchIndex = 0
            viewState.hasSearchedPDF = false
        }
        .onDisappear {
            resetInspectorDividerCursor()
        }
    }

    private func inspectorWidth(for totalWidth: CGFloat) -> CGFloat {
        let librarySpace: CGFloat = viewState.showLibrary ? 225 : 0
        let maximum = max(inspectorMinimumWidth, totalWidth - librarySpace - inspectorDividerWidth - readablePDFMinimumWidth)
        let preferred = CGFloat(preferredInspectorWidth)
        let width = min(max(preferred, inspectorMinimumWidth), maximum)
        if let dragWidth = viewState.inspectorDragWidth {
            return min(max(dragWidth, inspectorMinimumWidth), maximum)
        }
        return width
    }

    private func inspectorDivider(availableWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: inspectorDividerWidth)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(ReaderPalette.divider)
                    .frame(width: 1)
            }
            .onHover { hovering in
                updateInspectorDividerCursor(hovering)
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if viewState.inspectorDragStartWidth == nil {
                            viewState.inspectorDragStartWidth = inspectorWidth(for: availableWidth)
                        }
                        guard let startWidth = viewState.inspectorDragStartWidth else { return }
                        let proposed = startWidth - value.translation.width
                        viewState.inspectorDragWidth = clampedInspectorWidth(proposed, availableWidth: availableWidth)
                    }
                    .onEnded { _ in
                        if let width = viewState.inspectorDragWidth {
                            preferredInspectorWidth = Double(clampedInspectorWidth(width, availableWidth: availableWidth))
                        }
                        viewState.inspectorDragWidth = nil
                        viewState.inspectorDragStartWidth = nil
                    }
            )
            .help(L("拖动调整阅读助手宽度"))
            .accessibilityLabel(L("阅读助手宽度"))
            .accessibilityHint(L("左右拖动调整右侧栏宽度"))
    }

    private func clampedInspectorWidth(_ value: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let librarySpace: CGFloat = viewState.showLibrary ? 225 : 0
        let maximum = max(inspectorMinimumWidth, availableWidth - librarySpace - inspectorDividerWidth - readablePDFMinimumWidth)
        return min(max(value, inspectorMinimumWidth), maximum)
    }

    private func updateInspectorDividerCursor(_ hovering: Bool) {
        guard hovering != viewState.isInspectorDividerHovered else { return }
        viewState.isInspectorDividerHovered = hovering
        if hovering {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }

    private func resetInspectorDividerCursor() {
        guard viewState.isInspectorDividerHovered else { return }
        viewState.isInspectorDividerHovered = false
        NSCursor.pop()
    }

    private var pdfFindBar: some View {
        HStack {
            TextField(L("查找 PDF 原文"), text: $viewState.pdfQuery)
                .onSubmit { findInPDF() }
            Button(L("查找")) { findInPDF() }
            if !viewState.pdfMatches.isEmpty {
                Text("\(viewState.pdfMatchIndex + 1) / \(viewState.pdfMatches.count)")
                    .monospacedDigit()
                Button(L("上一处"), systemImage: "chevron.up") { stepMatch(-1) }
                    .labelStyle(.iconOnly)
                Button(L("下一处"), systemImage: "chevron.down") { stepMatch(1) }
                    .labelStyle(.iconOnly)
            } else if viewState.hasSearchedPDF {
                Text(L("没有匹配")).foregroundStyle(.secondary)
            }
            Button(L("关闭查找"), systemImage: "xmark") {
                viewState.showPDFFind = false
                viewState.pdfMatches = []
            }.labelStyle(.iconOnly)
        }
        .padding(8)
        .background(ReaderPalette.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ReaderPalette.divider)
                .frame(height: 1)
        }
    }

    private func findInPDF() {
        let query = viewState.pdfQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        viewState.hasSearchedPDF = !query.isEmpty
        viewState.pdfMatches = query.isEmpty ? [] : model.document?.findString(query, withOptions: .caseInsensitive) ?? []
        viewState.pdfMatchIndex = 0
    }

    private func stepMatch(_ offset: Int) {
        let count = viewState.pdfMatches.count
        guard count > 0 else { return }
        viewState.pdfMatchIndex = (viewState.pdfMatchIndex + offset + count) % count
    }

    private func beginManualAnnotation(selection: ReadingSelection? = nil) {
        guard let paper = model.selectedPaper else { return }
        viewState.manualAnnotationPaperID = paper.id
        viewState.manualAnnotationPaperTitle = paper.title
        viewState.manualAnnotationPageIndex = selection?.context.pageIndex ?? model.currentPageIndex
        viewState.manualAnnotationSelections = selection.map { [$0] } ?? model.activeSelections
        viewState.showManualAnnotationSheet = true
    }
}

/// Holds transient window state outside `ReaderView` itself. This keeps the
/// view compatible with the macOS SDK shipped on the development machine,
/// where the newer `@State` macro plugin may be unavailable to command-line
/// builds while `@StateObject` remains supported.
private final class ReaderViewState: ObservableObject {
    @Published var showImporter = false
    @Published var showLibrary = true
    @Published var showInspector = false
    @Published var libraryQuery = ""
    @Published var inspectorTab = 0
    @Published var noteDraft = ""
    @Published var editingNoteID: String?
    @Published var isDropTargeted = false
    @Published var showInfoSheet = false
    @Published var showPDFFind = false
    @Published var hasSearchedPDF = false
    @Published var pdfQuery = ""
    @Published var pdfMatches: [PDFSelection] = []
    @Published var pdfMatchIndex = 0
    @Published var inspectorDragStartWidth: CGFloat?
    @Published var inspectorDragWidth: CGFloat?
    @Published var isInspectorDividerHovered = false
    @Published var showConnectionSheet = false
    @Published var showNotesSheet = false
    @Published var showReadingGoalSheet = false
    @Published var showManualAnnotationSheet = false
    @Published var manualAnnotationPaperID: String?
    @Published var manualAnnotationPaperTitle = ""
    @Published var manualAnnotationPageIndex = 0
    @Published var manualAnnotationSelections: [ReadingSelection] = []
}

private final class PaperInfoSheetState: ObservableObject {
    @Published var tagsText = ""
    @Published var readingState = "unread"
    @Published var bibtex = ""
    @Published var importedEntries: [BibTeX.Entry] = []
    @Published var importedEntryIndex = 0
    @Published var importError: String?

    func load(_ paper: Paper) {
        tagsText = paper.tags.joined(separator: ", ")
        readingState = paper.readingState
        bibtex = paper.bibtex
        importedEntries = []
        importError = nil
    }
}

private struct PaperInfoSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = PaperInfoSheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let paper = model.selectedPaper {
                Text(L("文献信息")).font(InspectorText.title)
                LabeledContent(L("标题")) {
                    Text(paper.title).lineLimit(2).multilineTextAlignment(.trailing)
                }
                LabeledContent(L("文件")) {
                    Text(paper.fileName).font(InspectorText.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                TextField(L("标签，用逗号分隔"), text: $form.tagsText)
                    .textFieldStyle(.roundedBorder)
                Picker(L("阅读状态"), selection: $form.readingState) {
                    Text(L("未读")).tag("unread")
                    Text(L("在读")).tag("reading")
                    Text(L("已读")).tag("read")
                }
                HStack {
                    Text("BibTeX").font(InspectorText.section)
                    Spacer()
                    Button(L("从 .bib 导入")) { importBibTeX() }
                }
                if !form.importedEntries.isEmpty {
                    HStack {
                        Picker(L("引用条目"), selection: $form.importedEntryIndex) {
                            ForEach(form.importedEntries.indices, id: \.self) { index in
                                let entry = form.importedEntries[index]
                                Text(entry.label == entry.id ? entry.id : "\(entry.label) · \(entry.id)").tag(index)
                            }
                        }
                        Button(L("使用条目")) {
                            form.bibtex = form.importedEntries[form.importedEntryIndex].raw
                            form.importedEntries = []
                        }
                    }
                }
                if let error = form.importError {
                    Text(error).font(InspectorText.detail).foregroundStyle(.red)
                }
                TextEditor(text: $form.bibtex)
                    .font(InspectorText.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 130)
                HStack {
                    Button(L("复制 BibTeX")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(form.bibtex, forType: .string)
                        model.statusMessage = L("BibTeX 已复制。")
                    }
                    .disabled(form.bibtex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button(L("取消")) { dismiss() }
                    Button(L("保存")) { save(paper) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text(L("请先打开一篇文献。"))
                HStack {
                    Spacer()
                    Button(L("关闭")) { dismiss() }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
        .font(InspectorText.body)
        .background(ReaderPalette.canvas)
        .onAppear {
            if let paper = model.selectedPaper { form.load(paper) }
        }
        .onChange(of: model.selectedPaper?.id) { _, _ in
            if let paper = model.selectedPaper { form.load(paper) }
        }
    }

    private func importBibTeX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else {
                throw PaperDeskError.invalid(L("文件大于 8 MB，请先导出需要的文献条目。"))
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PaperDeskError.invalid(L("请将 BibTeX 文件保存为 UTF-8 格式后重试。"))
            }
            let entries = try BibTeX.entries(in: text)
            guard let first = entries.first else {
                throw PaperDeskError.invalid(L("文件里没有找到可用的引用条目。"))
            }
            form.importError = nil
            form.importedEntryIndex = 0
            form.importedEntries = entries.count == 1 ? [] : entries
            if entries.count == 1 { form.bibtex = first.raw }
        } catch {
            form.importedEntries = []
            form.importError = error.localizedDescription
        }
    }

    private func save(_ paper: Paper) {
        do {
            let tags = form.tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            try model.store.setTags(paperID: paper.id, tags: tags)
            try model.store.setReadingState(paperID: paper.id, state: form.readingState)
            try model.store.setBibliography(paperID: paper.id, bibtex: form.bibtex)
            model.refreshLibrary()
            model.statusMessage = L("文献信息已保存。")
            model.errorMessage = nil
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct LibrarySidebar: View {
    @ObservedObject var model: AppModel
    @Binding var query: String
    @Binding var showImporter: Bool

    private var filteredPapers: [Paper] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.papers }
        return (try? model.store.search(query: needle)) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("资料库")).font(InspectorText.title)
                Spacer()
                Button { showImporter = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(L("导入 PDF"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 9)
            TextField(L("搜索文献、标签和笔记"), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(InspectorText.body)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if filteredPapers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "books.vertical" : "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? L("还没有文献") : L("没有匹配的文献"))
                        .foregroundStyle(.secondary)
                    if query.isEmpty {
                        Button(L("导入第一篇 PDF")) { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredPapers) { paper in
                        PaperRow(paper: paper, selected: model.selectedPaper?.id == paper.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openPaper(paper) }
                            .contextMenu {
                                Button(paper.readingState == "read" ? L("标为在读") : L("标为已读")) {
                                    try? model.store.setReadingState(paperID: paper.id, state: paper.readingState == "read" ? "reading" : "read")
                                    model.refreshLibrary()
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .font(InspectorText.body)
        .background(ReaderPalette.inspector)
    }
}

private struct PaperRow: View {
    let paper: Paper
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: paper.readingState == "read" ? "checkmark.circle" : "doc.text")
                .foregroundStyle(selected ? ReaderPalette.action : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(paper.title)
                    .font(InspectorText.body)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(L("\(paper.pageCount) 页", "\(paper.pageCount) pages"))
                    if let first = paper.tags.first { Text("· \(first)") }
                }
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyReaderView: View {
    @Binding var showImporter: Bool
    var body: some View {
        VStack(spacing: 16) {
            PaperDeskBrandLockup()
                .padding(.bottom, 10)
            Text(L("从一篇文献开始")).font(InspectorText.title)
            Text(L("导入 PDF，选中文字后即可交给阅读助手讨论。"))
                .font(InspectorText.body)
                .foregroundStyle(.secondary)
            Button(L("导入 PDF")) { showImporter = true }
                .buttonStyle(.borderedProminent)
            Text(L("也可以把 PDF 拖到这里"))
                .font(InspectorText.detail)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ReaderPalette {
    // Keep surfaces close to the system materials so the reader follows the
    // user's light or dark appearance without relying on a bright accent color.
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let inspector = Color(nsColor: .controlBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let toolbar = Color(nsColor: .windowBackgroundColor)
    static let divider = Color(nsColor: .separatorColor).opacity(0.75)
    static let buttonTint = Color(red: 0.19, green: 0.39, blue: 0.64)
    static let action = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.57, green: 0.76, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.14, green: 0.34, blue: 0.58, alpha: 1)
    })
    static let ready = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.65, green: 0.78, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.37, blue: 0.26, alpha: 1)
    })
    static let softAction = action.opacity(0.09)
    static let focusAI = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.48, green: 0.73, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.39, blue: 0.75, alpha: 1)
    })
    static let focusManual = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.98, green: 0.76, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.64, green: 0.35, blue: 0.05, alpha: 1)
    })
    /// Answer-citation accent. Distinct from the yellow human selections and
    /// the legacy blue AI focus marks.
    static let citation = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.85, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.42, blue: 0.44, alpha: 1)
    })
}

enum InspectorText {
    static let body = serif(16)
    static let editable = body
    static let label = serif(14)
    static let labelStrong = serif(14, bold: true)
    static let section = serif(14, bold: true)
    static let detail = serif(13)
    static let detailStrong = serif(13, bold: true)
    static let badge = serif(10, bold: true)
    static let title = serif(17, bold: true)
    static let bodyNSFont = serifNS(16)
    static let badgeNSFont = serifNS(10, bold: true)

    static func serifNS(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let cascade = NSFontDescriptor(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size)
        let attributes: [NSFontDescriptor.AttributeName: Any] = [
            .name: bold ? "Georgia-Bold" : "Georgia",
            .cascadeList: [cascade]
        ]
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size)
            ?? .systemFont(ofSize: size)
    }

    private static func serif(_ size: CGFloat, bold: Bool = false) -> Font {
        // Request Songti before the default CJK fallback for mixed lines.
        let songti = CTFontDescriptorCreateWithNameAndSize(
            (bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular") as CFString, size
        )
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: bold ? "Georgia-Bold" : "Georgia",
            kCTFontCascadeListAttribute: [songti]
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

private struct ReaderInspector: View {
    @ObservedObject var model: AppModel
    @Binding var selectedTab: Int
    @Binding var noteDraft: String
    @Binding var editingNoteID: String?
    let onEditGoal: () -> Void
    let onShowNotes: () -> Void
    let onAddManualAnnotation: (ReadingSelection) -> Void

    private var selectedNote: ReadingNote? {
        guard let id = editingNoteID else { return nil }
        return model.notes.first(where: { $0.id == id && $0.status == "draft" })
    }

    private var pendingDraftCount: Int {
        model.notes.filter { $0.status == "draft" }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(selection: $selectedTab, pendingCount: pendingDraftCount)
                .padding(12)
            Divider()
            switch selectedTab {
            case 0:
                SelectionPanel(model: model, onEditGoal: onEditGoal, onShowNotes: onShowNotes, onAddManualAnnotation: onAddManualAnnotation)
            default:
                ReadingPanel(model: model, questions: model.questions, noteDraft: $noteDraft, editingNoteID: $editingNoteID, selectedNote: selectedNote)
            }
        }
        .font(InspectorText.body)
        .background(ReaderPalette.inspector)
    }
}

private struct InspectorTabBar: View {
    @Binding var selection: Int
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(title: L("焦点"), tag: 0)
            segment(title: pendingCount == 0 ? L("阅读") : "阅读 · \(pendingCount)", tag: 1)
        }
        .padding(3)
        .background(ReaderPalette.divider.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(height: 32)
    }

    private func segment(title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = tag }
        } label: {
            Text(title)
                .font(selection == tag ? InspectorText.section : InspectorText.label)
                .foregroundStyle(selection == tag ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selection == tag ? ReaderPalette.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: selection == tag ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5)
        .accessibilityAddTraits(selection == tag ? .isSelected : [])
    }
}

private struct SelectionPanel: View {
    @ObservedObject var model: AppModel
    let onEditGoal: () -> Void
    let onShowNotes: () -> Void
    let onAddManualAnnotation: (ReadingSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodexProjectStatusCard(model: model, onEditGoal: onEditGoal, onShowNotes: onShowNotes)

            if !model.activeSelections.isEmpty {
                HStack {
                    Spacer()
                    Button(L("清空焦点"), systemImage: "trash") { model.clearSelections() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(L("清空焦点"))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.activeSelections) { selection in
                            SelectionRow(selection: selection, model: model) {
                                onAddManualAnnotation(selection)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .background(ReaderPalette.inspector)
    }
}

private final class ConnectionDetailsState: ObservableObject {
    @Published var isPresented = false
}

private struct CodexProjectStatusCard: View {
    @ObservedObject var model: AppModel
    let onEditGoal: () -> Void
    let onShowNotes: () -> Void

    @StateObject private var details = ConnectionDetailsState()

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var recentContact: Date? {
        guard let paperID = model.selectedPaper?.id else { return nil }
        return model.codexLastContact[paperID]
    }

    private struct ConnectionGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let version: String?
        let count: Int
    }

    private var connectedClients: [MCPClientConnection] {
        guard let paper = model.selectedPaper else { return [] }
        return model.connectedClients(forPaperID: paper.id, documentHash: paper.fileHash)
    }

    private var connectionGroups: [ConnectionGroup] {
        struct Key: Hashable { let name: String; let version: String? }
        var order: [Key] = []
        var counts: [Key: Int] = [:]
        for connection in connectedClients {
            let name = connection.displayName
            let key = Key(name: name, version: connection.clientVersion)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.map { key in
            ConnectionGroup(id: "\(key.name)|\(key.version ?? "")", name: key.name,
                            version: key.version, count: counts[key] ?? 1)
        }
    }

    private var hasProject: Bool { model.codexProjectURL != nil }

    private var statusHelp: String {
        let groups = connectionGroups
        if groups.isEmpty { return hasProject ? L("未连接 · 项目已配置") : L("未连接 · 项目未准备") }
        return L("已连接：") + groups.map(groupText).joined(separator: "、")
    }

    private var statusDot: some View {
        Button {
            details.isPresented.toggle()
        } label: {
            Group {
                if connectionGroups.isEmpty {
                    Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.2)
                } else {
                    Circle().fill(ReaderPalette.ready)
                }
            }
            .frame(width: 8, height: 8)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(statusHelp)
        .accessibilityLabel(statusHelp)
        .accessibilityHint(L("查看连接详情"))
        .popover(isPresented: $details.isPresented, arrowEdge: .top) {
            connectionDetails
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("连接详情")).font(InspectorText.title)
            if connectionGroups.isEmpty {
                Text(L("暂无 MCP 连接"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connectionGroups) { group in
                    HStack(spacing: 6) {
                        Circle().fill(ReaderPalette.ready).frame(width: 6, height: 6)
                        Text(group.name).font(InspectorText.label)
                        if let version = group.version, !version.isEmpty {
                            Text(version).font(InspectorText.detail).foregroundStyle(.secondary)
                        }
                        if group.count > 1 {
                            Text("×\(group.count)").font(InspectorText.detail).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Divider()
            Text(hasProject ? L("项目已配置") : L("项目未准备"))
                .font(InspectorText.detail)
            if hasProject, !model.codexProjectBindingValid {
                Text(L("配置需更新"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.orange)
            }
            if !model.bridgeConnected {
                Text(L("本机 MCP 服务未运行"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.orange)
            }
            if let project = model.codexProjectURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("项目文件夹"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                    Text(project.lastPathComponent)
                        .font(InspectorText.detail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.path)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .font(InspectorText.body)
    }

    private func groupText(_ group: ConnectionGroup) -> String {
        var text = group.name
        if let version = group.version, !version.isEmpty { text += " · \(version)" }
        if group.count > 1 { text += " ×\(group.count)" }
        return text
    }

    var body: some View {
        if let paper = model.selectedPaper {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Label(paper.effectiveProjectName, systemImage: "folder.badge.gearshape")
                        .font(InspectorText.section)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(model.codexProjectURL?.path ?? L("尚未准备项目"))
                    Spacer(minLength: 4)
                    statusDot
                }

                if let recentContact {
                    Text(L("最近项目访问 · \(Self.localDateFormatter.string(from: recentContact))", "Last project access · \(Self.localDateFormatter.string(from: recentContact))"))
                        .foregroundStyle(.secondary)
                } else if hasProject && connectedClients.isEmpty && model.bridgeConnected {
                    Text(L("等待客户端连接"))
                        .foregroundStyle(.secondary)
                        .help(L("在 Codex、OpenCode 或其他 MCP 客户端中打开这篇文献的项目后，这里会显示连接状态。"))
                }
                if !model.bridgeConnected {
                    Label(L("本机 MCP 服务未运行"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Button(
                        model.codexProjectURL == nil ? L("准备项目") : L("在终端打开"),
                        systemImage: model.codexProjectURL == nil ? "folder.badge.plus" : "terminal"
                    ) {
                        model.createCodexProject()
                    }
                    .help(model.codexProjectURL.map { "在终端中打开：\($0.path)" } ?? L("生成项目配置并在终端中打开"))
                    if let projectURL = model.codexProjectURL {
                        Button(L("复制项目路径"), systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(projectURL.path, forType: .string)
                            model.statusMessage = L("Codex 项目路径已复制。")
                        }
                        .labelStyle(.iconOnly)
                        .help(L("复制项目路径"))
                    }
                }
                .controlSize(.small)

                Divider()

                HStack(spacing: 8) {
                    Button {
                        onEditGoal()
                    } label: {
                        Label(L("阅读目标"), systemImage: "target")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L("查看或修改阅读目标"))

                    Button {
                        onShowNotes()
                    } label: {
                        Label(L("笔记"), systemImage: "note.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L("查看这篇文献的笔记"))
                }
            }
            .font(InspectorText.label)
            .padding(10)
            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ReaderPalette.divider, lineWidth: 0.5)
            }
            .padding(10)
            .onAppear { model.refreshCodexProjectStatus() }
            .onChange(of: model.selectedPaper?.id) { _, _ in
                details.isPresented = false
            }
        }
    }
}

private struct SelectionRow: View {
    let selection: ReadingSelection
    @ObservedObject var model: AppModel
    let onAnnotate: () -> Void

    private var context: ContextSnapshot { selection.context }
    private var isFocused: Bool { model.context?.id == selection.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.showSelection(context)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(selection.label)
                            .font(InspectorText.section)
                            .foregroundStyle(sourceColor)
                        Text(L("PDF 第 \(context.pageIndex + 1) 页", "PDF page \(context.pageIndex + 1)"))
                            .font(InspectorText.detail)
                            .foregroundStyle(.tertiary)
                        Text(sourceLabel)
                            .font(InspectorText.detailStrong)
                            .foregroundStyle(sourceColor)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(sourceColor.opacity(0.10), in: Capsule())
                            .help(sourceHelp)
                        Spacer(minLength: 0)
                    }
                    if let image = image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 180, maxHeight: 78, alignment: .leading)
                            .background(ReaderPalette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if !context.sourceText.isEmpty {
                        Text(context.sourceText.replacingOccurrences(of: "\n", with: " "))
                            .font(InspectorText.body)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isFocused ? sourceColor : ReaderPalette.divider, lineWidth: isFocused ? 1 : 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isFocused ? .isSelected : [])

            Button {
                onAnnotate()
            } label: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(ReaderPalette.action)
            }
            .buttonStyle(.borderless)
            .help(L("为 \(selection.label) 添加批注", "Add an annotation to \(selection.label)"))

            Button {
                model.removeSelection(id: selection.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("移除 \(selection.label)", "Remove \(selection.label)"))
        }
    }

    private var image: NSImage? {
        guard let data = try? model.selectionImage(for: context) else { return nil }
        return NSImage(data: data)
    }

    private var sourceLabel: String {
        guard selection.isAI else { return L("手动") }
        let client = selection.aiOrigin?.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.map { "AI · \(String($0.prefix(18)))" } ?? "AI"
    }

    private var sourceHelp: String {
        guard selection.isAI else { return L("人工在 PaperDesk 中添加的阅读焦点") }
        let origin = selection.aiOrigin
        let client = origin?.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = origin?.clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (client?.isEmpty == false ? client : nil, version?.isEmpty == false ? version : nil) {
        case let (client?, version?): return L("AI 阅读焦点 · \(client) \(version)", "AI reading focus · \(client) \(version)")
        case let (client?, nil): return L("AI 阅读焦点 · \(client)", "AI reading focus · \(client)")
        case let (nil, version?): return L("AI 阅读焦点 · \(version)", "AI reading focus · \(version)")
        default: return L("AI 阅读焦点")
        }
    }

    private var sourceColor: Color {
        selection.isAI ? ReaderPalette.focusAI : ReaderPalette.focusManual
    }
}

private final class ReadingPanelState: ObservableObject {
    @Published var expandedConversationID: String? = nil
    @Published var excerptNoteID: String? = nil
    @Published var excerptOrder: [String] = []
    @Published var excerptIncluded = Set<String>()
    @Published var excerptRewriteText = ""
    @Published var expandedMessageIDs = Set<String>()
}

private struct ReadingPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var questions: PaperQuestions
    @Binding var noteDraft: String
    @Binding var editingNoteID: String?
    let selectedNote: ReadingNote?

    @StateObject private var form = ReadingPanelState()

    private var summarySourcesByNoteID: [String: [ExtractiveSource]] {
        guard let id = model.selectedPaper?.id,
              let summaries = try? model.store.extractiveSummaryMessages(paperID: id) else { return [:] }
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.summarySources ?? []) })
    }

    private var selectedExtractiveNote: ReadingNote? {
        guard let selectedNote,
              !(summarySourcesByNoteID[selectedNote.id] ?? []).isEmpty else { return nil }
        return selectedNote
    }

    private var pendingAnnotationNotes: [ReadingNote] {
        model.notes.filter { isPendingPDFAnnotation($0) }
    }

    private var pendingExcerptNotes: [ReadingNote] {
        model.notes.filter { $0.status == "draft" && $0.kind == "excerpt" }
    }

    private var pendingOrdinaryNotes: [ReadingNote] {
        model.notes.filter {
            $0.status == "draft" && !isPendingPDFAnnotation($0) && $0.kind != "excerpt"
        }
    }

    private func isPendingPDFAnnotation(_ note: ReadingNote) -> Bool {
        guard note.status == "draft" else { return false }
        // PaperDesk 0.5.5 did not persist `kind`; an AI draft from that
        // version is nevertheless a PDF-annotation draft and must not be
        // offered the ordinary-note confirmation path.
        return note.kind == "annotation" || (note.kind == nil && note.source == "ai")
    }

    var body: some View {
        let sourcesByNote = summarySourcesByNoteID
        let conversations = ConversationGrouping.group(discussionMessages)
        let codexBindings = codexBindingsByConversationID
        VStack(spacing: 0) {
            if let paperID = model.selectedPaper?.id, let progress = questions.progressByPaperID[paperID] {
                PaperQuestionProgressStatus(progress: progress) {
                    questions.cancel(paperID: paperID)
                }
                .padding(10)
                Divider()
            } else if let activeProgressError, !activeProgressError.isEmpty {
                Label(activeProgressError, systemImage: "exclamationmark.triangle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            if let conversation = conversations.first(where: { $0.id == form.expandedConversationID }) {
                conversationDetail(conversation, codexBinding: codexBindings[conversation.stableConversationID])
            } else {
                if let feedbackCounts {
                    ReadingFeedbackSummary(counts: feedbackCounts)
                    Divider()
                }
                if pendingNoteCount > 0 {
                    pendingDraftReview(sourcesByNote: sourcesByNote)
                    if let selectedNote {
                        Divider()
                        noteEditor(selectedNote, sourcesByNote: sourcesByNote)
                            .frame(maxHeight: 330)
                    }
                    Divider()
                }
                conversationList(conversations)
            }
        }
        .onAppear {
            loadExcerptEditor()
            syncActiveConversation()
        }
        .onChange(of: editingNoteID) { _, _ in loadExcerptEditor() }
        .onChange(of: model.notes) { _, _ in loadExcerptEditor() }
        .onChange(of: model.activeReadingConversationID) { _, _ in syncActiveConversation() }
        .onChange(of: model.selectedPaper?.id) { _, _ in syncActiveConversation() }
    }

    private var pendingNoteCount: Int {
        pendingAnnotationNotes.count + pendingExcerptNotes.count + pendingOrdinaryNotes.count
    }

    private var feedbackCounts: ReadingFeedbackCounts? {
        var counts = ReadingFeedbackCounts()
        for message in discussionMessages where message.role == .user {
            guard let feedback = message.readingFeedback else { continue }
            switch feedback.kind {
            case .unclear:
                counts.unclear += 1
            case .repeatedQuestion:
                counts.repeatedQuestion += 1
            case .followUp:
                counts.followUp += 1
            }
        }
        return counts.total == 0 ? nil : counts
    }

    private var codexBindingsByConversationID: [String: QuestionBinding] {
        guard let paperID = model.selectedPaper?.id,
              let bindings = try? model.store.questionBindings(paperID: paperID) else { return [:] }
        var result: [String: QuestionBinding] = [:]
        for binding in bindings where binding.backend.caseInsensitiveCompare("codex") == .orderedSame {
            result[binding.conversationID] = binding
        }
        return result
    }

    private func pendingDraftReview(sourcesByNote: [String: [ExtractiveSource]]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L("待审核"))
                    .font(InspectorText.section)
                Spacer()
                Text("\(pendingNoteCount)")
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pendingAnnotationNotes) { note in
                        Button { openNote(note) } label: { normalNoteRow(note) }
                            .buttonStyle(.plain)
                    }
                    ForEach(pendingExcerptNotes) { note in
                        extractiveNoteRow(note, sources: sourcesByNote[note.id] ?? [])
                            .contentShape(Rectangle())
                            .onTapGesture { openNote(note) }
                    }
                    ForEach(pendingOrdinaryNotes) { note in
                        Button { openNote(note) } label: { normalNoteRow(note) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private struct ConversationDay: Identifiable {
        let id: Date
        let title: String
        let conversations: [ConversationSummary]
    }

    private func conversationDays(_ conversations: [ConversationSummary]) -> [ConversationDay] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [ConversationSummary]] = [:]
        for conversation in conversations {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(conversation)
        }
        return order.map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = L("今天")
            } else if calendar.isDateInYesterday(day) {
                title = L("昨天")
            } else {
                title = Self.dayFormatter.string(from: day)
            }
            return ConversationDay(id: day, title: title, conversations: groups[day] ?? [])
        }
    }

    @ViewBuilder
    private func conversationList(_ conversations: [ConversationSummary]) -> some View {
        if conversations.isEmpty {
            emptyState(icon: "bubble.left.and.bubble.right",
                       title: L("还没有问答"),
                       detail: L("在与 Codex、opencode 或 Claude Code 的对话中归档问答后，会按对话分别显示在这里。"))
        } else {
            List {
                ForEach(conversationDays(conversations)) { day in
                    Section {
                        ForEach(day.conversations) { conversation in
                            conversationRow(conversation)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            Text(day.title)
                            Spacer()
                            Text("\(day.conversations.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(InspectorText.detail)
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 165, maxHeight: .infinity)
            .font(InspectorText.body)
        }
    }

    private func conversationRow(_ conversation: ConversationSummary) -> some View {
        Button {
            openConversation(conversation)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(InspectorText.section)
                        .lineLimit(2)
                        .help(conversation.title)
                    HStack(spacing: 6) {
                        sourceBadge(L(conversation.sourceLabel), color: conversationColor(conversation))
                        Text(L("\(conversation.turnCount) 轮", "\(conversation.turnCount) turns"))
                        Text(Self.shortDateFormatter.string(from: conversation.updatedAt))
                    }
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ReaderPalette.divider.opacity(0.9), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func conversationDetail(_ conversation: ConversationSummary,
                                    codexBinding: QuestionBinding?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    closeConversationDetail()
                } label: {
                    Label(L("返回阅读", "Back to Reading"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(L("返回阅读记录", "Back to reading records"))

                Divider()
                    .frame(height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    conversationTitleView(conversation, codexBinding: codexBinding)
                    HStack(spacing: 6) {
                        sourceBadge(L(conversation.sourceLabel), color: conversationColor(conversation))
                        Text(L("\(conversation.turnCount) 轮", "\(conversation.turnCount) turns"))
                            .font(InspectorText.detail)
                            .foregroundStyle(.secondary)
                        Text(Self.shortDateFormatter.string(from: conversation.updatedAt))
                            .font(InspectorText.detail)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    // A plain stack keeps the reply heights fixed before the
                    // initial scroll-to-answer, so opening a conversation does
                    // not bounce while lazy rows materialize.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            VStack(alignment: .leading, spacing: 0) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(ReaderPalette.divider.opacity(0.55))
                                        .frame(height: 1)
                                        .padding(.vertical, 12)
                                }
                                DiscussionTurn(message: message,
                                               conversationID: conversation.id,
                                               model: model,
                                               expandedMessageIDs: $form.expandedMessageIDs)
                            }
                            .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .task(id: conversation.id) {
                    if let answer = conversation.messages.last(where: { $0.role == .assistant }) {
                        scroll.scrollTo(answer.id, anchor: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderPalette.inspector)
    }

    private func openConversation(_ conversation: ConversationSummary) {
        withAnimation(.easeInOut(duration: 0.12)) {
            form.expandedConversationID = conversation.id
            model.activeReadingConversationID = conversation.id
            selectDefaultMessage(in: conversation)
        }
    }

    private func closeConversationDetail() {
        withAnimation(.easeInOut(duration: 0.12)) {
            form.expandedConversationID = nil
            form.expandedMessageIDs.removeAll()
            if model.activeReadingConversationID != nil {
                model.activeReadingConversationID = nil
            }
            model.clearCitationMarks()
        }
    }

    private func selectDefaultMessage(in conversation: ConversationSummary) {
        guard let answer = conversation.messages.last(where: { $0.role == .assistant }) else {
            form.expandedMessageIDs.removeAll()
            model.clearCitationMarks()
            return
        }
        form.expandedMessageIDs = [answer.id]
        model.activateCitations(for: answer)
    }

    @ViewBuilder
    private func conversationTitleView(_ conversation: ConversationSummary,
                                       codexBinding: QuestionBinding?) -> some View {
        HStack(spacing: 6) {
            Text(conversation.title)
                .font(InspectorText.section)
                .lineLimit(2)
                .help(conversation.title)
            Spacer(minLength: 0)
            if let url = codexThreadURL(for: codexBinding) {
                Link(destination: url) {
                    Label(L("在 Codex 中打开", "Open in Codex"), systemImage: "arrow.up.right.square")
                        .font(InspectorText.detail)
                        .foregroundStyle(ReaderPalette.action)
                }
                .help(L("在 Codex 中打开这条对话", "Open this conversation in Codex"))
                .accessibilityLabel(L("在 Codex 中打开", "Open in Codex"))
            }
        }
    }

    private func codexThreadURL(for binding: QuestionBinding?) -> URL? {
        guard let binding,
              binding.backend.caseInsensitiveCompare("codex") == .orderedSame,
              let threadID = UUID(uuidString: binding.externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return URL(string: "codex://threads/\(threadID.uuidString.lowercased())")
    }

    private func sourceBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(InspectorText.detailStrong)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func conversationColor(_ conversation: ConversationSummary) -> Color {
        conversation.isManual ? .secondary : ReaderPalette.action
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(detail)
                .font(InspectorText.detail)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func noteEditor(_ note: ReadingNote, sourcesByNote: [String: [ExtractiveSource]]) -> some View {
        if let sources = sourcesByNote[note.id], !sources.isEmpty {
            extractiveEditor(note, sources: sources)
                .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(isPendingPDFAnnotation(note) ? L("审核 PDF 批注") : L("审核 AI 笔记"))
                        .font(InspectorText.title)
                        .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        if model.deleteNote(note) { clearEditor() }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L("丢弃草稿"))
                    .accessibilityLabel(L("丢弃草稿"))
                    closeDraftEditor
                }
                TextEditor(text: $noteDraft)
                    .font(InspectorText.editable)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 110, maxHeight: 190)
                    .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ReaderPalette.divider, lineWidth: 0.5)
                    }
                editorActions(for: note)
            }
            .padding(12)
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private func editorActions(for note: ReadingNote) -> some View {
        let hasContent = !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
            if isPendingPDFAnnotation(note) {
                Button(L("写入 PDF")) {
                    if model.writeNoteToPDF(note, content: noteDraft) { clearEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasContent)
            } else {
                Button(L("确认保存")) {
                    if model.updateNote(note, content: noteDraft, status: "accepted") { clearEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasContent)
            }
            Button(L("保存草稿")) {
                model.updateNote(note, content: noteDraft)
            }
            .buttonStyle(.bordered)
            .disabled(!hasContent)
        }
        .controlSize(.regular)
    }

    private var closeDraftEditor: some View {
        Button(L("关闭审核"), systemImage: "xmark", action: clearEditor)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(L("关闭审核"))
    }

    private func clearEditor() {
        editingNoteID = nil
        noteDraft = ""
    }

    private func originTitle(for note: ReadingNote) -> String {
        guard note.source == "ai" else { return L("手动") }
        let clientName = note.origin?.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = note.origin?.clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = [clientName, clientVersion].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
        return client.isEmpty ? L("AI · 未知客户端") : "AI · \(client)"
    }

    private func recordTitle(for note: ReadingNote) -> String {
        let origin = originTitle(for: note)
        if model.pdfAnnotationNoteIDs.contains(note.id) {
            return L("PDF 批注 · \(origin)", "PDF annotation · \(origin)")
        }
        return origin
    }

    private func recordColor(for note: ReadingNote) -> Color {
        note.source == "ai" ? ReaderPalette.action : .secondary
    }

    private var discussionMessages: [PaperChatMessage] {
        model.discussion
    }

    private var activeProgressError: String? {
        guard let paperID = model.selectedPaper?.id else { return nil }
        return questions.errors[paperID]
    }

    private func syncActiveConversation() {
        guard let conversationID = model.activeReadingConversationID,
              let conversation = ConversationGrouping.group(discussionMessages).first(where: { $0.id == conversationID }) else {
            form.expandedConversationID = nil
            form.expandedMessageIDs.removeAll()
            model.clearCitationMarks()
            return
        }
        guard form.expandedConversationID != conversationID else { return }
        form.expandedConversationID = conversationID
        selectDefaultMessage(in: conversation)
    }

    @ViewBuilder
    private func normalNoteRow(_ note: ReadingNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recordTitle(for: note))
                    .font(InspectorText.section)
                    .foregroundStyle(recordColor(for: note))
                    .lineLimit(1)
                    .help(recordTitle(for: note))
                Spacer()
                Text(L("第 \(note.pageLabel) 页", "Page \(note.pageLabel)")).font(InspectorText.detail).foregroundStyle(.secondary)
            }
            LatexText(source: note.content, bodyFont: InspectorText.bodyNSFont, maxLines: 3,
                      allowsSelection: false)
                .foregroundStyle(.primary)
            let ids = (try? model.store.noteContextIDs(noteID: note.id)) ?? []
            if !ids.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if let context = try? model.store.context(id: id) {
                            Button(L("出处 \(index + 1) · PDF 第 \(context.pageIndex + 1) 页", "Citation \(index + 1) · PDF page \(context.pageIndex + 1)")) {
                                model.showSelection(context)
                            }
                            .buttonStyle(.link)
                            .font(InspectorText.detail)
                        }
                    }
                }
            }
        }
    }

    private func extractiveNoteRow(_ note: ReadingNote, sources: [ExtractiveSource]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(note.status == "draft" ? L("原文摘录草稿") : L("原文摘录"), systemImage: "text.quote")
                    .font(InspectorText.section)
                    .foregroundStyle(recordColor(for: note))
                Spacer()
                Button {
                    copySources(sources)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L("复制摘录"))
                Button(role: .destructive) {
                    model.deleteNote(note)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("删除摘录"))
            }
            Text(originTitle(for: note))
                .font(InspectorText.detail)
                .foregroundStyle(recordColor(for: note))
                .lineLimit(1)
            if let coverage = try? model.store.extractiveCoverage(noteID: note.id) {
                Text(L("可核对原文 \(coverage.textPageIndices.count) 页 · 无可提取原文 \(coverage.unavailablePageIndices.count) 页", "\(coverage.textPageIndices.count) pages verifiable · \(coverage.unavailablePageIndices.count) pages without extractable text"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }
            ForEach(sources, id: \.id) { source in
                VStack(alignment: .leading, spacing: 3) {
                    Button(L("PDF 第 \(source.pageIndex + 1) 页", "PDF page \(source.pageIndex + 1)")) {
                        model.navigate(to: source)
                    }
                    .buttonStyle(.link)
                    .font(InspectorText.detail)
                    Text(source.text)
                        .font(InspectorText.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("复制摘录")) { copySources(sources) }
            Button(L("删除摘录"), role: .destructive) { model.deleteNote(note) }
        }
    }

    @ViewBuilder
    private func extractiveEditor(_ note: ReadingNote, sources: [ExtractiveSource]) -> some View {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let orderedSources = form.excerptOrder.compactMap { sourceByID[$0] }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(note.status == "draft" ? L("审核原文摘录") : L("原文摘录"), systemImage: "text.quote")
                    .font(InspectorText.title)
                    .foregroundStyle(ReaderPalette.action)
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    if model.deleteNote(note) { clearEditor() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("删除原文摘录"))
                closeDraftEditor
            }

            Text(L("只保留 PDF 中可以逐字核对的句子；勾选或调整顺序不会改写原文。"))
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(orderedSources.enumerated()), id: \.element.id) { index, source in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                if form.excerptIncluded.contains(source.id) {
                                    form.excerptIncluded.remove(source.id)
                                } else {
                                    form.excerptIncluded.insert(source.id)
                                }
                            } label: {
                                Image(systemName: form.excerptIncluded.contains(source.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(form.excerptIncluded.contains(source.id) ? ReaderPalette.action : .secondary)
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 3) {
                                Button(L("PDF 第 \(source.pageIndex + 1) 页", "PDF page \(source.pageIndex + 1)")) {
                                    model.navigate(to: source)
                                }
                                .buttonStyle(.link)
                                .font(InspectorText.detail)
                                Text(source.text)
                                    .font(InspectorText.body)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 2)
                            VStack(spacing: 2) {
                                Button {
                                    moveExcerpt(source.id, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    moveExcerpt(source.id, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == orderedSources.count - 1)
                            }
                        }
                        .padding(7)
                        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(ReaderPalette.divider, lineWidth: 0.5)
                        }
                    }
                }
            }
            .frame(maxHeight: 190)

            HStack(spacing: 8) {
                Button(L("保存排序")) {
                    _ = model.reviewExtractiveDraft(note, sourceIDs: orderedSourceIDs, confirm: false)
                }
                .buttonStyle(.bordered)
                .disabled(note.status != "draft" || orderedSourceIDs.isEmpty)
                Button(L("确认原文摘录")) {
                    if model.reviewExtractiveDraft(note, sourceIDs: orderedSourceIDs, confirm: true) { clearEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(note.status != "draft" || orderedSourceIDs.isEmpty)
            }

            Divider()
            Text(L("需要解释或改写时，另存为普通笔记；原文摘录草稿会保留。"))
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)
            TextEditor(text: $form.excerptRewriteText)
                .font(InspectorText.editable)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 120)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ReaderPalette.divider, lineWidth: 0.5)
                }
            HStack {
                Spacer(minLength: 0)
                Button(L("另存为普通笔记")) {
                    if model.saveExcerptAsNote(note, content: form.excerptRewriteText) {
                        form.excerptRewriteText = form.excerptRewriteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(form.excerptRewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var orderedSourceIDs: [String] {
        form.excerptOrder.filter { form.excerptIncluded.contains($0) }
    }

    private func moveExcerpt(_ id: String, offset: Int) {
        guard let index = form.excerptOrder.firstIndex(of: id) else { return }
        let target = index + offset
        guard form.excerptOrder.indices.contains(target) else { return }
        form.excerptOrder.swapAt(index, target)
    }

    private func loadExcerptEditor() {
        guard let note = selectedExtractiveNote else {
            form.excerptNoteID = nil
            form.excerptOrder = []
            form.excerptIncluded = []
            form.excerptRewriteText = ""
            return
        }
        let sources = summarySourcesByNoteID[note.id] ?? []
        let ids = sources.map(\.id)
        // Preserve a user's temporary order while editing. If the selected
        // note changes or the stored sources change, rebuild from the source
        // order supplied by the database.
        if form.excerptNoteID != note.id {
            form.excerptNoteID = note.id
            form.excerptOrder = ids
            form.excerptIncluded = Set(ids)
            form.excerptRewriteText = sources.map(\.text).joined(separator: "\n\n")
        } else if Set(form.excerptOrder) != Set(ids) {
            form.excerptOrder = ids
            form.excerptIncluded = Set(ids)
        }
    }

    private func openNote(_ note: ReadingNote) {
        editingNoteID = note.id
        noteDraft = note.content
        let ids = (try? model.store.noteContextIDs(noteID: note.id)) ?? []
        let snapshot = (ids.first.flatMap { try? model.store.context(id: $0) }) ?? note.contextID.flatMap { try? model.store.context(id: $0) }
        model.navigate(pageIndex: note.pageIndex, regions: snapshot?.regions ?? [])
    }

    private func copySources(_ sources: [ExtractiveSource]) {
        let text = sources.map { L("[PDF 第 \($0.pageIndex + 1) 页]\n\($0.text)", "[PDF page \($0.pageIndex + 1)]\n\($0.text)") }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.statusMessage = L("原文摘录已复制。")
    }
}

private struct ReadingFeedbackCounts {
    var unclear = 0
    var repeatedQuestion = 0
    var followUp = 0

    var total: Int { unclear + repeatedQuestion + followUp }
}

private struct ReadingFeedbackSummary: View {
    let counts: ReadingFeedbackCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(ReaderPalette.action)
                Text(L("阅读反馈", "Reading feedback"))
                    .font(InspectorText.section)
                Spacer(minLength: 0)
                Text(L("共 \(counts.total) 条", "\(counts.total) total"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                countChip(label: L("不清楚", "Unclear"), count: counts.unclear, color: ReaderPalette.action)
                countChip(label: L("重复问题", "Repeated"), count: counts.repeatedQuestion, color: ReaderPalette.focusManual)
                countChip(label: L("普通追问", "Follow-up"), count: counts.followUp, color: .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func countChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
            Text("\(count)")
                .font(InspectorText.detailStrong)
        }
        .font(InspectorText.detail)
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("\(label) \(count) 条", "\(label): \(count)"))
    }
}

private final class ReferenceSelectionState: ObservableObject {
    @Published var referenceID: String?
}

private struct DiscussionTurn: View {
    let message: PaperChatMessage
    let conversationID: String
    @ObservedObject var model: AppModel
    @Binding var expandedMessageIDs: Set<String>
    @StateObject private var referenceSelection = ReferenceSelectionState()

    private var isAnswer: Bool { message.role == .assistant }
    private var citations: [MessageCitation] { message.citations ?? [] }
    private var citationMap: [String: String] {
        Dictionary(uniqueKeysWithValues: citations.map { ($0.label, $0.contextID) })
    }
    private var isLong: Bool {
        message.text.count > 900 || message.text.components(separatedBy: "\n\n").count > 6
    }
    private var isExpanded: Bool { expandedMessageIDs.contains(message.id) }
    private var isActiveAnswer: Bool {
        isAnswer && model.activeCitationMessageID == message.id
    }
    private var contextIDs: [String] {
        if let ids = message.sourceContextIDs, !ids.isEmpty { return ids }
        if let id = message.contextID { return [id] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            if !isAnswer && !contextIDs.isEmpty {
                sourceChips
            }
            if !isAnswer, message.readingFeedback != nil {
                feedbackChip
            }
            if isAnswer && !citations.isEmpty {
                citationChips
            }
            if isAnswer, let warnings = message.citationWarnings, !warnings.isEmpty {
                citationWarning(warnings)
            }
            if isAnswer || isLong {
                expansionControl
            }
        }
        .padding(8)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if isAnswer {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isActiveAnswer ? ReaderPalette.citation : ReaderPalette.divider.opacity(0.55),
                            lineWidth: isActiveAnswer ? 2 : 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            if isAnswer { activateAnswer() }
        }
        .popover(isPresented: Binding(
            get: { referenceSelection.referenceID != nil },
            set: { if !$0 { referenceSelection.referenceID = nil } }
        ), arrowEdge: .bottom) {
            if let referenceID = referenceSelection.referenceID {
                ReferenceCard(model: model, referenceID: referenceID,
                              archivedReference: message.referencedWorks?.first { $0.referenceID == referenceID })
            }
        }
    }

    private var cardBackground: Color {
        guard isAnswer else { return ReaderPalette.softAction }
        return isActiveAnswer ? ReaderPalette.citation.opacity(0.07) : .clear
    }

    private func toggleExpansion() {
        if isExpanded {
            expandedMessageIDs.remove(message.id)
        } else {
            expandedMessageIDs.insert(message.id)
        }
    }

    private func activateAnswer() {
        guard isAnswer else { return }
        model.activeReadingConversationID = conversationID
        model.activateCitations(for: message)
    }

    private var expansionControl: some View {
        Button {
            toggleExpansion()
        } label: {
            HStack(spacing: 3) {
                Text(isExpanded ? L("收起") : L("展开全文"))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(InspectorText.detail)
            .foregroundStyle(ReaderPalette.action)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? L("收起这条对话") : L("展开这条对话的全文"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(isAnswer ? L("答") : L("问"))
                .font(InspectorText.badge)
                .foregroundStyle(isAnswer ? Color.white : Color.secondary)
                .frame(width: 18, height: 18)
                .background(isAnswer ? ReaderPalette.citation : ReaderPalette.divider.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(isAnswer ? L("回答") : L("问题"))
            Text(Self.timeFormatter.string(from: message.createdAt))
                .font(InspectorText.detail)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if message.manuallyRecorded == true && isAnswer {
                Button {
                    model.setManualDiscussionSharing(discussionID: message.id, shared: !(message.sharedWithAI ?? false))
                } label: {
                    Label(message.sharedWithAI == true ? L("已共享") : L("仅本机"),
                          systemImage: message.sharedWithAI == true ? "person.2.fill" : "lock.fill")
                        .font(InspectorText.detail)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(message.sharedWithAI == true ? ReaderPalette.action : .secondary)
                .help(message.sharedWithAI == true ? L("点击后停止向 AI 客户端提供这条问答") : L("点击后允许 AI 客户端检索这条问答"))
            }
            if isActiveAnswer {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ReaderPalette.citation)
                    .help(L("正文中正在显示这条回答的引用"))
                    .accessibilityLabel(L("正在浏览这条回答的引用"))
            }
        }
    }

    private var content: some View {
        LatexText(source: message.text, bodyFont: InspectorText.bodyNSFont,
                  citationContextIDs: citationMap, citationColor: ReaderPalette.citation,
                  references: isAnswer ? model.references : [],
                  referencedWorks: isAnswer ? message.referencedWorks : nil,
                  showsReferenceLinks: isAnswer,
                  heightLimit: !isExpanded && (isAnswer || isLong) ? 110 : nil,
                  onTap: isAnswer ? { activateAnswer() } : nil,
                  onReference: { referenceSelection.referenceID = $0 })
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "paperdesk-citation" else { return .systemAction }
                let contextID = url.host ?? url.path.replacingOccurrences(of: "/", with: "")
                guard !contextID.isEmpty, let context = try? model.store.context(id: contextID) else { return .handled }
                activateAnswer()
                model.showSelection(context)
                return .handled
            })
            .frame(maxHeight: !isExpanded && (isAnswer || isLong) ? 110 : nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if !isExpanded && isLong {
                    LinearGradient(colors: [ReaderPalette.surface.opacity(0), ReaderPalette.surface],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 34)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                Button(L("复制原始文本")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
                if isAnswer {
                    Button(L("复制回答和出处", "Copy answer with sources")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answerWithSources, forType: .string)
                    }
                }
            }
            .padding(.leading, isAnswer ? 8 : 2)
            .contentShape(Rectangle())

    }

    private var sourceChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 5) {
            ForEach(contextIDs, id: \.self) { id in
                if let context = try? model.store.context(id: id) {
                    Button {
                        model.activeReadingConversationID = conversationID
                        model.showSelection(context)
                    } label: {
                        Text(L("\(sourceLabel(for: id))第 \(context.pageIndex + 1) 页", "\(sourceLabel(for: id))page \(context.pageIndex + 1)"))
                            .font(InspectorText.detail)
                            .foregroundStyle(ReaderPalette.focusManual)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(ReaderPalette.focusManual.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L("回到这处选区"))
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private var feedbackChip: some View {
        if let display = feedbackDisplay {
            HStack(spacing: 4) {
                Image(systemName: display.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(display.label)
                    .lineLimit(1)
                if let answerMode = display.answerMode {
                    Text("·")
                        .foregroundStyle(display.color.opacity(0.65))
                    Text(answerMode)
                        .lineLimit(1)
                }
            }
            .font(InspectorText.detail)
            .foregroundStyle(display.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(display.color.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().stroke(display.color.opacity(0.24), lineWidth: 0.5)
            }
            .help(display.helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("阅读反馈：\(display.label)", "Reading feedback: \(display.label)"))
            .accessibilityHint(display.helpText)
            .padding(.leading, 2)
        }
    }

    private var feedbackDisplay: (label: String, color: Color, icon: String, answerMode: String?, helpText: String)? {
        guard let feedback = message.readingFeedback else { return nil }
        let presentation: (label: String, color: Color, icon: String)
        switch feedback.kind {
        case .unclear:
            presentation = (L("不清楚", "Unclear"), ReaderPalette.action, "questionmark")
        case .repeatedQuestion:
            presentation = (L("重复问题", "Repeated"), ReaderPalette.focusManual, "arrow.triangle.2.circlepath")
        case .followUp:
            presentation = (L("普通追问", "Follow-up"), .secondary, "arrow.turn.down.right")
        }
        let answerMode = answerModeLabel(for: feedback.answerID)
        let evidence = feedback.evidence
        var helpText = evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? presentation.label : evidence
        if let answerMode {
            helpText += " · " + L("对应回答：\(answerMode)", "Answer: \(answerMode)")
        }
        return (presentation.label, presentation.color, presentation.icon, answerMode, helpText)
    }

    private func answerModeLabel(for answerID: String) -> String? {
        guard let answer = model.discussion.first(where: { $0.id == answerID && $0.role == .assistant }),
              let mode = answer.answerMode else { return nil }
        switch mode {
        case .direct:
            return L("直答", "Direct")
        case .selfReview:
            return L("自检", "Self-review")
        case .independentReview:
            return L("独立复核", "Independent review")
        }
    }

    private var citationChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("出处"))
                .font(InspectorText.detail)
                .foregroundStyle(.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 5) {
                ForEach(citations) { citation in
                    Button {
                        jump(to: citation)
                    } label: {
                        HStack(spacing: 3) {
                            Text(citation.label)
                                .font(InspectorText.detailStrong)
                            Text(pageText(for: citation))
                                .lineLimit(1)
                        }
                        .font(InspectorText.detail)
                        .foregroundStyle(ReaderPalette.citation)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ReaderPalette.citation.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().stroke(ReaderPalette.citation.opacity(0.35), lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(citationHelp(citation))
                }
            }
        }
        .padding(.leading, 8)
    }

    private func citationWarning(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("引用需要核对", "Citations need review"), systemImage: "exclamationmark.bubble")
                .font(InspectorText.detailStrong)
                .foregroundStyle(ReaderPalette.focusManual)
            ForEach(Array(warnings.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private var answerWithSources: String {
        var sections = [message.text]
        let sourceLines = citations.compactMap { citation -> String? in
            guard let context = try? model.store.context(id: citation.contextID) else { return nil }
            let quote = context.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = L("第 \(context.pageLabel) 页", "page \(context.pageLabel)")
            return quote.isEmpty ? "⟦\(citation.label)⟧ · \(location)" : "⟦\(citation.label)⟧ · \(location)\n> \(quote)"
        }
        if !sourceLines.isEmpty {
            sections.append(L("原文出处\n" + sourceLines.joined(separator: "\n\n"),
                              "PDF sources\n" + sourceLines.joined(separator: "\n\n")))
        }
        if let works = message.referencedWorks, !works.isEmpty {
            let lines = works.map { work in
                let authors = work.authors ?? L("作者未识别", "Author not recognized")
                let title = work.title ?? L("标题未识别", "Title not recognized")
                let year = work.year.map(String.init) ?? ""
                return "[\(work.label)] \(authors). \(title). \(year)."
            }
            sections.append(L("参考文献\n" + lines.joined(separator: "\n"),
                              "Bibliography\n" + lines.joined(separator: "\n")))
        }
        return sections.joined(separator: "\n\n")
    }

    private func jump(to citation: MessageCitation) {
        guard let context = try? model.store.context(id: citation.contextID) else { return }
        activateAnswer()
        model.showSelection(context)
    }

    private func pageText(for citation: MessageCitation) -> String {
        let label = citation.pageLabel ?? "?"
        return label.allSatisfy(\.isNumber) ? L("第 \(label) 页", "page \(label)") : label
    }

    private func citationHelp(_ citation: MessageCitation) -> String {
        guard let context = try? model.store.context(id: citation.contextID) else { return L("第 \(citation.label) 处出处", "Citation \(citation.label)") }
        let quote = context.sourceText.replacingOccurrences(of: "\n", with: " ")
        return quote.isEmpty ? L("第 \(citation.label) 处出处", "Citation \(citation.label)") : quote
    }

    private func sourceLabel(for id: String) -> String {
        guard let snapshotID = message.readingSnapshotID,
              let snapshot = try? model.store.readingSnapshot(id: snapshotID),
              let source = snapshot.state.selections.first(where: { $0.id == id }) else { return "" }
        return "\(source.label) · "
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct StatusBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if let selectedPaper = model.selectedPaper {
                Text(L("第 \(model.currentPageIndex + 1) / \(selectedPaper.pageCount) 页", "Page \(model.currentPageIndex + 1) of \(selectedPaper.pageCount)"))
            }
            if !model.referenceIndexingPaperIDs.isEmpty {
                Text(L("正在整理参考文献…", "Indexing references…"))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(error)
            } else if let message = model.statusMessage {
                Text(message).lineLimit(1)
            }
        }
        .font(InspectorText.detail)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ReaderPalette.toolbar)
    }
}
