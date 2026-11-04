import AppKit
import NaturalLanguage

enum Coordinates {
    static var primaryHeight: CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return primary?.frame.height ?? 0
    }

    static func appKitToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func axToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

struct TranslatedBlock {
    var source: String
    var english: String
    var bounds: CGRect
}

struct PlacedTranslation {
    var source: String
    var english: String
    var frame: CGRect
    var textWidth: CGFloat
    var collapsedWidth: CGFloat
    var collapsedHeight: CGFloat
}

enum LanguageFilter {
    private static let germanParts = [
        "anruf", "schirm", "stellung", "meldung", "nachricht", "speicher",
        "tastatur", "passwort", "verlauf", "einstell", "datenschutz", "standort",
        "netzwerk", "flugmodus", "benachrichtig", "zustand", "ordner", "datei",
        "freigabe", "wecker", "kalender", "lautlos", "zwischenablage", "ruhemodus",
        "anzeige", "seite",
    ]
    private static let germanEndings = [
        "ung", "keit", "heit", "schaft", "chen", "lein", "nis", "tum", "lich", "isch",
    ]

    static func german(_ blocks: [TextBlock]) -> [TextBlock] {
        var cache: [String: Bool] = [:]
        return blocks.filter { block in
            if let known = cache[block.text] { return known }
            let result = isGerman(block.text)
            cache[block.text] = result
            return result
        }
    }

    static func readsAsGerman(_ text: String) -> Bool {
        let hypotheses = hypotheses(for: text.precomposedStringWithCanonicalMapping)
        let german = hypotheses[.german] ?? 0
        let english = hypotheses[.english] ?? 0
        if hypotheses.max(by: { $0.value < $1.value })?.key == .german { return true }
        return german > english && german >= 0.4
    }

    private static func isGerman(_ text: String) -> Bool {
        let normal = text.precomposedStringWithCanonicalMapping
        if hasGermanSignal(normal) { return true }
        let hypotheses = hypotheses(for: normal)
        let german = hypotheses[.german] ?? 0
        let english = hypotheses[.english] ?? 0
        if hypotheses.max(by: { $0.value < $1.value })?.key == .german { return true }
        return german > 0 && german >= english
    }

    private static func hypotheses(for text: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 12)
    }

    private static func hasGermanSignal(_ text: String) -> Bool {
        if text.contains(where: { "äöüÄÖÜß".contains($0) }) { return true }
        let lower = text.lowercased()
        if germanParts.contains(where: { lower.contains($0) }) { return true }
        let letters = String(lower.filter(\.isLetter))
        if letters.count < 8 { return false }
        return germanEndings.contains(where: { letters.hasSuffix($0) })
    }
}

enum Metrics {
    static let leading: CGFloat = 4
    static let grip: CGFloat = 14
    static let speaker: CGFloat = 26
    static let indicator: CGFloat = 26
    static let gap: CGFloat = 1
    static let controlHeight: CGFloat = 28
    static let margin: CGFloat = 8
    static let edge: CGFloat = 4
    static let minText: CGFloat = 28
    static var controls: CGFloat { leading + grip + speaker + gap + indicator }
}

enum TextMeasure {
    private static let font = NSFont.systemFont(ofSize: 13)
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 6

    static func oneLineWidth(_ text: String) -> CGFloat {
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return max(Metrics.minText, width + horizontalPadding)
    }

    static func measure(_ text: String, width: CGFloat) -> (height: CGFloat, lines: Int) {
        let textWidth = max(1, width - horizontalPadding)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        _ = manager.glyphRange(for: container)
        var lines = 0
        let range = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, _ in
            lines += 1
        }
        if lines == 0 { lines = 1 }
        let used = manager.usedRect(for: container)
        return (max(ceil(used.height) + verticalPadding, 1), lines)
    }
}

enum Layout {
    static func pages(for items: [TranslatedBlock]) -> [[PlacedTranslation]] {
        let primary = Coordinates.primaryHeight
        let screens = NSScreen.screens
            .map { Coordinates.appKitToAX($0.visibleFrame, primaryHeight: primary) }
            .filter { $0.width > 10 && $0.height > 10 }
        if screens.isEmpty || items.isEmpty { return [] }
        var grouped = Array(repeating: [TranslatedBlock](), count: screens.count)
        for item in items {
            let center = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
            let index = screens.firstIndex { $0.contains(center) } ?? nearest(screens, center)
            grouped[index].append(item)
        }
        var perScreen: [[[PlacedTranslation]]] = []
        for (index, group) in grouped.enumerated() where !group.isEmpty {
            let placed = place(group, on: screens[index])
            if !placed.isEmpty {
                perScreen.append(paginate(placed))
            }
        }
        let count = perScreen.map(\.count).max() ?? 0
        return (0..<count).compactMap { page in
            let items = perScreen.flatMap { group in
                group.indices.contains(page) ? group[page] : []
            }
            return items.isEmpty ? nil : items
        }
    }

    private static func place(_ items: [TranslatedBlock], on screen: CGRect) -> [PlacedTranslation] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var placed: [PlacedTranslation] = []
        for index in sorted.indices {
            let item = sorted[index]
            guard let textFrame = frame(item, sorted: sorted, index: index, screen: screen) else { continue }
            var left = textFrame.minX - Metrics.controls
            var textWidth = textFrame.width
            if left < screen.minX + Metrics.edge {
                left = screen.minX + Metrics.edge
            }
            let maxWidth = screen.maxX - Metrics.edge - left
            if Metrics.controls + textWidth > maxWidth {
                textWidth = max(maxWidth - Metrics.controls, Metrics.minText)
            }
            let expandedWidth = Metrics.controls + textWidth
            if textWidth < 8 || expandedWidth > screen.width { continue }
            let measured = TextMeasure.measure(item.english, width: textWidth)
            var chipTop = textFrame.minY
            var chipHeight = textFrame.height
            if measured.lines <= 1 {
                chipHeight = measured.height
                let bottomLimit = screen.maxY - Metrics.edge
                if chipTop + chipHeight > bottomLimit {
                    chipTop = max(screen.minY, bottomLimit - chipHeight)
                }
                if chipTop + chipHeight > bottomLimit {
                    chipHeight = bottomLimit - chipTop
                }
            }
            if chipHeight <= 1 { continue }
            let collapsedWidth = min(Metrics.controls, expandedWidth)
            let collapsedHeight = min(Metrics.controlHeight, chipHeight)
            placed.append(
                PlacedTranslation(
                    source: item.source,
                    english: item.english,
                    frame: CGRect(x: left, y: chipTop, width: expandedWidth, height: chipHeight),
                    textWidth: textWidth,
                    collapsedWidth: collapsedWidth,
                    collapsedHeight: collapsedHeight
                )
            )
        }
        return placed
    }

    private static func frame(_ block: TranslatedBlock, sorted: [TranslatedBlock], index: Int, screen: CGRect) -> CGRect? {
        var left = block.bounds.minX
        var top = block.bounds.minY
        if left < screen.minX + Metrics.edge { left = screen.minX + Metrics.edge }
        let lineWidth = TextMeasure.oneLineWidth(block.english)
        let room = screen.maxX - Metrics.margin - left
        if lineWidth > room {
            let shift = min(lineWidth - room, max(0, left - (screen.minX + Metrics.edge)))
            left -= shift
        }
        let maxWidth = max(screen.maxX - Metrics.margin - left, Metrics.minText)
        var width = min(lineWidth, maxWidth)
        if left + width > screen.maxX - Metrics.margin {
            width = screen.maxX - Metrics.margin - left
        }
        if width < Metrics.minText || top >= screen.maxY - 8 { return nil }
        let textHeight = TextMeasure.measure(block.english, width: width).height
        let next = nextTop(sorted, index, screen.maxY)
        let limit = min(next - 2, block.bounds.minY + 220)
        let desiredBottom = block.bounds.minY + textHeight
        let bottom = min(desiredBottom, max(block.bounds.maxY, limit))
        var height = bottom - block.bounds.minY
        if top + height > screen.maxY - 4 {
            height = screen.maxY - 4 - top
        }
        if height <= 0 { return nil }
        if top < screen.minY {
            height -= screen.minY - top
            top = screen.minY
            if height <= 0 { return nil }
        }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    private static func nextTop(_ sorted: [TranslatedBlock], _ index: Int, _ screenBottom: CGFloat) -> CGFloat {
        let block = sorted[index].bounds
        var limit = screenBottom
        for otherIndex in sorted.indices {
            if otherIndex == index { continue }
            let other = sorted[otherIndex].bounds
            if other.minY <= block.minY { continue }
            let overlap = min(block.maxX, other.maxX) - max(block.minX, other.minX)
            if overlap < 8 { continue }
            if other.minY < limit { limit = other.minY }
        }
        return limit
    }

    private static func paginate(_ placed: [PlacedTranslation]) -> [[PlacedTranslation]] {
        var pages: [[PlacedTranslation]] = []
        for chip in placed {
            if let index = pages.firstIndex(where: { group in
                group.allSatisfy { !overlaps($0.frame, chip.frame) }
            }) {
                pages[index].append(chip)
            } else {
                pages.append([chip])
            }
        }
        return pages
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    private static func nearest(_ screens: [CGRect], _ point: CGPoint) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, screen) in screens.enumerated() {
            let dx = max(screen.minX - point.x, point.x - screen.maxX, 0)
            let dy = max(screen.minY - point.y, point.y - screen.maxY, 0)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
