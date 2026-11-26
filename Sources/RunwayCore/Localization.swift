import Foundation

/// Looks a string up in the app bundle (`Contents/Resources/<lang>.lproj`, compiled from
/// `Resources/Localizable.xcstrings`). English is the source language: with no lproj
/// (tests, bare binary) the key itself is returned, which is the English copy.
public func tr(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .main)
}

extension Locale {
    /// The locale of the language the app resolved (follows the Mac's language, or `-AppleLanguages`),
    /// keeping the user's region for number and date conventions.
    public static var runway: Locale {
        guard let language = Bundle.main.preferredLocalizations.first else { return .current }
        if Locale.current.language.languageCode?.identifier == language { return .current }
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
    }
}
