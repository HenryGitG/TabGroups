import Foundation

enum L10n {
    private static var bundle: Bundle {
        Bundle.main.bundleURL.pathExtension == "app" ? .main : .module
    }

    static func text(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: fallback, comment: "")
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback: fallback), locale: Locale.current, arguments: arguments)
    }
}
