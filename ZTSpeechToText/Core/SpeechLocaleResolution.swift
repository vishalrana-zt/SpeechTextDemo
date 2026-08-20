//
//  SpeechLocaleResolution.swift
//  ZTSpeechToText
//
//  Created by apple on 20/08/26.
//

import Foundation

/// Shared locale-resolution logic used by both SpeechRecognizerTranscriptionEngine
/// (legacy SFSpeechRecognizer) and SpeechAnalyzerTranscriptionEngine (iOS 26 SpeechAnalyzer),
/// so locale behavior is consistent across engines.
enum SpeechLocaleResolution {

    /// Resolves the best supported locale using a conservative, non-hardcoded policy:
    /// exact hint match -> region-aware hint match -> same language (stable order) -> current locale -> first supported.
    /// `supportedByIdentifier` may contain either `en-US` or `en_US`; matching is normalized.
    static func resolve(
        localeHint: Locale?,
        supportedByIdentifier: [String: Locale],
        allSupported: [Locale]
    ) -> Locale? {
        let sortedSupported = allSupported.sorted {
            normalizedIdentifier($0.identifier) < normalizedIdentifier($1.identifier)
        }

        let normalizedSupportedByIdentifier = Dictionary(
            supportedByIdentifier.values.map { (normalizedIdentifier($0.identifier), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if let localeHint {
            let hintID = normalizedIdentifier(localeHint.identifier)
            let hintLanguage = localeHint.language.languageCode?.identifier.lowercased()
            let hintHasRegion = hintID.contains("-")

            if let exact = normalizedSupportedByIdentifier[hintID] {
                return exact
            }

            // Prefix matching is only safe when the hint includes a region.
            // For language-only hints like "en", prefix matching can pick arbitrary
            // regions (en-AU/en-IN/...) depending on collection order.
            if hintHasRegion,
               let byPrefix = sortedSupported.first(where: { locale in
                   let id = normalizedIdentifier(locale.identifier)
                   return id.hasPrefix(hintID) || hintID.hasPrefix(id)
               }) {
                return byPrefix
            }

            if let hintLanguage {
                // Prefer current device region for the selected language when available.
                if let region = Locale.current.region?.identifier.lowercased() {
                    let currentRegionalID = normalizedIdentifier("\(hintLanguage)-\(region)")
                    if let currentRegional = normalizedSupportedByIdentifier[currentRegionalID] {
                        return currentRegional
                    }
                }

                if let byLanguage = sortedSupported.first(where: {
                    $0.language.languageCode?.identifier.lowercased() == hintLanguage
                }) {
                    return byLanguage
                }
            }
        }

        let current = Locale.current
        let currentID = normalizedIdentifier(current.identifier)

        if let exact = sortedSupported.first(where: {
            normalizedIdentifier($0.identifier) == currentID
        }) {
            return exact
        }

        if let currentLanguage = current.language.languageCode?.identifier.lowercased(),
           let byLanguage = sortedSupported.first(where: {
               $0.language.languageCode?.identifier.lowercased() == currentLanguage
           }) {
            return byLanguage
        }

        return sortedSupported.first
    }

    private static func normalizedIdentifier(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
