import AppKit
import SwiftUI
import PaperDeskCore

/// Presents the same PaperDesk MCP connection information that can be copied
/// into Codex, another desktop AI client, or a local launcher. The generated
/// values come from AppModel so this view never embeds a path, port, or secret.
struct ConnectionConfigurationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var form = ConnectionConfigurationSheetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("连接 AI 客户端"))
                        .font(InspectorText.title)
                    Text(L("将本机 MCP 配置复制到你的 AI 客户端。"))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                TextField(L("客户端显示名（可选）"), text: $form.clientLabel)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("绑定当前文献"), isOn: $form.boundToCurrentPaper)
                    .toggleStyle(.switch)
                    .disabled(model.selectedPaper == nil)
            }
            Text(form.boundToCurrentPaper && model.selectedPaper != nil
                 ? L("这份配置固定连接到当前论文。")
                 : L("讨论和笔记检索会跟随 PaperDesk 当前打开的论文。"))
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Picker(L("AI 正文读取范围"), selection: $model.scope) {
                    ForEach(ContextScope.allCases, id: \.self) { value in
                        Text(L(value.title)).tag(value)
                    }
                }
                .disabled(model.selectedPaper == nil)
                Text(L("新文献默认仅共享已固定的选区；需要更多上下文时可改为当前页或全文。",
                       "New papers share pinned selections by default. Choose the current page or full text when more context is needed."))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }

            if let configurationError = form.configurationError {
                Label(configurationError, systemImage: "exclamationmark.triangle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("通用 JSON 配置"))
                        .font(InspectorText.section)
                    Spacer()
                    Button(L("复制 JSON"), systemImage: "doc.on.doc") { copy(form.configuration, message: L("MCP 配置已复制。")) }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .disabled(form.configuration.isEmpty)
                }
                TextEditor(text: .constant(form.configuration))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 145, maxHeight: 230)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("启动命令"))
                        .font(InspectorText.section)
                    Spacer()
                    Button(L("复制命令"), systemImage: "doc.on.doc") {
                        let text = ([form.launchCommand] + (form.launchArguments.isEmpty ? [] : [form.launchArguments])).joined(separator: " ")
                        copy(text, message: L("启动命令已复制。"))
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .disabled(form.launchCommand.isEmpty)
                }
                HStack(spacing: 8) {
                    TextField(L("可执行文件"), text: .constant(form.launchCommand))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    TextField(L("参数"), text: .constant(form.launchArguments))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
            }

            HStack {
                Button(L("重新生成")) { reload() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640)
        .frame(minHeight: 500)
        .font(InspectorText.body)
        .onAppear { reload() }
        .onChange(of: form.clientLabel) { _, _ in reload() }
        .onChange(of: form.boundToCurrentPaper) { _, _ in reload() }
    }

    private func reload() {
        let label = form.clientLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            form.configuration = try model.mcpConfiguration(bound: form.boundToCurrentPaper && model.selectedPaper != nil,
                                                       clientLabel: label)
            let launch = try model.mcpLaunchConfiguration(bound: form.boundToCurrentPaper && model.selectedPaper != nil,
                                                         clientLabel: label)
            form.launchCommand = launch.command
            form.launchArguments = launch.arguments.joined(separator: " ")
            form.configurationError = nil
        } catch {
            form.configuration = ""
            form.launchCommand = ""
            form.launchArguments = ""
            form.configurationError = error.localizedDescription
        }
    }

    private func copy(_ text: String, message: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.statusMessage = message
    }
}

private final class ConnectionConfigurationSheetState: ObservableObject {
    @Published var clientLabel = L("AI 客户端")
    @Published var boundToCurrentPaper = true
    @Published var configuration = ""
    @Published var launchCommand = ""
    @Published var launchArguments = ""
    @Published var configurationError: String?
}

