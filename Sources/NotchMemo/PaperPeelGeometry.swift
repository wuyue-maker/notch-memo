import CoreGraphics
import Foundation

/// A flat sheet followed by a cylindrical bend and its folded paper back.
/// Only the moving bend is subdivided; the flat regions are drawn once.
struct PaperPeelGeometry {
    struct Sample {
        let y: CGFloat
        let depth: CGFloat
        let normal: CGFloat
    }

    let height: CGFloat
    let fold: CGFloat
    let radius: CGFloat

    init(height: CGFloat, progress: CGFloat) {
        self.height = max(0, height)
        let flat = min(1, max(0, progress))
        fold = self.height * flat
        radius = min(32, self.height * 0.12) * min(1, (1 - flat) * 10)
    }

    func sample(_ sourceY: CGFloat) -> Sample {
        guard radius > 0.0001, sourceY > fold else {
            return Sample(y: sourceY, depth: 0, normal: 1)
        }
        let distance = sourceY - fold
        let angle = distance / radius
        if angle < .pi {
            return Sample(y: fold + radius * sin(angle),
                          depth: radius * (1 - cos(angle)), normal: cos(angle))
        }
        return Sample(y: fold - (distance - .pi * radius), depth: 2 * radius, normal: -1)
    }
}
