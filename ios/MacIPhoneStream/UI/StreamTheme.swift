import UIKit

/// Shared colors for the connection screen, device management, and scanner.
enum StreamTheme {
    static let accent = UIColor(red: 57.0 / 255, green: 210.0 / 255, blue: 247.0 / 255, alpha: 1)
    static let background = UIColor(white: 0.075, alpha: 1)
    static let surface = UIColor(white: 0.14, alpha: 1)
    static let accentSurface = accent.withAlphaComponent(0.14)
    static let selectedForeground = UIColor.black
}
