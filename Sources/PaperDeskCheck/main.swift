import Foundation
import PaperDeskCore
import PaperDeskBridge

do {
    let arguments = CommandLine.arguments
    if arguments.contains("--verify") {
        try await Verification.run()
    } else if let index = arguments.firstIndex(of: "--fixture"), arguments.indices.contains(index + 1) {
        let url = URL(fileURLWithPath: arguments[index + 1])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SamplePDF.create(at: url)
        print("Created synthetic reading fixture.")
    } else if let index = arguments.firstIndex(of: "--call"), arguments.indices.contains(index + 1) {
        let method = arguments[index + 1]
        let payload: JSONValue
        if arguments.indices.contains(index + 2), !arguments[index + 2].hasPrefix("--") {
            payload = try JSONDecoder().decode(JSONValue.self, from: Data(arguments[index + 2].utf8))
        } else { payload = .object([:]) }
        let client = LocalBridgeClient(socketURL: LibraryPaths.socket(root: LibraryPaths.root()))
        print(try client.call(method: method, arguments: payload).encodedText())
    } else {
        print("paperdesk-check\n  --verify  Run local storage, bridge and protocol checks\n  --fixture PATH.pdf  Create a synthetic PDF for local checks\n  --library PATH --call TOOL [JSON]  Call a running local reader")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
