import AppKit

enum Prefs {
    private static let keyCodeKey = "hotkey_key_code"
    private static let modifiersKey = "hotkey_modifiers"
    private static let labelKey = "hotkey_label"
    private static let regionKeyCodeKey = "region_hotkey_key_code"
    private static let regionModifiersKey = "region_hotkey_modifiers"
    private static let regionLabelKey = "region_hotkey_label"
    private static let wordKeyCodeKey = "word_hotkey_key_code"
    private static let wordModifiersKey = "word_hotkey_modifiers"
    private static let wordLabelKey = "word_hotkey_label"
    private static let apiKeyKey = "elevenlabs_api_key"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    static var hotkey: Hotkey {
        get {
            guard UserDefaults.standard.object(forKey: keyCodeKey) != nil else {
                return Hotkey.default
            }
            let code = UserDefaults.standard.integer(forKey: keyCodeKey)
            let modifiers = NSEvent.ModifierFlags(
                rawValue: UInt(UserDefaults.standard.integer(forKey: modifiersKey))
            )
            let label = UserDefaults.standard.string(forKey: labelKey) ?? ""
            return Hotkey(keyCode: code, modifiers: modifiers, label: label)
        }
        set {
            UserDefaults.standard.set(newValue.keyCode, forKey: keyCodeKey)
            UserDefaults.standard.set(Int(newValue.modifiers.rawValue), forKey: modifiersKey)
            UserDefaults.standard.set(newValue.label, forKey: labelKey)
        }
    }

    static var regionHotkey: Hotkey {
        get {
            guard UserDefaults.standard.object(forKey: regionKeyCodeKey) != nil else {
                return Hotkey.regionDefault
            }
            let code = UserDefaults.standard.integer(forKey: regionKeyCodeKey)
            let modifiers = NSEvent.ModifierFlags(
                rawValue: UInt(UserDefaults.standard.integer(forKey: regionModifiersKey))
            )
            let label = UserDefaults.standard.string(forKey: regionLabelKey) ?? ""
            return Hotkey(keyCode: code, modifiers: modifiers, label: label)
        }
        set {
            UserDefaults.standard.set(newValue.keyCode, forKey: regionKeyCodeKey)
            UserDefaults.standard.set(Int(newValue.modifiers.rawValue), forKey: regionModifiersKey)
            UserDefaults.standard.set(newValue.label, forKey: regionLabelKey)
        }
    }

    static var wordHotkey: Hotkey {
        get {
            guard UserDefaults.standard.object(forKey: wordKeyCodeKey) != nil else {
                return Hotkey.wordDefault
            }
            let code = UserDefaults.standard.integer(forKey: wordKeyCodeKey)
            let modifiers = NSEvent.ModifierFlags(
                rawValue: UInt(UserDefaults.standard.integer(forKey: wordModifiersKey))
            )
            let label = UserDefaults.standard.string(forKey: wordLabelKey) ?? ""
            return Hotkey(keyCode: code, modifiers: modifiers, label: label)
        }
        set {
            UserDefaults.standard.set(newValue.keyCode, forKey: wordKeyCodeKey)
            UserDefaults.standard.set(Int(newValue.modifiers.rawValue), forKey: wordModifiersKey)
            UserDefaults.standard.set(newValue.label, forKey: wordLabelKey)
        }
    }
}
