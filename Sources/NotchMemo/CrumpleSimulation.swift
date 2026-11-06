import Foundation
import simd

/// The folded paper surface, sampled at regular intervals of the crumple.
///
/// `frames[0]` is the flat sheet; the last frame is the settled paper ball.
/// Frames are precomputed once so the animation can simply interpolate between
/// them at display refresh rate.
struct CrumpleMesh {
    let aspect: Float
    let spacing: Float
    let rest: [SIMD3<Float>]
    let uvs: [SIMD2<Float>]
    let indices: [UInt32]
    let frames: [[SIMD3<Float>]]
    let incidentFaces: [[UInt32]]

    var vertexCount: Int { rest.count }
    var triangleCount: Int { indices.count / 3 }
}

/// Deterministic cloth-ish folding simulation adapted from the React Bits
/// "Paper Crumple" interaction: a jittered grid is pulled toward an ellipsoid
/// while edge and hinge constraints decide where the sheet buckles, leaving
/// hard creases instead of an even shrink.
enum CrumpleSimulation {
    private struct Edge {
        var a: UInt16
        var b: UInt16
        var rest: Float
    }

    private struct Hinge {
        var a: UInt16
        var b: UInt16
        var rest: Float
        var weight: Float
    }

    static func build(aspect: Float,
                      seed: UInt64 = 7,
                      detail: Int = 64,
                      frameCount: Int = 64,
                      stepsPerFrame: Int = 3) -> CrumpleMesh {
        let aspect = max(0.25, min(4, aspect))
        let resolution = max(8, min(24, detail / 4))
        let columns = max(8, Int((Float(resolution) / max(1, aspect)).rounded()))
        let rows = max(8, Int((Float(resolution) * min(1, aspect)).rounded()))
        let count = (columns + 1) * (rows + 1)
        let shortSide: Float = 1

        var rng = SplitMix64(state: seed &+ 0x9E37_79B9_7F4A_7C15)

        // Jitter the interior grid points so the folds do not line up with the
        // texture, while keeping the outer edge straight.
        var rest = [SIMD3<Float>](repeating: .zero, count: count)
        var uvs = [SIMD2<Float>](repeating: .zero, count: count)
        for row in 0...rows {
            for column in 0...columns {
                let index = row * (columns + 1) + column
                let jitterU = (column > 0 && column < columns) ? (rng.unit() - 0.5) * 0.5 : 0
                let jitterV = (row > 0 && row < rows) ? (rng.unit() - 0.5) * 0.5 : 0
                let u = (Float(column) + jitterU) / Float(columns)
                let v = (Float(row) + jitterV) / Float(rows)
                rest[index] = SIMD3<Float>(u - 0.5, (v - 0.5) * aspect, 0)
                uvs[index] = SIMD2<Float>(u, v)
            }
        }

        // Two triangles per cell; alternate the diagonal for an irregular mesh.
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row * (columns + 1) + column)
                let b = a + 1
                let c = a + UInt32(columns + 1)
                let d = c + 1
                if rng.unit() > 0.5 {
                    indices.append(contentsOf: [a, b, d, a, d, c])
                } else {
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }

        // Folding guides: six soft directions that bias where creases form.
        let guideCount = 6
        var guides: [(x: Float, y: Float, phase: Float, weight: Float)] = []
        for _ in 0..<guideCount {
            let angle = rng.unit() * .pi * 2
            guides.append((cos(angle), sin(angle), rng.unit() * .pi * 2,
                           0.4 + rng.unit() * 0.6))
        }

        var edges: [Edge] = []
        var hinges: [Hinge] = []
        var adjacency: [Int: (a: UInt16, b: UInt16, opposite: UInt16)] = [:]
        adjacency.reserveCapacity(indices.count)

        var triangle = 0
        while triangle < indices.count {
            for corner in 0..<3 {
                let a = indices[triangle + corner]
                let b = indices[triangle + (corner + 1) % 3]
                let opposite = indices[triangle + (corner + 2) % 3]
                let key = Int(min(a, b)) * count + Int(max(a, b))
                if let other = adjacency[key] {
                    let c = other.opposite
                    let d = opposite
                    let length = distance(rest[Int(c)], rest[Int(d)])
                    let mx = (rest[Int(c)].x + rest[Int(d)].x) * 0.5
                    let my = (rest[Int(c)].y + rest[Int(d)].y) * 0.5
                    var weakness: Float = 0
                    for guide in guides {
                        let phase = (mx * guide.x + my * guide.y) / shortSide * 4 + guide.phase
                        let offset = abs(sin(phase))
                        weakness = max(weakness, exp(-offset * offset * 80) * guide.weight)
                    }
                    hinges.append(Hinge(a: UInt16(c), b: UInt16(d), rest: length,
                                        weight: 0.12 + (1 - weakness) * 0.75))
                } else {
                    adjacency[key] = (UInt16(a), UInt16(b), UInt16(opposite))
                    edges.append(Edge(a: UInt16(a), b: UInt16(b),
                                      rest: distance(rest[Int(a)], rest[Int(b)])))
                }
            }
            triangle += 3
        }

        let spacing = sqrt(shortSide * shortSide / Float(count))
        let thickness = shortSide * 0.008
        let sharpness: Float = 0.6
        let depth: Float = 0.65

        var initialRadius: Float = 0
        for point in rest {
            initialRadius = max(initialRadius, hypot(point.x / 0.94, point.y / 1.02))
        }
        initialRadius *= 1.02
        let finalRadius = shortSide * (0.19 - depth * 0.025)

        // Candidate vertices for the layer-separation pass, resolved from the
        // rest layout once: only nearby points can end up inside a triangle.
        var candidates = [[UInt16]](repeating: [], count: indices.count / 3)
        var triangleIndex = 0
        while triangleIndex < indices.count {
            let a = Int(indices[triangleIndex])
            let b = Int(indices[triangleIndex + 1])
            let c = Int(indices[triangleIndex + 2])
            let centerX = (rest[a].x + rest[b].x + rest[c].x) / 3
            let centerY = (rest[a].y + rest[b].y + rest[c].y) / 3
            let limit = spacing * spacing * 6
            for pointIndex in 0..<count where pointIndex != a && pointIndex != b && pointIndex != c {
                let dx = rest[pointIndex].x - centerX
                let dy = rest[pointIndex].y - centerY
                if dx * dx + dy * dy < limit {
                    candidates[triangleIndex / 3].append(UInt16(pointIndex))
                }
            }
            triangleIndex += 3
        }

        var points = rest
        var previous = rest
        var before = rest
        var samples: [[SIMD3<Float>]] = [[SIMD3<Float>]](repeating: rest, count: frameCount + 1)
        let totalSteps = frameCount * stepsPerFrame

        for step in 1...totalSteps {
            let progress = Float(step) / Float(totalSteps)
            let compression = progress * progress * (3 - 2 * progress)
            let radius = initialRadius * (1 - compression) + finalRadius * compression

            before = points
            let velocityLimit = spacing * 0.15
            for index in points.indices {
                let x = points[index].x / shortSide
                let y = points[index].y / shortSide
                var buckle: Float = 0
                for guide in guides {
                    buckle += sin((x * guide.x + y * guide.y) * 5 + guide.phase) * guide.weight
                }
                var velocity = (points[index] - previous[index]) * 0.55
                velocity.x = min(velocityLimit, max(-velocityLimit, velocity.x))
                velocity.y = min(velocityLimit, max(-velocityLimit, velocity.y))
                velocity.z = min(velocityLimit, max(-velocityLimit, velocity.z))
                previous[index] = points[index]
                points[index] += velocity
                points[index].z += (buckle / Float(guideCount)) * shortSide * 0.0007
                    * sin(progress * .pi)
            }

            for pass in 0..<18 {
                constrainHinges(&points, hinges, stiffness: 0.45 * (1 - sharpness * 0.4),
                                reverse: pass % 2 == 0)
                for index in points.indices {
                    let x = points[index].x / 0.94
                    let y = points[index].y / 1.02
                    let z = points[index].z / 0.86
                    let length = sqrt(x * x + y * y + z * z)
                    if length > radius {
                        let push = (1 - radius / length) * 0.55
                        points[index] -= points[index] * push
                    }
                }
                constrainEdges(&points, edges, reverse: pass % 2 != 0)
                if pass == 8 || pass == 17 {
                    separateLayers(&points, previous: before, rest: rest,
                                   indices: indices, candidates: candidates,
                                   thickness: thickness, spacing: spacing)
                }
            }

            for hingeIndex in hinges.indices where distance(points[Int(hinges[hingeIndex].a)],
                                                             points[Int(hinges[hingeIndex].b)])
                < hinges[hingeIndex].rest * 0.86 {
                let length = distance(points[Int(hinges[hingeIndex].a)],
                                      points[Int(hinges[hingeIndex].b)])
                hinges[hingeIndex].rest += (length - hinges[hingeIndex].rest) * 0.12
            }

            if step % stepsPerFrame == 0 {
                samples[step / stepsPerFrame] = points
            }
        }

        var incident = [[UInt32]](repeating: [], count: count)
        for face in stride(from: 0, to: indices.count, by: 3) {
            for offset in 0..<3 {
                incident[Int(indices[face + offset])].append(UInt32(face / 3))
            }
        }

        return CrumpleMesh(aspect: aspect, spacing: spacing, rest: rest, uvs: uvs,
                           indices: indices, frames: samples, incidentFaces: incident)
    }

    private static func constrainEdges(_ points: inout [SIMD3<Float>],
                                       _ edges: [Edge],
                                       reverse: Bool) {
        for step in 0..<edges.count {
            let edge = edges[reverse ? edges.count - 1 - step : step]
            let a = Int(edge.a)
            let b = Int(edge.b)
            let delta = points[b] - points[a]
            let length = simd_length(delta)
            guard length > 0.000001 else { continue }
            let amount = (1 - edge.rest / length) * 0.5
            points[a] += delta * amount
            points[b] -= delta * amount
        }
    }

    private static func constrainHinges(_ points: inout [SIMD3<Float>],
                                        _ hinges: [Hinge],
                                        stiffness: Float,
                                        reverse: Bool) {
        for step in 0..<hinges.count {
            let hinge = hinges[reverse ? hinges.count - 1 - step : step]
            let a = Int(hinge.a)
            let b = Int(hinge.b)
            let delta = points[b] - points[a]
            let length = simd_length(delta)
            guard length > 0.000001 else { continue }
            let amount = (1 - hinge.rest / length) * 0.5 * stiffness * hinge.weight
            points[a] += delta * amount
            points[b] -= delta * amount
        }
    }

    /// Push nearby vertices out of each triangle so the folded layers keep a
    /// paper's thickness instead of z-fighting through each other.
    private static func separateLayers(_ points: inout [SIMD3<Float>],
                                       previous: [SIMD3<Float>],
                                       rest: [SIMD3<Float>],
                                       indices: [UInt32],
                                       candidates: [[UInt16]],
                                       thickness: Float,
                                       spacing: Float) {
        let margin = thickness * 2
        var triangle = 0
        while triangle < indices.count {
            let face = triangle / 3
            let a = Int(indices[triangle])
            let b = Int(indices[triangle + 1])
            let c = Int(indices[triangle + 2])
            let pa = points[a]
            let ab = points[b] - pa
            let ac = points[c] - pa
            var normal = simd_cross(ab, ac)
            let length = simd_length(normal)
            guard length > 0.0000001 else {
                triangle += 3
                continue
            }
            normal /= length

            let minX = min(pa.x, min(points[b].x, points[c].x)) - margin
            let maxX = max(pa.x, max(points[b].x, points[c].x)) + margin
            let minY = min(pa.y, min(points[b].y, points[c].y)) - margin
            let maxY = max(pa.y, max(points[b].y, points[c].y)) + margin
            let minZ = min(pa.z, min(points[b].z, points[c].z)) - margin
            let maxZ = max(pa.z, max(points[b].z, points[c].z)) + margin

            let bb = simd_dot(ab, ab)
            let cc = simd_dot(ac, ac)
            let bc = simd_dot(ab, ac)
            let determinant = bb * cc - bc * bc
            guard determinant > 0.0000000001 else {
                triangle += 3
                continue
            }

            for candidate in candidates[face] {
                let p = Int(candidate)
                let point = points[p]
                if point.x < minX || point.x > maxX
                    || point.y < minY || point.y > maxY
                    || point.z < minZ || point.z > maxZ { continue }
                let delta = point - pa
                let signedDistance = simd_dot(delta, normal)
                let previousDistance = simd_dot(previous[p] - previous[a], normal)
                let side: Float = previousDistance >= 0 ? 1 : -1
                if signedDistance * side >= thickness || abs(signedDistance) > margin { continue }
                let pb = simd_dot(delta, ab)
                let pc = simd_dot(delta, ac)
                let u = (cc * pb - bc * pc) / determinant
                let v = (bb * pc - bc * pb) / determinant
                if u < 0 || v < 0 || u + v > 1 { continue }
                let w = 1 - u - v
                let correction = (thickness * side - signedDistance) / (1 + w * w + u * u + v * v)
                let movement = normal * correction
                points[p] += movement
                points[a] -= movement * w
                points[b] -= movement * u
                points[c] -= movement * v
            }
            triangle += 3
        }
    }

    private static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(a - b)
    }
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
