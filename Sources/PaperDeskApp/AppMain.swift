import SwiftUI
import AppKit
import PDFKit
import PaperDeskCore
import PaperDeskStorage
import PaperDeskBridge

@main
enum Launcher {
    static let version = "0.7.8"

    @MainActor
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-live-question" {
            let client = CommandLine.arguments[2]
            Task {
                do { try await ReaderSelfCheck.checkLiveQuestion(clientID: client); exit(0) }
                catch { print("Live question failed: \(error.localizedDescription)"); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--check-floating-question") {
            Task {
                do { try await ReaderSelfCheck.checkFloatingQuestion(); exit(0) }
                catch { FileHandle.standardError.write(Data("PaperDesk question check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--check-question-bubble") {
            do { try ReaderSelfCheck.checkQuestionBubble(); exit(0) }
            catch { FileHandle.standardError.write(Data("PaperDesk bubble check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        if let option = CommandLine.arguments.firstIndex(of: "--serve-project-check"),
           CommandLine.arguments.indices.contains(option + 1) {
            do { try ReaderSelfCheck.serveProjectCheck(at: URL(fileURLWithPath: CommandLine.arguments[option + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data("PaperDesk project check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--check-region-preview") {
            do { try ReaderSelfCheck.checkRegionPreview(); try ReaderSelfCheck.checkReaderSelectionMarks(); exit(0) }
            catch { FileHandle.standardError.write(Data("PaperDesk region check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--check-responsive-zoom") {
            do { try ReaderSelfCheck.checkResponsiveZoom(); exit(0) }
            catch { FileHandle.standardError.write(Data("PaperDesk zoom check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--self-check") {
            do {
                try ReaderSelfCheck.run()
                try ReaderSelfCheck.checkChatStorage()
                try ReaderSelfCheck.checkExtractiveStorage()
                try ReaderSelfCheck.checkReadingState()
                try ReaderSelfCheck.checkReferenceRendering()
                try ReaderSelfCheck.checkMathFonts()
                exit(0)
            }
            catch { FileHandle.standardError.write(Data("PaperDesk check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--help") {
            print(L("PaperDesk \(version)\n  --library PATH  使用指定本地资料库\n  --demo          打开合成的功能演示PDF\n  --self-check    检查PDF、保存与工具流程（不打开窗口）",
                    "PaperDesk \(version)\n  --library PATH  Use a specific local library\n  --demo          Open the synthetic demo PDF\n  --self-check    Verify PDF, storage, and tool flows (no window)"))
            return
        }
        PaperDeskApplication.main()
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    let model: AppModel?
    let startupError: String?
    private var bridge: LocalBridgeServer?
    init() {
        do {
            let root = LibraryPaths.root()
            let store = try LibraryStore(rootURL: root)
            let model = try AppModel(store: store)
            if CommandLine.arguments.contains("--demo") {
                let sample = root.appendingPathComponent("Reading Sample.pdf")
                if !FileManager.default.fileExists(atPath: sample.path) { try SamplePDF.create(at: sample) }
                model.openPDF(url: sample)
                if let document = model.document, let selection = document.findString("Hermitian operator", withOptions: .caseInsensitive).first {
                    model.captureSelection(selection, document: document)
                }
            }
            let service = ReaderTools(model: model)
            let server = LocalBridgeServer(socketURL: LibraryPaths.socket(root: root)) { request in
                await service.handleWithProgress(request)
            }
            self.model = model
            self.startupError = nil
            do {
                try server.start()
                model.bridgeConnected = true
                self.bridge = server
            } catch {
                model.statusMessage = L("本机 MCP 连接未启动。")
            }
        } catch {
            model = nil; startupError = error.localizedDescription
        }
    }
    func stop() { bridge?.stop() }
}

struct PaperDeskApplication: App {
    @StateObject private var runtime = AppRuntime()
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.chinese.rawValue
    var body: some Scene {
        WindowGroup("PaperDesk") {
            Group {
                if let model = runtime.model {
                    ReaderView(model: model)
                        .id(language)
                        .onOpenURL { model.openPDF(url: $0) }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(L("暂时无法打开资料库")).font(InspectorText.title)
                        Text(runtime.startupError ?? L("请重新打开应用。")).textSelection(.enabled)
                        Button(L("退出")) { NSApplication.shared.terminate(nil) }
                    }
                    .font(InspectorText.body)
                    .padding(36).frame(minWidth: 520, minHeight: 300)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in runtime.stop() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("关于 PaperDesk")) {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "PaperDesk", .applicationVersion: Launcher.version,
                        .credits: NSAttributedString(string: L("本地文献阅读、批注与笔记。可接入本地 MCP 客户端。"))
                    ])
                }
            }
        }
        Settings {
            if let model = runtime.model {
                ConnectionPolicyControls(model: model)
                    .padding(24)
                    .frame(width: 510, alignment: .leading)
                    .font(InspectorText.body)
                    .id(language)
            }
        }
    }
}
