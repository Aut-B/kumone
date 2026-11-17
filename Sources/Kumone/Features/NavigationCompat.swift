import SwiftUI

// MARK: - iOS 15 navigation fallbacks
//
// iPhone 6s stops at iOS 15, where `NavigationStack`, `NavigationLink(value:)`
// and `navigationDestination` do not exist. The same navigation is expressed
// with `NavigationView` plus destination-based links there: every
// `DestinationLink` builds `DestinationView` itself instead of relying on a
// value registered on the stack.

/// A stack that is a real `NavigationStack` on iOS 16+ and a `NavigationView`
/// on iOS 15.
struct AppNavStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content().appDestinations() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// Same as `AppNavStack`, for the roots that drive their stack from a path.
///
/// iOS 15 cannot bind a path, so the binding is simply unused there: pushes
/// come from the links themselves.
struct AppNavStackPath<Content: View>: View {
    @Binding var path: [Destination]
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) { content().appDestinations() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// A link to a `Destination`: value-based on iOS 16+, destination-based on
/// iOS 15.
struct DestinationLink<Label: View>: View {
    let value: Destination
    @ViewBuilder var label: () -> Label

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationLink(value: value) { label() }
        } else {
            NavigationLink { DestinationView(destination: value) } label: { label() }
        }
    }
}
