import Testing

@testable import XippiSession

@Suite("ConsistentColor")
struct ConsistentColorTests {
    // XEP-0392 section 13.1: text, angle, r, g, b at saturation 100 and lightness 50.
    static let vectors: [(text: String, angle: Double, r: Double, g: Double, b: Double)] = [
        ("Romeo", 327.255249, 0.865, 0.000, 0.686),
        ("juliet@capulet.lit", 209.410400, 0.000, 0.515, 0.573),
        ("😺", 331.199341, 0.872, 0.000, 0.659),
        ("council", 359.994507, 0.918, 0.000, 0.394),
        ("Board", 171.430664, 0.000, 0.527, 0.457),
    ]

    @Test("angle matches every test vector", arguments: vectors)
    func angle(vector: (text: String, angle: Double, r: Double, g: Double, b: Double)) {
        #expect(abs(ConsistentColor.hue(for: vector.text) - vector.angle) < 0.0001)
    }

    @Test("rgb matches every test vector", arguments: vectors)
    func rgb(vector: (text: String, angle: Double, r: Double, g: Double, b: Double)) {
        let color = ConsistentColor.color(for: vector.text)
        #expect(abs(color.r - vector.r) < 0.001)
        #expect(abs(color.g - vector.g) < 0.001)
        #expect(abs(color.b - vector.b) < 0.001)
    }

    @Test func channelsStayInRange() {
        for name in ["a", "b", "carla", "x@y.z", "🙂"] {
            for lightness in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let c = ConsistentColor.color(for: name, saturation: 1, lightness: lightness)
                for channel in [c.r, c.g, c.b] { #expect((0.0...1.0).contains(channel)) }
            }
        }
    }
}
