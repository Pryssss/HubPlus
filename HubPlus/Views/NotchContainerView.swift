import SwiftUI

/// Hosts the island: collapsed pill (draggable) or expanded panel. Fully-rounded so
/// it reads as a floating island at any edge.
struct NotchContainerView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: NotchUIModel
    var onDragChanged: () -> Void
    var onDragEnded: () -> Void
    var onHover: (Bool) -> Void
    var onClose: () -> Void

    private var radius: CGFloat { ui.expanded ? 18 : 15 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            if ui.expanded {
                NotchRootView(store: store, ui: ui, onClose: onClose)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { _ in onDragChanged() }
                            .onEnded { _ in onDragEnded() }
                    )
            } else {
                NotchPillView(store: store, vertical: ui.vertical)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in onDragChanged() }
                            .onEnded { _ in onDragEnded() }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .onHover { onHover($0) }
        .preferredColorScheme(.dark)
    }
}
