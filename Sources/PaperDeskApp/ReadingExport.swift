import AppKit
import Foundation
import UniformTypeIdentifiers
import PaperDeskCore

private struct ReadingExport: Encodable {
    let version = 4
    let paper: Paper
    let notes: [ReadingNote]
    let contexts: [ContextSnapshot]
    let readingInstructions: String
    let discussion: [PaperChatMessage]
    let readingState: PaperReadingState
    let questionSnapshots: [ReadingQuestionSnapshot]
    let noteSources: [String: [String]]
    let extractiveSources: [String: [ExtractiveSource]]
    let extractiveCoverage: [String: ExtractiveCoverage]
}

extension AppModel {
    func exportReadingRecords() {
        guard let paper = selectedPaper else { return }
        do {
            let notes = try store.notes(paperID: paper.id)
            let chat = try store.chatSession(paperID: paper.id)
            let readingState = try store.readingState(paperID: paper.id)
            let snapshots = try Set(chat.messages.compactMap(\.readingSnapshotID)).sorted()
                .compactMap { try store.readingSnapshot(id: $0) }
            var noteSources: [String: [String]] = [:]
            var extractiveSources: [String: [ExtractiveSource]] = [:]
            var coverage: [String: ExtractiveCoverage] = [:]
            var ids = Set(chat.messages.compactMap(\.contextID) + chat.messages.flatMap { $0.sourceContextIDs ?? [] })
            ids.formUnion(readingState.selections.map(\.id))
            for note in notes {
                let sources = try store.noteContextIDs(noteID: note.id)
                if !sources.isEmpty { noteSources[note.id] = sources }
                ids.formUnion(sources)
                let excerpts = try store.extractiveSummary(noteID: note.id)
                if !excerpts.isEmpty { extractiveSources[note.id] = excerpts }
                coverage[note.id] = try store.extractiveCoverage(noteID: note.id)
            }
            let contexts = try ids.sorted().compactMap { try store.context(id: $0) }
            let package = ReadingExport(paper: paper, notes: notes, contexts: contexts,
                                        readingInstructions: chat.readingInstructions, discussion: chat.messages,
                                        readingState: readingState, questionSnapshots: snapshots,
                                        noteSources: noteSources, extractiveSources: extractiveSources, extractiveCoverage: coverage)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(package)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = L("\(paper.title)-阅读记录.json", "\(paper.title)-reading-records.json")
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = L("阅读记录已导出。")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
