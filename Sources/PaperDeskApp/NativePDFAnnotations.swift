import AppKit
import Foundation
import PDFKit
import PaperDeskCore

/// The small PDFKit bridge used by the reader when a note is approved for
/// writing into the PDF itself.
///
/// PDFKit's `PDFAnnotation` objects are the source of truth for this helper;
/// the library database can still keep the richer note/context record, but a
/// note written through this type is also a real, portable PDF annotation.
@MainActor
enum NativePDFAnnotations {
    // PDFKit exposes the standard /NM name, but some PDFKit versions omit
    // custom /NM values while rebuilding a document's dataRepresentation.
    // /T (the annotation's optional text label/userName) is a second standard
    // annotation field and survives those round trips.  We write both and
    // accept either on read, without putting the marker in /Contents.
    private static let annotationNameKey = PDFAnnotationKey.name
    private static let annotationTextLabelKey = PDFAnnotationKey.textLabel
    private static let markerPrefix = "com.paperdesk.note.v1:"

    /// Returns the note IDs owned by PaperDesk annotations in the document.
    ///
    /// The marker is stored in standard annotation dictionary fields (`/NM`
    /// and `/T`) so it can be recovered after a PDFKit save/reopen round trip.
    /// Only values with our exact prefix are considered; unrelated
    /// annotations are left alone.
    static func noteIDs(in document: PDFDocument) -> Set<String> {
        var result = Set<String>()
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                if let noteID = noteID(for: annotation) {
                    result.insert(noteID)
                }
            }
        }
        return result
    }

    /// Removes this note's previously written annotations and, unless
    /// `remove` is true, writes the current note back as native PDF marks.
    ///
    /// Every valid anchored rectangle becomes a Highlight annotation with
    /// proper quad points.  A Text annotation is placed at the first valid
    /// anchor (or the note's page when there is no rectangle) and contains the
    /// complete note content.  No file is written here: the caller owns the
    /// atomic `PDFDocument.dataRepresentation()`/replace operation.
    static func edit(
        _ document: PDFDocument,
        note: ReadingNote,
        contexts: [ContextSnapshot],
        remove: Bool = false
    ) throws {
        let noteID = note.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteID.isEmpty else {
            throw PaperDeskError.invalid(L("批注缺少稳定标识，不能写入 PDF。"))
        }

        // Removal is deliberately done after all new annotations have been
        // prepared and validated below.  If a stale anchor or a PDFKit error
        // makes the replacement unsafe, the caller still has the previous
        // marks in its in-memory document and can retry safely.
        guard !remove else {
            removeAnnotations(for: noteID, from: document)
            return
        }

        guard document.pageCount > 0 else {
            throw PaperDeskError.invalid(L("当前 PDF 没有可写入批注的页面。"))
        }

        // The caller normally passes only contexts linked to this note.  The
        // paper check is an additional guard against accidentally marking a
        // different paper when a broader context list is supplied.
        let paperContexts = contexts.filter { $0.paperID == note.paperID }
        var anchors: [(page: PDFPage, pageIndex: Int, rect: CGRect)] = []

        for context in paperContexts {
            for region in context.regions {
                guard let page = document.page(at: region.pageIndex),
                      let rect = validRect(for: region, on: page) else { continue }
                anchors.append((page: page, pageIndex: region.pageIndex, rect: rect))
            }
        }

        // Prepare every annotation before mutating any page.  In particular,
        // this verifies that PDFKit accepts the durable marker for all marks
        // so a failed write cannot leave a partly tagged update behind.
        var pending: [(page: PDFPage, annotation: PDFAnnotation)] = []
        pending.reserveCapacity(anchors.count + 1)
        let color = note.source == "ai"
            ? NSColor(srgbRed: 0.43, green: 0.68, blue: 0.93, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.78, blue: 0.27, alpha: 1)

        for (index, anchor) in anchors.enumerated() {
            let highlight = PDFAnnotation(bounds: anchor.rect, forType: .highlight, withProperties: nil)
            highlight.color = color.withAlphaComponent(0.42)
            highlight.contents = note.content
            highlight.quadrilateralPoints = quadPoints(for: anchor.rect)
            try setMarker(marker(for: noteID, kind: "highlight", index: index), on: highlight)
            pending.append((page: anchor.page, annotation: highlight))
        }

        let commentAnchor: (page: PDFPage, pageIndex: Int, rect: CGRect?)
        if let first = anchors.first {
            commentAnchor = first
        } else {
            guard note.pageIndex >= 0, note.pageIndex < document.pageCount,
                  let page = document.page(at: note.pageIndex) else {
                throw PaperDeskError.invalid(L("批注锚点不属于当前 PDF，不能安全写入。"))
            }
            commentAnchor = (page: page, pageIndex: note.pageIndex, rect: nil)
        }

        guard let commentBounds = commentBounds(
            on: commentAnchor.page,
            anchor: commentAnchor.rect,
            sequence: pending.count
        ) else {
            throw PaperDeskError.invalid(L("当前 PDF 页面没有可放置批注图标的区域。"))
        }

        let comment = PDFAnnotation(bounds: commentBounds, forType: .text, withProperties: nil)
        comment.iconType = .comment
        comment.color = color
        comment.contents = note.content
        try setMarker(marker(for: noteID, kind: "comment", index: 0), on: comment)
        pending.append((page: commentAnchor.page, annotation: comment))

        // Updating a note is remove-then-add.  This makes repeated approvals
        // idempotent while retaining every annotation that does not carry our
        // exact marker for this note.
        removeAnnotations(for: noteID, from: document)
        for item in pending {
            item.page.addAnnotation(item.annotation)
        }
    }

    // MARK: - Markers

    private static func marker(for noteID: String, kind: String, index: Int) -> String {
        "\(markerPrefix)\(base64URL(noteID))/\(kind)/\(index)"
    }

    private static func noteID(from marker: String) -> String? {
        guard marker.hasPrefix(markerPrefix) else { return nil }
        let payload = String(marker.dropFirst(markerPrefix.count))
        guard let encodedID = payload.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first,
              !encodedID.isEmpty,
              let data = Data(base64URL: String(encodedID)),
              let noteID = String(data: data, encoding: .utf8),
              !noteID.isEmpty else { return nil }
        return noteID
    }

    private static func setMarker(_ marker: String, on annotation: PDFAnnotation) throws {
        // Keep the conventional /NM name where PDFKit supports it, and always
        // attempt /T as the durable fallback.  The marker is deliberately not
        // placed in `contents`, which remains the user's visible note text.
        let nameAccepted = annotation.setValue(marker, forAnnotationKey: annotationNameKey)
        let textLabelAccepted = annotation.setValue(marker, forAnnotationKey: annotationTextLabelKey)
        let nameMatches = (annotation.value(forAnnotationKey: annotationNameKey) as? String) == marker
        let textLabelMatches = (annotation.value(forAnnotationKey: annotationTextLabelKey) as? String) == marker
        guard (nameAccepted && nameMatches) || (textLabelAccepted && textLabelMatches) else {
            throw PaperDeskError.invalid(L("PDF 不接受 PaperDesk 批注标识，未写入批注。"))
        }
    }

    private static func noteID(for annotation: PDFAnnotation) -> String? {
        for key in [annotationNameKey, annotationTextLabelKey] {
            guard let marker = annotation.value(forAnnotationKey: key) as? String,
                  let noteID = noteID(from: marker) else { continue }
            return noteID
        }
        return nil
    }

    private static func removeAnnotations(for targetID: String, from document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in Array(page.annotations) {
                guard noteID(for: annotation) == targetID else { continue }
                page.removeAnnotation(annotation)
            }
        }
    }

    // MARK: - Geometry

    /// Turns a stored page region into a safe crop-box intersection.  Region
    /// coordinates are page-space coordinates (not view coordinates), so a
    /// non-zero crop-box origin is preserved rather than assumed to be zero.
    private static func validRect(for region: PageRegion, on page: PDFPage) -> CGRect? {
        let values = [region.x, region.y, region.width, region.height]
        guard values.allSatisfy({ $0.isFinite }), region.width > 0, region.height > 0 else { return nil }

        let raw = CGRect(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height
        ).standardized
        let crop = page.bounds(for: .cropBox).standardized
        guard crop.width > 0, crop.height > 0 else { return nil }

        let clipped = raw.intersection(crop)
        guard clipped.width > 0.5, clipped.height > 0.5,
              clipped.minX.isFinite, clipped.minY.isFinite,
              clipped.maxX.isFinite, clipped.maxY.isFinite else { return nil }
        return clipped
    }

    /// PDFKit expects quad points relative to the annotation bounds, in the
    /// order upper-left, upper-right, lower-left, lower-right.
    private static func quadPoints(for rect: CGRect) -> [NSValue] {
        let origin = rect.origin
        return [
            NSValue(point: CGPoint(x: rect.minX - origin.x, y: rect.maxY - origin.y)),
            NSValue(point: CGPoint(x: rect.maxX - origin.x, y: rect.maxY - origin.y)),
            NSValue(point: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y)),
            NSValue(point: CGPoint(x: rect.maxX - origin.x, y: rect.minY - origin.y))
        ]
    }

    private static func commentBounds(on page: PDFPage, anchor: CGRect?, sequence: Int) -> CGRect? {
        let crop = page.bounds(for: .cropBox).standardized
        guard crop.width > 4, crop.height > 4 else { return nil }

        let requestedSize = min(26.0, max(16.0, min(crop.width, crop.height) * 0.06))
        let size = min(requestedSize, min(crop.width, crop.height))
        guard size > 4 else { return nil }

        let point: CGPoint
        if let anchor {
            point = CGPoint(x: anchor.maxX + 6, y: anchor.maxY - size)
        } else {
            point = CGPoint(
                x: crop.minX + 12 + CGFloat(sequence % 5) * (size + 6),
                y: crop.maxY - size - 12 - CGFloat(sequence / 5) * (size + 6)
            )
        }

        let minX = crop.minX
        let maxX = max(crop.minX, crop.maxX - size)
        let minY = crop.minY
        let maxY = max(crop.minY, crop.maxY - size)
        let x = min(max(point.x, minX), maxX)
        let y = min(max(point.y, minY), maxY)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URL value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }
}
