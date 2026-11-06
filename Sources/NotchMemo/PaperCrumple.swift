import AppKit
import MetalKit
import SwiftUI

/// A one-shot crumple used when the last task is checked off. The frozen note
/// folds into a paper ball and clears away while the fresh note fades in.
struct PaperCrumpleView: View {
    private let image: NSImage
    private let onFinish: () -> Void

    init(image: NSImage, onFinish: @escaping () -> Void = {}) {
        self.image = image
        self.onFinish = onFinish
    }

    var body: some View {
        CrumpleRepresentable(image: image, onFinish: onFinish)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Heats up the Metal pipeline at launch so the first crumple has no hitch.
enum PaperCrumpleWarmup {
    static func prepare() {
        CrumpleScene.warmUp()
    }
}

private struct CrumpleRepresentable: NSViewRepresentable {
    let image: NSImage
    let onFinish: () -> Void

    func makeNSView(context: Context) -> NSView {
        if let view = CrumpleMetalView(image: image, onFinish: onFinish) { return view }
        let fallback = NSImageView()
        fallback.image = image
        fallback.imageScaling = .scaleProportionallyUpOrDown
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CrumpleMetalView: MTKView {
    private let scene: CrumpleScene?

    init?(image: NSImage, onFinish: @escaping () -> Void) {
        guard let device = CrumpleScene.metalDevice,
              let scene = CrumpleScene(image: image) else { return nil }
        scene.onFinish = onFinish
        self.scene = scene
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        clearDepth = 1
        layer?.isOpaque = false
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        delegate = scene
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // CAMetalLayer defaults to opaque; without this the desktop behind the
        // panel turns black wherever the paper has already crumpled away.
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        (layer as? CAMetalLayer)?.isOpaque = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
