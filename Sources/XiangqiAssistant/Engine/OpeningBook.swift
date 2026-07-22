import Foundation

/// The audit trail attached to every usable move in the offline opening book.
/// A move without a known provenance record is discarded while loading.
struct OpeningBookProvenance: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let origin: String
    let license: String
    let notes: String?
}

struct OpeningBookMetadata: Codable, Hashable, Sendable {
    let bookID: String
    let formatVersion: Int
    let generatedAt: String?
    let summary: String?
}

/// A book suggestion, not a final recommendation. Callers must ask Pikafish to
/// evaluate these moves together with its normal candidates before displaying
/// or playing anything.
struct OpeningBookCandidate: Codable, Hashable, Sendable {
    let uci: String
    let weight: Int
    let line: String?
    let tags: [String]
    let provenance: [OpeningBookProvenance]
}

/// Read-only, fail-closed local opening book.
///
/// The on-disk format is intentionally data-only. It cannot choose a final
/// move, alter a board, or invoke the engine. Its sole API returns legal moves
/// that the engine may include in a later verification search.
struct OpeningBook: Sendable {
    static let shared = OpeningBook()

    let metadata: OpeningBookMetadata
    let provenance: [OpeningBookProvenance]

    private let recordsByPosition: [String: [CandidateRecord]]

    var isEmpty: Bool { recordsByPosition.isEmpty }
    var positionCount: Int { recordsByPosition.count }
    var candidateCount: Int { recordsByPosition.values.reduce(0) { $0 + $1.count } }

    /// Loads the bundled v1 book. A missing, unreadable, malformed, or unknown
    /// format becomes an empty book so analysis can continue normally.
    init(bundle: Bundle = .main) {
        guard let url = Self.resourceURL(in: bundle),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            self = .empty
            return
        }
        self.init(data: data)
    }

    /// Direct data initializer kept available for deterministic unit tests and
    /// for validating future bundled revisions without changing the loader.
    init(data: Data) {
        guard let document = try? JSONDecoder().decode(BookDocument.self, from: data),
              document.formatVersion == 1
        else {
            self = .empty
            return
        }

        var provenanceByID: [String: OpeningBookProvenance] = [:]
        for stored in document.provenance {
            let id = stored.id?.trimmed ?? ""
            let title = stored.title?.trimmed ?? ""
            let origin = stored.origin?.trimmed ?? ""
            let license = stored.license?.trimmed ?? ""
            guard !id.isEmpty, !title.isEmpty, !origin.isEmpty, !license.isEmpty,
                  provenanceByID[id] == nil
            else { continue }
            provenanceByID[id] = OpeningBookProvenance(
                id: id,
                title: title,
                origin: origin,
                license: license,
                notes: stored.notes?.trimmed.nilIfEmpty
            )
        }

        var loaded: [String: [CandidateRecord]] = [:]
        for entry in document.entries {
            guard let rawKey = entry.key,
                  let key = Self.positionKey(from: rawKey)
            else { continue }

            let line = entry.line?.trimmed.nilIfEmpty
            let entryProvenance = entry.provenanceIDs.compactMap { provenanceByID[$0.trimmed] }

            for storedMove in entry.moves {
                guard let uci = Self.canonicalUCI(storedMove.uci) else { continue }

                let moveProvenance = storedMove.provenanceIDs.compactMap {
                    provenanceByID[$0.trimmed]
                }
                let resolvedProvenance = Self.deduplicated(
                    moveProvenance.isEmpty ? entryProvenance : moveProvenance
                )

                // Provenance is mandatory rather than merely decorative.
                guard !resolvedProvenance.isEmpty else { continue }

                let record = CandidateRecord(
                    uci: uci,
                    weight: min(1_000, max(1, storedMove.weight ?? 1)),
                    line: storedMove.line?.trimmed.nilIfEmpty ?? line,
                    tags: Self.normalizedTags(entry.tags + storedMove.tags),
                    provenance: resolvedProvenance
                )
                loaded[key, default: []].append(record)
            }
        }

        // Merge duplicate moves deterministically, retaining the strongest
        // data record rather than allowing file order to affect suggestions.
        var merged: [String: [CandidateRecord]] = [:]
        for (key, records) in loaded {
            var bestByMove: [String: CandidateRecord] = [:]
            for record in records {
                if let current = bestByMove[record.uci], current.weight >= record.weight {
                    continue
                }
                bestByMove[record.uci] = record
            }
            merged[key] = bestByMove.values.sorted(by: Self.recordOrdering)
        }

        metadata = OpeningBookMetadata(
            bookID: document.bookID?.trimmed.nilIfEmpty ?? "offline-opening-book-v1",
            formatVersion: document.formatVersion,
            generatedAt: document.generatedAt?.trimmed.nilIfEmpty,
            summary: document.summary?.trimmed.nilIfEmpty
        )
        provenance = provenanceByID.values.sorted { $0.id < $1.id }
        recordsByPosition = merged.filter { !$0.value.isEmpty }
    }

    /// Returns only book moves that are legal for the supplied trusted board.
    /// The FEN must describe that same board and side; otherwise fail closed.
    /// Returned order is stable, but it is not an engine evaluation.
    func candidates(
        for fen: String,
        board: BoardState,
        side: PieceSide,
        limit: Int = 8
    ) -> [OpeningBookCandidate] {
        guard limit > 0,
              let requestedKey = Self.positionKey(from: fen)
        else { return [] }

        var expectedBoard = board
        expectedBoard.redToMove = side == .red
        guard requestedKey == Self.positionKey(from: expectedBoard.toFEN()),
              let records = recordsByPosition[requestedKey]
        else { return [] }

        var seen: Set<String> = []
        return records.compactMap { record -> OpeningBookCandidate? in
            guard seen.insert(record.uci).inserted,
                  let move = UCIMove(uci: record.uci),
                  board.isLegalMove(move, for: side)
            else { return nil }

            return OpeningBookCandidate(
                uci: record.uci,
                weight: record.weight,
                line: record.line,
                tags: record.tags,
                provenance: record.provenance
            )
        }.prefix(limit).map { $0 }
    }

    /// Canonical key used by the JSON file: exactly the first two FEN fields.
    static func positionKey(from fen: String) -> String? {
        let fields = fen.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { return nil }

        let placement = String(fields[0])
        let side = String(fields[1]).lowercased()
        guard side == "w" || side == "b", Self.isValidPlacement(placement) else { return nil }
        return "\(placement) \(side)"
    }

    private static let empty = OpeningBook(
        metadata: OpeningBookMetadata(
            bookID: "offline-opening-book-empty",
            formatVersion: 1,
            generatedAt: nil,
            summary: nil
        ),
        provenance: [],
        recordsByPosition: [:]
    )

    private init(
        metadata: OpeningBookMetadata,
        provenance: [OpeningBookProvenance],
        recordsByPosition: [String: [CandidateRecord]]
    ) {
        self.metadata = metadata
        self.provenance = provenance
        self.recordsByPosition = recordsByPosition
    }

    private static func resourceURL(in bundle: Bundle) -> URL? {
        let locations: [(String, String?)] = [
            ("opening_book_v1", "OpeningBook"),
            ("opening_book_v1", "Resources/OpeningBook"),
            ("opening_book_v1", nil)
        ]
        for (name, subdirectory) in locations {
            if let url = bundle.url(
                forResource: name,
                withExtension: "json",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }

    private static func canonicalUCI(_ raw: String?) -> String? {
        guard let text = raw?.trimmed.lowercased(), text.count == 4,
              let move = UCIMove(uci: text), move.uci == text
        else { return nil }
        return text
    }

    private static func isValidPlacement(_ placement: String) -> Bool {
        let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 10 else { return false }
        let pieces = Set("kabnrcpKABNRCP")

        for rank in ranks {
            var files = 0
            for character in rank {
                if let empty = character.wholeNumberValue {
                    guard (1...9).contains(empty) else { return false }
                    files += empty
                } else {
                    guard pieces.contains(character) else { return false }
                    files += 1
                }
            }
            guard files == 9 else { return false }
        }
        return true
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map(\.trimmed).filter { !$0.isEmpty })).sorted()
    }

    private static func deduplicated(
        _ records: [OpeningBookProvenance]
    ) -> [OpeningBookProvenance] {
        var seen: Set<String> = []
        return records.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    private static func recordOrdering(_ lhs: CandidateRecord, _ rhs: CandidateRecord) -> Bool {
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.uci < rhs.uci
    }
}

private struct CandidateRecord: Sendable {
    let uci: String
    let weight: Int
    let line: String?
    let tags: [String]
    let provenance: [OpeningBookProvenance]
}

// MARK: - Tolerant Codable storage format

private struct BookDocument: Codable {
    let formatVersion: Int
    let bookID: String?
    let generatedAt: String?
    let summary: String?
    let provenance: [StoredProvenance]
    let entries: [StoredEntry]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, bookID, generatedAt, summary, provenance, entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        bookID = try? container.decode(String.self, forKey: .bookID)
        generatedAt = try? container.decode(String.self, forKey: .generatedAt)
        summary = try? container.decode(String.self, forKey: .summary)
        provenance = (try? container.decode(
            LossyArray<StoredProvenance>.self,
            forKey: .provenance
        ))?.values ?? []
        entries = (try? container.decode(
            LossyArray<StoredEntry>.self,
            forKey: .entries
        ))?.values ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(bookID, forKey: .bookID)
        try container.encodeIfPresent(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(entries, forKey: .entries)
    }
}

private struct StoredProvenance: Codable {
    let id: String?
    let title: String?
    let origin: String?
    let license: String?
    let notes: String?

    private enum CodingKeys: String, CodingKey { case id, title, origin, license, notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        title = try? container.decode(String.self, forKey: .title)
        origin = try? container.decode(String.self, forKey: .origin)
        license = try? container.decode(String.self, forKey: .license)
        notes = try? container.decode(String.self, forKey: .notes)
    }
}

private struct StoredEntry: Codable {
    let key: String?
    let line: String?
    let tags: [String]
    let provenanceIDs: [String]
    let moves: [StoredMove]

    private enum CodingKeys: String, CodingKey {
        case key, line, tags, provenanceIDs, moves
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try? container.decode(String.self, forKey: .key)
        line = try? container.decode(String.self, forKey: .line)
        tags = (try? container.decode(LossyArray<String>.self, forKey: .tags))?.values ?? []
        provenanceIDs = (try? container.decode(
            LossyArray<String>.self,
            forKey: .provenanceIDs
        ))?.values ?? []
        moves = (try? container.decode(LossyArray<StoredMove>.self, forKey: .moves))?.values ?? []
    }
}

private struct StoredMove: Codable {
    let uci: String?
    let weight: Int?
    let line: String?
    let tags: [String]
    let provenanceIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case uci, weight, line, tags, provenanceIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uci = try? container.decode(String.self, forKey: .uci)
        weight = try? container.decode(Int.self, forKey: .weight)
        line = try? container.decode(String.self, forKey: .line)
        tags = (try? container.decode(LossyArray<String>.self, forKey: .tags))?.values ?? []
        provenanceIDs = (try? container.decode(
            LossyArray<String>.self,
            forKey: .provenanceIDs
        ))?.values ?? []
    }
}

private struct LossyArray<Element: Codable>: Codable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let value = try container.decode(LossyValue<Element>.self).value {
                decoded.append(value)
            }
        }
        values = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in values { try container.encode(value) }
    }
}

private struct LossyValue<Value: Codable>: Codable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        if let value {
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
