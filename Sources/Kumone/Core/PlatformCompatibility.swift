#if os(macOS)
import AppKit
import SwiftUI

public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformView = NSView
public typealias PlatformFont = NSFont
public typealias PlatformViewRepresentable = NSViewRepresentable

public extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

public extension PlatformImage {
    /// Renders the image into a circle of the given point diameter.
    func circularCropped(diameter: CGFloat) -> PlatformImage {
        let target = NSImage(size: NSSize(width: diameter, height: diameter))
        target.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).addClip()
        let sourceAspect = size.width / max(size.height, 1)
        var drawRect = rect
        if sourceAspect > 1 {
            drawRect.size.width = diameter * sourceAspect
            drawRect.origin.x = -(drawRect.width - diameter) / 2
        } else if sourceAspect < 1 {
            drawRect.size.height = diameter / sourceAspect
            drawRect.origin.y = -(drawRect.height - diameter) / 2
        }
        draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        target.unlockFocus()
        return target
    }

    var cgImageRef: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

public enum Platform {
    public static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static func copyToPasteboard(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    public static var windowBackgroundColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

#elseif os(iOS)
import UIKit
import SwiftUI

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformView = UIView
public typealias PlatformFont = UIFont
public typealias PlatformViewRepresentable = UIViewRepresentable

public extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

public extension PlatformImage {
    /// Renders the image into a circle of the given point diameter.
    func circularCropped(diameter: CGFloat) -> PlatformImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            let sourceAspect = self.size.width / max(self.size.height, 1)
            var drawRect = rect
            if sourceAspect > 1 {
                drawRect.size.width = diameter * sourceAspect
                drawRect.origin.x = -(drawRect.width - diameter) / 2
            } else if sourceAspect < 1 {
                drawRect.size.height = diameter / sourceAspect
                drawRect.origin.y = -(drawRect.height - diameter) / 2
            }
            self.draw(in: drawRect)
        }
    }

    var cgImageRef: CGImage? {
        cgImage
    }
}

public enum Platform {
    public static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    public static func copyToPasteboard(string: String) {
        UIPasteboard.general.string = string
    }

    public static var windowBackgroundColor: Color {
        Color(uiColor: .systemBackground)
    }
}
#endif

extension View {
    /// Suppress the system focus ring on a decorative button (e.g. the album
    /// artwork that opens the now-playing page / album). macOS 27 draws the
    /// blue focus ring on these far more eagerly, which read as a stray border
    /// on the artwork (#97). No-op on OS versions without the modifier.
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

// MARK: - iOS 15 fallbacks
//
// The deployment target is iOS 15 (iPhone 6s can go no further), so every
// modifier below is gated: the modern API runs where it exists, older systems
// fall back to plain behaviour.

extension View {
    ///  is iOS 17+; older systems swap the content without
    /// the cross-fade.
    func compatContentTransitionOpacity() -> AnyView {
        if #available(iOS 17.0, macOS 14.0, *) {
            return AnyView(self.contentTransition(.opacity))
        }
        return AnyView(self)
    }

    ///  is iOS 16+.
    func compatPresentationDetentsHeight(_ height: CGFloat) -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.presentationDetents([.height(height)]))
        }
        return AnyView(self)
    }

    func compatPresentationDetentsFraction(_ fraction: Double) -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.presentationDetents([.fraction(fraction)]))
        }
        return AnyView(self)
    }

    ///  is iOS 16+; iOS 15 forms are grouped anyway.
    func compatFormGrouped() -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.formStyle(.grouped))
        }
        return AnyView(self)
    }

    ///  is iOS 16+.
    func compatHiddenScrollContentBackground() -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.scrollContentBackground(.hidden))
        }
        return AnyView(self)
    }
}

/// mm:ss for a millisecond value —  formatting is iOS 16+.
enum CompatDuration {
    static func mmss(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "--:--" }
        let total = milliseconds / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
