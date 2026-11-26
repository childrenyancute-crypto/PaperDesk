import SwiftUI
import PaperDeskCore

/// The compact card shown when the reader clicks a bibliography chip or an
/// author-year mention. It deliberately shows only authors, title, and year;
/// identifiers and raw text stay available for verification but do not crowd
/// the reading flow.
struct ReferenceCard: View {
    @ObservedObject var model: AppModel
    let referenceID: String
    var archivedReference: MessageReference? = nil
    @Environment(\.dismiss) private var dismiss

    private var reference: PaperReference? {
        model.references.first { $0.id == referenceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reference = archivedReference ?? reference.map(MessageReference.init) {
                HStack(spacing: 8) {
                    statusBadge(reference.status)
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(L("关闭", "Close"))
                }

                Text(reference.title?.isEmpty == false ? reference.title! : L("标题未识别", "Title not recognized"))
                    .font(InspectorText.section)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 3) {
                    labeledText("person.2", reference.authors?.isEmpty == false ? reference.authors! : L("作者未识别", "Authors not recognized"))
                    labeledText("calendar", reference.year.map(String.init) ?? L("年份未识别", "Year not recognized"))
                }
                .font(InspectorText.detail)
                .foregroundStyle(.secondary)

                if let current = self.reference,
                   current.status != .verified,
                   let error = model.referenceVerificationErrors[current.id], !error.isEmpty {
                    Text(error)
                        .font(InspectorText.detail)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if let current = self.reference {
                        verifyButton(current)
                    }
                    Spacer(minLength: 0)
                }
                if self.reference == nil {
                    Text(L("显示的是回答归档时保存的书目信息。", "Showing the bibliography details saved with this answer."))
                        .font(InspectorText.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L("这条参考文献已被移除。", "This reference was removed."))
                    .font(InspectorText.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func labeledText(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusBadge(_ status: PaperReferenceStatus) -> some View {
        let verified = status == .verified
        return Label(verified ? L("书目信息已核实", "Bibliography verified") : L("未核实 · 本地识别", "Unverified · local extraction"),
                     systemImage: verified ? "checkmark.seal.fill" : "questionmark.circle")
            .font(InspectorText.detailStrong)
            .foregroundStyle(verified ? ReaderPalette.ready : ReaderPalette.focusManual)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((verified ? ReaderPalette.ready : ReaderPalette.focusManual).opacity(0.12),
                        in: Capsule())
    }

    private func verifyButton(_ reference: PaperReference) -> some View {
        let running = model.verifyingReferenceIDs.contains(reference.id)
            || model.referenceVerificationRunningPaperIDs.contains(reference.paperID)
        return Button {
            model.verifyReference(reference.id)
        } label: {
            if running {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("核实中…", "Verifying…"))
                }
                .font(InspectorText.detail)
            } else {
                Label(reference.status == .verified ? L("重新核实", "Verify again") : L("用 AI 核实", "Verify with AI"),
                      systemImage: "checkmark.seal")
                    .font(InspectorText.detail)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(ReaderPalette.action)
        .disabled(running)
        .help(running ? L("正在后台核实这条文献", "Verifying this reference in the background") : L("让已连接的 AI 客户端核对作者、标题和年份", "Ask the connected AI client to check the authors, title, and year"))
    }
}
