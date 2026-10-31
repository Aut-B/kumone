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

    /// `.scrollIndicators(.never)` is iOS 16+; unlike `.hidden` it also
    /// applies when a mouse is connected (macOS).
    func compatScrollIndicatorsNever() -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.scrollIndicators(.never))
        }
        return AnyView(self)
    }

    /// `autocorrectionDisabled` is iOS 16+ / macOS 13+; older systems keep the
    /// default autocorrection behaviour for URL and account fields.
    func compatAutocorrectionDisabled() -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.autocorrectionDisabled())
        }
        return AnyView(self)
    }

    /// `navigationDestination(for:)` is iOS 16+ / macOS 13+. On iOS 15 the
    /// value-based link is replaced by one that carries its own destination, so
    /// this modifier is simply dropped.
    func compatNavigationDestination<Data: Hashable, Destination: View>(
        for type: Data.Type,
        @ViewBuilder destination: @escaping (Data) -> Destination
    ) -> AnyView {
        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(self.navigationDestination(for: type, destination: destination))
        }
        return AnyView(self)
    }
}

#if os(iOS)
extension View {
    /// `scrollDismissesKeyboard` is iOS 16+; on iOS 15 the search field keeps
    /// the default dismissal behaviour (tapping outside / scroll still works).
    func compatScrollDismissesKeyboardInteractively() -> AnyView {
        if #available(iOS 16.0, *) {
            return AnyView(self.scrollDismissesKeyboard(.interactively))
        }
        return AnyView(self)
    }
}
#endif

/// `ViewThatFits` is iOS 16+ / macOS 13+. On iOS 15 the wider arrangement is
/// used unconditionally — the same choice `ViewThatFits` makes on a phone in
/// portrait for every layout this app uses.
struct CompatViewThatFits<Wide: View, Narrow: View>: View {
    @ViewBuilder var wide: () -> Wide
    @ViewBuilder var narrow: () -> Narrow

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            ViewThatFits(in: .horizontal) { wide(); narrow() }
        } else {
            wide()
        }
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

// MARK: - Clock & lock fallbacks for iOS 15
//
// `ContinuousClock` and `OSAllocatedUnfairLock` are iOS 16+ / macOS 13+. The
// deployment target is iOS 15, so both are reimplemented with APIs present on
// every Apple platform: `Date` for the clock and `os_unfair_lock` (iOS 10 /
// macOS 10.12) for the lock. Call sites keep the same shape (`withLock`,
// `.milliseconds`, `Instant`), so behaviour is unchanged.

struct CompatInstant: Sendable, Hashable, Equatable, Comparable {
    let date: Date
    init() { self.date = Date() }
    static var now: CompatInstant { CompatInstant() }
    static func < (lhs: CompatInstant, rhs: CompatInstant) -> Bool { lhs.date < rhs.date }

    /// iOS 15 stand-in for `ContinuousClock.Instant.duration(to:)` (iOS 16+).
    /// Returns elapsed seconds as a `TimeInterval`, so call sites keep
    /// comparing against a plain second count (e.g. `>= 20`).
    func duration(to other: CompatInstant) -> TimeInterval {
        other.date.timeIntervalSince(self.date)
    }
}

struct CompatElapsed: Sendable {
    let milliseconds: Int
}

extension CompatInstant {
    static func - (lhs: CompatInstant, rhs: CompatInstant) -> CompatElapsed {
        CompatElapsed(milliseconds: Int((lhs.date.timeIntervalSince(rhs.date) * 1000).rounded()))
    }
}

enum CompatClock {
    static var now: CompatInstant { .now }
    typealias Instant = CompatInstant
}

/// Drop-in for `OSAllocatedUnfairLock`, backed by `os_unfair_lock`.
final class CompatUnfairLock<Value>: @unchecked Sendable {
    private var value: Value
    private var unfairLock = os_unfair_lock()

    init(initialState: Value) {
        self.value = initialState
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return try body(&value)
    }
}

/// `Animation.spring(duration:)` is iOS 17+; iOS 15/16 fall back to a plain
/// ease-in-out of the same duration, which reads nearly identically for these
/// short transitions.
func compatSpringAnimation(duration: Double) -> Animation {
    if #available(iOS 17.0, macOS 14.0, *) {
        return .spring(duration: duration)
    }
    return .easeInOut(duration: duration)
}

/// `Animation.spring(response:dampingFraction:)` is iOS 16+. On iOS 15 the
/// `dampingFraction` spring does not exist, so it is approximated with the
/// older `spring(response:blendDuration:)` (iOS 13+). The visual difference for
/// these short UI transitions is negligible.
extension Animation {
    static func compatSpring(response: Double, dampingFraction: Double) -> Animation {
        if #available(iOS 16.0, macOS 13.0, *) {
            return .spring(response: response, dampingFraction: dampingFraction)
        }
        return .spring(response: response, blendDuration: max(response * (1 - dampingFraction), 0.01))
    }
}

extension View {
    /// `.presentationBackground(.clear)` is iOS 16.4+; older systems show the
    /// default sheet background.
    func compatPresentationBackgroundClear() -> AnyView {
        if #available(iOS 16.4, macOS 13.0, *) {
            return AnyView(self.presentationBackground(.clear))
        }
        return AnyView(self)
    }

    /// `.presentationBackgroundInteraction(.enabled)` is iOS 16.4+.
    func compatPresentationBackgroundInteractionEnabled() -> AnyView {
        if #available(iOS 16.4, macOS 13.0, *) {
            return AnyView(self.presentationBackgroundInteraction(.enabled))
        }
        return AnyView(self)
    }
}
