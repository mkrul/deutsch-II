import AppKit
import Combine
import Translation

enum ModelStatus {
    case checking
    case ready
    case missing
    case unavailable
}

enum TranslateState {
    case idle
    case working
    case showing
    case error
}

struct TranslationOutcome {
    var results: [String: String]
    var attempted: Int
    var failed: Int
}

@MainActor
final class Translator {
    private var cache: [String: String] = [:]
    private var session: TranslationSession?

    func cancel() {
        session?.cancel()
    }

    func translate(_ texts: [String]) async throws -> TranslationOutcome {
        let unique = Array(Set(texts))
        var results: [String: String] = [:]
        var pending: [String] = []
        for text in unique {
            if let cached = cache[text] {
                results[text] = cached
            } else {
                pending.append(text)
            }
        }
        if pending.isEmpty {
            return TranslationOutcome(results: results, attempted: unique.count, failed: 0)
        }
        let active = TranslationSession(
            installedSource: Locale.Language(identifier: "de"),
            target: Locale.Language(identifier: "en")
        )
        session = active
        defer { session = nil }
        var failed = 0
        for chunk in pending.chunks(of: 24) {
            try Task.checkCancellation()
            let requests = chunk.enumerated().map { offset, text in
                let source = text.count > 1500 ? String(text.prefix(1500)) : text
                return TranslationSession.Request(sourceText: source, clientIdentifier: "\(offset)")
            }
            do {
                let responses = try await active.translations(from: requests)
                var got = Set<Int>()
                for response in responses {
                    let parsed = response.clientIdentifier.flatMap(Int.init)
                    let index = parsed.flatMap { chunk.indices.contains($0) ? $0 : nil }
                        ?? chunk.firstIndex(of: response.sourceText)
                    guard let index else { continue }
                    let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if translated.isEmpty { continue }
                    let source = chunk[index]
                    cache[source] = translated
                    results[source] = translated
                    got.insert(index)
                }
                failed += chunk.indices.filter { !got.contains($0) }.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if TranslationError.notInstalled ~= error || TranslationError.alreadyCancelled ~= error {
                    throw error
                }
                for (offset, text) in chunk.enumerated() {
                    try Task.checkCancellation()
                    let source = text.count > 1500 ? String(text.prefix(1500)) : text
                    do {
                        let response = try await active.translate(source)
                        let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if translated.isEmpty {
                            failed += 1
                        } else {
                            cache[text] = translated
                            results[text] = translated
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if TranslationError.notInstalled ~= error {
                            throw TranslationError.notInstalled
                        }
                        failed += 1
                        _ = offset
                    }
                }
            }
        }
        if cache.count > 500 { cache.removeAll() }
        return TranslationOutcome(results: results, attempted: unique.count, failed: failed)
    }
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = AppModel()

    @Published var apiKey: String = Prefs.apiKey {
        didSet {
            let clean = Self.cleanKey(apiKey)
            if clean != apiKey {
                apiKey = clean
                return
            }
            Prefs.apiKey = clean
        }
    }
    @Published var apiKeyDraft = ""
    @Published var apiKeyEditing = false
    @Published var hotkey: Hotkey = Prefs.hotkey {
        didSet { updateChrome() }
    }
    @Published var regionHotkey: Hotkey = Prefs.regionHotkey {
        didSet { updateChrome() }
    }
    @Published var wordHotkey: Hotkey = Prefs.wordHotkey {
        didSet { updateChrome() }
    }
    @Published var recording = false {
        didSet { updateChrome() }
    }
    @Published var recordingRegion = false {
        didSet { updateChrome() }
    }
    @Published var recordingWord = false {
        didSet { updateChrome() }
    }
    @Published var hotkeyError: String?
    @Published var accessibilityOn = false
    @Published var modelStatus: ModelStatus = .checking
    @Published var downloading = false
    @Published var downloadError: String?
    @Published var downloadConfiguration: TranslationSession.Configuration?
    @Published var state: TranslateState = .idle {
        didSet { updateChrome() }
    }
    @Published var banner: String?
    @Published var macLanguageGerman = false
    @Published var languageNote: String?

    var showWindow: () -> Void = {}

    private let translator = Translator()
    private let overlay = OverlayController()
    private let hud = StatusHUD()
    private var statusItem: NSStatusItem?
    private var regionItem: NSMenuItem?
    private var wordItem: NSMenuItem?
    private var languageItem: NSMenuItem?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var recordMonitor: Any?
    private var pendingModifier: UInt16?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var relaunchAfterAccessibility = false
    private var accessibilityWasBackgrounded = false
    private var downloadAttempt = 0
    private var prepareStarted = false
    private let regionSelector = RegionSelector()
    private var pageTap: CFMachPort?
    private var pageTapSource: CFRunLoopSource?

    private override init() {
        super.init()
        overlay.onShow = { [weak self] in
            self?.showedTranslation()
        }
        overlay.onClose = { [weak self] in
            self?.removePageKeys()
        }
        overlay.onSpeechError = { [weak self] message in
            self?.showError(message)
        }
        overlay.apiKey = { [weak self] in
            self?.apiKey ?? ""
        }
        let clean = Self.cleanKey(apiKey)
        if clean != apiKey { apiKey = clean }
        apiKeyDraft = apiKey
        apiKeyEditing = apiKey.isEmpty
        regionSelector.onSelect = { rect in
            Task { @MainActor in
                AppModel.shared.translate(region: rect)
            }
        }
    }

    func beginApiKeyEdit() {
        apiKeyDraft = apiKey
        apiKeyEditing = true
    }

    func cancelApiKeyEdit() {
        apiKeyDraft = apiKey
        apiKeyEditing = false
    }

    func lockApiKey() {
        let clean = Self.cleanKey(apiKeyDraft)
        apiKey = clean
        apiKeyDraft = clean
        apiKeyEditing = clean.isEmpty
    }

    func start() {
        let clean = Self.cleanKey(apiKey)
        if clean != apiKey { apiKey = clean }
        installStatusItem()
        if let message = registerHotkeys() {
            hotkeyError = message
        }
        refreshAccessibility()
        refreshMacLanguage()
        Task { await refreshModel() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                AppModel.shared.refreshAccessibility()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppModel.shared.refreshAccessibility()
                AppModel.shared.refreshMacLanguage()
                await AppModel.shared.refreshModel()
                AppModel.shared.relaunchIfAccessibilityChanged()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if AppModel.shared.relaunchAfterAccessibility {
                    AppModel.shared.accessibilityWasBackgrounded = true
                }
            }
        }
        updateChrome()
    }

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityOn {
            accessibilityOn = trusted
        }
        if trusted {
            relaunchAfterAccessibility = false
            accessibilityWasBackgrounded = false
        }
    }

    private func relaunchIfAccessibilityChanged() {
        guard relaunchAfterAccessibility, accessibilityWasBackgrounded else { return }
        relaunchAfterAccessibility = false
        accessibilityWasBackgrounded = false
        guard !AXIsProcessTrusted() else { return }
        relaunch()
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func refreshModel() async {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: "de"),
            to: Locale.Language(identifier: "en")
        )
        switch status {
        case .installed:
            modelStatus = .ready
        case .supported:
            modelStatus = .missing
        case .unsupported:
            modelStatus = .unavailable
        @unknown default:
            modelStatus = .unavailable
        }
    }

    func performPrimary() {
        if !accessibilityOn {
            requestAccessibility()
            return
        }
        if modelStatus == .checking || modelStatus == .unavailable || downloading {
            return
        }
        if modelStatus != .ready {
            startDownload()
            return
        }
        if recording { cancelRecording() }
        if recordingRegion { cancelRegionRecording() }
        if recordingWord { cancelWordRecording() }
        performHotkeyAction()
    }

    func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [prompt: true] as CFDictionary
        relaunchAfterAccessibility = true
        accessibilityWasBackgrounded = false
        AXIsProcessTrustedWithOptions(options)
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for candidate in urls {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { break }
        }
    }

    func startDownload() {
        guard !downloading else { return }
        downloading = true
        downloadError = nil
        prepareStarted = false
        var configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "de"),
            target: Locale.Language(identifier: "en")
        )
        downloadAttempt += 1
        for _ in 0..<downloadAttempt {
            configuration.invalidate()
        }
        downloadConfiguration = configuration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.downloading && !self.prepareStarted {
                self.downloading = false
                self.downloadError = "The download failed. Check the connection and try again."
            }
        }
    }

    func prepareDownload(using session: TranslationSession) async {
        guard downloading else { return }
        prepareStarted = true
        do {
            try await session.prepareTranslation()
            await refreshModel()
            if modelStatus != .ready {
                downloadError = "The download failed. Check the connection and try again."
            } else {
                downloadError = nil
            }
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            downloadError = message.isEmpty
                ? "The download failed. Check the connection and try again."
                : message
        }
        downloading = false
    }

    func toggleRecording() {
        if recording {
            cancelRecording()
        } else {
            if recordingRegion { cancelRegionRecording() }
            if recordingWord { cancelWordRecording() }
            beginRecording()
        }
    }

    func toggleRegionRecording() {
        if recordingRegion {
            cancelRegionRecording()
        } else {
            if recording { cancelRecording() }
            if recordingWord { cancelWordRecording() }
            beginRegionRecording()
        }
    }

    func toggleWordRecording() {
        if recordingWord {
            cancelWordRecording()
        } else {
            if recording { cancelRecording() }
            if recordingRegion { cancelRegionRecording() }
            beginWordRecording()
        }
    }

    func hotkeyPressed() {
        guard !recording, !recordingRegion, !recordingWord else { return }
        if regionSelector.active {
            regionSelector.end()
            return
        }
        performHotkeyAction()
    }

    func regionHotkeyPressed() {
        guard !recording, !recordingRegion, !recordingWord else { return }
        if regionSelector.active {
            regionSelector.end()
            return
        }
        if state == .working {
            cancelWork()
        }
        if overlay.isOpen {
            clearOverlay()
        }
        regionSelector.begin()
    }

    func wordHotkeyPressed() {
        guard !recording, !recordingRegion, !recordingWord else { return }
        if regionSelector.active {
            regionSelector.end()
            return
        }
        startTranslation(word: true)
    }

    func translate(region rect: CGRect) {
        let ax = Coordinates.appKitToAX(rect, primaryHeight: Coordinates.primaryHeight)
        startTranslation(region: ax)
    }

    var primaryTitle: String {
        if !accessibilityOn { return "Open Accessibility settings" }
        switch modelStatus {
        case .checking:
            return "Checking the offline model…"
        case .unavailable:
            return "German to English is unavailable"
        case .missing:
            return downloading ? "Downloading…" : "Download German to English"
        case .ready:
            return actionTitle
        }
    }

    var showsPrimaryButton: Bool {
        if !accessibilityOn { return true }
        switch modelStatus {
        case .ready:
            return state == .working || state == .showing
        case .checking, .missing, .unavailable:
            return true
        }
    }

    var primaryEnabled: Bool {
        if downloading || modelStatus == .checking || modelStatus == .unavailable { return false }
        return true
    }

    var helperText: String {
        if !accessibilityOn {
            return "Turn on accessibility for Translate. System Settings lists it under Privacy & Security, Accessibility. The switch must be on. Translate reopens itself after you turn the switch on. The region and word hotkeys do not read the screen until you press them."
        }
        if modelStatus != .ready, let downloadError, !downloadError.isEmpty {
            return downloadError
        }
        switch modelStatus {
        case .checking:
            return "Checking whether German to English is on this Mac."
        case .unavailable:
            return "German to English is not available on this Mac."
        case .missing:
            return "Download German to English once. After this, translation stays on this Mac. Words from other apps are not uploaded and are not saved."
        case .ready:
            return "Press \(regionHotkey.display), then drag over one section, to translate that section. Press \(wordHotkey.display) to translate the German word under the pointer. The English appears in a bubble under the Translate menu bar icon. Click a speaker in the bubble to hear that German. Press Escape to close the bubble."
        }
    }

    var translationStatus: String {
        switch state {
        case .idle:
            return "Translation: off"
        case .working:
            return "Translation: working"
        case .showing:
            return "Translation: on"
        case .error:
            return banner ?? "Translation: off"
        }
    }

    var modelStatusText: String {
        switch modelStatus {
        case .checking: return "Offline model: checking"
        case .ready: return "Offline model: ready"
        case .missing: return "Offline model: not downloaded"
        case .unavailable: return "Offline model: unavailable"
        }
    }

    var hotkeyDetail: String? {
        if recordingRegion || recordingWord { return nil }
        if let hotkeyError { return hotkeyError }
        if recording { return "Press a key, or tap ⌘, ⌥, ⌃, or ⇧. Escape cancels." }
        return nil
    }

    var regionHotkeyDetail: String? {
        guard recordingRegion else { return nil }
        if let hotkeyError { return hotkeyError }
        return "Press a key, or tap ⌘, ⌥, ⌃, or ⇧. Escape cancels."
    }

    var wordHotkeyDetail: String? {
        guard recordingWord else { return nil }
        if let hotkeyError { return hotkeyError }
        return "Press a key, or tap ⌘, ⌥, ⌃, or ⇧. Escape cancels."
    }

    private var actionTitle: String {
        if state == .working { return "Cancel translation" }
        return "Clear translation"
    }

    private func performHotkeyAction() {
        if state == .working {
            cancelWork()
            return
        }
        if overlay.isOpen {
            clearOverlay()
        }
    }

    private func startTranslation(region: CGRect? = nil, word: Bool = false) {
        guard word || region != nil else { return }
        generation += 1
        let token = generation
        overlay.clear()
        banner = nil
        state = .working
        hud.show("Translating…", color: Palette.working)
        task?.cancel()
        translator.cancel()
        task = Task { await self.run(token, region: region, word: word) }
    }

    private func cancelWork() {
        generation += 1
        task?.cancel()
        task = nil
        translator.cancel()
        overlay.clear()
        hud.hide()
        banner = nil
        state = .idle
    }

    private func clearOverlay() {
        overlay.clear()
        hud.hide()
        banner = nil
        state = .idle
    }

    private func run(_ token: Int, region: CGRect?, word: Bool = false) async {
        if !AXIsProcessTrusted() {
            accessibilityOn = false
            showErrorIfCurrent(token, "Turn on accessibility for Translate")
            return
        }
        if modelStatus != .ready {
            await refreshModel()
        }
        if modelStatus == .unavailable {
            showErrorIfCurrent(token, "German to English is not available on this Mac")
            return
        }
        if modelStatus != .ready {
            showErrorIfCurrent(token, "Download German to English in Translate first")
            return
        }
        let mouse = NSEvent.mouseLocation
        let place = word ? "under the pointer" : "in this selection"
        let point = CGPoint(x: mouse.x, y: Coordinates.primaryHeight - mouse.y)
        let captured = await Task.detached(priority: .userInitiated) {
            if word {
                guard let block = ScreenReader.word(at: point) else { return ([TextBlock](), [TextBlock]()) }
                return ([block], LanguageFilter.german([block]))
            }
            guard let region else { return ([TextBlock](), [TextBlock]()) }
            let raw = ScreenReader.capture(on: region, selection: true, limit: 700)
            return (raw, LanguageFilter.german(raw))
        }.value
        guard token == generation, !Task.isCancelled else { return }
        if captured.0.isEmpty {
            showErrorIfCurrent(token, word ? "No readable text" : "No readable text \(place)")
            return
        }
        let blocks = captured.1
        let missing = word ? "Nothing to translate" : "No German to translate \(place)"
        if blocks.isEmpty {
            showErrorIfCurrent(token, missing)
            return
        }
        let unique = Array(Set(blocks.map(\.text)))
        let outcome: TranslationOutcome
        do {
            outcome = try await translated(unique)
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            await refreshModel()
            if modelStatus == .ready {
                showErrorIfCurrent(token, "Could not translate that. Try again.")
            } else {
                showErrorIfCurrent(token, "Download German to English in Translate again")
            }
            return
        }
        guard token == generation, !Task.isCancelled else { return }
        if outcome.attempted > 0 && outcome.failed == outcome.attempted {
            await refreshModel()
            if modelStatus == .ready {
                showErrorIfCurrent(token, "Could not translate that. Try again.")
            } else {
                showErrorIfCurrent(token, "Download German to English in Translate again")
            }
            return
        }
        let visible: [TranslatedBlock] = blocks.compactMap { block in
            guard let english = outcome.results[block.text]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !english.isEmpty,
                  english.caseInsensitiveCompare(block.text) != .orderedSame else { return nil }
            let oneWord = english.split(whereSeparator: \.isWhitespace).count < 2
            if !oneWord && LanguageFilter.readsAsGerman(english) { return nil }
            return TranslatedBlock(source: block.text, english: english, bounds: block.bounds)
        }
        if visible.isEmpty {
            showErrorIfCurrent(token, missing)
            return
        }
        guard token == generation, !Task.isCancelled else { return }
        overlay.show(items: visible, anchor: statusAnchor(near: mouse))
        if !overlay.isOpen {
            showErrorIfCurrent(token, "Could not draw the translation")
        }
    }

    private func translated(_ texts: [String]) async throws -> TranslationOutcome {
        do {
            let outcome = try await translator.translate(texts)
            if outcome.attempted == 0 || outcome.failed < outcome.attempted {
                return outcome
            }
        } catch let error where !(error is CancellationError) && TranslationError.notInstalled ~= error {
            await refreshModel()
            guard modelStatus == .ready else { throw error }
        }
        return try await translator.translate(texts)
    }

    private func showedTranslation() {
        banner = nil
        hud.hide()
        if state != .showing {
            state = .showing
        } else {
            updateChrome()
        }
        installPageKeys()
    }

    private func installPageKeys() {
        guard pageTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let model = Unmanaged<AppModel>.fromOpaque(userInfo).takeUnretainedValue()
                return model.receivePageKey(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pageTap = tap
        pageTapSource = source
    }

    private func removePageKeys() {
        if let pageTap {
            CGEvent.tapEnable(tap: pageTap, enable: false)
            CFMachPortInvalidate(pageTap)
            self.pageTap = nil
        }
        if let pageTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), pageTapSource, .commonModes)
            self.pageTapSource = nil
        }
    }

    private func receivePageKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let pageTap { CGEvent.tapEnable(tap: pageTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 53 else { return Unmanaged.passUnretained(event) }
        if recording || recordingRegion || recordingWord || regionSelector.active {
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if !event.flags.intersection(modifiers).isEmpty {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.clearOverlay()
        }
        return nil
    }

    private func showErrorIfCurrent(_ token: Int, _ message: String) {
        guard token == generation else { return }
        showError(message)
    }

    private func showError(_ message: String) {
        let restoreShowing = overlay.isOpen
        state = .error
        banner = message
        hud.show(message, color: Palette.error)
        let token = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard self.generation == token, self.state == .error else { return }
            self.banner = nil
            if restoreShowing && self.overlay.isOpen {
                self.state = .showing
                self.hud.hide()
            } else {
                self.state = .idle
                self.hud.hide()
            }
        }
    }

    private func beginRecording() {
        recording = true
        hotkeyError = nil
        regionSelector.end()
        HotkeyCenter.shared.unregister()
        showWindow()
        installRecordMonitor()
    }

    private func beginRegionRecording() {
        recordingRegion = true
        hotkeyError = nil
        regionSelector.end()
        HotkeyCenter.shared.unregister()
        showWindow()
        installRecordMonitor()
    }

    private func beginWordRecording() {
        recordingWord = true
        hotkeyError = nil
        regionSelector.end()
        HotkeyCenter.shared.unregister()
        showWindow()
        installRecordMonitor()
    }

    private func installRecordMonitor() {
        removeMonitor()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            AppModel.shared.consumeRecording(event)
        }
    }

    private func cancelRecording() {
        recording = false
        removeMonitor()
        if let message = registerHotkeys() {
            hotkeyError = message
        }
    }

    private func cancelRegionRecording() {
        recordingRegion = false
        removeMonitor()
        if let message = registerHotkeys() {
            hotkeyError = message
        }
    }

    private func cancelWordRecording() {
        recordingWord = false
        removeMonitor()
        if let message = registerHotkeys() {
            hotkeyError = message
        }
    }

    private func consumeRecording(_ event: NSEvent) -> NSEvent? {
        guard recording || recordingRegion || recordingWord else { return event }
        if event.type == .flagsChanged {
            return consumeModifierRecording(event)
        }
        pendingModifier = nil
        if event.isARepeat { return nil }
        if event.keyCode == 53 {
            if recordingWord {
                cancelWordRecording()
            } else if recordingRegion {
                cancelRegionRecording()
            } else {
                cancelRecording()
            }
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let next = Hotkey(keyCode: Int(event.keyCode), modifiers: modifiers, label: Hotkey.label(for: event))
        return assignRecorded(next)
    }

    private func consumeModifierRecording(_ event: NSEvent) -> NSEvent? {
        let code = Int(event.keyCode)
        guard Hotkey.modifierLabel(for: code) != nil else { return event }
        if Hotkey.modifierIsDown(code, flags: event.modifierFlags) {
            pendingModifier = event.keyCode
            return nil
        }
        guard pendingModifier == event.keyCode else { return nil }
        pendingModifier = nil
        guard let label = Hotkey.modifierLabel(for: code) else { return nil }
        return assignRecorded(Hotkey(keyCode: code, modifiers: [], label: label))
    }

    private func assignRecorded(_ next: Hotkey) -> NSEvent? {
        let region = recordingRegion ? next : regionHotkey
        let word = recordingWord ? next : wordHotkey
        if region == word {
            hotkeyError = "Choose a different key from the other hotkey."
            _ = registerHotkeys()
            return nil
        }
        if let message = HotkeyCenter.shared.register(region: region, word: word) {
            hotkeyError = message
            _ = registerHotkeys()
            return nil
        }
        hotkeyError = nil
        if recordingWord {
            Prefs.wordHotkey = next
            wordHotkey = next
            recordingWord = false
        } else if recordingRegion {
            Prefs.regionHotkey = next
            regionHotkey = next
            recordingRegion = false
        } else {
            Prefs.hotkey = next
            hotkey = next
            recording = false
        }
        removeMonitor()
        return nil
    }

    private func registerHotkeys() -> String? {
        HotkeyCenter.shared.register(region: regionHotkey, word: wordHotkey)
    }

    private func removeMonitor() {
        pendingModifier = nil
        if let recordMonitor {
            NSEvent.removeMonitor(recordMonitor)
            self.recordMonitor = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Translate"
        let menu = NSMenu()
        let select = NSMenuItem(title: "Translate a selection", action: #selector(regionAction), keyEquivalent: "")
        select.target = self
        let regionMenu = NSMenuItem(title: "Region: \(regionHotkey.display)", action: nil, keyEquivalent: "")
        regionMenu.isEnabled = false
        let wordMenu = NSMenuItem(title: "Word: \(wordHotkey.display)", action: nil, keyEquivalent: "")
        wordMenu.isEnabled = false
        let language = NSMenuItem(title: "Switch Mac to English", action: #selector(languageAction), keyEquivalent: "")
        language.target = self
        let open = NSMenuItem(title: "Open Translate", action: #selector(openSettingsAction), keyEquivalent: "")
        open.target = self
        let quit = NSMenuItem(title: "Quit Translate", action: #selector(quitAction), keyEquivalent: "")
        quit.target = self
        menu.addItem(select)
        menu.addItem(regionMenu)
        menu.addItem(wordMenu)
        menu.addItem(.separator())
        menu.addItem(language)
        menu.addItem(open)
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        regionItem = regionMenu
        wordItem = wordMenu
        languageItem = language
    }

    private func updateChrome() {
        guard let statusItem else { return }
        let caption: String?
        let color: NSColor
        switch state {
        case .idle:
            caption = nil
            color = Palette.ink
        case .working:
            caption = "…"
            color = Palette.working
        case .showing:
            caption = nil
            color = Palette.showing
        case .error:
            caption = "!"
            color = Palette.error
        }
        statusItem.button?.image = StatusIcon.image(caption: caption, color: color)
        if recordingRegion {
            regionItem?.title = "Region: setting…"
        } else {
            regionItem?.title = "Region: \(regionHotkey.display)"
        }
        if recordingWord {
            wordItem?.title = "Word: setting…"
        } else {
            wordItem?.title = "Word: \(wordHotkey.display)"
        }
        languageItem?.title = macLanguageGerman ? "Switch Mac to English" : "Switch Mac to German"
    }

    func refreshMacLanguage() {
        macLanguageGerman = SystemLanguage.prefersGerman()
        updateChrome()
    }

    func toggleMacLanguage() {
        let result = SystemLanguage.toggle()
        macLanguageGerman = result.german
        if result.failed {
            languageNote = "The Mac language did not change."
        } else if result.stillOpen.isEmpty {
            languageNote = result.german
                ? "Open apps were quit and opened again in German."
                : "Open apps were quit and opened again in English."
        } else {
            let names = result.stillOpen.joined(separator: ", ")
            languageNote = result.german
                ? "Open apps were quit and opened again in German. These stayed open: \(names)."
                : "Open apps were quit and opened again in English. These stayed open: \(names)."
        }
        updateChrome()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if overlay.isOpen {
            clearOverlay()
        }
    }

    private func statusAnchor(near mouse: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        }
        guard let button = statusItem?.button, let window = button.window else {
            let visible = screen.visibleFrame
            return NSRect(x: visible.maxX - 28, y: visible.maxY, width: 24, height: 0)
        }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        if screen.frame.intersects(icon) {
            return icon
        }
        let iconScreen = NSScreen.screens.first { $0.frame.intersects(icon) }
        let fromRight = (iconScreen?.frame.maxX ?? icon.midX) - icon.midX
        let midX = screen.frame.maxX - fromRight
        let y = min(screen.visibleFrame.maxY, screen.frame.maxY - 1)
        return NSRect(x: midX - icon.width / 2, y: y, width: icon.width, height: 0)
    }

    @objc private func statusAction() {
        if recording { cancelRecording() }
        if recordingRegion { cancelRegionRecording() }
        if recordingWord { cancelWordRecording() }
        if regionSelector.active { regionSelector.end() }
        performHotkeyAction()
    }

    @objc private func regionAction() {
        if recording { cancelRecording() }
        if recordingRegion { cancelRegionRecording() }
        if recordingWord { cancelWordRecording() }
        regionHotkeyPressed()
    }

    @objc private func languageAction() {
        toggleMacLanguage()
    }

    @objc private func openSettingsAction() {
        showWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private static func cleanKey(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
