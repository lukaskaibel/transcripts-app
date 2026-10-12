#if os(iOS)
import SwiftUI

extension View {
    /// The Mac's dropdown panel, on iPhone and iPad: a sheet on the iPhone, a popover beside the control on the iPad.
    /// The content is the same view the Mac shows, so a change to it shows everywhere; it says itself how tall its
    /// sheet starts (a picker at half the screen, the composer at full height).
    func dropdown<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content
    ) -> some View {
        popover(isPresented: isPresented) {
            content { isPresented.wrappedValue = false }
                .presentationCompactAdaptation(.sheet)
                .presentationDragIndicator(.visible)
        }
    }

    /// The Mac's debug remote clicks controls by these names; iPhone and iPad are tested with UI tests instead.
    func debugFrame(_ id: String) -> some View { self }

    /// The Mac needs help putting the cursor into a field that appears; on iPhone and iPad a field only takes the
    /// keyboard when it is tapped, so the keyboard doesn't cover the list it filters.
    func focusOnAppear(_ isActive: Bool = true) -> some View { self }
}
#endif
