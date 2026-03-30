import AppKit

class KeyableWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    private let longPressDuration: TimeInterval = 0.18
    private let dragActivationDistance: CGFloat = 4.0
    private let manualLiftHeight: CGFloat = 18.0
    private let liftAnimationDuration: TimeInterval = 0.08
    private let dropAnimationDuration: TimeInterval = 0.05
    private var mouseDownScreenPoint: NSPoint = .zero
    private var mouseDownWindowOrigin: NSPoint = .zero
    private var longPressReached = false
    private var isDraggingCharacter = false
    private var isMouseDown = false
    private var isLifted = false
    private var longPressWorkItem: DispatchWorkItem?
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // AVPlayerLayer is GPU-rendered so layer.render(in:) won't capture video pixels.
        // Use CGWindowListCreateImage to sample actual on-screen alpha at click point.
        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        // Use the full virtual display height for the CG coordinate flip, not just
        // the main screen. NSScreen coordinates have origin at bottom-left of the
        // primary display, while CG uses top-left. The primary screen's height is
        // the correct basis for the flip across all monitors.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel: [UInt8] = [0, 0, 0, 0]
            if let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if pixel[3] > 30 {
                    return self
                }
                return nil
            }
        }

        // Fallback: accept click if within center 60% of the view
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else {
            character?.handleClick()
            return
        }

        isMouseDown = true
        longPressReached = false
        isDraggingCharacter = false
        isLifted = false
        mouseDownWindowOrigin = win.frame.origin
        mouseDownScreenPoint = NSEvent.mouseLocation

        longPressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isMouseDown, let win = self.window else { return }
            self.longPressReached = true
            self.character?.beginManualDrag()
            self.installMouseUpMonitorsIfNeeded()

            let liftedOrigin = NSPoint(x: win.frame.origin.x, y: win.frame.origin.y + self.manualLiftHeight)
            self.isLifted = true
            self.mouseDownWindowOrigin = liftedOrigin
            self.mouseDownScreenPoint = NSEvent.mouseLocation

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.liftAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrameOrigin(liftedOrigin)
            }
        }
        longPressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, longPressReached else { return }

        let currentScreenPoint = NSEvent.mouseLocation
        let dx = currentScreenPoint.x - mouseDownScreenPoint.x
        let dy = currentScreenPoint.y - mouseDownScreenPoint.y

        if !isDraggingCharacter {
            let distance = hypot(dx, dy)
            guard distance >= dragActivationDistance else { return }
            isDraggingCharacter = true
        }

        let newOrigin = NSPoint(x: mouseDownWindowOrigin.x + dx, y: mouseDownWindowOrigin.y + dy)
        win.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        finishManualDragIfNeeded()
    }

    private func finishManualDragIfNeeded() {
        isMouseDown = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        removeMouseUpMonitors()

        if isDraggingCharacter || longPressReached {
            if isLifted, let win = window {
                let droppedOrigin = NSPoint(x: win.frame.origin.x, y: win.frame.origin.y - manualLiftHeight)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = self.dropAnimationDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    win.animator().setFrameOrigin(droppedOrigin)
                }, completionHandler: { [weak self] in
                    self?.character?.endManualDrag()
                })
            } else {
                character?.endManualDrag()
            }
            isDraggingCharacter = false
            longPressReached = false
            isLifted = false
            return
        }

        character?.handleClick()
    }

    private func installMouseUpMonitorsIfNeeded() {
        guard globalMouseUpMonitor == nil, localMouseUpMonitor == nil else { return }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishManualDragIfNeeded()
            }
        }

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.finishManualDragIfNeeded()
            return event
        }
    }

    private func removeMouseUpMonitors() {
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
        if let monitor = localMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseUpMonitor = nil
        }
    }
}
