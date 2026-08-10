//
//  AppLanguage.swift
//  TLocation
//

import Foundation

/// The language the user has forced in Settings, or `.system` to follow the
/// device's own language order.
///
/// The override works by writing the standard `AppleLanguages` preference into
/// the app's own defaults domain. `CFBundle` reads that list once, while the
/// process is starting, to decide which `.lproj` to serve — so a change here
/// only takes effect the next time TLocation is launched. Settings says so
/// explicitly rather than pretending the switch is instant.
///
/// Doing it this way (rather than an `\.environment(\.locale)` override on the
/// root view) is what makes the choice apply to *everything*: SwiftUI `Text`,
/// `String(localized:)` called from plain model code, the `UIAlertController`s
/// `AlertPresenter` puts up, and the App Intents the system runs in the
/// background with no UI at all.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case vietnamese = "vi"

    var id: String { rawValue }

    /// Language names are always shown in the language they name (an endonym),
    /// which is why these are not translated strings. "System" is the one
    /// exception — it is a word in the UI's own language, not a language name.
    var endonym: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    /// `AppleLanguages` value for this choice, or `nil` to stop overriding.
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: return nil
        case .english, .vietnamese: return [rawValue]
        }
    }
}

enum LanguageSettings {
    /// The system-wide key `CFBundle` consults; writing it into the app's own
    /// defaults domain overrides the language for this app only.
    private static let appleLanguagesKey = "AppleLanguages"

    static var selected: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: UserDefaults.Keys.appLanguage)
        return stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Persists the choice and rewrites `AppleLanguages`. Safe to call with the
    /// value that is already selected.
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: UserDefaults.Keys.appLanguage)
        if let value = language.appleLanguagesValue {
            defaults.set(value, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }

    /// The choice that was in force when this process started, which is the one
    /// the running UI is actually drawn in. Settings compares against this to
    /// decide whether a restart is genuinely outstanding, so picking a language
    /// and then picking the original back does not leave a false warning up.
    private(set) static var activeAtLaunch: AppLanguage = .system

    /// Re-asserts the stored choice at launch. `AppleLanguages` lives in the
    /// same defaults domain the user can wipe by reinstalling, and this keeps
    /// the two halves of the setting from drifting apart if one is ever cleared
    /// without the other.
    static func restoreAtLaunch() {
        let language = selected
        activeAtLaunch = language
        apply(language)
    }
}
