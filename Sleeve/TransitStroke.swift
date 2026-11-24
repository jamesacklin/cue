import SceneKit

/// A batched, face-on ribbon. Each input path is independent and keeps its exact endpoints.
struct TransitStroke {
    typealias Point = SIMD3<Float>
    private var vertices: [SCNVector3] = []
    private var indices: [UInt32] = []
    private var centerIndices: [UInt32] = []

    mutating func append(_ corners: [Point], width: Float, bend: Float) {
        var points: [Point] = []
        for point in corners {
            if let last = points.last, simd_distance(last, point) < 0.0001 { continue }
            points.append(point)
        }
        guard points.count >= 2 else { return }
        var samples = [points[0]]
        for i in 1..<(points.count - 1) {
            let turn = points[i]
            let incoming = points[i - 1] - turn
            let outgoing = points[i + 1] - turn
            let trim = min(bend, simd_length(incoming) * 0.45, simd_length(outgoing) * 0.45)
            let a = turn + simd_normalize(incoming) * trim
            let b = turn + simd_normalize(outgoing) * trim
            samples.append(a)
            for step in 1...6 {
                let t = Float(step) / 6
                samples.append((1 - t) * (1 - t) * a + 2 * (1 - t) * t * turn + t * t * b)
            }
        }
        samples.append(points[points.count - 1])
        for i in samples.indices {
            let tangent = samples[min(i + 1, samples.count - 1)] - samples[max(0, i - 1)]
            let side = Point(-tangent.y, tangent.x, 0)
            let offset = side * (width * 0.5 / max(simd_length(side), 0.0001))
            let base = UInt32(vertices.count)
            vertices.append(SCNVector3(samples[i] - offset))
            vertices.append(SCNVector3(samples[i] + offset))
            vertices.append(SCNVector3(samples[i]))
            if i > 0 {
                indices += [base - 3, base - 2, base, base, base - 2, base + 1]
                centerIndices += [base - 1, base + 2]
            }
        }
    }

    func geometry() -> SCNGeometry {
        // The centerline keeps distant routes visible when the ribbon becomes subpixel.
        let surface = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let center = SCNGeometryElement(indices: centerIndices, primitiveType: .line)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [surface, center])
    }

    /// Cross between years in the aisle below the destination jackets. Change depth
    /// during the lateral run and make both approaches in the station's own plane.
    static func transfer(from a: Point, to b: Point) -> [Point] {
        if abs(a.y - b.y) < 0.01 {
            return [a, a - [0,0.44,0], b - [0,0.44,0], b]
        }
        let side: Float = b.x < a.x ? -1.15 : 1.15
        let aisle = b.y - 0.65
        return [a, a + [side,0,0], [a.x + side,aisle,a.z],
                [b.x,aisle,b.z], b]
    }
}
