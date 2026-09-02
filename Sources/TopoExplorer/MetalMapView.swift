import AppKit
import MetalKit
import SwiftUI

final class MapCanvasView: MTKView {
    weak var mapRenderer: MapRenderer?
    var analysisMode = false {
        didSet { if analysisMode != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var profileMode = false {
        didSet { if profileMode != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var lastDragPoint: CGPoint?
    private var mouseDownPoint: CGPoint?
    private var mouseDownClickCount = 0
    private var didDrag = false
    private var pointerTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.mapRenderer?.viewBecameVisible()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        mapRenderer?.inspect(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        mapRenderer?.clearInspection()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if analysisMode {
            lastDragPoint = nil
            mouseDownPoint = nil
            mapRenderer?.beginAreaSelection(at: point)
            return
        }
        if profileMode {
            lastDragPoint = nil
            mouseDownPoint = nil
            mapRenderer?.beginProfileSelection(at: point)
            return
        }
        mouseDownPoint = point
        mouseDownClickCount = event.clickCount
        didDrag = false
        if event.clickCount == 2 {
            mapRenderer?.zoom(factor: 2, around: point)
        }
        lastDragPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if analysisMode {
            mapRenderer?.updateAreaSelection(to: point)
            return
        }
        if profileMode {
            mapRenderer?.updateProfileSelection(to: point)
            return
        }
        if let previous = lastDragPoint {
            if let mouseDownPoint,
               hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 3
            {
                didDrag = true
            }
            mapRenderer?.pan(deltaX: point.x - previous.x, deltaY: point.y - previous.y)
        }
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        if analysisMode {
            mapRenderer?.finishAreaSelection(at: convert(event.locationInWindow, from: nil))
        } else if profileMode {
            mapRenderer?.finishProfileSelection(at: convert(event.locationInWindow, from: nil))
        } else if !didDrag, mouseDownClickCount == 1, let mouseDownPoint {
            mapRenderer?.pinInspection(at: mouseDownPoint)
        }
        lastDragPoint = nil
        mouseDownPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: analysisMode || profileMode ? .crosshair : .openHand)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.08
        mapRenderer?.zoom(factor: exp(Double(event.scrollingDeltaY) * sensitivity), around: point)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mapRenderer?.zoom(factor: max(0.1, 1 + Double(event.magnification)), around: point)
    }

    override func keyDown(with event: NSEvent) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch event.charactersIgnoringModifiers {
        case "0": mapRenderer?.forceFit()
        case "+", "=": mapRenderer?.zoom(factor: 1.5, around: center)
        case "-", "_": mapRenderer?.zoom(factor: 1 / 1.5, around: center)
        default: super.keyDown(with: event)
        }
    }
}

struct MetalMapView: NSViewRepresentable {
    let manifest: MapManifest
    let dataDirectory: URL
    @ObservedObject var style: StyleSettings
    @ObservedObject var layers: LayerSettings
    @ObservedObject var comparison: ComparisonSettings
    @ObservedObject var geoScience: GeoScienceSettings
    @ObservedObject var export: MapExportController
    @ObservedObject var viewport: ViewportController
    let analysisMode: Bool
    let profileMode: Bool
    let reduceMotion: Bool

    final class Coordinator {
        var renderer: MapRenderer?
        var lastExportID = -1
        var lastLandscapeContextRequestToken = -1
        var lastPinnedThematicProductID: String?
        var lastPinnedLandcoverMode = -1
        var lastAnalysisMode = false
        var lastProfileMode = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MapCanvasView {
        let view = MapCanvasView(frame: .zero)
        context.coordinator.renderer = MapRenderer(view: view, manifest: manifest, viewport: viewport)
        return view
    }

    func updateNSView(_ view: MapCanvasView, context: Context) {
        view.analysisMode = analysisMode
        view.profileMode = profileMode
        if context.coordinator.lastAnalysisMode && !analysisMode {
            context.coordinator.renderer?.cancelAreaSelection()
        }
        context.coordinator.lastAnalysisMode = analysisMode
        if context.coordinator.lastProfileMode && !profileMode {
            context.coordinator.renderer?.cancelProfileSelection()
        }
        context.coordinator.lastProfileMode = profileMode
        context.coordinator.renderer?.update(
            manifest: manifest,
            dataDirectory: dataDirectory,
            style: style.renderStyle,
            layers: layers.renderLayers,
            comparison: comparison.renderComparison,
            geoScience: geoScience.renderOptions(in: manifest),
            fitToken: viewport.fitToken,
            navigationToken: viewport.navigationToken,
            target: viewport.target,
            reduceMotion: reduceMotion
        )
        let pinnedInputsChanged = context.coordinator.lastPinnedThematicProductID
                != geoScience.selectedRasterID
            || context.coordinator.lastPinnedLandcoverMode != comparison.mode.rawValue
        context.coordinator.lastPinnedThematicProductID = geoScience.selectedRasterID
        context.coordinator.lastPinnedLandcoverMode = comparison.mode.rawValue
        if pinnedInputsChanged, let probe = viewport.pinnedProbe {
            context.coordinator.lastLandscapeContextRequestToken = viewport.landscapeContextRequestToken
            context.coordinator.renderer?.cancelLandscapeContextQuery()
            context.coordinator.renderer?.refreshPinnedInspection(probe)
        } else if viewport.landscapeContextRequestToken
            != context.coordinator.lastLandscapeContextRequestToken
        {
            context.coordinator.lastLandscapeContextRequestToken = viewport.landscapeContextRequestToken
            if let probe = viewport.pinnedProbe {
                context.coordinator.renderer?.queryLandscapeContext(
                    around: probe, radiusMeters: viewport.landscapeContextRadius
                )
            } else {
                context.coordinator.renderer?.cancelLandscapeContextQuery()
            }
        }
        if let request = export.request, request.id != context.coordinator.lastExportID {
            context.coordinator.lastExportID = request.id
            context.coordinator.renderer?.export(request) { result in
                export.finish(result)
            }
        }
    }
}
