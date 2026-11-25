import AppKit
import PDFKit
import SwiftUI
import PaperDeskCore

/// The PDFKit view is kept deliberately small: it owns display and selection,
/// while AppModel owns the durable reading state.
struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let document: PDFDocument?
    let searchSelection: PDFSelection?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PDFReaderContainer {
        let view = PDFReaderContainer(frame: .zero)
        let pdfView = view.pdfView
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.autoScales = false
        view.formulaCaptureEnabled = model.formulaCaptureMode
        view.onRegionCaptured = { [weak model] pageIndex, bounds, imageData in
            model?.captureRegion(pageIndex: pageIndex, bounds: bounds, imageData: imageData)
        }
        context.coordinator.attach(to: pdfView)
        if let document { pdfView.document = document }
        view.overlay.markedSelections = model.activeSelections
        view.overlay.citationMarks = model.activeCitationMarks
        view.setZoomMode(model.zoomMode)
        return view
    }

    func updateNSView(_ view: PDFReaderContainer, context: Context) {
        context.coordinator.model = model
        view.formulaCaptureEnabled = model.formulaCaptureMode
        let pdfView = view.pdfView
        if pdfView.document !== document {
            view.overlay.resetForNewDocument()
            pdfView.document = document
            // A new PDF can legitimately reuse the same page number. Reset
            // the request marker so the initial position is still applied.
            context.coordinator.lastNavigationSerial = nil
            context.coordinator.lastNavigationRegions = []
            context.coordinator.lastSearchSelection = nil
        }
        view.overlay.markedSelections = model.activeSelections
        view.overlay.citationMarks = model.activeCitationMarks
        view.setZoomMode(model.zoomMode)
        if let document,
           let request = model.navigationRequest,
           model.navigationSerial != context.coordinator.lastNavigationSerial,
           let page = document.page(at: request) {
            if let region = model.navigationRegions.first(where: { $0.pageIndex == request }) {
                pdfView.go(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height), on: page)
            } else if let region = model.restoredViewport {
                pdfView.go(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height), on: page)
            } else {
                pdfView.go(to: page)
            }
            view.showTransientRegions(model.navigationRegions, pageIndex: request)
            context.coordinator.lastNavigationSerial = model.navigationSerial
            context.coordinator.lastNavigationRegions = model.navigationRegions
        }
        if model.navigationRegions != context.coordinator.lastNavigationRegions {
            view.showTransientRegions(model.navigationRegions, pageIndex: model.currentPageIndex)
            context.coordinator.lastNavigationRegions = model.navigationRegions
        }
        if searchSelection !== context.coordinator.lastSearchSelection {
            context.coordinator.lastSearchSelection = searchSelection
            pdfView.highlightedSelections = searchSelection.map { [$0] } ?? []
            if let searchSelection { pdfView.go(to: searchSelection) }
        }
        context.coordinator.observeViewport()
    }

    final class Coordinator: NSObject {
        weak var model: AppModel?
        weak var view: PDFView?
        private var observers: [NSObjectProtocol] = []
        var lastNavigationSerial: Int?
        var lastNavigationRegions: [PageRegion] = []
        weak var lastSearchSelection: PDFSelection?
        private var selectionWorkItem: DispatchWorkItem?
        private var viewportWorkItem: DispatchWorkItem?
        private weak var clipView: NSClipView?
        private var viewportObserver: NSObjectProtocol?
        private var mouseUpMonitor: Any?

        init(model: AppModel) { self.model = model }

        func attach(to view: PDFView) {
            self.view = view
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: Notification.Name.PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self else { return }
                self.selectionWorkItem?.cancel()
                guard view?.currentSelection?.string?.isEmpty == false else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.scheduleSelection() }
            })
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak view] event in
                if let view, event.window === view.window, event.window != nil,
                   view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                   MainActor.assumeIsolated({ self?.model?.formulaCaptureMode == false }) {
                    self?.scheduleSelection()
                }
                return event
            }
            observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                self?.scheduleViewport()
            })
            observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    if let view { self?.model?.recordDisplayedPDFScale(view.scaleFactor) }
                    self?.scheduleViewport()
                }
            })
        }

        private func scheduleSelection() {
            selectionWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, let model = self.model,
                          let document = view.document, let selection = view.currentSelection else { return }
                    model.captureSelection(selection, document: document)
                }
            }
            selectionWorkItem = work
            DispatchQueue.main.async(execute: work)
        }

        func observeViewport() {
            guard let clip = view?.documentView?.enclosingScrollView?.contentView, clip !== clipView else { return }
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.scheduleViewport()
            }
            scheduleViewport()
        }

        private func scheduleViewport() {
            viewportWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, let model = self.model,
                          let document = view.document, model.document === document, let currentPage = view.currentPage else { return }
                    let visible = self.clipView.map { $0.convert($0.bounds, to: view).intersection(view.bounds) } ?? view.bounds
                    let regions = view.visiblePages.compactMap { page -> PageRegion? in
                        let bounds = view.convert(visible, to: page).intersection(page.bounds(for: .cropBox))
                        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
                        return PageRegion(pageIndex: document.index(for: page), x: bounds.minX, y: bounds.minY,
                                          width: bounds.width, height: bounds.height)
                    }
                    model.recordDisplayedPage(document.index(for: currentPage), visibleRegions: regions)
                }
            }
            viewportWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        deinit {
            selectionWorkItem?.cancel()
            viewportWorkItem?.cancel()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            if let viewportObserver { center.removeObserver(viewportObserver) }
            if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        }
    }
}
