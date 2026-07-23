import Foundation

/// Shared storage backed by an app-group UserDefaults suite so CXRoster and FlightCapture can share flight IDs.
final class SharedFlightStore {
    static let shared = SharedFlightStore()

    private static let appGroupIdentifier = "group.com.bulletProof.CXShared"
    private let flightKeyMapKey = "flightKeyCompositeMap.v1"
    private let rosterUIDMapKey = "flightKeyRosterMap.v1"
    private let flightCaptureCreatedKey = "flightCaptureCreatedKeys.v1"
    private let flightCaptureCrewCapturedKey = "flightCaptureCrewCapturedKeys.v1"
    private let flightDutyTimesKey = "flightDutyTimes.v1"

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

    struct DutyTimes: Codable {
        let onDutyTimeInterval: TimeInterval?
        let offDutyTimeInterval: TimeInterval?
        let source: String

        var onDuty: Date? {
            onDutyTimeInterval.map(Date.init(timeIntervalSince1970:))
        }

        var offDuty: Date? {
            offDutyTimeInterval.map(Date.init(timeIntervalSince1970:))
        }
    }

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

    func saveRosterDutyTimes(flightKey: String, onDuty: Date?, offDuty: Date? = nil) {
        saveDutyTimes(flightKey: flightKey, onDuty: onDuty, offDuty: offDuty, source: "Roster")
    }

    func saveManualDutyTimes(flightKey: String, onDuty: Date?, offDuty: Date? = nil) {
        saveDutyTimes(flightKey: flightKey, onDuty: onDuty, offDuty: offDuty, source: "Manual")
    }

    func dutyTimes(for flightKey: String) -> DutyTimes? {
        queue.sync {
            readDutyTimesMap()[flightKey]
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

    /// Clears the created marker for one flight key.
    func clearFlightCaptureCreated(_ flightKey: String) {
        queue.sync {
            var created = readStringArray(forKey: flightCaptureCreatedKey)
            created.removeAll { $0 == flightKey }
            writeStringArray(created, forKey: flightCaptureCreatedKey)
            debugLog("clearFlightCaptureCreated flightKey=\(flightKey)")
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

    /// Records that crew data was exported for the provided flight key.
    func markCrewCaptured(_ flightKey: String) {
        queue.sync {
            var captured = readStringArray(forKey: flightCaptureCrewCapturedKey)
            if !captured.contains(flightKey) {
                captured.append(flightKey)
                writeStringArray(captured, forKey: flightCaptureCrewCapturedKey)
            }
            debugLog("markCrewCaptured flightKey=\(flightKey)")
        }
    }

    /// Checks whether crew data has already been exported for the provided key.
    func isCrewCaptured(_ flightKey: String) -> Bool {
        queue.sync {
            let array = readStringArray(forKey: flightCaptureCrewCapturedKey)
            return array.contains(flightKey)
        }
    }

    /// Clears the crew-captured marker for one flight key.
    func clearCrewCaptured(_ flightKey: String) {
        queue.sync {
            var captured = readStringArray(forKey: flightCaptureCrewCapturedKey)
            captured.removeAll { $0 == flightKey }
            writeStringArray(captured, forKey: flightCaptureCrewCapturedKey)
            debugLog("clearCrewCaptured flightKey=\(flightKey)")
        }
    }

    /// Clears FlightCapture-created and crew-captured tracking lists.
    func resetFlightCaptureCreatedKeys() {
        queue.sync {
            removeValue(forKey: flightCaptureCreatedKey)
            removeValue(forKey: flightCaptureCrewCapturedKey)
            debugLog("resetFlightCaptureCreatedKeys")
        }
    }

    /// Removes all stored flight data. Intended for debugging or unit tests.
    func reset() {
        queue.sync {
            removeValue(forKey: flightKeyMapKey)
            removeValue(forKey: rosterUIDMapKey)
            removeValue(forKey: flightCaptureCreatedKey)
            removeValue(forKey: flightCaptureCrewCapturedKey)
            removeValue(forKey: flightDutyTimesKey)
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

    private func saveDutyTimes(flightKey: String, onDuty: Date?, offDuty: Date?, source: String) {
        queue.sync {
            var map = readDutyTimesMap()
            if source == "Roster", map[flightKey]?.source == "Manual" {
                debugLog("preserved manual duty times for flightKey=\(flightKey)")
                return
            }

            map[flightKey] = DutyTimes(
                onDutyTimeInterval: onDuty?.timeIntervalSince1970,
                offDutyTimeInterval: offDuty?.timeIntervalSince1970,
                source: source
            )
            writeDutyTimesMap(map)
            debugLog("saveDutyTimes flightKey=\(flightKey) source=\(source)")
        }
    }

    private func readDutyTimesMap() -> [String: DutyTimes] {
        guard let data = readData(forKey: flightDutyTimesKey),
              let decoded = try? JSONDecoder().decode([String: DutyTimes].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeDutyTimesMap(_ value: [String: DutyTimes]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeData(data, forKey: flightDutyTimesKey)
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

    private func readData(forKey key: String) -> Data? {
        if let defaults {
            return defaults.data(forKey: key)
        }
        return inMemoryStore[key] as? Data
    }

    private func writeData(_ value: Data, forKey key: String) {
        if let defaults {
            defaults.set(value, forKey: key)
            return
        }
        inMemoryStore[key] = value
    }
}
