import AppKit
import CoreText
import Foundation
import os
import SwiftUI

enum AppFonts {
    static let kemcoPixelBold = "KemcoPixelBold"

    private static let logger = Logger(subsystem: "works.earendil.pi-deck", category: "Fonts")

    /// No-op: product chrome uses system fonts; bundled pixel font is unused.
    static func registerBundledFonts() {}

    /// Prefer system UI fonts for product chrome (pixel display font retired).
    static func kemcoPixelBold(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    private static func registerFont(named name: String, extension ext: String) {
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: name, withExtension: ext)

        guard let url else {
#if DEBUG
            logger.warning("Bundled font \(name).\(ext) was not found.")
#endif
            return
        }

        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            if let error {
                let cfError = error.takeRetainedValue()
                if CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                    return
                }
#if DEBUG
                logger.warning("Bundled font \(name).\(ext) could not be registered: \(String(describing: cfError))")
#endif
            }
            return
        }
    }
}
