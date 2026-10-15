import Foundation
import Curation

/// The two historical shapes of `reviewedIDsByDay`, independent of persistence and activation.
enum ReviewBaseline {
    typealias Days = [DayKey: Set<String>]
    typealias Lenses = [String: Days]

    enum Interpretation: Equatable, Sendable {
        case keyed(Lenses)
        case legacy(Lenses) // The caller must save this conversion at activation, before the lens changes.
        case unavailable
        case incompatibleLegacyLens
    }

    static func interpret(_ data: Data?, lens: MediaSelection) -> Interpretation {
        guard let data else { return .unavailable }
        if let keyed = decodeKeyed(data) { return .keyed(keyed) }
        guard let flat = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return .unavailable
        }
        let legacy = days(flat)
        guard !legacy.isEmpty else { return .unavailable }
        // Before includePhotos existed, a flat baseline could only belong to photos or both.
        guard lens != .videosOnly else { return .incompatibleLegacyLens }
        return .legacy([lens.rawValue: legacy])
    }

    static func decodeKeyed(_ data: Data) -> Lenses? {
        guard let nested = try? JSONDecoder().decode([String: [String: [String]]].self, from: data) else {
            return nil
        }
        return nested.mapValues(days)
    }

    static func encode(_ baselines: Lenses) -> Data? {
        let nested = baselines.mapValues { map in
            Dictionary(uniqueKeysWithValues: map.map { ($0.key.description, $0.value.sorted()) })
        }
        return try? JSONEncoder().encode(nested)
    }

    private static func days(_ values: [String: [String]]) -> Days {
        var result: Days = [:]
        for (key, ids) in values {
            if let day = DayKey(key) { result[day] = Set(ids) }
        }
        return result
    }
}
