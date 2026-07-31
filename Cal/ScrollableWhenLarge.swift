import SwiftUI

/// Lets a fixed-height empty state scroll once the text outgrows the screen.
///
/// `ContentUnavailableView` centres its content in the available space and does
/// not scroll. That is fine at default text sizes and clips at the accessibility
/// ones — Apple's own audit reports it as "Text clipped", and the longer the
/// explanation the worse it gets. The Planner's calendar-permission copy is three
/// lines at default and does not fit at all at AX5.
///
/// Wrapping in a `ScrollView` costs nothing when the content already fits: the
/// `minHeight` keeps it vertically centred exactly as before, and the scroll only
/// engages once there is something to scroll to.
struct ScrollableWhenLarge<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

extension View {
    /// See `ScrollableWhenLarge`.
    func scrollableWhenLarge() -> some View {
        ScrollableWhenLarge { self }
    }
}
