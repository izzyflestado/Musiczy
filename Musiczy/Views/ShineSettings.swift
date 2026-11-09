import Foundation

extension SettingsKey {
    static let ambientSaturation = "ambientSaturation"
    static let ambientSize = "ambientSize"
    static let shineLength = "shineLength"
    static let shineSpeed = "shineSpeed"
}

/// Default and range of each slider. Change the numbers here.
enum ShineDefault {
    // Ambient light
    static let saturation: Double = 1.3
    static let saturationRange: ClosedRange<Double> = 0...2
    static let size: Double = 1.0                    // 1 = the size in ShineStyle
    static let sizeRange: ClosedRange<Double> = 0.1...2

    // Shine (the white highlight)
    static let length: Double = ShineStyle.sweepLength   // fraction of the border it covers
    static let lengthRange: ClosedRange<Double> = 0.05...0.6
    static let speed: Double = 1.0                   // 1 = one lap in ShineStyle.sweepSeconds
    static let speedRange: ClosedRange<Double> = 0.25...3
}
