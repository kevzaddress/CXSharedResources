import Foundation

/// Provides consistent airport code normalization across apps by mapping IATA and other aliases to canonical ICAO identifiers.
final class AirportNormalizer {
    static let shared = AirportNormalizer()

    private let aliasMap: [String: String]
    private let characterSet = CharacterSet.alphanumerics.inverted

    private init() {
        aliasMap = AirportNormalizer.loadAliases()
    }

    /// Normalizes an arbitrary airport string (IATA, ICAO, or alias) into the canonical code used for hashing/export.
    func normalize(_ rawCode: String) -> String {
        let cleaned = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .components(separatedBy: characterSet)
            .joined()

        guard !cleaned.isEmpty else { return rawCode.uppercased() }

        if let mapped = aliasMap[cleaned] {
            return mapped
        }

        return cleaned
    }

    private static func loadAliases() -> [String: String] {
        guard let url = bundleCandidates()
            .compactMap({ $0.url(forResource: "airportAliases", withExtension: "json") })
            .first else {
            #if DEBUG
            print("[AirportNormalizer] airportAliases.json not found in any bundle; falling back to identity mapping")
            #endif
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            #if DEBUG
            print("[AirportNormalizer] Loaded \(decoded.count) airport aliases")
            #endif
            return decoded
        } catch {
            #if DEBUG
            print("[AirportNormalizer] Failed to load aliases: \(error)")
            #endif
            return [:]
        }
    }

    private static func bundleCandidates() -> [Bundle] {
        var seen = Set<ObjectIdentifier>()
        var result: [Bundle] = []

        func append(_ bundle: Bundle) {
            let identifier = ObjectIdentifier(bundle)
            if !seen.contains(identifier) {
                seen.insert(identifier)
                result.append(bundle)
            }
        }

        append(Bundle.main)
        append(Bundle(for: Token.self))
        Bundle.allBundles.forEach(append)
        Bundle.allFrameworks.forEach(append)

        return result
    }

    private final class Token {}
}
