import CryptoKit
import Foundation

/// XEP-0392 consistent color generation.
public enum ConsistentColor {
    /// The hue angle in degrees, from 0 up to but excluding 360.
    public static func hue(for identifier: String) -> Double {
        let digest = Insecure.SHA1.hash(data: Data(identifier.utf8))
        var iterator = digest.makeIterator()
        let low = UInt16(iterator.next() ?? 0)
        let high = UInt16(iterator.next() ?? 0)
        let value = low | (high << 8)
        return Double(value) / 65536.0 * 360.0
    }

    /// Saturation and lightness are 0...1. The result is sRGB, each channel 0...1.
    public static func color(
        for identifier: String,
        saturation: Double = 1.0,
        lightness: Double = 0.5
    ) -> (r: Double, g: Double, b: Double) {
        let angle = hue(for: identifier)
        let s = min(max(saturation, 0), 1) * 100
        let l = min(max(lightness, 0), 1) * 100
        let rgb = HSLuv.toRGB(h: angle, s: s, l: l)
        return (rgb.r, rgb.g, rgb.b)
    }
}

/// HSLuv to sRGB, ported from the published HSLuv reference algorithm
/// (https://www.hsluv.org/, MIT license).
enum HSLuv {
    private static let m: [[Double]] = [
        [3.240969941904521, -1.537383177570093, -0.498610760293],
        [-0.96924363628087, 1.87596750150772, 0.041555057407175],
        [0.055630079696993, -0.20397695888897, 1.056971514242878],
    ]
    private static let refU = 0.19783000664283
    private static let refV = 0.46831999493879
    private static let kappa = 903.2962962
    private static let epsilon = 0.0088564516

    static func toRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let lch = hsluvToLch(h: h, s: s, l: l)
        let luv = lchToLuv(lch)
        let xyz = luvToXyz(luv)
        return xyzToRgb(xyz)
    }

    private static func bounds(forLightness l: Double) -> [(slope: Double, intercept: Double)] {
        var result: [(Double, Double)] = []
        let sub1 = pow(l + 16, 3) / 1_560_896
        let sub2 = sub1 > epsilon ? sub1 : l / kappa
        for row in m {
            for t in [0.0, 1.0] {
                let top1 = (284_517 * row[0] - 94_839 * row[2]) * sub2
                let top2 =
                    (838_422 * row[2] + 769_860 * row[1] + 731_718 * row[0]) * l * sub2 - 769_860
                    * t * l
                let bottom = (632_260 * row[2] - 126_452 * row[1]) * sub2 + 126_452 * t
                result.append((top1 / bottom, top2 / bottom))
            }
        }
        return result
    }

    private static func maxChroma(lightness l: Double, hue h: Double) -> Double {
        let hrad = h / 360 * 2 * Double.pi
        var minLength = Double.greatestFiniteMagnitude
        for line in bounds(forLightness: l) {
            let length = line.intercept / (sin(hrad) - line.slope * cos(hrad))
            if length >= 0 { minLength = min(minLength, length) }
        }
        return minLength
    }

    private static func hsluvToLch(h: Double, s: Double, l: Double) -> (
        l: Double, c: Double, h: Double
    ) {
        if l > 99.9999999 { return (100, 0, h) }
        if l < 0.00000001 { return (0, 0, h) }
        return (l, maxChroma(lightness: l, hue: h) / 100 * s, h)
    }

    private static func lchToLuv(_ lch: (l: Double, c: Double, h: Double)) -> (
        l: Double, u: Double, v: Double
    ) {
        let hrad = lch.h / 360 * 2 * Double.pi
        return (lch.l, cos(hrad) * lch.c, sin(hrad) * lch.c)
    }

    private static func lToY(_ l: Double) -> Double {
        l <= 8 ? l / kappa : pow((l + 16) / 116, 3)
    }

    private static func luvToXyz(_ luv: (l: Double, u: Double, v: Double)) -> (
        x: Double, y: Double, z: Double
    ) {
        if luv.l == 0 { return (0, 0, 0) }
        let varU = luv.u / (13 * luv.l) + refU
        let varV = luv.v / (13 * luv.l) + refV
        let y = lToY(luv.l)
        let x = 0 - (9 * y * varU) / ((varU - 4) * varV - varU * varV)
        let z = (9 * y - 15 * varV * y - varV * x) / (3 * varV)
        return (x, y, z)
    }

    private static func fromLinear(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func xyzToRgb(_ xyz: (x: Double, y: Double, z: Double)) -> (
        r: Double, g: Double, b: Double
    ) {
        func channel(_ row: [Double]) -> Double {
            min(max(fromLinear(row[0] * xyz.x + row[1] * xyz.y + row[2] * xyz.z), 0), 1)
        }
        return (channel(m[0]), channel(m[1]), channel(m[2]))
    }
}
