import AppKit
import MetalKit
import SwiftUI

final class MapCanvasView: MTKView {
    weak var mapRenderer: MapRenderer?
    private var lastDragPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            mapRenderer?.zoom(factor: 2, around: point)
        }
        lastDragPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let previous = lastDragPoint {
            mapRenderer?.pan(deltaX: point.x - previous.x, deltaY: point.y - previous.y)
        }
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
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
    @ObservedObject var viewport: ViewportController

    final class Coordinator {
        var renderer: MapRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MapCanvasView {
        let view = MapCanvasView(frame: .zero)
        context.coordinator.renderer = MapRenderer(view: view, manifest: manifest, viewport: viewport)
        return view
    }

    func updateNSView(_ view: MapCanvasView, context: Context) {
        context.coordinator.renderer?.update(
            manifest: manifest,
            dataDirectory: dataDirectory,
            style: style.renderStyle,
            fitToken: viewport.fitToken,
            referenceToken: viewport.referenceToken,
            reference: viewport.activeReference
        )
    }
}
