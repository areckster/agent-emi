import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

enum VectorMath {
    static func normalize(_ vectors: inout [[Float]]) {
        for index in vectors.indices {
            normalize(&vectors[index])
        }
    }

    static func normalize(_ vector: inout [Float]) {
        let norm = sqrt(vector.reduce(0) { $0 + Double($1 * $1) })
        if norm > .ulpOfOne {
            let scale = Float(1.0 / norm)
            for i in vector.indices {
                vector[i] *= scale
            }
        }
    }

    static func dotProducts(between query: [Float], and matrix: [[Float]]) -> [Float] {
        guard !matrix.isEmpty else { return [] }
        let count = matrix.count
        let dimension = query.count
        var results = [Float](repeating: 0, count: count)
#if canImport(Accelerate)
        var flattened: [Float] = []
        flattened.reserveCapacity(count * dimension)
        for row in matrix {
            flattened.append(contentsOf: row)
        }
        var queryCopy = query
        results.withUnsafeMutableBufferPointer { resultBuffer in
            flattened.withUnsafeBufferPointer { matrixPointer in
                queryCopy.withUnsafeMutableBufferPointer { queryPointer in
                    cblas_sgemv(
                        CblasRowMajor,
                        CblasNoTrans,
                        Int32(count),
                        Int32(dimension),
                        1.0,
                        matrixPointer.baseAddress,
                        Int32(dimension),
                        queryPointer.baseAddress,
                        1,
                        0.0,
                        resultBuffer.baseAddress,
                        1
                    )
                }
            }
        }
#else
        for rowIndex in 0..<count {
            let row = matrix[rowIndex]
            var sum: Float = 0
            for column in 0..<dimension {
                sum += row[column] * query[column]
            }
            results[rowIndex] = sum
        }
#endif
        return results
    }
}
