//
//  SpeechLocaleResolution.swift
//  ZTSpeechToText
//
//  Created by apple on 20/08/26.
//


import Foundation

/// Shared locale-resolution logic used by both SpeechRecognizerTranscriptionEngine
/// (legacy SFSpeechRecognizer) and SpeechAnalyzerTranscriptionEngine (iOS 26 SpeechAnalyzer),
/// so region-preference behavior never drifts between the two engines.
enum SpeechLocaleResolution {

    /// Deterministic fallback order per language, used when the device's own
    /// region isn't in the engine's supported-locale list. Ordered by
    /// real-world on-device support / population, not arbitrary.
    static let regionPriorityByLanguage: [String: [String]] = [
        "en": ["en-US", "en-IN", "en-GB", "en-AU", "en-CA", "en-ZA", "en-SG", "en-IE", "en-NZ"],
        "es": ["es-ES", "es-MX", "es-US", "es-AR", "es-CO", "es-CL"],
        "fr": ["fr-FR", "fr-CA", "fr-CH", "fr-BE"]
    ]

    /// Resolves the best supported locale for a given language hint, preferring
    /// (in order): exact hint match -> device's own region for that language ->
    /// fixed priority list -> alphabetically-sorted first match for that language.
    /// `supportedByIdentifier` must be keyed by lowercased locale identifier.
    static func resolve(
        localeHint: Locale?,
        supportedByIdentifier: [String: Locale],
        allSupported: [Locale]
    ) -> Locale? {
        if let localeHint {
            let hintID = localeHint.identifier.lowercased()

            if let exact = supportedByIdentifier[hintID] {
                return exact
            }

            let languageCode = (localeHint.language.languageCode?.identifier ?? hintID).lowercased()

            if let deviceRegion = Locale.current.region?.identifier {
                let deviceLocaleID = "\(languageCode)-\(deviceRegion)".lowercased()
                if let deviceMatch = supportedByIdentifier[deviceLocaleID] {
                    return deviceMatch
                }
            }

            if let priorityList = regionPriorityByLanguage[languageCode] {
                for identifier in priorityList {
                    if let match = supportedByIdentifier[identifier.lowercased()] {
                        return match
                    }
                }
            }

            let matches = allSupported
                .filter { ($0.language.languageCode?.identifier ?? $0.identifier).lowercased() == languageCode }
                .sorted { $0.identifier < $1.identifier }
            if let match = matches.first {
                return match
            }
        }

        let sortedSupported = allSupported.sorted { $0.identifier < $1.identifier }
        let current = Locale.current
        if let exact = sortedSupported.first(where: { $0.identifier == current.identifier }) {
            return exact
        }
        if let currentLanguage = current.language.languageCode?.identifier,
           let byLanguage = sortedSupported.first(where: {
               $0.language.languageCode?.identifier == currentLanguage
           }) {
            return byLanguage
        }
        return sortedSupported.first
    }
}