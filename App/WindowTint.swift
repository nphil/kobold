import SwiftUI
import UIKit

/// Paints the window the app sits in.
///
/// Presenting a sheet does not just slide something up. iOS scales the
/// presenting screen back, rounds its corners and slides it down a little, and
/// what shows in the gap that opens is the **window** — which is black unless
/// something says otherwise. On a themed dark app that gap reads as a hole
/// punched behind the interface rather than as depth, and it is most obvious in
/// the moment the animation is at its widest.
///
/// Nothing in SwiftUI reaches the window, so this does: an empty representable
/// that walks to its own window once it has one and tints it. It draws nothing
/// and takes no touches.
///
/// The tint is deferred to the next run loop turn deliberately — a view is not
/// in a window during its first `updateUIView`, so setting it synchronously
/// would silently do nothing on launch and work on every subsequent theme
/// change, which is the sort of bug that looks like a race because it is one.
struct WindowTint: UIViewRepresentable {
    let color: Color

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let resolved = UIColor(color)
        DispatchQueue.main.async {
            view.window?.backgroundColor = resolved
        }
    }
}

extension View {
    /// Tints the window behind the whole app, so a sheet presentation opens
    /// onto the theme rather than onto black.
    func windowTint(_ color: Color) -> some View {
        background(WindowTint(color: color).allowsHitTesting(false))
    }
}
