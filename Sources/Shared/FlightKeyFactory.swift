import Foundation
import CryptoKit

/// Utility helpers for generating consistent flight identifiers across apps.
struct FlightKeyFactory {
    static let defaultAirlinePrefix = "CX"
    private static let delimiter = "|"
    
    /// Normalises a raw flight number into the canonical form used for hashing.
    /// Removes non-alphanumeric characters, uppercases, and ensures the configured airline prefix is present.
    static func normalizeFlightNumber(_ rawValue: String, airlinePrefix: String = defaultAirlinePrefix) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleaned = trimmed.replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return airlinePrefix }
        
        if cleaned.hasPrefix(airlinePrefix) {
            return cleaned
        }
        
        if let digitRange = cleaned.range(of: "[0-9].*", options: .regularExpression) {
            let suffix = cleaned[digitRange]
            return airlinePrefix + suffix
        }
        
        return airlinePrefix + cleaned
    }
    
    /// Normalises an airport identifier to uppercase without surrounding whitespace.
    static func normalizeAirportCode(_ code: String) -> String {
        AirportNormalizer.shared.normalize(code)
    }
    
    /// Generates the deterministic flight key used by both apps.
    static func flightKey(
        date: String,
        flightNumber: String,
        from: String,
        to: String,
        airlinePrefix: String = defaultAirlinePrefix
    ) -> String {
        let normalizedNumber = normalizeFlightNumber(flightNumber, airlinePrefix: airlinePrefix)
        let normalizedFrom = normalizeAirportCode(from)
        let normalizedTo = normalizeAirportCode(to)
        let input = compositeKey(
            date: date,
            flightNumber: normalizedNumber,
            from: normalizedFrom,
            to: normalizedTo
        )
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    
    /// Produces the composite key used to persist lookup entries.
    static func compositeKey(date: String, flightNumber: String, from: String, to: String) -> String {
        [date, flightNumber, from, to].joined(separator: delimiter)
    }
}
