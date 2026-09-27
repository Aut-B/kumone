import SwiftUI

/// The floating toast.
///
/// It used to live in `MainWindow.swift`, but that file is compiled for macOS
/// only now (its sidebar layout needs `NavigationSplitView`, which iOS 15
/// cannot build), and iOS shows toasts too.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .compatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
