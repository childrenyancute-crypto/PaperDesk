import Foundation
import CoreGraphics
import CoreText

/// A synthetic fixture for local verification. It is never presented as a real paper.
public enum SamplePDF {
    public static func create(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PaperDeskError.invalid("无法生成本地演示 PDF。")
        }
        let pages: [[String]] = [
            ["PaperDesk reading sample", "Synthetic document for testing, not a research article.", "", "1. A finite-dimensional quantum system", "Let H be a Hermitian operator on a finite-dimensional space.", "Its eigenvectors can be chosen as an orthonormal basis.", "", "H |n> = E_n |n>                                      (1)", "<m|n> = delta_mn                                    (2)", "", "Select a passage and ask the reading assistant about it.", "Saved notes should return to this exact source location."],
            ["2. Time evolution", "For a time-independent Hamiltonian,", "", "U(t) = exp(-i H t / hbar)                            (3)", "", "In the eigenbasis of H, every component acquires a phase.", "The following page checks page navigation and persistence.", "", "This document contains only synthetic verification content."],
            ["Appendix A. Reading checks", "A.1 Selection snapshots must retain their original page.", "A.2 Notes must survive closing and reopening the library.", "A.3 Repeating one save request must not duplicate a note.", "A.4 Restricting the context must restrict page access.", "", "End of local reading sample."]
        ]
        for lines in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            for (index, text) in lines.enumerated() {
                let font = CTFontCreateWithName(index == 0 ? "Times-Bold" as CFString : "Times-Roman" as CFString, index == 0 ? 21 : 13, nil)
                let attributes = [kCTFontAttributeName: font] as CFDictionary
                let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 48, y: 730 - CGFloat(index) * 27)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
