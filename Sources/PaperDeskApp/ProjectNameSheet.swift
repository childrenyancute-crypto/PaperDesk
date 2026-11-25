import SwiftUI
import PaperDeskCore

private final class ProjectNameSheetState: ObservableObject {
    @Published var name: String
    @Published var errorMessage: String?

    init(name: String) {
        self.name = name
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProjectNameSheet: View {
    @ObservedObject var model: AppModel
    let prompt: ProjectNamePrompt

    @Environment(\.dismiss) private var dismiss
    @StateObject private var form: ProjectNameSheetState

    init(model: AppModel, prompt: ProjectNamePrompt) {
        self.model = model
        self.prompt = prompt
        _form = StateObject(wrappedValue: ProjectNameSheetState(name: prompt.defaultName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("创建阅读项目"), systemImage: "folder.badge.gearshape")
                    .font(InspectorText.title)
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(prompt.paperTitle)
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 5) {
                Text(L("项目名")).font(InspectorText.section)
                TextField(L("项目名"), text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }

            Text(L("项目文件夹会用这个名称创建，右侧项目卡也会显示它。"))
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = form.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("创建项目")) { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(form.trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .font(InspectorText.body)
    }

    private func create() {
        guard !form.trimmedName.isEmpty else { return }
        do {
            try model.createProjectFromPrompt(name: form.trimmedName)
            dismiss()
        } catch {
            form.errorMessage = error.localizedDescription
        }
    }
}
