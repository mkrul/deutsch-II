import AppKit
import AVFoundation

private let overlayFrontLevel = NSWindow.Level(rawValue: Int(Int32.max))

final class OverlayPanel: NSPanel {
    private let allowsKey: Bool

    init(frame: NSRect, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        level = overlayFrontLevel
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override func orderFrontRegardless() {
        if level != overlayFrontLevel { level = overlayFrontLevel }
        super.orderFrontRegardless()
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class HitView: NSView {
    var symbol = ""
    var onClick: () -> Void = {}

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let text = symbol as NSString
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        text.draw(in: rect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func setSymbol(_ value: String) {
        symbol = value
        needsDisplay = true
    }
}

final class BubblePanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override func orderFrontRegardless() {
        if level != .popUpMenu { level = .popUpMenu }
        super.orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleRoot: NSView {
    static let caretHeight: CGFloat = 8
    var caretX: CGFloat = 24 {
        didSet { needsDisplay = true }
    }
    let scroll = NSScrollView()

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = Self.bubblePath(in: bounds, caretX: caretX)
        Palette.paper.setFill()
        path.fill()
        Palette.stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        let path = Self.bubblePath(in: bounds, caretX: caretX)
        layer?.shadowPath = path.cgPath
        let inset: CGFloat = 1
        scroll.frame = NSRect(
            x: inset,
            y: inset,
            width: max(0, bounds.width - inset * 2),
            height: max(0, bounds.height - Self.caretHeight - inset)
        )
    }

    static func bubblePath(in rect: NSRect, caretX: CGFloat) -> NSBezierPath {
        let radius: CGFloat = 8
        let left = rect.minX + 0.5
        let right = rect.maxX - 0.5
        let bottom = rect.minY + 0.5
        let top = rect.maxY - caretHeight - 0.5
        let tipY = rect.maxY - 0.5
        let limit = max(left + radius + 14, right - radius - 14)
        let tip = min(max(caretX, left + radius + 14), limit)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left + radius, y: top))
        path.line(to: NSPoint(x: tip - 7, y: top))
        path.line(to: NSPoint(x: tip, y: tipY))
        path.line(to: NSPoint(x: tip + 7, y: top))
        path.line(to: NSPoint(x: right - radius, y: top))
        path.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right, y: top - radius), radius: radius)
        path.line(to: NSPoint(x: right, y: bottom + radius))
        path.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: right - radius, y: bottom), radius: radius)
        path.line(to: NSPoint(x: left + radius, y: bottom))
        path.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: bottom + radius), radius: radius)
        path.line(to: NSPoint(x: left, y: top - radius))
        path.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left + radius, y: top), radius: radius)
        path.close()
        return path
    }
}

final class BubbleDocument: NSView {
    override var isFlipped: Bool { true }
}

final class BubbleRow: NSView {
    let source: String
    let english: String
    let speaker = HitView()
    var showsDivider = false
    private let divider = NSView()
    private static let germanFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let englishFont = NSFont.systemFont(ofSize: 13)
    private static let speakerWidth: CGFloat = 28
    private static let textGap: CGFloat = 2
    private static let padTop: CGFloat = 8
    private static let padBottom: CGFloat = 8
    private static let padRight: CGFloat = 12

    init(source: String, english: String) {
        self.source = source
        self.english = english
        super.init(frame: .zero)
        speaker.setSymbol("🔊")
        speaker.toolTip = "Hear this German"
        addSubview(speaker)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.stroke.cgColor
        addSubview(divider)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setSpeaking(_ speaking: Bool) {
        speaker.setSymbol(speaking ? "…" : "🔊")
    }

    static func height(source: String, english: String, width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - speakerWidth - padRight)
        let german = textHeight(source, font: germanFont, width: textWidth)
        let translated = textHeight(english, font: englishFont, width: textWidth)
        return padTop + german + textGap + translated + padBottom
    }

    override func layout() {
        super.layout()
        speaker.frame = NSRect(x: 2, y: 0, width: Self.speakerWidth - 2, height: bounds.height)
        divider.isHidden = !showsDivider
        divider.frame = NSRect(x: 10, y: bounds.height - 1, width: max(0, bounds.width - 20), height: 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let textWidth = max(1, bounds.width - Self.speakerWidth - Self.padRight)
        let textX = Self.speakerWidth
        let germanHeight = Self.textHeight(source, font: Self.germanFont, width: textWidth)
        let germanRect = NSRect(x: textX, y: Self.padTop, width: textWidth, height: germanHeight)
        let englishRect = NSRect(
            x: textX,
            y: Self.padTop + germanHeight + Self.textGap,
            width: textWidth,
            height: Self.textHeight(english, font: Self.englishFont, width: textWidth)
        )
        draw(source, font: Self.germanFont, color: Palette.ink, in: germanRect)
        draw(english, font: Self.englishFont, color: .black, in: englishRect)
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 4000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style]
        )
        return max(16, ceil(bounds.height))
    }
}

@MainActor
final class StatusHUD {
    private let panel = OverlayPanel(frame: .zero, allowsKey: false)
    private let label = NSTextField(labelWithString: "")

    init() {
        panel.ignoresMouseEvents = true
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.drawsBackground = false
        label.isBezeled = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.addSubview(label)
        panel.contentView = root
    }

    func show(_ text: String, color: NSColor) {
        guard let screen = screen() else { return }
        label.stringValue = text
        let maxWidth = min(420, screen.visibleFrame.width - 32)
        let bounds = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth - 28, height: 200)) ?? .zero
        let width = min(maxWidth, max(52, ceil(bounds.width) + 28))
        let height = max(32, ceil(bounds.height) + 16)
        let frame = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 10,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        panel.contentView?.layer?.backgroundColor = color.cgColor
        label.frame = NSRect(x: 14, y: 8, width: width - 28, height: height - 16)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    func play(_ data: Data) throws {
        let next = try AVAudioPlayer(data: data)
        next.delegate = self
        next.prepareToPlay()
        next.play()
        player = next
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            if self?.player === player {
                self?.player = nil
            }
        }
    }
}

@MainActor
final class OverlayController {
    private let panel = BubblePanel(frame: NSRect(x: 0, y: 0, width: 220, height: 72))
    private let root = BubbleRoot()
    private let document = BubbleDocument()
    private var rows: [BubbleRow] = []
    private var speakingRow: BubbleRow?
    private var speechTask: Task<Void, Never>?
    private let speaker = Speaker()
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?
    var onSpeechError: ((String) -> Void)?
    var apiKey: () -> String = { "" }
    private var clickTap: CFMachPort?
    private var clickTapSource: CFRunLoopSource?
    private var holding = false

    var isOpen: Bool { panel.isVisible }

    init() {
        root.scroll.drawsBackground = false
        root.scroll.backgroundColor = .clear
        root.scroll.borderType = .noBorder
        root.scroll.hasVerticalScroller = true
        root.scroll.hasHorizontalScroller = false
        root.scroll.autohidesScrollers = true
        root.scroll.scrollerStyle = .overlay
        root.scroll.automaticallyAdjustsContentInsets = false
        root.scroll.contentInsets = NSEdgeInsets()
        root.scroll.documentView = document
        root.scroll.contentView.drawsBackground = false
        root.scroll.contentView.backgroundColor = .clear
        root.addSubview(root.scroll)
        panel.contentView = root
    }

    func show(items: [TranslatedBlock], anchor: NSRect) {
        let entries = Self.entries(from: items)
        guard !entries.isEmpty else { return }
        stopSpeech()
        rebuild(entries)
        place(anchor: anchor)
        panel.orderFrontRegardless()
        installClickShield()
        onShow?()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func clear() {
        let notify = isOpen
        stopSpeech()
        removeClickShield()
        panel.orderOut(nil)
        if notify { onClose?() }
    }

    private static func entries(from items: [TranslatedBlock]) -> [(String, String)] {
        let ordered = items.sorted { lhs, rhs in
            if abs(lhs.bounds.minY - rhs.bounds.minY) > 2 { return lhs.bounds.minY < rhs.bounds.minY }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var seen = Set<String>()
        var entries: [(String, String)] = []
        for item in ordered {
            let source = item.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = item.english.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty || english.isEmpty { continue }
            if seen.insert(source).inserted {
                entries.append((source, english))
            }
        }
        return entries
    }

    private func rebuild(_ entries: [(String, String)]) {
        for row in rows { row.removeFromSuperview() }
        rows = entries.map { source, english in
            let row = BubbleRow(source: source, english: english)
            row.speaker.onClick = { [weak self, weak row] in
                guard let self, let row else { return }
                self.speak(row)
            }
            document.addSubview(row)
            return row
        }
    }

    private func place(anchor: NSRect) {
        let width = measuredWidth()
        let rowWidth = max(1, width - 2)
        var contentHeight: CGFloat = 0
        var heights: [CGFloat] = []
        for (index, row) in rows.enumerated() {
            row.showsDivider = index < rows.count - 1
            let rowHeight = BubbleRow.height(source: row.source, english: row.english, width: rowWidth)
            heights.append(rowHeight)
            contentHeight += rowHeight
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let maxHeight = min(420, max(80, visible.height - 24))
        var height = min(maxHeight, contentHeight + BubbleRoot.caretHeight + 1)
        let gap: CGFloat = 2
        var x = anchor.midX - width / 2
        var y = anchor.minY - gap - height
        let margin: CGFloat = 8
        if y < visible.minY + margin {
            height = max(80, anchor.minY - gap - (visible.minY + margin))
            y = anchor.minY - gap - height
        }
        x = min(max(x, visible.minX + margin), max(visible.minX + margin, visible.maxX - margin - width))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        root.caretX = min(max(anchor.midX - x, 24), width - 24)
        root.layoutSubtreeIfNeeded()
        var rowY: CGFloat = 0
        for (row, rowHeight) in zip(rows, heights) {
            row.frame = NSRect(x: 0, y: rowY, width: rowWidth, height: rowHeight)
            rowY += rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(rowY, 1))
        root.scroll.hasVerticalScroller = rowY > root.scroll.bounds.height + 1
        root.scroll.contentView.scroll(to: .zero)
    }

    private func measuredWidth() -> CGFloat {
        let germanFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let englishFont = NSFont.systemFont(ofSize: 13)
        var text: CGFloat = 24
        for row in rows {
            text = max(text, ceil((row.source as NSString).size(withAttributes: [.font: germanFont]).width))
            text = max(text, ceil((row.english as NSString).size(withAttributes: [.font: englishFont]).width))
        }
        return min(360, max(132, text + 50))
    }

    private func installClickShield() {
        guard clickTap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let overlay = Unmanaged<OverlayController>.fromOpaque(userInfo).takeUnretainedValue()
                return overlay.receiveClick(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        clickTap = tap
        clickTapSource = source
    }

    private func removeClickShield() {
        holding = false
        if let clickTap {
            CGEvent.tapEnable(tap: clickTap, enable: false)
            CFMachPortInvalidate(clickTap)
            self.clickTap = nil
        }
        if let clickTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), clickTapSource, .commonModes)
            self.clickTapSource = nil
        }
    }

    private func receiveClick(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let cg = event.location
        let point = CGPoint(x: cg.x, y: Coordinates.primaryHeight - cg.y)
        let inside = panel.isVisible && panel.frame.contains(point)
        if type == .leftMouseDown {
            holding = inside
            if inside, let row = speakerRow(at: point) {
                row.speaker.onClick()
            }
            return inside ? nil : Unmanaged.passUnretained(event)
        }
        if holding {
            if type == .leftMouseUp { holding = false }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func speakerRow(at screen: CGPoint) -> BubbleRow? {
        let windowPoint = panel.convertPoint(fromScreen: screen)
        guard let content = panel.contentView else { return nil }
        let local = content.convert(windowPoint, from: nil)
        var view = content.hitTest(local)
        while let current = view {
            if current is HitView {
                return current.superview as? BubbleRow
            }
            view = current.superview
        }
        return nil
    }

    private func speak(_ row: BubbleRow) {
        let german = row.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if german.isEmpty { return }
        speakingRow?.setSpeaking(false)
        speakingRow = row
        row.setSpeaking(true)
        speechTask?.cancel()
        speaker.stop()
        let key = apiKey()
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await GermanSpeech.shared.audio(apiKey: key, german: german)
                if Task.isCancelled || self.speakingRow !== row { return }
                row.setSpeaking(false)
                if self.speakingRow === row { self.speakingRow = nil }
                try self.speaker.play(data)
            } catch is CancellationError {
                return
            } catch SpeechError.missingKey {
                self.failSpeech(row, "Add your ElevenLabs API key in Translate")
            } catch SpeechError.rejected {
                self.failSpeech(row, "The ElevenLabs API key was rejected")
            } catch {
                self.failSpeech(row, "ElevenLabs could not read that")
            }
        }
    }

    private func failSpeech(_ row: BubbleRow, _ message: String) {
        if speakingRow === row {
            row.setSpeaking(false)
            speakingRow = nil
        }
        onSpeechError?(message)
    }

    private func stopSpeech() {
        speechTask?.cancel()
        speechTask = nil
        speakingRow?.setSpeaking(false)
        speakingRow = nil
        speaker.stop()
    }
}
