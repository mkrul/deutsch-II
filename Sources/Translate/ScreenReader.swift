import AppKit
import ApplicationServices

struct TextBlock: Sendable {
    var text: String
    var bounds: CGRect
}

enum ScreenReader {
    static func capture(on screen: CGRect, selection: Bool = false, limit: Int = 100) -> [TextBlock] {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let bounded = screen.width > 10 && screen.height > 10
        var windows = visibleWindows()
        if bounded {
            windows = windows.filter { $0.bounds.intersects(screen) }
        }
        let readableWindows = windows.filter { $0.readable && isPartiallyVisible($0, in: windows) }
        let readable = selection && bounded
            ? readableWindows.sorted { lhs, rhs in
                let left = lhs.bounds.intersection(screen)
                let right = rhs.bounds.intersection(screen)
                let leftArea = left.isNull ? 0 : left.width * left.height
                let rightArea = right.isNull ? 0 : right.width * right.height
                return leftArea > rightArea
            }
            : readableWindows
        let deadline = Date().addingTimeInterval(selection ? 8 : 2.6)
        var raw: [TextBlock] = []
        var budget = 8000
        let popups = popupWindows()
        for window in popups {
            guard Date() <= deadline, budget > 0, raw.count < 700 else { break }
            collectPopup(window, screen: bounded ? screen : nil, selection: selection, deadline: deadline, into: &raw, budget: &budget)
        }
        let overlays = notificationWindows()
        var seenOverlays = Set<pid_t>()
        for window in overlays where seenOverlays.insert(window.pid).inserted {
            collectOverlay(pid: window.pid, windows: overlays, screen: bounded ? screen : nil, selection: selection, deadline: deadline, into: &raw, budget: &budget)
        }
        var seen = Set<pid_t>()
        for window in readable {
            if Date() > deadline || budget <= 0 || raw.count >= 700 { break }
            if !seen.insert(window.pid).inserted { continue }
            autoreleasepool {
                collectApp(
                    pid: window.pid,
                    windows: windows,
                    screen: bounded ? screen : nil,
                    selection: selection,
                    deadline: deadline,
                    into: &raw,
                    budget: &budget
                )
            }
        }
        let merged = LineMerger.merge(raw, gap: 32)
        let onScreen = bounded ? merged.filter { block in
            if selection { return screen.intersects(block.bounds) }
            return screen.contains(CGPoint(x: block.bounds.midX, y: block.bounds.midY))
        } : merged
        let ordered = onScreen.sorted { lhs, rhs in
            if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        return Array(ordered.prefix(limit))
    }

    private static func collectApp(
        pid: pid_t,
        windows: [VisibleWindow],
        screen: CGRect?,
        selection: Bool,
        deadline: Date,
        into raw: inout [TextBlock],
        budget: inout Int
    ) {
        if Date() > deadline { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var axWindows = copyWindows(app)
        if let screen {
            axWindows = axWindows.filter { element in
                guard let frame = copyFrame(element) else { return false }
                return frame.intersects(screen)
            }
        }
        revealWebContent(app: app, windows: &axWindows)
        let readable = windows.filter { $0.readable && $0.pid == pid }
        var matched: [(AXUIElement, VisibleWindow)] = []
        for element in axWindows {
            guard let frame = copyFrame(element) else { continue }
            if copyBool(element, kAXMinimizedAttribute) { continue }
            if let window = match(frame, to: readable) {
                matched.append((element, window))
            }
        }
        if matched.isEmpty, windows.first(where: \.readable)?.pid == pid {
            for element in axWindows {
                guard Date() <= deadline, budget > 0, raw.count < 700 else { return }
                walk(element, pid: pid, anchor: nil, windows: windows, screen: selection ? screen : nil, overlay: false, selection: selection, deadline: deadline, into: &raw, budget: &budget, depth: 0)
            }
            return
        }
        for (element, window) in matched {
            guard Date() <= deadline, budget > 0, raw.count < 700 else { return }
            walk(element, pid: pid, anchor: window, windows: windows, screen: selection ? screen : nil, overlay: false, selection: selection, deadline: deadline, into: &raw, budget: &budget, depth: 0)
        }
    }

    private static func collectOverlay(
        pid: pid_t,
        windows: [VisibleWindow],
        screen: CGRect?,
        selection: Bool,
        deadline: Date,
        into raw: inout [TextBlock],
        budget: inout Int
    ) {
        if Date() > deadline { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        for element in copyWindows(app) {
            guard Date() <= deadline, budget > 0, raw.count < 700 else { return }
            guard let frame = copyFrame(element), windows.contains(where: { tightlyMatches(frame, $0) }) else { continue }
            walk(element, pid: pid, anchor: nil, windows: windows, screen: screen, overlay: true, selection: selection, deadline: deadline, into: &raw, budget: &budget, depth: 0)
        }
    }

    private static func revealWebContent(app: AXUIElement, windows: inout [AXUIElement]) {
        var areas: [AXUIElement] = []
        for window in windows {
            collectWebAreas(window, into: &areas, depth: 0)
        }
        let flag = NSNumber(value: true)
        var waiting = false
        for area in areas where !containsReadableText(area, depth: 0, seen: 0).found {
            if AXUIElementSetAttributeValue(area, "AXEnhancedUserInterface" as CFString, flag) == .success {
                waiting = true
            }
        }
        guard waiting else { return }
        let until = Date().addingTimeInterval(0.8)
        while Date() < until {
            Thread.sleep(forTimeInterval: 0.05)
            let refreshed = copyWindows(app)
            if refreshed.contains(where: { containsWebText($0, depth: 0) }) {
                windows = refreshed
                return
            }
        }
        windows = copyWindows(app)
    }

    private static func collectWebAreas(_ element: AXUIElement, into areas: inout [AXUIElement], depth: Int) {
        if depth > 24 { return }
        if copyString(element, kAXRoleAttribute) == "AXWebArea" {
            areas.append(element)
        }
        for child in copyChildren(element) {
            collectWebAreas(child, into: &areas, depth: depth + 1)
        }
    }

    private static func containsWebText(_ element: AXUIElement, depth: Int) -> Bool {
        if depth > 24 { return false }
        if copyString(element, kAXRoleAttribute) == "AXWebArea" {
            return containsReadableText(element, depth: 0, seen: 0).found
        }
        for child in copyChildren(element) where containsWebText(child, depth: depth + 1) {
            return true
        }
        return false
    }

    private static func containsReadableText(_ element: AXUIElement, depth: Int, seen: Int) -> (found: Bool, seen: Int) {
        if depth > 12 || seen > 240 { return (false, seen) }
        let next = seen + 1
        let role = copyString(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole || role == "AXHeading" || role == kAXButtonRole || role == kAXPopUpButtonRole,
           readableText(element) != nil {
            return (true, next)
        }
        var count = next
        for child in copyChildren(element) {
            let result = containsReadableText(child, depth: depth + 1, seen: count)
            if result.found { return result }
            count = result.seen
        }
        return (false, count)
    }

    private static func walk(
        _ element: AXUIElement,
        pid: pid_t,
        anchor: VisibleWindow?,
        windows: [VisibleWindow],
        screen: CGRect?,
        overlay: Bool,
        selection: Bool,
        deadline: Date,
        into raw: inout [TextBlock],
        budget: inout Int,
        depth: Int
    ) {
        if depth > 70 || budget <= 0 || raw.count >= 700 || Date() > deadline { return }
        budget -= 1
        if isSecure(element) { return }
        let role = copyString(element, kAXRoleAttribute) ?? ""
        if role == kAXMenuBarRole || role == "AXMenuBar" { return }
        let children = copyChildren(element)
        let childHasText = children.contains { readableText($0) != nil }
        if !childHasText, let text = readableText(element), let frame = copyFrame(element), frame.width >= 8, frame.height >= 8 {
            let shown = overlay ? onScreen(frame, screen: screen, selection: selection) : isVisible(frame, pid: pid, anchor: anchor, windows: windows)
            let chosen = !selection || screen == nil || screen!.intersects(frame)
            if shown && chosen {
                raw.append(TextBlock(text: text, bounds: frame))
            }
        }
        for child in children {
            walk(child, pid: pid, anchor: anchor, windows: windows, screen: screen, overlay: overlay, selection: selection, deadline: deadline, into: &raw, budget: &budget, depth: depth + 1)
        }
    }

    private static func isPartiallyVisible(_ window: VisibleWindow, in windows: [VisibleWindow]) -> Bool {
        let bounds = window.bounds
        let inset = bounds.insetBy(dx: min(12, bounds.width / 4), dy: min(12, bounds.height / 4))
        let points = [
            CGPoint(x: inset.midX, y: inset.midY),
            CGPoint(x: inset.minX, y: inset.minY),
            CGPoint(x: inset.maxX, y: inset.minY),
            CGPoint(x: inset.minX, y: inset.maxY),
            CGPoint(x: inset.maxX, y: inset.maxY),
        ]
        return points.contains { point in
            windows.first(where: { $0.bounds.contains(point) })?.id == window.id
        }
    }

    private static func onScreen(_ frame: CGRect, screen: CGRect?, selection: Bool) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen, screen.width > 10, screen.height > 10 {
            if selection { return screen.intersects(frame) }
            return screen.contains(center)
        }
        let displays = NSScreen.screens.map { Coordinates.appKitToAX($0.frame, primaryHeight: Coordinates.primaryHeight) }
        return displays.contains { $0.contains(center) }
    }

    private static func tightlyMatches(_ frame: CGRect, _ window: VisibleWindow) -> Bool {
        let intersection = frame.intersection(window.bounds)
        if intersection.isNull || intersection.isEmpty { return false }
        let score = intersection.width * intersection.height
        let frameArea = max(frame.width * frame.height, 1)
        let windowArea = max(window.bounds.width * window.bounds.height, 1)
        return score / frameArea >= 0.8 && score / windowArea >= 0.8
    }

    private static func collectPopup(
        _ window: VisibleWindow,
        screen: CGRect?,
        selection: Bool,
        deadline: Date,
        into raw: inout [TextBlock],
        budget: inout Int
    ) {
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit) == .success,
              let hit,
              let root = menuRoot(hit, within: window.bounds) else { return }
        walk(root, pid: window.pid, anchor: nil, windows: [window], screen: screen, overlay: true, selection: selection, deadline: deadline, into: &raw, budget: &budget, depth: 0)
    }

    private static func menuRoot(_ element: AXUIElement, within bounds: CGRect) -> AXUIElement? {
        var current = element
        var best: AXUIElement?
        for _ in 0..<14 {
            let role = copyString(current, kAXRoleAttribute) ?? ""
            if role == kAXMenuRole, let frame = copyFrame(current), frame.intersects(bounds) {
                best = current
            }
            guard let next = copyParent(current) else { break }
            let parentRole = copyString(next, kAXRoleAttribute) ?? ""
            if parentRole != kAXMenuRole && parentRole != kAXMenuItemRole {
                break
            }
            current = next
        }
        if let best { return best }
        if let frame = copyFrame(element), frame.intersects(bounds) { return element }
        return nil
    }

    private static func popupWindows() -> [VisibleWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let screens = NSScreen.screens.map { Coordinates.appKitToAX($0.frame, primaryHeight: Coordinates.primaryHeight) }
        var result: [VisibleWindow] = []
        let mine = getpid()
        for item in info {
            let layer = number(item[kCGWindowLayer as String]) ?? 0
            if layer < 20 { continue }
            guard let pid = number(item[kCGWindowOwnerPID as String]).map({ pid_t($0) }), pid != 0, pid != mine else { continue }
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), rect.width >= 40, rect.height >= 40 else { continue }
            if coversScreen(rect, screens: screens) { continue }
            let id = CGWindowID(number(item[kCGWindowNumber as String]) ?? 0)
            result.append(VisibleWindow(pid: pid, bounds: rect, id: id, readable: true))
        }
        return result
    }

    private static func notificationWindows() -> [VisibleWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var bundleByPid: [pid_t: String] = [:]
        var result: [VisibleWindow] = []
        for item in info {
            guard let pid = number(item[kCGWindowOwnerPID as String]).map({ pid_t($0) }), pid != 0, pid != getpid() else { continue }
            let bundle = bundleByPid[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            bundleByPid[pid] = bundle
            guard bundle == "com.apple.notificationcenterui" else { continue }
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), rect.width >= 16, rect.height >= 16 else { continue }
            let id = CGWindowID(number(item[kCGWindowNumber as String]) ?? 0)
            result.append(VisibleWindow(pid: pid, bounds: rect, id: id, readable: true))
        }
        return result
    }

    private static func isVisible(_ frame: CGRect, pid: pid_t, anchor: VisibleWindow?, windows: [VisibleWindow]) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let top = windows.first(where: { $0.bounds.contains(center) }) else { return false }
        if let anchor {
            if top.id != anchor.id { return false }
            let expanded = anchor.bounds.insetBy(dx: -8, dy: -8)
            return expanded.contains(center)
        }
        return top.readable && top.pid == pid
    }

    private static func match(_ frame: CGRect, to windows: [VisibleWindow]) -> VisibleWindow? {
        var best: VisibleWindow?
        var bestScore: CGFloat = 0
        let frameArea = max(frame.width * frame.height, 1)
        for window in windows {
            let intersection = frame.intersection(window.bounds)
            if intersection.isNull || intersection.isEmpty { continue }
            let score = intersection.width * intersection.height
            let otherArea = max(window.bounds.width * window.bounds.height, 1)
            let fraction = score / min(frameArea, otherArea)
            if fraction < 0.35 { continue }
            if score > bestScore {
                bestScore = score
                best = window
            }
        }
        return best
    }

    private static func visibleWindows() -> [VisibleWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [VisibleWindow] = []
        let mine = getpid()
        for item in info {
            let layer = number(item[kCGWindowLayer as String]) ?? 0
            if layer < 0 || layer >= 20 { continue }
            guard let pid = number(item[kCGWindowOwnerPID as String]).map({ pid_t($0) }), pid != 0 else { continue }
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { continue }
            if rect.width < 16 || rect.height < 16 { continue }
            let id = CGWindowID(number(item[kCGWindowNumber as String]) ?? 0)
            result.append(VisibleWindow(pid: pid, bounds: rect, id: id, readable: pid != mine))
        }
        return result
    }

    private static func copyParent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyWindows(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        if error == .success, let windows = value as? [AXUIElement], !windows.isEmpty {
            return windows
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return [] }
        return [unsafeBitCast(focused, to: AXUIElement.self)]
    }

    private static func readableText(_ element: AXUIElement) -> String? {
        let role = copyString(element, kAXRoleAttribute) ?? ""
        let values: [String?]
        switch role {
        case kAXStaticTextRole, "AXHeading", "AXLink", "AXUnknown":
            values = [
                copyString(element, kAXValueAttribute),
                copyString(element, kAXTitleAttribute),
                copyString(element, kAXDescriptionAttribute),
            ]
        case kAXTextFieldRole, kAXTextAreaRole, "AXSearchField", "AXComboBox":
            values = [copyString(element, kAXValueAttribute)]
        case kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, "AXMenuButton", kAXMenuItemRole, "AXCell", "AXRow":
            values = [
                copyString(element, kAXTitleAttribute),
                copyString(element, kAXValueAttribute),
                copyString(element, kAXDescriptionAttribute),
            ]
        default:
            return nil
        }
        for value in values {
            let text = normalizeScreenText(value ?? "")
            if text.contains(where: { $0.isLetter }) {
                return text
            }
        }
        return nil
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        copyString(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        guard let origin = copyPoint(element, kAXPositionAttribute),
              let size = copySize(element, kAXSizeAttribute),
              size.width >= 1, size.height >= 1 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func word(at point: CGPoint) -> TextBlock? {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        if let block = wordInFrontWindow(at: point) { return block }
        switch wordNow(at: point) {
        case .block(let block):
            return block
        case .missed, .empty:
            if let hit = copyHit(at: point) {
                var pid: pid_t = 0
                AXUIElementGetPid(hit, &pid)
                if pid == getpid() || isSecure(hit) { return nil }
            }
            if let block = wordInCapture(at: point) { return block }
            guard let hit = copyHit(at: point), revealWeb(from: hit) else { return nil }
            if case .block(let block) = wordNow(at: point) { return block }
            return nil
        }
    }

    private static func wordInCapture(at point: CGPoint) -> TextBlock? {
        let rect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        let blocks = capture(on: rect, selection: true, limit: 40)
        guard let block = nearest(blocks, to: point) else { return nil }
        let tokens = wordTokens(block.text)
        guard let first = tokens.first else { return nil }
        if tokens.count == 1 {
            let word = normalizeScreenText(first.text)
            guard word.contains(where: { $0.isLetter }) else { return nil }
            return TextBlock(text: word, bounds: block.bounds)
        }
        if case .block(let word) = layoutWords(block.text, role: kAXMenuItemRole, in: block.bounds, at: point) {
            return word
        }
        guard block.bounds.height <= 80 else { return nil }
        let font = NSFont.systemFont(ofSize: max(9, min(block.bounds.height * 0.72, 28)))
        let natural = (block.text as NSString).size(withAttributes: [.font: font]).width
        guard natural + 24 < block.bounds.width else { return nil }
        let token = point.x < block.bounds.midX ? first : tokens[tokens.count - 1]
        let word = normalizeScreenText(token.text)
        guard word.contains(where: { $0.isLetter }) else { return nil }
        return TextBlock(text: word, bounds: block.bounds)
    }

    private static func nearest(_ blocks: [TextBlock], to point: CGPoint) -> TextBlock? {
        let ranked = blocks.sorted { lhs, rhs in
            let left = gap(lhs.bounds, point)
            let right = gap(rhs.bounds, point)
            if left != right { return left < right }
            return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
        guard let block = ranked.first, gap(block.bounds, point) <= 12 else { return nil }
        return block
    }

    private static func gap(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
        let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
        return hypot(dx, dy)
    }

    private static func wordInFrontWindow(at point: CGPoint) -> TextBlock? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let screens = NSScreen.screens.map { Coordinates.appKitToAX($0.frame, primaryHeight: Coordinates.primaryHeight) }
        let mine = getpid()
        for item in info {
            let layer = number(item[kCGWindowLayer as String]) ?? 0
            if layer < 0 { continue }
            guard let pid = number(item[kCGWindowOwnerPID as String]).map({ pid_t($0) }), pid != 0, pid != mine else { continue }
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), rect.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            let large = rect.width > 1000 || rect.height > 720 || coversScreen(rect, screens: screens)
            if large && layer >= 20 { continue }
            if large && layer < 3 { return nil }
            return word(inApp: pid, matching: rect, at: point)
        }
        return nil
    }

    private static func word(inApp pid: pid_t, matching bounds: CGRect, at point: CGPoint) -> TextBlock? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = copyWindows(app)
        let roots = windows.isEmpty ? copyChildren(app) : windows
        for root in roots {
            guard let frame = copyFrame(root) else { continue }
            let hit = frame.insetBy(dx: -8, dy: -8).contains(point)
            let overlap = frame.intersection(bounds)
            let aligned = !overlap.isNull && overlap.width * overlap.height > min(frame.width * frame.height, bounds.width * bounds.height) * 0.45
            if !hit && !aligned { continue }
            guard let element = smallestText(in: root, at: point, depth: 0, budget: 500) else { continue }
            if case .block(let block) = word(from: element, at: point) { return block }
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard let text = smallestText(in: element, at: point, depth: 0, budget: 200) else { return nil }
        if case .block(let block) = word(from: text, at: point) { return block }
        return nil
    }

    private static func coversScreen(_ rect: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let intersection = screen.intersection(rect)
            if intersection.isNull || intersection.isEmpty { return false }
            return intersection.width * intersection.height > screen.width * screen.height * 0.85
        }
    }

    private enum WordHit {
        case block(TextBlock)
        case missed
        case empty
    }

    private static func wordNow(at point: CGPoint) -> WordHit {
        guard let element = textElement(containing: point) else { return .empty }
        return word(from: element, at: point)
    }

    private static func word(from element: AXUIElement, at point: CGPoint) -> WordHit {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == getpid() || isSecure(element) { return .missed }
        guard let raw = wordString(element) else { return .empty }
        let length = (raw as NSString).length
        guard length > 0 else { return .empty }
        if case .unsupported = rangeBounds(element, NSRange(location: 0, length: 1)) {
            return measuredWord(raw, element: element, at: point)
        }
        if let index = characterIndex(in: element, length: length, at: point),
           let token = wordTokens(raw).first(where: { NSLocationInRange(index, $0.range) }),
           let block = block(for: token, element: element, at: point) {
            return .block(block)
        }
        if length <= 600, let token = wordTokens(raw).first(where: { token in
            guard case .rect(let rect) = rangeBounds(element, token.range) else { return false }
            return rect.insetBy(dx: -2, dy: -2).contains(point)
        }), let block = block(for: token, element: element, at: point) {
            return .block(block)
        }
        if let block = wordOnLine(raw, element: element, at: point) { return .block(block) }
        return measuredWord(raw, element: element, at: point)
    }

    private static func wordString(_ element: AXUIElement) -> String? {
        if let text = rawString(element) { return text }
        let role = copyString(element, kAXRoleAttribute) ?? ""
        guard role == "AXGroup" || role == "AXDialog" || role == "AXSheet" || role == "AXPopUpButton" else { return nil }
        guard let frame = copyFrame(element), frame.height <= 96, frame.height >= 8, frame.width >= 8 else { return nil }
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXValueAttribute] {
            guard let text = copyString(element, attribute), text.contains(where: { $0.isLetter }) else { continue }
            if (text as NSString).length <= 90 { return text }
        }
        return nil
    }

    private static func wordOnLine(_ raw: String, element: AXUIElement, at point: CGPoint) -> TextBlock? {
        let ns = raw as NSString
        let role = copyString(element, kAXRoleAttribute) ?? ""
        for line in 0..<16 {
            switch lineRange(element, line) {
            case .unsupported:
                return nil
            case .missing:
                return nil
            case .range(let range):
                guard range.location >= 0, range.length > 0, range.location + range.length <= ns.length else { return nil }
                if case .rect(let rect) = rangeBounds(element, range), rect.insetBy(dx: -3, dy: -3).contains(point) {
                    let lineText = ns.substring(with: range)
                    if case .block(let block) = layoutWords(lineText, role: role, in: rect, at: point) {
                        return block
                    }
                    return nil
                }
                if range.location + range.length >= ns.length { return nil }
            }
        }
        return nil
    }

    private enum LineRange {
        case range(NSRange)
        case unsupported
        case missing
    }

    private static func lineRange(_ element: AXUIElement, _ line: Int) -> LineRange {
        let number = NSNumber(value: line)
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            number,
            &result
        )
        if error == .parameterizedAttributeUnsupported || error == .attributeUnsupported || error == .notImplemented {
            return .unsupported
        }
        guard error == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return .missing }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue((result as! AXValue), .cfRange, &cfRange), cfRange.location >= 0, cfRange.length > 0 else {
            return .missing
        }
        return .range(NSRange(location: cfRange.location, length: cfRange.length))
    }

    private static func block(for token: WordToken, element: AXUIElement, at point: CGPoint) -> TextBlock? {
        let rect: CGRect
        if case .rect(let value) = rangeBounds(element, token.range) {
            rect = value
        } else if let frame = copyFrame(element) {
            rect = frame
        } else {
            return nil
        }
        let word = normalizeScreenText(token.text)
        guard word.contains(where: { $0.isLetter }), rect.width >= 1, rect.height >= 1 else { return nil }
        if !rect.insetBy(dx: -4, dy: -4).contains(point), let frame = copyFrame(element), !frame.contains(point) {
            return nil
        }
        return TextBlock(text: word, bounds: rect)
    }

    private static func textElement(containing point: CGPoint) -> AXUIElement? {
        guard let hit = copyHit(at: point) else { return nil }
        if let found = smallestText(in: hit, at: point, depth: 0, budget: 200) { return found }
        var current = hit
        for _ in 0..<16 {
            guard let parent = copyParent(current) else { return nil }
            current = parent
            if let found = smallestText(in: current, at: point, depth: 0, budget: 400) { return found }
        }
        return nil
    }

    private static func smallestText(in element: AXUIElement, at point: CGPoint, depth: Int, budget: Int) -> AXUIElement? {
        var remaining = budget
        return smallestText(in: element, at: point, depth: depth, budget: &remaining)
    }

    private static func smallestText(in element: AXUIElement, at point: CGPoint, depth: Int, budget: inout Int) -> AXUIElement? {
        if depth > 10 || budget <= 0 { return nil }
        budget -= 1
        var best: AXUIElement?
        var bestArea = CGFloat.greatestFiniteMagnitude
        if wordString(element) != nil, let frame = copyFrame(element), frame.insetBy(dx: -4, dy: -4).contains(point) {
            best = element
            bestArea = frame.width * frame.height
        }
        for child in copyChildren(element) {
            guard budget > 0 else { break }
            if let frame = copyFrame(child), !frame.insetBy(dx: -8, dy: -8).contains(point), frame.width > 4, frame.height > 4 {
                continue
            }
            guard let found = smallestText(in: child, at: point, depth: depth + 1, budget: &budget),
                  let frame = copyFrame(found) else { continue }
            let area = frame.width * frame.height
            if area < bestArea {
                best = found
                bestArea = area
            }
        }
        return best
    }

    private static func copyHit(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success else {
            return nil
        }
        return element
    }

    private static func revealWeb(from element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == 0 || pid == getpid() { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var current: AXUIElement? = element
        var web: AXUIElement?
        for _ in 0..<24 {
            guard let node = current else { break }
            if copyString(node, kAXRoleAttribute) == "AXWebArea" { web = node }
            current = copyParent(node)
        }
        guard let web else { return false }
        guard AXUIElementSetAttributeValue(web, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success else { return false }
        Thread.sleep(forTimeInterval: 0.35)
        return true
    }

    private enum RangeBounds {
        case rect(CGRect)
        case unsupported
        case missing
    }

    private static func rangeBounds(_ element: AXUIElement, _ range: NSRange) -> RangeBounds {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .missing }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            value,
            &result
        )
        if error == .parameterizedAttributeUnsupported || error == .attributeUnsupported || error == .notImplemented {
            return .unsupported
        }
        guard error == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return .missing }
        var rect = CGRect.zero
        guard AXValueGetValue((result as! AXValue), .cgRect, &rect), rect.width >= 1, rect.height >= 1 else { return .missing }
        return .rect(rect)
    }

    private static func characterIndex(in element: AXUIElement, length: Int, at point: CGPoint) -> Int? {
        var low = 0
        var high = length - 1
        while low <= high {
            let mid = (low + high) / 2
            switch rangeBounds(element, NSRange(location: mid, length: 1)) {
            case .unsupported:
                return nil
            case .missing:
                return nil
            case .rect(let rect):
                if rect.insetBy(dx: -1, dy: -1).contains(point) { return mid }
                if rect.maxY < point.y - 1 {
                    low = mid + 1
                } else if rect.minY > point.y + 1 {
                    high = mid - 1
                } else if rect.maxX < point.x {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
        }
        return nil
    }

    private struct WordToken {
        var text: String
        var range: NSRange
    }

    private static func wordTokens(_ text: String) -> [WordToken] {
        let ns = text as NSString
        var tokens: [WordToken] = []
        var index = 0
        while index < ns.length {
            while index < ns.length, isGap(ns.character(at: index)) { index += 1 }
            if index >= ns.length { break }
            let start = index
            while index < ns.length, !isGap(ns.character(at: index)) { index += 1 }
            var wordStart = start
            var wordEnd = index
            while wordStart < wordEnd, isEdge(ns.character(at: wordStart)) { wordStart += 1 }
            while wordEnd > wordStart, isEdge(ns.character(at: wordEnd - 1)) { wordEnd -= 1 }
            if wordStart >= wordEnd { continue }
            let range = NSRange(location: wordStart, length: wordEnd - wordStart)
            let word = ns.substring(with: range)
            if word.contains(where: { $0.isLetter }) {
                tokens.append(WordToken(text: word, range: range))
            }
        }
        return tokens
    }

    private static func isGap(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isEdge(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    private static func measuredWord(_ raw: String, element: AXUIElement, at point: CGPoint) -> WordHit {
        guard let frame = copyFrame(element) else { return .missed }
        let lines = raw.components(separatedBy: .newlines)
        if lines.count > 1 {
            let band = frame.height / CGFloat(lines.count)
            let index = min(lines.count - 1, max(0, Int((point.y - frame.minY) / max(band, 1))))
            let lineFrame = CGRect(x: frame.minX, y: frame.minY + band * CGFloat(index), width: frame.width, height: band)
            return layoutWords(lines[index], role: copyString(element, kAXRoleAttribute) ?? "", in: lineFrame, at: point)
        }
        return layoutWords(raw, role: copyString(element, kAXRoleAttribute) ?? "", in: frame, at: point)
    }

    private static func layoutWords(_ raw: String, role: String, in frame: CGRect, at point: CGPoint) -> WordHit {
        let tokens = wordTokens(raw)
        guard let token = tokens.first else { return .missed }
        if tokens.count == 1 {
            let word = normalizeScreenText(token.text)
            guard word.contains(where: { $0.isLetter }) else { return .missed }
            return .block(TextBlock(text: word, bounds: frame))
        }
        let font = role == kAXMenuItemRole ? NSFont.menuFont(ofSize: 0) : NSFont.systemFont(ofSize: max(9, min(frame.height * 0.72, 28)))
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let ns = raw as NSString
        let natural = ns.size(withAttributes: attributes).width
        var originX = frame.minX
        if role == kAXMenuItemRole, natural + 18 < frame.width - 4 {
            originX += 18
        } else if natural < frame.width * 0.9 {
            originX += (frame.width - natural) / 2
        }
        for token in tokens {
            let prefix = ns.substring(with: NSRange(location: 0, length: token.range.location))
            let prefixWidth = (prefix as NSString).size(withAttributes: attributes).width
            let wordWidth = max((token.text as NSString).size(withAttributes: attributes).width, 4)
            let rect = CGRect(x: originX + prefixWidth, y: frame.minY, width: wordWidth, height: frame.height)
            if rect.insetBy(dx: -2, dy: -2).contains(point) {
                let word = normalizeScreenText(token.text)
                guard word.contains(where: { $0.isLetter }) else { continue }
                return .block(TextBlock(text: word, bounds: rect))
            }
        }
        return .missed
    }

    private static func rawString(_ element: AXUIElement) -> String? {
        let role = copyString(element, kAXRoleAttribute) ?? ""
        let values: [String?]
        switch role {
        case kAXStaticTextRole, "AXHeading", "AXLink", "AXUnknown":
            values = [
                copyString(element, kAXValueAttribute),
                copyString(element, kAXTitleAttribute),
                copyString(element, kAXDescriptionAttribute),
            ]
        case kAXTextFieldRole, kAXTextAreaRole, "AXSearchField", "AXComboBox":
            values = [copyString(element, kAXValueAttribute)]
        case kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, "AXMenuButton", kAXMenuItemRole, "AXCell", "AXRow":
            values = [
                copyString(element, kAXTitleAttribute),
                copyString(element, kAXValueAttribute),
                copyString(element, kAXDescriptionAttribute),
            ]
        default:
            return nil
        }
        for value in values {
            let text = value ?? ""
            if text.contains(where: { $0.isLetter }) { return text }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

private struct VisibleWindow {
    var pid: pid_t
    var bounds: CGRect
    var id: CGWindowID
    var readable: Bool
}

func normalizeScreenText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

enum LineMerger {
    static func merge(_ items: [TextBlock], gap: CGFloat) -> [TextBlock] {
        mergeHorizontal(dedupe(items), maxGap: gap)
            .sorted { lhs, rhs in
                if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
                return lhs.bounds.minX < rhs.bounds.minX
            }
    }

    private static func dedupe(_ items: [TextBlock]) -> [TextBlock] {
        var kept: [TextBlock] = []
        for item in items {
            let duplicate = kept.contains { other in
                other.text == item.text &&
                    abs(other.bounds.minX - item.bounds.minX) <= 6 &&
                    abs(other.bounds.minY - item.bounds.minY) <= 6 &&
                    abs(other.bounds.width - item.bounds.width) <= 12
            }
            if !duplicate { kept.append(item) }
        }
        return kept
    }

    private static func mergeHorizontal(_ items: [TextBlock], maxGap: CGFloat) -> [TextBlock] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var lines: [TextBlock] = []
        for item in sorted {
            var best = -1
            var bestGap = CGFloat.greatestFiniteMagnitude
            for index in lines.indices {
                let line = lines[index]
                if line.text.count + item.text.count > 1400 { continue }
                if !sameLine(line.bounds, item.bounds) { continue }
                let gap = item.bounds.minX - line.bounds.maxX
                if gap < -8 || gap > maxGap { continue }
                if gap < bestGap {
                    bestGap = gap
                    best = index
                }
            }
            if best >= 0 {
                let previous = lines[best]
                lines[best] = TextBlock(
                    text: join(previous.text, item.text),
                    bounds: previous.bounds.union(item.bounds)
                )
            } else {
                lines.append(item)
            }
        }
        return lines
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let h1 = max(a.height, 1)
        let h2 = max(b.height, 1)
        let taller = max(h1, h2)
        let shorter = min(h1, h2)
        if taller / shorter > 2.4 { return false }
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= shorter * 0.45
    }

    private static func join(_ left: String, _ right: String) -> String {
        if left.hasSuffix("-") { return left + right }
        if let first = right.first, ",.;:!?%)]}".contains(first) { return left + right }
        if let last = left.last, last == "(" || last == "[" { return left + right }
        return "\(left) \(right)"
    }
}
