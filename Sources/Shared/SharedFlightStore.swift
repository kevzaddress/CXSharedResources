import Foundation

/// Shared storage backed by an app-group UserDefaults suite so CXRoster and FlightCapture can share flight IDs.
final class SharedFlightStore {
    static let shared = SharedFlightStore()

    private static let appGroupIdentifier = "group.com.bulletProof.CXShared"
    private let flightKeyMapKey = "flightKeyCompositeMap.v1"
    private let rosterUIDMapKey = "flightKeyRosterMap.v1"
    private let flightCaptureCreatedKey = "flightCaptureCreatedKeys.v1"

    private let defaults: UserDefaults?
    private var inMemoryStore: [String: Any] = [:]
    private let queue = DispatchQueue(label: "SharedFlightStore.queue")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private init() {
        if let sharedDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            defaults = sharedDefaults
            debugLog("Initialized with app-group defaults: \(Self.appGroupIdentifier)")
        } else {
            defaults = nil
            debugLog("❌ App-group defaults unavailable (\(Self.appGroupIdentifier)); using in-memory non-persistent store.")
        }
    }

    // MARK: - Public API

    /// Persists the mapping between a flight signature and its key, optionally tying it to a roster UID.
    func saveMapping(
        flightKey: String,
        date: String,
        flightNumber: String,
        from: String,
        to: String,
        rosterUID: String? = nil,
        airlinePrefix: String = FlightKeyFactory.defaultAirlinePrefix
    ) {
        let composite = normalizedCompositeKey(
            date: date,
            flightNumber: flightNumber,
            from: from,
            to: to,
            airlinePrefix: airlinePrefix
        )

        queue.sync {
            var map = readStringMap(forKey: flightKeyMapKey)
            map[composite] = flightKey
            writeStringMap(map, forKey: flightKeyMapKey)
            debugLog("saveMapping composite=\(composite) flightKey=\(flightKey) rosterUID=\(rosterUID ?? "nil")")

            if let rosterUID {
                var rosterMap = readStringMap(forKey: rosterUIDMapKey)
                rosterMap[rosterUID] = flightKey
                writeStringMap(rosterMap, forKey: rosterUIDMapKey)
            }
        }
    }

    /// Returns the stored flight key for the provided flight signature, if one exists.
    func flightKey(
        date: String,
        flightNumber: String,
        from: String,
        to: String,
        airlinePrefix: String = FlightKeyFactory.defaultAirlinePrefix
    ) -> String? {
        let composite = normalizedCompositeKey(
            date: date,
            flightNumber: flightNumber,
            from: from,
            to: to,
            airlinePrefix: airlinePrefix
        )

        return queue.sync {
            let map = readStringMap(forKey: flightKeyMapKey)
            let found = map[composite]
            debugLog("lookup composite=\(composite) -> \(found ?? "nil")")
            return found
        }
    }

    /// Returns the stored flight key for a roster UID if one was saved previously.
    func flightKey(rosterUID: String) -> String? {
        return queue.sync {
            let rosterMap = readStringMap(forKey: rosterUIDMapKey)
            let found = rosterMap[rosterUID]
            debugLog("lookup rosterUID=\(rosterUID) -> \(found ?? "nil")")
            return found
        }
    }

    /// Attempts to find any existing mapping for the given date and flight number, regardless of route codes.
    func existingMapping(
        date: String,
        flightNumber: String,
        airlinePrefix: String = FlightKeyFactory.defaultAirlinePrefix
    ) -> (flightKey: String, from: String, to: String)? {
        let normalizedNumber = FlightKeyFactory.normalizeFlightNumber(flightNumber, airlinePrefix: airlinePrefix)

        return queue.sync {
            let map = readStringMap(forKey: flightKeyMapKey)
            guard !map.isEmpty else {
                return nil
            }

            let targetDate = dateFormatter.date(from: date)
            let flightCaptureCreated = Set(readStringArray(forKey: flightCaptureCreatedKey))
            var exactCandidate: (flightKey: String, from: String, to: String)?
            var fallback: (flightKey: String, from: String, to: String, delta: Int)?

            for (composite, flightKey) in map {
                let parts = composite.split(separator: "|")
                guard parts.count == 4 else { continue }
                let storedDate = String(parts[0])
                let storedNumber = String(parts[1])
                let storedFrom = String(parts[2])
                let storedTo = String(parts[3])

                guard storedNumber == normalizedNumber else { continue }

                if storedDate == date {
                    if !flightCaptureCreated.contains(flightKey) {
                        debugLog("existingMapping matched composite=\(composite) flightKey=\(flightKey)")
                        return (flightKey, storedFrom, storedTo)
                    }
                    if exactCandidate == nil {
                        exactCandidate = (flightKey, storedFrom, storedTo)
                    }
                }

                if let target = targetDate, let stored = dateFormatter.date(from: storedDate) {
                    let delta = abs(Calendar.current.dateComponents([.day], from: stored, to: target).day ?? Int.max)
                    if delta <= 1 {
                        if !flightCaptureCreated.contains(flightKey) {
                            if fallback == nil || delta < fallback!.delta {
                                fallback = (flightKey, storedFrom, storedTo, delta)
                            }
                        } else if fallback == nil {
                            fallback = (flightKey, storedFrom, storedTo, delta)
                        }
                    }
                } else {
                    debugLog("existingMapping could not parse dates stored=\(storedDate) target=\(date)")
                }
            }

            if let fallback {
                debugLog("existingMapping fallback matched flightKey=\(fallback.flightKey) dateDelta=\(fallback.delta)")
                return (fallback.flightKey, fallback.from, fallback.to)
            }

            if let exactCandidate {
                debugLog("existingMapping returning flightCaptureCreated key=\(exactCandidate.flightKey)")
                return exactCandidate
            }

            return nil
        }
    }

    /// Removes a roster mapping without touching the underlying composite map.
    func removeRosterMapping(forRosterUID rosterUID: String) {
        queue.sync {
            var rosterMap = readStringMap(forKey: rosterUIDMapKey)
            rosterMap.removeValue(forKey: rosterUID)
            writeStringMap(rosterMap, forKey: rosterUIDMapKey)
            debugLog("removeRosterMapping rosterUID=\(rosterUID)")
        }
    }

    /// Records that FlightCapture created/updated a flight for the provided key.
    func markFlightCaptureCreated(_ flightKey: String) {
        queue.sync {
            var created = readStringArray(forKey: flightCaptureCreatedKey)
            if !created.contains(flightKey) {
                created.append(flightKey)
                writeStringArray(created, forKey: flightCaptureCreatedKey)
            }
            debugLog("markFlightCaptureCreated flightKey=\(flightKey)")
        }
    }

    /// Checks whether FlightCapture has already pushed this flight key.
    func isFlightCaptureCreated(_ flightKey: String) -> Bool {
        flightCaptureCreatedKeys().contains(flightKey)
    }

    /// Returns all flight keys that FlightCapture has already exported.
    func flightCaptureCreatedKeys() -> Set<String> {
        queue.sync {
            let array = readStringArray(forKey: flightCaptureCreatedKey)
            return Set(array)
        }
    }

    /// Clears the "created" tracking list.
    func resetFlightCaptureCreatedKeys() {
        queue.sync {
            removeValue(forKey: flightCaptureCreatedKey)
            debugLog("resetFlightCaptureCreatedKeys")
        }
    }

    /// Removes all stored flight data. Intended for debugging or unit tests.
    func reset() {
        queue.sync {
            removeValue(forKey: flightKeyMapKey)
            removeValue(forKey: rosterUIDMapKey)
            removeValue(forKey: flightCaptureCreatedKey)
            debugLog("reset all stored mappings")
        }
    }

    // MARK: - Utilities

    private func normalizedCompositeKey(
        date: String,
        flightNumber: String,
        from: String,
        to: String,
        airlinePrefix: String
    ) -> String {
        let normalizedNumber = FlightKeyFactory.normalizeFlightNumber(flightNumber, airlinePrefix: airlinePrefix)
        let normalizedFrom = FlightKeyFactory.normalizeAirportCode(from)
        let normalizedTo = FlightKeyFactory.normalizeAirportCode(to)
        return FlightKeyFactory.compositeKey(
            date: date,
            flightNumber: normalizedNumber,
            from: normalizedFrom,
            to: normalizedTo
        )
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[SharedFlightStore] \(message)")
        #endif
    }

    private func readStringMap(forKey key: String) -> [String: String] {
        if let defaults {
            return defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        }
        return inMemoryStore[key] as? [String: String] ?? [:]
    }

    private func writeStringMap(_ value: [String: String], forKey key: String) {
        if let defaults {
            defaults.set(value, forKey: key)
            return
        }
        inMemoryStore[key] = value
    }

    private func readStringArray(forKey key: String) -> [String] {
        if let defaults {
            return defaults.array(forKey: key) as? [String] ?? []
        }
        return inMemoryStore[key] as? [String] ?? []
    }

    private func writeStringArray(_ value: [String], forKey key: String) {
        if let defaults {
            defaults.set(value, forKey: key)
            return
        }
        inMemoryStore[key] = value
    }

    private func removeValue(forKey key: String) {
        if let defaults {
            defaults.removeObject(forKey: key)
            return
        }
        inMemoryStore.removeValue(forKey: key)
    }
}
