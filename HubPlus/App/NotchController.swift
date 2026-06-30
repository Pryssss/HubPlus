import AppKit
import SwiftUI
import Combine

enum NotchTab { case agents, stats }

@MainActor
final class NotchUIModel: ObservableObject {
    @Published var expanded = false
    @Published var vertical = false   // true when docked to a side edge
    @Published var tab: NotchTab = .agents
}

/// Owns the island window. Collapsed pill ⇄ expanded panel. The pill is dragged with
/// an explicit DragGesture (so SwiftUI hit-testing doesn't swallow the move); on
/// release it snaps to the nearest screen edge and expands inward from there.
@MainActor
final class NotchController {
    private let store: AppStore
    private let ui = NotchUIModel()
    private var panel: NSPanel?

    private enum Edge: String { case top, bottom, left, right }
    private var pillCenter: CGPoint = .zero   // persisted, screen coords (y-up)
    private var edge: Edge = .top

    private var pinned = false
    private var animating = false
    private var dragOffset: CGSize?
    private var dragStartMouse: CGPoint?
    private var didDrag = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var clickMonitor: Any?
    private var tabCancellable: AnyCancellable?

    private var isVerticalEdge: Bool { edge == .left || edge == .right }
    private var collapsedSize: NSSize {
        isVerticalEdge ? NSSize(width: 34, height: 132) : NSSize(width: 210, height: 30)
    }
    private let expandedWidth: CGFloat = 560

    init(store: AppStore) {
        self.store = store
        let d = UserDefaults.standard
        if let x = d.object(forKey: "pillX") as? Double, let y = d.object(forKey: "pillY") as? Double {
            pillCenter = CGPoint(x: x, y: y)
        }
        if let e = d.string(forKey: "pillEdge"), let parsed = Edge(rawValue: e) { edge = parsed }
        ui.vertical = isVerticalEdge
        tabCancellable = ui.$tab.sink { [weak self] tab in
            guard tab == .stats else { return }
            MainActor.assumeIsolated { self?.store.refreshStats(force: true) }
        }
    }

    func show() {
        if panel == nil { makePanel() }
        if pillCenter == .zero, let screen = notchScreen() {
            pillCenter = CGPoint(x: screen.frame.midX, y: topY(screen))
            edge = .top
        }
        ui.vertical = isVerticalEdge
        applyFrame(animated: false)
        panel?.orderFrontRegardless()
    }

    func toggle() { setExpanded(!ui.expanded, pin: !ui.expanded) }
    func openExpanded() { setExpanded(true, pin: true) }

    // MARK: Hover / tap / drag

    private func hover(_ inside: Bool) {
        if dragOffset != nil { return }   // ignore hover while dragging
        if inside {
            cancelCollapse()
            if !ui.expanded { scheduleExpand() }
        } else {
            cancelExpand()
            if !pinned { scheduleCollapse() }
        }
    }

    /// Driven by NSEvent.mouseLocation (absolute screen coords) so moving the window
    /// can't feed back into the gesture's translation.
    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            dragOffset = CGSize(width: mouse.x - panel.frame.origin.x,
                                height: mouse.y - panel.frame.origin.y)
            dragStartMouse = mouse
            didDrag = false
            cancelExpand(); cancelCollapse()
            return
        }
        if let start = dragStartMouse, abs(mouse.x - start.x) + abs(mouse.y - start.y) > 4 {
            didDrag = true
        }
        if didDrag, let off = dragOffset {
            panel.setFrameOrigin(CGPoint(x: mouse.x - off.width, y: mouse.y - off.height))
        }
    }

    private func dragEnded() {
        defer { dragOffset = nil; dragStartMouse = nil; didDrag = false }
        if didDrag {
            snapAfterDrag()
        } else if !ui.expanded {
            setExpanded(true, pin: true)   // a tap on the collapsed pill expands
        }
    }

    private func close() { setExpanded(false, pin: false) }

    private func scheduleExpand() {
        cancelExpand()
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(true, pin: false) }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func cancelExpand() { expandWork?.cancel(); expandWork = nil }

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false, pin: false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }
    private func cancelCollapse() { collapseWork?.cancel(); collapseWork = nil }

    private func setExpanded(_ value: Bool, pin: Bool) {
        pinned = pin && value
        if ui.expanded != value { ui.expanded = value }
        applyFrame(animated: true)
        if ui.expanded && pinned { installClickMonitor() } else { removeClickMonitor() }
        panel?.orderFrontRegardless()
    }

    // MARK: Geometry

    private func topY(_ screen: NSScreen) -> CGFloat {
        let inset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        return screen.frame.maxY - inset - collapsedSize.height / 2
    }

    private func expandedHeight() -> CGFloat {
        let rows = max(store.rows.count, 1)
        let h: CGFloat = 20 + 34 + 68 + CGFloat(rows) * 52
        let maxH = (notchScreen()?.frame.height ?? 800) - 80
        return min(h, maxH)
    }

    private func horizontalOriginX(width w: CGFloat, vf: NSRect) -> CGFloat {
        let f = (pillCenter.x - vf.minX) / max(vf.width, 1)
        if f < 0.34 { return pillCenter.x - collapsedSize.width / 2 }
        if f > 0.66 { return pillCenter.x + collapsedSize.width / 2 - w }
        return pillCenter.x - w / 2
    }

    private func applyFrame(animated: Bool) {
        guard let panel, let screen = notchScreen() else { return }
        let vf = screen.frame
        let size = ui.expanded
            ? NSSize(width: expandedWidth, height: expandedHeight())
            : collapsedSize
        let cW = collapsedSize.width, cH = collapsedSize.height
        let pillLeft = pillCenter.x - cW / 2
        let pillRight = pillCenter.x + cW / 2
        let pillTop = pillCenter.y + cH / 2
        let pillBottom = pillCenter.y - cH / 2

        var origin: CGPoint
        if !ui.expanded {
            origin = CGPoint(x: pillLeft, y: pillBottom)
        } else {
            let hx = horizontalOriginX(width: size.width, vf: vf)
            switch edge {
            case .top:    origin = CGPoint(x: hx, y: pillTop - size.height)
            case .bottom: origin = CGPoint(x: hx, y: pillBottom)
            case .left:   origin = CGPoint(x: pillLeft, y: pillTop - size.height)
            case .right:  origin = CGPoint(x: pillRight - size.width, y: pillTop - size.height)
            }
        }
        let x = max(vf.minX + 6, min(origin.x, vf.maxX - size.width - 6))
        let y = max(vf.minY + 6, min(origin.y, vf.maxY - size.height - 6))
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if animated {
            animating = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animating = false }
            })
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Snap the pill flush to the nearest screen edge and remember it.
    /// After a drag (collapsed pill OR expanded panel), snap to the nearest screen
    /// edge based on the window's own frame, so the hub lives only along edges.
    private func snapAfterDrag() {
        guard let panel, let screen = notchScreen() else { return }
        let vf = screen.frame
        let inset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        let wf = panel.frame

        let dTop = vf.maxY - wf.maxY
        let dBottom = wf.minY - vf.minY
        let dLeft = wf.minX - vf.minX
        let dRight = vf.maxX - wf.maxX
        let nearest = min(dTop, dBottom, dLeft, dRight)

        if nearest == dLeft { edge = .left }
        else if nearest == dRight { edge = .right }
        else if nearest == dBottom { edge = .bottom }
        else { edge = .top }
        ui.vertical = isVerticalEdge

        let halfW = collapsedSize.width / 2, halfH = collapsedSize.height / 2
        switch edge {
        case .top:    pillCenter = CGPoint(x: wf.midX, y: (vf.maxY - inset) - halfH)
        case .bottom: pillCenter = CGPoint(x: wf.midX, y: vf.minY + halfH + 6)
        case .left:   pillCenter = CGPoint(x: vf.minX + halfW + 6, y: wf.maxY - halfH)
        case .right:  pillCenter = CGPoint(x: vf.maxX - halfW - 6, y: wf.maxY - halfH)
        }
        pillCenter.x = max(vf.minX + halfW + 6, min(pillCenter.x, vf.maxX - halfW - 6))
        pillCenter.y = max(vf.minY + halfH + 6, min(pillCenter.y, (vf.maxY - inset) - halfH))

        if ui.expanded { pinned = true; installClickMonitor() }   // keep it open after a drag

        let d = UserDefaults.standard
        d.set(Double(pillCenter.x), forKey: "pillX")
        d.set(Double(pillCenter.y), forKey: "pillY")
        d.set(edge.rawValue, forKey: "pillEdge")
        applyFrame(animated: true)
    }

    // MARK: Window

    private func makePanel() {
        let container = NotchContainerView(
            store: store, ui: ui,
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() },
            onHover: { [weak self] inside in self?.hover(inside) },
            onClose: { [weak self] in self?.close() },
            onJump: { row in WindowJumper.jump(pid: Int32(row.info.pid)) }
        )
        let hosting = NSHostingController(rootView: container)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
    }

    // MARK: Click-outside

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.setExpanded(false, pin: false)
        }
    }
    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}
