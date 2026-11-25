import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import PaperDeskCore

/// The PDFKit view owns display, scrolling, zooming and text selection only.
/// Region capture is handled by the sibling overlay below.  Drawing from
/// `PDFView.draw(_:)` is too early in PDFKit's rendering stack: its page views
/// can cover that drawing again before it reaches the screen.
final class PDFRegionView: PDFView {}

/// A transparent sibling placed above `PDFRegionView` by `PDFReaderContainer`.
/// It is an event target only while formula capture is enabled.  Returning nil
/// from `hitTest` in the normal mode lets AppKit continue hit testing the
/// PDFView underneath, preserving ordinary text selection and scrolling.
final class PDFRegionOverlayView: NSView {
    weak var pdfView: PDFRegionView?
    var formulaCaptureEnabled = false {
        didSet {
            guard formulaCaptureEnabled != oldValue else { return }
            if !formulaCaptureEnabled { clearDrag() }
            needsDisplay = true
        }
    }
    var onRegionCaptured: ((Int, CGRect, Data) -> Void)?
    var markedSelections: [ReadingSelection] = [] {
        didSet { if markedSelections != oldValue { needsDisplay = true } }
    }
    /// Citation marks for the answer currently being read. Kept separate from
    /// selections so the two layers never share colours or badges.
    var citationMarks: [CitationMark] = [] {
        didSet { if citationMarks != oldValue { needsDisplay = true } }
    }

    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    // Kept as a page-space rectangle so it remains correct when PDFView zooms
    // or lays out pages again during a drag.
    private(set) var dragBounds: CGRect?
    private var transientPageIndex: Int?
    private var transientRegions: [PageRegion] = []
    private var transientClearWorkItem: DispatchWorkItem?

    override func hitTest(_ point: NSPoint) -> NSView? {
        formulaCaptureEnabled ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard formulaCaptureEnabled, let pdfView else {
            pdfView?.mouseDown(with: event)
            return
        }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false), let document = pdfView.document else {
            clearDrag()
            pdfView.mouseDown(with: event)
            return
        }
        let pagePoint = clampedPagePoint(point, page: page)
        guard document.index(for: page) >= 0 else {
            pdfView.mouseDown(with: event)
            return
        }
        dragStart = pagePoint
        dragPage = page
        dragBounds = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard formulaCaptureEnabled, let page = dragPage, let start = dragStart, let pdfView else {
            pdfView?.mouseDragged(with: event)
            return
        }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        let end = clampedPagePoint(point, page: page)
        dragBounds = normalizedRect(from: start, to: end).intersection(page.bounds(for: .cropBox))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard formulaCaptureEnabled, let page = dragPage, let start = dragStart, let pdfView else {
            pdfView?.mouseUp(with: event)
            return
        }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        let end = clampedPagePoint(point, page: page)
        let bounds = normalizedRect(from: start, to: end).intersection(page.bounds(for: .cropBox))
        let pageIndex = pdfView.document?.index(for: page) ?? NSNotFound
        clearDrag()
        guard pageIndex != NSNotFound, bounds.width >= 4, bounds.height >= 4 else {
            return
        }
        do {
            let imageData = try PDFRegionRenderer.render(page: page, bounds: bounds)
            onRegionCaptured?(pageIndex, bounds, imageData)
        } catch {
            NSSound.beep()
        }
    }

    // When capture mode is active the overlay is the hit target, so forward
    // gestures that belong to PDFView itself.  With capture mode off these
    // methods are never needed because hitTest returns nil.
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = pdfView?.documentView?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            pdfView?.scrollWheel(with: event)
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    override func rotate(with event: NSEvent) {
        pdfView?.rotate(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pdfView, let document = pdfView.document,
              !markedSelections.isEmpty || !citationMarks.isEmpty || !transientRegions.isEmpty || dragBounds != nil else { return }
        let clip = pdfView.documentView?.enclosingScrollView?.contentView
        let viewport = clip.map { convert($0.bounds, from: $0).intersection(bounds) } ?? bounds
        guard !viewport.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: viewport).addClip()

        let visiblePages = Set(pdfView.visiblePages.map { document.index(for: $0) })
        var badges: [(String, CGRect, Bool)] = []
        for selection in markedSelections {
            let fill = selection.isAI ? NSColor.systemBlue.withAlphaComponent(0.22) : NSColor.systemYellow.withAlphaComponent(0.28)
            let stroke: NSColor? = selection.context.imageRelativePath == nil ? nil : (selection.isAI ? .systemBlue : .systemOrange)
            var labeledPages: Set<Int> = []
            for region in selection.context.regions where visiblePages.contains(region.pageIndex) {
                guard let page = document.page(at: region.pageIndex) else { continue }
                let rect = overlayRect(for: region, on: page, pdfView: pdfView)
                guard rect.intersects(viewport) else { continue }
                drawRegion(rect, fill: fill, stroke: stroke)
                if labeledPages.insert(region.pageIndex).inserted {
                    badges.append((selection.isAI ? "\(selection.label) · AI" : selection.label, rect, selection.isAI))
                }
            }
        }
        if let pageIndex = transientPageIndex, let page = document.page(at: pageIndex) {
            for region in transientRegions where region.pageIndex == pageIndex {
                guard !markedSelections.contains(where: { $0.context.regions.contains(region) }) else { continue }
                drawRegion(overlayRect(for: region, on: page, pdfView: pdfView), fill: NSColor.systemYellow.withAlphaComponent(0.28), stroke: NSColor.systemOrange)
            }
        }
        if let page = dragPage, let bounds = dragBounds, bounds.width > 0, bounds.height > 0 {
            let rect = convert(pdfView.convert(bounds, from: page), from: pdfView)
            drawRegion(rect, fill: NSColor.systemBlue.withAlphaComponent(0.15), stroke: NSColor.systemBlue)
        }
        var placed: [CGRect] = []
        for (label, rect, isAI) in badges {
            if let badge = drawBadge(label, above: rect, within: viewport, avoiding: placed, isAI: isAI) {
                placed.append(badge)
            }
        }

        // Citation layer for the single answer being read. Underline plus a
        // faint tint keeps the text legible; the circled number distinguishes
        // it from the yellow human selections and blue legacy AI marks.
        var citationBadges: [(String, CGRect)] = []
        for mark in citationMarks {
            var labeledPages: Set<Int> = []
            for region in mark.regions where visiblePages.contains(region.pageIndex) {
                guard let page = document.page(at: region.pageIndex) else { continue }
                let rect = overlayRect(for: region, on: page, pdfView: pdfView)
                guard rect.intersects(viewport) else { continue }
                drawCitationRegion(rect)
                if labeledPages.insert(region.pageIndex).inserted {
                    citationBadges.append((mark.label, rect))
                }
            }
        }
        for (label, rect) in citationBadges {
            if let badge = drawCitationBadge(label, above: rect, within: viewport, avoiding: placed) {
                placed.append(badge)
            }
        }
    }

    func showTransientRegions(_ regions: [PageRegion], pageIndex: Int?) {
        transientClearWorkItem?.cancel()
        transientRegions = regions
        transientPageIndex = regions.isEmpty ? nil : pageIndex
        needsDisplay = true
        guard !regions.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.transientRegions = []
            self?.transientPageIndex = nil
            self?.needsDisplay = true
        }
        transientClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func resetForNewDocument() {
        clearDrag()
        markedSelections = []
        citationMarks = []
        showTransientRegions([], pageIndex: nil)
    }

    private func clearDrag() {
        dragStart = nil
        dragPage = nil
        dragBounds = nil
        needsDisplay = true
    }

    private func clampedPagePoint(_ viewPoint: CGPoint, page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        let bounds = page.bounds(for: .cropBox)
        return CGPoint(x: min(max(pagePoint.x, bounds.minX), bounds.maxX), y: min(max(pagePoint.y, bounds.minY), bounds.maxY))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func overlayRect(for region: PageRegion, on page: PDFPage, pdfView: PDFRegionView) -> CGRect {
        let pageRect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        return convert(pdfView.convert(pageRect, from: page), from: pdfView)
    }

    private func drawRegion(_ rect: CGRect, fill: NSColor, stroke: NSColor?) {
        guard rect.width > 0, rect.height > 0 else { return }
        fill.setFill()
        let path = NSBezierPath(rect: rect)
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private enum CitationStyle {
        static let fill = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0.42, green: 0.82, blue: 0.82, alpha: 0.16)
                : NSColor(srgbRed: 0.08, green: 0.48, blue: 0.50, alpha: 0.12)
        }
        static let line = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.85, alpha: 0.65)
                : NSColor(srgbRed: 0.07, green: 0.42, blue: 0.44, alpha: 0.55)
        }
        static let badge = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0.16, green: 0.52, blue: 0.54, alpha: 0.95)
                : NSColor(srgbRed: 0.07, green: 0.40, blue: 0.42, alpha: 0.92)
        }
    }

    private func drawCitationRegion(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        CitationStyle.fill.setFill()
        NSBezierPath(rect: rect).fill()
        CitationStyle.line.setStroke()
        let underline = NSBezierPath()
        underline.move(to: CGPoint(x: rect.minX, y: rect.minY + 1))
        underline.line(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
        underline.lineWidth = 1.5
        underline.stroke()
    }

    private func drawCitationBadge(_ label: String, above rect: CGRect, within viewport: CGRect, avoiding placed: [CGRect]) -> CGRect? {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let diameter = max(16, ceil(max(size.width, size.height)) + 6)
        guard viewport.width >= diameter + 4, viewport.height >= diameter + 4 else { return nil }
        let x = min(max(rect.minX, viewport.minX + 2), viewport.maxX - diameter - 2)
        let y = min(max(rect.maxY + 3, viewport.minY + 2), viewport.maxY - diameter - 2)
        var badge = CGRect(x: x, y: y, width: diameter, height: diameter)
        let neighbors = placed.map { $0.insetBy(dx: -2, dy: -1) }.sorted { $0.minX < $1.minX }
        for neighbor in neighbors where badge.intersects(neighbor) { badge.origin.x = neighbor.maxX }
        if badge.maxX > viewport.maxX - 2 {
            badge.origin.x = x
            for neighbor in neighbors.reversed() where badge.intersects(neighbor) {
                badge.origin.x = neighbor.minX - diameter
            }
            if badge.minX < viewport.minX + 2 { badge.origin.x = x }
        }
        CitationStyle.badge.setFill()
        NSBezierPath(ovalIn: badge).fill()
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        return badge
    }

    private func drawBadge(_ label: String, above rect: CGRect, within viewport: CGRect, avoiding placed: [CGRect], isAI: Bool) -> CGRect? {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let width = max(18, ceil(size.width) + 8)
        let height: CGFloat = 18
        guard viewport.width >= width + 4, viewport.height >= height + 4 else { return nil }
        let x = min(max(rect.minX, viewport.minX + 2), viewport.maxX - width - 2)
        let y = min(max(rect.maxY + 3, viewport.minY + 2), viewport.maxY - height - 2)
        var badge = CGRect(x: x, y: y, width: width, height: height)
        // Close or overlapping boxes can share an anchor. Try the nearest
        // free position on the same row before covering an earlier label.
        let neighbors = placed.map { $0.insetBy(dx: -2, dy: -1) }.sorted { $0.minX < $1.minX }
        for neighbor in neighbors where badge.intersects(neighbor) { badge.origin.x = neighbor.maxX }
        if badge.maxX > viewport.maxX - 2 {
            badge.origin.x = x
            for neighbor in neighbors.reversed() where badge.intersects(neighbor) {
                badge.origin.x = neighbor.minX - width
            }
            if badge.minX < viewport.minX + 2 { badge.origin.x = x }
        }
        (isAI ? NSColor.systemBlue.withAlphaComponent(0.92) : NSColor(srgbRed: 0.43, green: 0.24, blue: 0.08, alpha: 1)).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        return badge
    }

    deinit {
        transientClearWorkItem?.cancel()
    }
}

/// Owns the PDF view and its sibling overlay.  Keeping the overlay as a real
/// sibling (rather than a PDFView subview) makes it reliably render above
/// PDFKit's private page views while still allowing normal events through.
final class PDFReaderContainer: NSView {
    let pdfView = PDFRegionView(frame: .zero)
    let overlay = PDFRegionOverlayView(frame: .zero)

    private var zoomMode: PDFZoomMode = .fitWidth
    private var lastZoomMode: PDFZoomMode?
    private weak var lastDocument: PDFDocument?
    private var lastViewportSize = CGSize.zero
    private var lastPageSize = CGSize.zero
    private var updatingZoom = false
    private weak var observedClip: NSClipView?
    private var viewportObservers: [NSObjectProtocol] = []
    private var scaleObserver: NSObjectProtocol?
    private var refitScheduled = false
    private var horizontalScrollerUpdateScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installSubviews()
    }

    private func installSubviews() {
        pdfView.frame = bounds
        overlay.frame = bounds
        addSubview(pdfView)
        addSubview(overlay, positioned: .above, relativeTo: pdfView)
        overlay.pdfView = pdfView

        // A scale change can come from a pinch gesture or PDFKit itself, not
        // only from AppModel's zoom buttons. Keep the horizontal scroller in
        // sync with those changes as well.
        scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHorizontalScrollerUpdate() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // PDFKit may change the scroll origin when its frame or scale changes.
        let destination = viewportDestination()
        super.setFrameSize(newSize)
        layoutReader(preserving: destination)
    }

    override func layout() {
        super.layout()
        layoutReader(preserving: viewportDestination())
    }

    private func layoutReader(preserving destination: PDFDestination?) {
        if pdfView.frame != bounds { pdfView.frame = bounds }
        if overlay.frame != bounds { overlay.frame = bounds }
        observeViewportSize()
        updateZoom(preserving: destination)
        updateHorizontalScrollerVisibility()
    }

    func setZoomMode(_ mode: PDFZoomMode) {
        zoomMode = mode
        observeViewportSize()
        updateZoom(preserving: viewportDestination())
        updateHorizontalScrollerVisibility()
    }

    private func observeViewportSize() {
        let clip = pdfView.documentView?.enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        let center = NotificationCenter.default
        viewportObservers.forEach(center.removeObserver)
        viewportObservers = []
        observedClip = clip
        guard let clip else { return }
        clip.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        viewportObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlay.needsDisplay = true
                self?.scheduleRefit()
            }
        })
        viewportObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.needsDisplay = true }
        })
    }

    private func scheduleRefit() {
        guard !refitScheduled else { return }
        refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refitScheduled = false
            self.updateZoom(preserving: self.viewportDestination())
            self.updateHorizontalScrollerVisibility()
        }
    }

    private func scheduleHorizontalScrollerUpdate() {
        // PDFViewScaleChanged is posted while PDFKit is still laying out its
        // document view. Waiting one main-loop turn lets us measure the
        // settled document frame and coalesces a burst of pinch events.
        guard !horizontalScrollerUpdateScheduled else { return }
        horizontalScrollerUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.horizontalScrollerUpdateScheduled = false
            self.updateHorizontalScrollerVisibility()
            self.overlay.needsDisplay = true
        }
    }

    deinit {
        viewportObservers.forEach(NotificationCenter.default.removeObserver)
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    }

    private func viewportDestination() -> PDFDestination? {
        guard let destination = pdfView.currentDestination else { return nil }
        guard let anchorPage = destination.page, let currentPage = pdfView.currentPage,
              anchorPage !== currentPage else { return destination }
        // In continuous mode the viewport can begin on the previous sheet.
        // Express that same location relative to the actual reading page.
        let point = pdfView.convert(pdfView.convert(destination.point, from: anchorPage), to: currentPage)
        return PDFDestination(page: currentPage, at: point)
    }

    private func updateZoom(preserving destination: PDFDestination?) {
        guard !updatingZoom, let document = pdfView.document else { return }
        let newDocument = document !== lastDocument
        guard let page = (newDocument ? nil : destination?.page) ?? pdfView.currentPage ?? document.page(at: 0) else { return }

        let viewport = viewportSize
        let boundsChanged = viewport != lastViewportSize
        let modeChanged = zoomMode != lastZoomMode
        let crop = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard pageSize.width > 0, pageSize.height > 0 else { return }

        let needsRefit = newDocument || modeChanged || boundsChanged || pageSize != lastPageSize
        guard needsRefit, let target = fittedScale(pageSize: pageSize, viewport: viewport) else { return }
        let scaleChanged = abs(pdfView.scaleFactor - target) > 0.0005

        updatingZoom = true
        defer { updatingZoom = false }
        lastDocument = document
        lastZoomMode = zoomMode
        lastPageSize = pageSize

        pdfView.autoScales = false
        if scaleChanged {
            pdfView.scaleFactor = target
            pdfView.layoutDocumentView()
            // With always-visible scroll bars, PDFKit can reduce the usable
            // bounds on the first layout. Refit to the space it actually has.
            if viewportSize != viewport,
               let adjusted = fittedScale(pageSize: pageSize, viewport: viewportSize),
               abs(pdfView.scaleFactor - adjusted) > 0.0005 {
                pdfView.scaleFactor = adjusted
                pdfView.layoutDocumentView()
            }
            scheduleRefit()
        }
        lastViewportSize = viewportSize

        switch zoomMode {
        case .fitPage:
            pdfView.go(to: page)
            centerHorizontally(page)
        case .fitWidth:
            if !newDocument, let destination { pdfView.go(to: destination) }
            centerHorizontally(pdfView.currentPage ?? page)
        case .fixed:
            if !newDocument, let destination, boundsChanged || scaleChanged {
                pdfView.go(to: destination)
            }
        }
        overlay.needsDisplay = true
    }

    private var viewportSize: CGSize {
        // The clip frame is in screen points and excludes any reserved scroll
        // bars. PDFKit's outer bounds may still report the full width here.
        observedClip?.frame.size ?? pdfView.bounds.size
    }

    private func fittedScale(pageSize: CGSize, viewport: CGSize) -> CGFloat? {
        let margins = pdfView.pageBreakMargins
        let width = viewport.width - margins.left - margins.right
        let height = viewport.height - margins.top - margins.bottom
        guard width > 0, height > 0 else { return nil }
        let scale: CGFloat
        switch zoomMode {
        case .fitWidth: scale = width / pageSize.width
        case .fitPage: scale = min(width / pageSize.width, height / pageSize.height)
        case .fixed(let fixed): scale = fixed
        }
        guard scale.isFinite, scale > 0 else { return nil }
        return min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    /// PDFKit centers the document as a whole. In mixed-size PDFs a narrow
    /// page can end up off center within that wider scrollable document.
    private func centerHorizontally(_ page: PDFPage) {
        guard let scrollView = pdfView.documentView?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
        let visible = clip.convert(clip.bounds, to: pdfView)
        let shift = pageRect.midX - visible.midX
        guard abs(shift) >= 1 else { return }
        let clipShift = clip.convert(CGPoint(x: shift, y: 0), from: pdfView).x
            - clip.convert(CGPoint.zero, from: pdfView).x
        clip.scroll(to: CGPoint(x: clip.bounds.minX + clipShift, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    /// PDFKit creates a horizontal scroller for many documents even when its
    /// document view fits the clip. Keep the scroller out of the layout until
    /// the laid-out document really exceeds the visible width. Measuring the
    /// document view (rather than a particular page) also handles continuous
    /// documents containing pages of different widths.
    private func updateHorizontalScrollerVisibility() {
        guard !updatingZoom,
              let scrollView = pdfView.documentView?.enclosingScrollView,
              let documentView = pdfView.documentView else { return }

        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth.isFinite, clipWidth > 0 else {
            if scrollView.hasHorizontalScroller {
                scrollView.hasHorizontalScroller = false
            }
            return
        }

        let documentWidth = documentView.bounds.width
        let hasHorizontalOverflow = documentWidth.isFinite && documentWidth > clipWidth + 1

        // Changing hasHorizontalScroller is the least surprising way to hide
        // the legacy bottom track: unlike merely setting alpha, it does not
        // leave an empty, reserved scrollbar frame. It changes only the
        // vertical clip size, so it cannot make a fit-width calculation
        // oscillate on its own. Explicitly unhide the scroller when it is
        // needed because overlay-style scroll views may retain an auto-hidden
        // NSScroller after a previous no-overflow state.
        if scrollView.hasHorizontalScroller != hasHorizontalOverflow {
            scrollView.hasHorizontalScroller = hasHorizontalOverflow
        }
        scrollView.horizontalScroller?.isHidden = !hasHorizontalOverflow
    }

    var formulaCaptureEnabled: Bool {
        get { overlay.formulaCaptureEnabled }
        set { overlay.formulaCaptureEnabled = newValue }
    }

    var onRegionCaptured: ((Int, CGRect, Data) -> Void)? {
        get { overlay.onRegionCaptured }
        set { overlay.onRegionCaptured = newValue }
    }

    func showTransientRegions(_ regions: [PageRegion], pageIndex: Int?) {
        overlay.showTransientRegions(regions, pageIndex: pageIndex)
    }
}

enum PDFRegionRenderer {
    private static let maxPixelEdge = 1_600.0
    private static let maxPNGBytes = 2 * 1024 * 1024

    static func render(page: PDFPage, bounds: CGRect) throws -> Data {
        let crop = page.bounds(for: .cropBox)
        let clipped = bounds.standardized.intersection(crop)
        guard clipped.width > 0, clipped.height > 0 else {
            throw PaperDeskError.invalid(L("公式区域没有落在当前页面内。"))
        }
        // PDFView selections use the original page coordinates. PDFKit draws
        // the page with the display box's origin and rotation already applied.
        let drawingBounds = clipped.applying(page.transform(for: .cropBox))
        let maxDimension = max(drawingBounds.width, drawingBounds.height)
        var scale = min(2.0, maxPixelEdge / maxDimension)
        var lastData: Data?
        while scale >= 0.25 {
            let width = max(1, Int(ceil(drawingBounds.width * scale)))
            let height = max(1, Int(ceil(drawingBounds.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PaperDeskError.invalid(L("无法创建公式区域图像。"))
            }
            context.interpolationQuality = .high
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            context.translateBy(x: -drawingBounds.minX * scale, y: -drawingBounds.minY * scale)
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
            guard let image = context.makeImage(), let data = pngData(image) else {
                throw PaperDeskError.invalid(L("无法编码公式区域图像。"))
            }
            lastData = data
            if data.count <= maxPNGBytes { return data }
            scale *= 0.75
        }
        if let lastData, lastData.count <= maxPNGBytes { return lastData }
        throw PaperDeskError.invalid(L("公式区域图像仍然过大，请缩小框选范围。"))
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
