import SwiftUI

/// Visual paper curl only. The live paper keeps all of its original controls,
/// so scrollable content and text fields are never rasterised into a snapshot
/// (that made the middle of the note disappear for a frame while unfolding).
struct StickerPeelModifier: AnimatableModifier {
    var progress: CGFloat
    var reducedMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let flat = min(1, max(0, progress))
        if reducedMotion {
            content.opacity(flat)
        } else {
            GeometryReader { geometry in
                let size = geometry.size
                let peel = PaperPeelGeometry(height: size.height, progress: progress)
                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: size.width, height: size.height)
                        .mask(alignment: .top) {
                            Rectangle().frame(height: max(0, peel.fold))
                        }
                    Canvas { context, canvasSize in
                        drawCurl(context: context, size: canvasSize, progress: progress)
                    } symbols: {
                        backPaper
                            .frame(width: size.width, height: size.height)
                            .tag(1)
                    }
                    .allowsHitTesting(false)
                    .opacity(min(1, flat * 8))
                }
            }
            .rotationEffect(.degrees(Double(3 * (1 - progress))), anchor: .top)
            .shadow(color: .black.opacity(0.18), radius: 11, x: 0, y: 6)
        }
    }

    private var backPaper: some View {
        RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.95, green: 0.93, blue: 0.86),
                         Color(red: 0.86, green: 0.83, blue: 0.74)],
                startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 0.75)
            }
    }

    /// Draws only the curled edge and the folded-back paper. The printed face
    /// stays the live content above the fold, so nothing in it can blink.
    private func drawCurl(context: GraphicsContext, size: CGSize, progress: CGFloat) {
        guard size.width > 0, size.height > 0,
              let back = context.resolveSymbol(id: 1) else { return }
        let geometry = PaperPeelGeometry(height: size.height, progress: progress)
        guard geometry.radius > 0.0001 else { return }
        var context = context
        context.clip(to: Path(CGRect(origin: .zero, size: size)))

        let rollEnd = min(size.height, geometry.fold + .pi * geometry.radius)
        let extent = max(0, rollEnd - geometry.fold)
        let strips = max(1, Int(ceil(extent)))
        for index in 0..<strips {
            let y0 = geometry.fold + extent * CGFloat(index) / CGFloat(strips)
            let y1 = geometry.fold + extent * CGFloat(index + 1) / CGFloat(strips)
            drawBand(from: y0, to: y1, geometry: geometry, size: size, back: back, context: context)
        }
        if rollEnd < size.height {
            drawBand(from: rollEnd, to: size.height, geometry: geometry, size: size,
                     back: back, context: context)
        }
    }

    private func drawBand(from y0: CGFloat, to y1: CGFloat, geometry: PaperPeelGeometry,
                          size: CGSize, back: GraphicsContext.ResolvedSymbol,
                          context: GraphicsContext) {
        guard y1 > y0 else { return }
        let start = geometry.sample(y0)
        let end = geometry.sample(y1)
        let middle = geometry.sample((y0 + y1) / 2)
        let top = min(start.y, end.y)
        let height = abs(end.y - start.y)
        guard height > 0.001, top < size.height, top + height > 0 else { return }
        let widthScale = 1 - middle.depth / 1800
        let width = size.width * widthScale
        let left = (size.width - width) / 2
        let rect = CGRect(x: left, y: top - 0.3, width: width, height: height + 0.6)

        if middle.normal >= 0 {
            // Front of the sheet: a plain paper lip. Text stays live above it.
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(red: 0.98, green: 0.965, blue: 0.925),
                                  Color(red: 0.945, green: 0.925, blue: 0.875)]),
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)))
        } else {
            var band = context
            band.clip(to: Path(rect))
            band.translateBy(x: left, y: start.y)
            band.scaleBy(x: widthScale, y: (end.y - start.y) / (y1 - y0))
            band.translateBy(x: 0, y: -y0)
            band.draw(back, at: .zero, anchor: .topLeading)
        }

        // Small moving light/dark bands describe the bend.
        if middle.depth > 0.01 {
            let darkness = (1 - abs(middle.normal)) * 0.16
            var shading = context
            shading.clip(to: Path(rect))
            shading.fill(Path(rect), with: .color(.black.opacity(Double(darkness))))
            if middle.normal > 0.15 {
                shading.fill(Path(rect), with: .color(.white.opacity(Double((1 - middle.normal) * 0.14))))
            }
        }
    }
}
