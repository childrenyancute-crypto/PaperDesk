import SwiftUI
import PaperDeskCore

private final class FloatingQuestionButtonState: ObservableObject {
    @Published var isPresented = false
    @Published var targets: PaperQuestionTargets?
    @Published var targetError: String?
    @Published var bubbleOffset = CGSize.zero
    @Published var bubbleDragStart: CGSize?
    // A native Button should win a click, while a drag that starts on the
    // same bubble must not trigger that Button when the pointer is released.
    var bubbleDidMove = false
    @Published var panelCenter: CGPoint?
    @Published var panelDragStart: CGPoint?
    @Published var panelSize = CGSize.zero
    @Published var panelContentHeight: CGFloat = 0
}

private struct FloatingPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct FloatingQuestionContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private final class FloatingQuestionPopoverState: ObservableObject {
    @Published var draft = ""
    @Published var selectedTargetID = ""
    @Published var externalSessionID = ""
    @Published var localError: String?
}

/// Shared progress row used by the floating composer and the Reading panel.
/// The process owns the stage and detail text, so every harness gets the same
/// presentation as soon as it reports progress through PaperQuestions.
struct PaperQuestionProgressStatus: View {
    let progress: PaperQuestionProgress
    var compact = false
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 7 : 9) {
            ProgressView()
                .controlSize(compact ? .mini : .small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title)
                    .font(compact ? InspectorText.detailStrong : InspectorText.labelStrong)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = progress.detail, !detail.isEmpty {
                    Text(detail)
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Text(L("本阶段已用时", "Time in this stage"))
                    Text(progress.startedAt, style: .timer)
                        .monospacedDigit()
                }
                .font(InspectorText.detail)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button(L("停止等待", "Stop waiting"), action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("停止后会保留草稿。", "Stopping keeps your draft."))
        }
        .padding(compact ? 7 : 9)
        .background(ReaderPalette.softAction, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }
}

struct FloatingQuestionButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var questions: PaperQuestions
    let onOpenHistory: () -> Void

    @StateObject private var form = FloatingQuestionButtonState()

    private static let dragCoordinateSpace = "paperdesk-floating-question"

    private var paperID: String? { model.selectedPaper?.id }
    private var isRunning: Bool {
        guard let paperID else { return false }
        return questions.runningPaperIDs.contains(paperID)
    }
    private var completedConversationID: String? {
        guard let paperID else { return nil }
        return questions.completedConversationIDs[paperID]
    }

    private let askDiameter: CGFloat = 38
    private let doneDiameter: CGFloat = 34
    private let controlSpacing: CGFloat = 6
    private let edgeInset: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if form.isPresented {
                    floatingPanel(bounds: geometry.size)
                }
                floatingControls(bounds: geometry.size)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.dragCoordinateSpace)
        }
        .onChange(of: model.selectedPaper?.id) { _, _ in
            form.isPresented = false
            form.targets = nil
            form.targetError = nil
            form.panelCenter = nil
            form.panelDragStart = nil
            form.panelSize = .zero
            form.panelContentHeight = 0
        }
        .onChange(of: connectionSignature) { _, _ in refreshTargetsIfPresented() }
        .onChange(of: detectedProcessSignature) { _, _ in refreshTargetsIfPresented() }
        .onChange(of: model.activeReadingConversationID) { _, _ in refreshTargetsIfPresented() }
        .onChange(of: model.discussion.count) { _, _ in refreshTargetsIfPresented() }
    }

    @ViewBuilder
    private var askButton: some View {
        Button {
            performBubbleAction { toggleComposer() }
        } label: {
            Image(systemName: isRunning ? "hourglass" : "text.bubble")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.pulse, isActive: isRunning)
                .foregroundStyle(ReaderPalette.action)
                .frame(width: askDiameter, height: askDiameter)
                .background(ReaderPalette.surface, in: Circle())
                .overlay { Circle().stroke(ReaderPalette.action.opacity(0.32), lineWidth: 0.8) }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("询问当前文献"))
        .accessibilityLabel(L("询问当前文献"))
    }

    @ViewBuilder
    private var completedButton: some View {
        if let completedConversationID {
            Button {
                performBubbleAction {
                    model.activeReadingConversationID = completedConversationID
                    if let paperID { questions.acknowledge(paperID: paperID) }
                    onOpenHistory()
                }
            } label: {
                Image(systemName: "checkmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ReaderPalette.ready)
                    .frame(width: doneDiameter, height: doneDiameter)
                    .background(ReaderPalette.surface, in: Circle())
                    .overlay { Circle().stroke(ReaderPalette.ready.opacity(0.35), lineWidth: 0.8) }
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("打开刚完成的阅读问答"))
            .accessibilityLabel(L("打开刚完成的阅读问答"))
        }
    }

    private func floatingControls(bounds: CGSize) -> some View {
        let groupSize = controlsSize
        return HStack(spacing: controlSpacing) {
            completedButton
            askButton
        }
        // Buttons keep their native click behavior; the simultaneous drag
        // only takes over once the pointer has moved beyond the drag threshold.
        .simultaneousGesture(bubbleDragGesture(bounds: bounds, groupSize: groupSize))
        .position(bubbleCenter(bounds: bounds, groupSize: groupSize))
    }

    private var controlsSize: CGSize {
        CGSize(width: askDiameter + (completedConversationID == nil ? 0 : controlSpacing + doneDiameter),
               height: askDiameter)
    }

    private func floatingPanel(bounds: CGSize) -> some View {
        let width = min(440, max(300, bounds.width - 24))
        // Keep the drag handle inside the panel's available-height budget.
        // The ScrollView remains compact when its content fits, but can scroll
        // when the window is too short for the complete composer.
        let handleHeight: CGFloat = 28
        let maxContentHeight = max(1, bounds.height - 16 - handleHeight)
        let measuredContentHeight = form.panelContentHeight > 0 ? form.panelContentHeight : 340
        let contentHeight = min(maxContentHeight, measuredContentHeight)
        return VStack(spacing: 0) {
            panelDragHandle(bounds: bounds, width: width)
            ScrollView(.vertical) {
                FloatingQuestionPopover(
                    model: model,
                    questions: questions,
                    isPresented: $form.isPresented,
                    draftPaperID: paperID,
                    targets: form.targets,
                    targetError: form.targetError,
                    onRefreshTargets: refreshTargets
                )
            }
            .frame(height: max(1, contentHeight))
            .onPreferenceChange(FloatingQuestionContentHeightKey.self) { height in
                guard height.isFinite, height > 0,
                      abs(height - form.panelContentHeight) > 0.5 else { return }
                form.panelContentHeight = height
            }
        }
        .frame(width: width)
        .background(ReaderPalette.inspector)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(ReaderPalette.divider, lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FloatingPanelSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(FloatingPanelSizeKey.self) { size in
            guard size != form.panelSize else { return }
            form.panelSize = size
        }
        .position(panelCenter(bounds: bounds, width: width))
    }

    private var connectionSignature: [String] {
        model.mcpConnections.values.map {
            "\($0.id)|\($0.paperID)|\($0.documentHash ?? "")|\($0.clientID ?? "")|\($0.clientName)|\($0.clientVersion ?? "")|\($0.processID.map { String($0) } ?? "")"
        }.sorted()
    }

    private var detectedProcessSignature: [String] {
        model.detectedMCPProcesses.map {
            "\($0.pid)|\($0.paperID)|\($0.documentHash ?? "")|\($0.clientID ?? "")|\($0.clientName ?? "")"
        }.sorted()
    }

    private func panelDragHandle(bounds: CGSize, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(ReaderPalette.divider)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
            Button {
                form.isPresented = false
                form.panelCenter = nil
                form.panelSize = .zero
                form.panelContentHeight = 0
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("关闭"))
            .accessibilityLabel(L("关闭"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .gesture(panelDragGesture(bounds: bounds, width: width))
        .frame(height: 28)
    }

    private func toggleComposer() {
        if form.isPresented {
            form.isPresented = false
            form.panelCenter = nil
            form.panelSize = .zero
            form.panelContentHeight = 0
            return
        }
        form.targetError = nil
        refreshTargets()
        form.panelCenter = nil
        form.panelSize = .zero
        form.panelContentHeight = 0
        form.isPresented = true
    }

    private func performBubbleAction(_ action: () -> Void) {
        guard !form.bubbleDidMove else {
            // A drag can share the same hit region as a Button. Consume the
            // release after a drag, then let the next click activate normally.
            form.bubbleDidMove = false
            return
        }
        action()
    }

    private func refreshTargets() {
        model.refreshMCPConnectionState()
        do {
            form.targets = try model.questionTargets()
            form.targetError = nil
        } catch {
            form.targets = nil
            form.targetError = error.localizedDescription
        }
    }

    private func refreshTargetsIfPresented() {
        guard form.isPresented else { return }
        refreshTargets()
    }

    private func bubbleBaseCenter(bounds: CGSize, groupSize: CGSize) -> CGPoint {
        CGPoint(x: bounds.width - edgeInset - groupSize.width / 2,
                y: bounds.height - edgeInset - groupSize.height / 2)
    }

    private func bubbleCenter(bounds: CGSize, groupSize: CGSize) -> CGPoint {
        let base = bubbleBaseCenter(bounds: bounds, groupSize: groupSize)
        let proposed = CGPoint(x: base.x + form.bubbleOffset.width,
                               y: base.y + form.bubbleOffset.height)
        return clampedCenter(proposed, size: groupSize, bounds: bounds)
    }

    private func clampedBubbleOffset(_ offset: CGSize, bounds: CGSize, groupSize: CGSize) -> CGSize {
        let base = bubbleBaseCenter(bounds: bounds, groupSize: groupSize)
        let center = clampedCenter(CGPoint(x: base.x + offset.width, y: base.y + offset.height),
                                   size: groupSize, bounds: bounds)
        return CGSize(width: center.x - base.x, height: center.y - base.y)
    }

    private func bubbleDragGesture(bounds: CGSize, groupSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                if form.bubbleDragStart == nil {
                    form.bubbleDragStart = form.bubbleOffset
                }
                form.bubbleDidMove = true
                let start = form.bubbleDragStart ?? .zero
                form.bubbleOffset = clampedBubbleOffset(
                    CGSize(width: start.width + value.translation.width,
                           height: start.height + value.translation.height),
                    bounds: bounds, groupSize: groupSize
                )
            }
            .onEnded { _ in
                form.bubbleDragStart = nil
                if form.bubbleDidMove {
                    // Leave the suppression flag set through the current
                    // gesture's Button release, then clear it before the next
                    // user interaction.
                    DispatchQueue.main.async {
                        form.bubbleDidMove = false
                    }
                }
            }
    }

    private func defaultPanelCenter(bounds: CGSize, width: CGFloat) -> CGPoint {
        let fallbackHeight = min(420, max(180, bounds.height - 16))
        let size = form.panelSize == .zero ? CGSize(width: width, height: fallbackHeight) : form.panelSize
        let groupSize = controlsSize
        let bubble = bubbleCenter(bounds: bounds, groupSize: groupSize)
        let minX = size.width / 2 + 10
        let maxX = bounds.width - size.width / 2 - 10
        let x = max(minX, min(maxX, bubble.x + groupSize.width / 2 - size.width / 2))
        let above = bubble.y - groupSize.height / 2 - 10 - size.height / 2
        let below = bubble.y + groupSize.height / 2 + 10 + size.height / 2
        let preferredY = above - size.height / 2 >= 10 ? above : below
        let minY = size.height / 2 + 10
        let maxY = bounds.height - size.height / 2 - 10
        let y = max(minY, min(maxY, preferredY))
        return CGPoint(x: x, y: y)
    }

    private func panelCenter(bounds: CGSize, width: CGFloat) -> CGPoint {
        let fallbackHeight = min(420, max(180, bounds.height - 16))
        let size = form.panelSize == .zero ? CGSize(width: width, height: fallbackHeight) : form.panelSize
        let proposed = form.panelCenter ?? defaultPanelCenter(bounds: bounds, width: width)
        return clampedCenter(proposed, size: size, bounds: bounds)
    }

    private func clampedCenter(_ point: CGPoint, size: CGSize, bounds: CGSize) -> CGPoint {
        let minX = size.width / 2 + 8
        let maxX = bounds.width - size.width / 2 - 8
        let minY = size.height / 2 + 8
        let maxY = bounds.height - size.height / 2 - 8
        let x = max(minX, min(max(minX, maxX), point.x))
        let y = max(minY, min(max(minY, maxY), point.y))
        return CGPoint(x: x, y: y)
    }

    private func panelDragGesture(bounds: CGSize, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                let size = form.panelSize
                guard size != .zero else { return }
                if form.panelDragStart == nil {
                    form.panelDragStart = form.panelCenter ?? defaultPanelCenter(bounds: bounds, width: width)
                }
                guard let start = form.panelDragStart else { return }
                let proposed = CGPoint(x: start.x + value.translation.width,
                                       y: start.y + value.translation.height)
                form.panelCenter = clampedCenter(proposed, size: size, bounds: bounds)
            }
            .onEnded { _ in form.panelDragStart = nil }
    }
}

private struct FloatingQuestionPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject var questions: PaperQuestions
    @Binding var isPresented: Bool
    let draftPaperID: String?
    let targets: PaperQuestionTargets?
    let targetError: String?
    let onRefreshTargets: () -> Void

    @StateObject private var form = FloatingQuestionPopoverState()

    private var draft: String { form.draft }
    private var externalSessionID: String { form.externalSessionID }
    private var storedDraft: String {
        guard let paperID = draftPaperID else { return "" }
        return questions.drafts[paperID] ?? ""
    }

    private var choices: [PaperQuestionTarget] { targets?.choices ?? [] }
    private var activeTarget: PaperQuestionTarget? { targets?.active }
    private var hasProject: Bool { targets?.hasProject ?? (model.codexProjectURL != nil) }
    private var connectedNames: [String] {
        var seen = Set<String>()
        return (targets?.connectedClients ?? []).compactMap { connection in
            let name = connection.displayName
            return seen.insert(name).inserted ? name : nil
        }
    }
    private var requiresExplicitTargetSelection: Bool {
        if activeTarget != nil {
            return !(targets?.activeUnavailableReason?.isEmpty ?? true)
        }
        return choices.count > 1 || !(targets?.activeUnavailableReason?.isEmpty ?? true)
    }
    private var selectedTarget: PaperQuestionTarget? {
        if let target = choices.first(where: { $0.id == form.selectedTargetID }) {
            return target
        }
        if !requiresExplicitTargetSelection, let activeTarget { return activeTarget }
        if !requiresExplicitTargetSelection { return choices.first }
        return nil
    }
    private var selectedNeedsSessionBinding: Bool {
        guard let selectedTarget else { return false }
        return selectedTarget.needsManualSessionBinding
    }
    private var canSend: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedTarget != nil,
              !(model.selectedPaper.map { questions.runningPaperIDs.contains($0.id) } ?? true) else { return false }
        if selectedNeedsSessionBinding {
            return !externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            recipient
            if let draftPaperID, let progress = questions.progressByPaperID[draftPaperID] {
                PaperQuestionProgressStatus(progress: progress, compact: true) {
                    questions.cancel(paperID: draftPaperID)
                }
            }
            selectionChips
            editor
            footer
        }
        .padding(16)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FloatingQuestionContentHeightKey.self, value: proxy.size.height)
            }
        }
        .background(ReaderPalette.inspector)
        .onAppear { loadDraftAndSelection() }
        .onChange(of: draft) { _, value in
            guard let paperID = draftPaperID else { return }
            questions.drafts[paperID] = value
        }
        .onChange(of: storedDraft) { previous, current in
            let sentDraft = previous.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty, !sentDraft.isEmpty,
                  draft.trimmingCharacters(in: .whitespacesAndNewlines) == sentDraft else { return }
            form.draft = ""
        }
        .onChange(of: form.selectedTargetID) { _, _ in
            // A session ID belongs to one target. Never carry a pasted ID to
            // another conversation after the user changes the destination.
            form.externalSessionID = ""
        }
        .onChange(of: choices.map(\.id)) { _, _ in
            synchronizeTargetSelection()
        }
    }

    @ViewBuilder
    private var recipient: some View {
        if choices.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if !hasProject {
                    Label(L("还没有可用的外部对话"), systemImage: "link.badge.plus")
                        .font(InspectorText.label)
                    Text(L("可以先为这篇文献准备一个项目，再从 Codex、OpenCode 或其他 MCP 客户端发起对话。"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("准备文献项目")) {
                        do {
                            try model.prepareQuestionProject()
                            onRefreshTargets()
                        } catch {
                            form.localError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if connectedNames.isEmpty {
                    Label(L("没有已连接的客户端"), systemImage: "link.badge.plus")
                        .font(InspectorText.label)
                    Text(L("请在 Codex、OpenCode 或其他 MCP 客户端中打开这篇文献的项目，连接后再提问。"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(L("已连接客户端暂时无法发送提问"), systemImage: "exclamationmark.triangle")
                        .font(InspectorText.label)
                    Text(L("已连接：\(connectedNames.joined(separator: "、"))。请确认对应的命令行程序已安装并可用。", "Connected: \(connectedNames.joined(separator: ", ")). Make sure the corresponding command-line client is installed and available."))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .background(ReaderPalette.softAction, in: RoundedRectangle(cornerRadius: 7))
        } else if choices.count > 1 || requiresExplicitTargetSelection {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("发送到"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                Picker(L("发送到"), selection: $form.selectedTargetID) {
                    Text(L("选择发送目标")).tag("")
                    ForEach(choices) { target in
                        Text(targetLabel(target)).tag(target.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let activeTarget {
            recipientRow(activeTarget, detail: L("活跃对话"))
        } else if let target = choices.first {
            recipientRow(target, detail: L("新对话"))
        }

        if let activeUnavailableReason = targets?.activeUnavailableReason,
           !activeUnavailableReason.isEmpty {
            Label(activeUnavailableReason, systemImage: "exclamationmark.triangle")
                .font(InspectorText.detail)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if selectedNeedsSessionBinding {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("粘贴这个对话的外部会话 ID"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                TextField("External session ID", text: $form.externalSessionID)
                    .textFieldStyle(.roundedBorder)
                    .font(InspectorText.label)
                Text(L("这是尚未关联外部会话的旧记录。请从对应的 \(selectedTarget?.displayName ?? "客户端") 对话中复制会话 ID。绑定后，之后可直接续问。", "This is an older record with no linked external conversation. Copy the session ID from the corresponding \(selectedTarget?.displayName ?? "client") conversation. Once linked, you can follow up directly."))
                    .font(InspectorText.detail)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recipientRow(_ target: PaperQuestionTarget, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: target.iconName)
                .foregroundStyle(ReaderPalette.action)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(target.title))
                    .font(InspectorText.labelStrong)
                    .lineLimit(1)
                Text(detail)
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(target.displayName)
                .font(InspectorText.detail)
                .foregroundStyle(ReaderPalette.action)
        }
        .padding(9)
        .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(ReaderPalette.divider, lineWidth: 0.5) }
    }

    @ViewBuilder
    private var selectionChips: some View {
        if !model.activeSelections.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("随问题附带的阅读焦点"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(model.activeSelections) { selection in
                            Text(L("\(selection.label) · 第 \(selection.context.pageIndex + 1) 页", "\(selection.label) · page \(selection.context.pageIndex + 1)"))
                                .font(InspectorText.detail)
                                .foregroundStyle(selection.isAI ? ReaderPalette.focusAI : ReaderPalette.focusManual)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background((selection.isAI ? ReaderPalette.focusAI : ReaderPalette.focusManual).opacity(0.11), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $form.draft)
                .font(InspectorText.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 200)
                .background(ReaderPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(ReaderPalette.divider, lineWidth: 0.5)
                }
            if draft.isEmpty {
                Text(L("问问这篇文献……"))
                    .font(InspectorText.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = form.localError ?? targetError ?? paperError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(L("⌘↩ 发送"))
                    .font(InspectorText.detail)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if model.activeReadingConversationID != nil {
                    Button(L("结束续问")) { endContinuation() }
                        .buttonStyle(.borderless)
                        .font(InspectorText.detail)
                        .help(L("清空续问目标，下次改为新建对话"))
                }
                Button(L("关闭", "Close")) { isPresented = false }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Button(action: send) {
                    Text(L("发送"))
                        .frame(minWidth: 64, minHeight: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
    }

    private var paperError: String? {
        guard let paperID = draftPaperID else { return L("请先打开一篇文献。") }
        return questions.errors[paperID]
    }

    private func targetLabel(_ target: PaperQuestionTarget) -> String {
        if target.isKnownConversation {
            return "\(target.displayName) · \(L(target.title))" + (target.needsManualSessionBinding ? L(" · 需会话 ID") : "")
        }
        return L("在 \(target.displayName) 中新建对话", "New conversation in \(target.displayName)")
    }

    private func endContinuation() {
        model.activeReadingConversationID = nil
        form.selectedTargetID = ""
        form.externalSessionID = ""
        onRefreshTargets()
    }

    private func loadDraftAndSelection() {
        guard let paperID = draftPaperID else { return }
        form.draft = questions.drafts[paperID] ?? ""
        synchronizeTargetSelection()
    }

    private func synchronizeTargetSelection() {
        if let activeTarget, targets?.activeUnavailableReason?.isEmpty ?? true {
            form.selectedTargetID = activeTarget.id
        } else if requiresExplicitTargetSelection {
            if !choices.contains(where: { $0.id == form.selectedTargetID }) {
                form.selectedTargetID = ""
            }
        } else if !choices.contains(where: { $0.id == form.selectedTargetID }) {
            form.selectedTargetID = choices.first?.id ?? ""
        }
    }

    private func send() {
        form.localError = nil
        guard let paperID = draftPaperID,
              model.selectedPaper?.id == paperID,
              let target = selectedTarget else {
            form.localError = paperError ?? L("没有可用的外部对话。")
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let resolvedTarget: PaperQuestionTarget
        if selectedNeedsSessionBinding {
            let externalID = externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalID.isEmpty else {
                form.localError = L("请先粘贴外部会话 ID。")
                return
            }
            resolvedTarget = target.bindingSession(externalID)
        } else {
            resolvedTarget = target
        }

        questions.send(text, to: resolvedTarget, in: model)
    }
}
