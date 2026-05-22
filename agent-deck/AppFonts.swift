import AppKit
import CoreText
import Foundation
import os
import SwiftUI

enum AppFonts {
    static let kemcoPixelBold = "KemcoPixelBold"

    private static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "Fonts")

    static func registerBundledFonts() {
        // Idempotent: if the font already resolves — registered earlier this
        // launch, or installed in the user's Font Book — skip. Re-registering an
        // already-registered URL trips a CoreText bug: CTFontManagerRegisterFontsForURL
        // builds its "already registered" CFError with a nil NSLocalizedFailureReason
        // and the NSDictionary insert throws NSInvalidArgumentException — a hard crash
        // the exception unwinds before our `alreadyRegistered` guard can run.
        guard NSFont(name: kemcoPixelBold, size: 1) == nil else { return }
        registerFont(named: "Kemco Pixel Bold", extension: "ttf")
    }

    static func kemcoPixelBold(size: CGFloat) -> Font {
        if let font = NSFont(name: kemcoPixelBold, size: size) {
            return Font(font)
        }
        return .system(size: size, weight: .bold)
    }

    private static func registerFont(named name: String, extension ext: String) {
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: name, withExtension: ext)

        guard let url else {
            logger.warning("Bundled font \(name).\(ext) was not found.")
            return
        }

        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            if let error {
                let cfError = error.takeRetainedValue()
                if CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                    return
                }
                logger.warning("Bundled font \(name).\(ext) could not be registered: \(String(describing: cfError))")
            }
            return
        }
    }
}
