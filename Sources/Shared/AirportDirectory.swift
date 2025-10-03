import Foundation

/// Provides airport metadata lookups, including time zone resolution for ICAO and IATA codes.
final class AirportDirectory {
    static let shared = AirportDirectory()

    private var icaoToIATA: [String: String] = [:]
    private var iataToTimeZone: [String: TimeZone] = [:]

    private init() {
        loadAirports()
        loadTimeZones()
    }

    /// Returns the time zone for the supplied airport code (ICAO or IATA).
    func timeZone(for airportCode: String) -> TimeZone? {
        let normalized = airportCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if let tz = iataToTimeZone[normalized] {
            return tz
        }

        if let iata = icaoToIATA[normalized], let tz = iataToTimeZone[iata] {
            return tz
        }

        return nil
    }

    /// Returns the canonical IATA code for a given ICAO code, if known.
    func iataCode(forICAO icao: String) -> String? {
        icaoToIATA[icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }

    // MARK: - Loading helpers

    private func loadAirports() {
        guard let url = resourceURL(named: "airports", extension: "json") else { return }
        do {
            let data = try Data(contentsOf: url)
            if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (iata, value) in raw {
                    guard let dict = value as? [String: Any] else { continue }
                    if let icao = dict["icao"] as? String, !icao.isEmpty {
                        icaoToIATA[icao.uppercased()] = iata.uppercased()
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[AirportDirectory] Failed to load airports.json: \(error)")
            #endif
        }
    }

    private func loadTimeZones() {
        guard let url = resourceURL(named: "timezones", extension: "json") else { return }
        do {
            let data = try Data(contentsOf: url)
            if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let airports = raw["airports"] as? [String: String] {
                for (iata, identifier) in airports {
                    if let tz = TimeZone(identifier: identifier) {
                        iataToTimeZone[iata.uppercased()] = tz
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[AirportDirectory] Failed to load timezones.json: \(error)")
            #endif
        }
    }

    private func resourceURL(named name: String, extension ext: String) -> URL? {
        var seen = Set<ObjectIdentifier>()
        var bundles: [Bundle] = []

        func append(_ bundle: Bundle) {
            let identifier = ObjectIdentifier(bundle)
            if !seen.contains(identifier) {
                seen.insert(identifier)
                bundles.append(bundle)
            }
        }

        append(Bundle.main)
        append(Bundle(for: Token.self))
        Bundle.allBundles.forEach(append)
        Bundle.allFrameworks.forEach(append)

        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private final class Token {}
}
