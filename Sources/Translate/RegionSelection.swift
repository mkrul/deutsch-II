import AppKit
import Darwin

final class RegionSelector {
    var onBegin: () -> Void = {}
    var onSelect: (CGRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private(set) var active = false
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var pushedCursor = false
    private var delivering = false
    private var session = 0

    func begin() {
        end()
        session += 1
        let token = session
        active = true
        let watching = installTap()
        onBegin()
        let primary = Coordinates.primaryHeight
        let frames = NSScreen.screens.map { screen in
            (frame: screen.frame, ax: Coordinates.appKitToAX(screen.frame, primaryHeight: primary))
        }
        if watching {
            NSCursor.crosshair.push()
            pushedCursor = true
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let images = frames.map { ScreenSnapshot.cgImage(ax: $0.ax) }
            DispatchQueue.main.async {
                guard self.session == token, self.active else { return }
                self.present(frames: frames.map(\.frame), images: images, watching: watching)
            }
        }
    }

    private func present(frames: [CGRect], images: [CGImage?], watching: Bool) {
        let selection = dragRect
        for (frame, image) in zip(frames, images) {
            let panel = OverlayPanel(frame: frame, allowsKey: !watching)
            panel.ignoresMouseEvents = watching
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            let view = RegionDragView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            if let image {
                view.frozen = NSImage(cgImage: image, size: frame.size)
            }
            view.screenSelection = selection
            view.onFinish = { [weak self] rect in
                self?.finish(rect)
            }
            view.onCancel = { [weak self] in
                self?.end()
            }
            container.addSubview(view)
            panel.contentView = container
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if !watching {
            NSApp.activate(ignoringOtherApps: true)
            panels.first?.makeKey()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    self?.end()
                    return nil
                }
                return event
            }
        }
    }

    func end() {
        let cancel = active && !delivering
        active = false
        dragOrigin = nil
        dragCurrent = nil
        removeTap()
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        if cancel { onCancel() }
    }

    private func finish(_ rect: CGRect) {
        guard active else { return }
        delivering = true
        end()
        delivering = false
        onSelect(rect)
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel, .keyDown,
        ]
        let mask = types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let selector = Unmanaged<RegionSelector>.fromOpaque(userInfo).takeUnretainedValue()
                return selector.receive(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            self.tapSource = nil
        }
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                DispatchQueue.main.async { [weak self] in self?.end() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else { return nil }
        let location = event.location
        DispatchQueue.main.async { [weak self] in
            self?.mouse(type, at: location)
        }
        return nil
    }

    private func mouse(_ type: CGEventType, at cg: CGPoint) {
        guard active else { return }
        let point = CGPoint(x: cg.x, y: Coordinates.primaryHeight - cg.y)
        switch type {
        case .leftMouseDown:
            dragOrigin = point
            dragCurrent = point
        case .leftMouseDragged:
            if dragOrigin == nil { dragOrigin = point }
            dragCurrent = point
        case .leftMouseUp:
            dragCurrent = point
            let rect = dragRect
            if let rect, rect.width >= 8, rect.height >= 8 {
                finish(rect)
            } else {
                end()
            }
            return
        default:
            return
        }
        let rect = dragRect
        for panel in panels {
            panel.contentView?.subviews.compactMap { $0 as? RegionDragView }.first?.screenSelection = rect
        }
    }

    private var dragRect: NSRect? {
        guard let dragOrigin, let dragCurrent else { return nil }
        return NSRect(
            x: min(dragOrigin.x, dragCurrent.x),
            y: min(dragOrigin.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragOrigin.x),
            height: abs(dragCurrent.y - dragOrigin.y)
        )
    }
}

private final class RegionDragView: NSView {
    var onFinish: (CGRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var frozen: NSImage?
    var screenSelection: NSRect? {
        didSet { needsDisplay = true }
    }
    private var origin: NSPoint?
    private var current: NSPoint?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let frozen {
            frozen.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let selection = drawnSelection {
            Palette.paper.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
            Palette.paper.withAlphaComponent(0.12).setFill()
            selection.fill()
        } else {
            let text = "Drag over the German. Escape cancels." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: Palette.paper,
            ]
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: bounds.height - size.height - 48,
                width: size.width,
                height: size.height
            )
            text.draw(in: rect, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
        current = origin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = event.locationInWindow
        guard let selection, let screenRect = window?.convertToScreen(selection), selection.width >= 8, selection.height >= 8 else {
            let cancel = onCancel
            DispatchQueue.main.async(execute: cancel)
            return
        }
        let finish = onFinish
        DispatchQueue.main.async {
            finish(screenRect)
        }
    }

    private var drawnSelection: NSRect? {
        if let selection { return selection }
        guard let screenSelection, let window else { return nil }
        return window.convertFromScreen(screenSelection)
    }

    private var selection: NSRect? {
        guard let origin, let current else { return nil }
        return NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }
}

private enum ScreenSnapshot {
    private typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> CGImage?

    private static let create: Create? = {
        guard let symbol = dlsym(
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
            "CGWindowListCreateImage"
        ) else { return nil }
        return unsafeBitCast(symbol, to: Create.self)
    }()

    static func cgImage(ax: CGRect) -> CGImage? {
        guard let create, let cg = create(ax, 1, 0, 1), hasContent(cg) else { return nil }
        return cg
    }

    private static func hasContent(_ image: CGImage) -> Bool {
        let bytesPerPixel = image.bitsPerPixel / 8
        guard image.width > 1, image.height > 1, bytesPerPixel >= 3,
              let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let samples = [0.2, 0.5, 0.8]
        for yFraction in samples {
            for xFraction in samples {
                let x = min(image.width - 1, Int(CGFloat(image.width) * xFraction))
                let y = min(image.height - 1, Int(CGFloat(image.height) * yFraction))
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                guard offset + 2 < length else { continue }
                let color = Int(pointer[offset]) + Int(pointer[offset + 1]) + Int(pointer[offset + 2])
                if color > 12 { return true }
            }
        }
        return false
    }
}
