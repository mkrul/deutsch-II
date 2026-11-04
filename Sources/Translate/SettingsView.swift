import SwiftUI
import Translation

private enum Ink {
    static let paper = Color(red: 246 / 255, green: 241 / 255, blue: 232 / 255)
    static let ink = Color(red: 27 / 255, green: 58 / 255, blue: 75 / 255)
    static let body = Color(red: 36 / 255, green: 48 / 255, blue: 56 / 255)
    static let muted = Color(red: 92 / 255, green: 107 / 255, blue: 115 / 255)
    static let error = Color(red: 140 / 255, green: 47 / 255, blue: 47 / 255)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Translate")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Ink.ink)
                Text("This screen stays in English.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
                    .padding(.top, 4)
                Text("Press the region hotkey, then drag over one section, to translate that section. Press the word hotkey to translate the German word under the pointer. The English appears in a bubble under the Translate menu bar icon. Press Escape to close that bubble. Click a speaker in the bubble to hear that German.\n\nmacOS cannot change the words inside other apps. Leave Translate running. The region and word hotkeys do not read the screen until you press them.")
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.body)
                    .lineSpacing(3)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                status("Accessibility: \(model.accessibilityOn ? "on" : "off")", top: 24, error: false)
                status(model.modelStatusText, top: 6, error: false)
                status(model.translationStatus, top: 6, error: model.state == .error)
                regionHotkeyRow
                wordHotkeyRow
                Text(model.helperText)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.body)
                    .lineSpacing(3)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showsPrimaryButton {
                    Button(action: model.performPrimary) {
                        Text(model.primaryTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.ink)
                    .controlSize(.large)
                    .disabled(!model.primaryEnabled)
                    .padding(.top, 20)
                }
                languageRow
                if model.downloading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
                apiKeyRow
                Text("Paste the key from your ElevenLabs account. Lock keeps the saved key from changing until you choose Edit. It stays on this Mac. A speaker sends that German to ElevenLabs only when you click it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pictures, many games, and some apps do not expose their words, so those stay in German. A normal label, message, or sentence can be translated.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .lineSpacing(3)
                    .padding(.top, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.paper)
        .scrollContentBackground(.hidden)
        .preferredColorScheme(.light)
        .translationTask(model.downloadConfiguration) { session in
            await model.prepareDownload(using: session)
        }
    }

    private var regionHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(model.recordingRegion ? "Press the region hotkey" : "Region: \(model.regionHotkey.display)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 12)
                Button(model.recordingRegion ? "Cancel" : "Set region hotkey") {
                    model.toggleRegionRecording()
                }
                .controlSize(.large)
            }
            if let detail = model.regionHotkeyDetail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(model.hotkeyError == nil ? Ink.muted : Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
    }

    private var wordHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(model.recordingWord ? "Press the word hotkey" : "Word: \(model.wordHotkey.display)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 12)
                Button(model.recordingWord ? "Cancel" : "Set word hotkey") {
                    model.toggleWordRecording()
                }
                .controlSize(.large)
            }
            if let detail = model.wordHotkeyDetail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(model.hotkeyError == nil ? Ink.muted : Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
    }

    private var apiKeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            SecureField("ElevenLabs API key", text: model.apiKeyEditing ? $model.apiKeyDraft : .constant(model.apiKey))
                .textFieldStyle(.roundedBorder)
                .disabled(!model.apiKeyEditing)
            if model.apiKeyEditing {
                if !model.apiKey.isEmpty {
                    Button("Cancel") { model.cancelApiKeyEdit() }
                        .controlSize(.large)
                }
                Button("Lock") { model.lockApiKey() }
                    .controlSize(.large)
            } else {
                Button("Edit") { model.beginApiKeyEdit() }
                    .controlSize(.large)
            }
        }
        .padding(.top, 20)
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(model.macLanguageGerman ? "Mac language: German" : "Mac language: English")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 12)
                Button(model.macLanguageGerman ? "Switch to English" : "Switch to German") {
                    model.toggleMacLanguage()
                }
                .controlSize(.large)
            }
            Text(model.languageNote ?? "This quits open apps and opens them again in the other language. Save your work first. A restart is not required.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    private func status(_ text: String, top: CGFloat, error: Bool) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(error ? Ink.error : Ink.ink)
            .padding(.top, top)
            .fixedSize(horizontal: false, vertical: true)
    }
}
