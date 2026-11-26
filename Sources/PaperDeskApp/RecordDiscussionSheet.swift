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

            ConnectionPolicyControls(model: model, bindToPaper: form.boundToCurrentPaper)

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

struct ConnectionPolicyControls: View {
    @ObservedObject var model: AppModel
    var bindToPaper = true
    @StateObject private var check = ConnectionCheckState()

    private var clientNames: [String] {
        guard let paper = model.selectedPaper else { return [] }
        return Array(Set(model.connectedClients(forPaperID: paper.id).map(\.displayName))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("允许 AI 标记 PDF 原文", "Allow AI to highlight PDF sources"), isOn: $model.allowsAICitationMarks)
            Text(L("允许已连接的客户端为回答生成原文高亮。高亮随回答显示。", "Connected clients can create source highlights that appear with an answer."))
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)
            Picker(L("AI 正文读取范围"), selection: $model.scope) {
                ForEach(ContextScope.allCases, id: \.self) { value in
                    Text(L(value.title)).tag(value)
                }
            }
            .disabled(model.selectedPaper == nil)
            Divider()
            HStack {
                if clientNames.isEmpty {
                    Label(L("当前论文暂无已连接的客户端", "No clients are connected to this paper"), systemImage: "circle")
                } else {
                    Label(clientNames.joined(separator: " · "), systemImage: "checkmark.circle")
                }
                Spacer()
                Button(L("本机连接自检", "Check local connection")) { checkConnection() }
                    .disabled(check.result == .checking)
            }
            .font(InspectorText.detail)
            switch check.result {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .passed:
                Label(L("PaperDesk 本机连接正常。", "PaperDesk's local connection passed."), systemImage: "checkmark.circle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(InspectorText.detail)
                    .foregroundStyle(.red)
            }
        }
    }

    private func checkConnection() {
        check.result = .checking
        Task {
            do {
                let launch = try model.mcpLaunchConfiguration(
                    bound: bindToPaper && model.selectedPaper != nil, clientLabel: "")
                _ = try await model.checkMCPConnection(launch: launch)
                model.refreshMCPConnectionState()
                check.result = .passed
            } catch {
                check.result = .failed(error.localizedDescription)
            }
        }
    }
}

private final class ConnectionCheckState: ObservableObject {
    enum Result: Equatable {
        case idle, checking, passed, failed(String)
    }

    @Published var result: Result = .idle
}

