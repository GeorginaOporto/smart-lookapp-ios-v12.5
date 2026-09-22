import Foundation
import Combine
import UIKit
import ZIPFoundation

/// Android v12.2 visual ranking contract. Lower values are better distances.
enum MVDVisualSearchFormula {
    static let contextWeight = 0.40
    static let extractedWeight = 0.60
    static let legacyWeight = 0.35
    static let embeddingWeight = 0.65
    // Android v12.4: 8 points per positive vote on a 0...100 distance,
    // represented here as the equivalent 0.08 similarity boost.
    static let positiveBoostPerVote = 0.08
    static let positiveBoostCap = 0.40

    static func combinedVisualDistance(context: Double, extracted: Double) -> Double {
        context * contextWeight + extracted * extractedWeight
    }

    static func finalDistance(visual: Double, embedding: Double?) -> Double {
        guard let embedding else { return visual }
        return visual * legacyWeight + embedding * embeddingWeight
    }
}

/// Documento actualmente abierto, disponible para la futura integración local
/// de Mate. No persiste credenciales ni envía el contenido fuera del iPad.
final class MVDDocumentSession: ObservableObject {
    static let shared = MVDDocumentSession()

    @Published private(set) var context: MVDDocumentContext?
    @Published private(set) var pageText = ""

    private init() {}

    func update(context: MVDDocumentContext, text: String) {
        self.context = context
        self.pageText = text
    }

    func clear() {
        context = nil
        pageText = ""
    }
}

/// In-memory reading session for Mate. Only item/page cross-references are
/// retained as observations; raw pages and part numbers are never written to
/// disk.
final class MVDMateReadingSession: ObservableObject {
    static let shared = MVDMateReadingSession()

    @Published private(set) var context: MVDDocumentContext?
    @Published private(set) var pagesRead = 0
    @Published private(set) var isReading = false
    @Published private(set) var observations: [MVDMateItemObservation] = []
    @Published private(set) var preferredItem: String?
    @Published private(set) var detectedDrawingItems: [String] = []

    private var pageTextByNumber: [String: String] = [:]
    private var seenObservationIDs: Set<String> = []
    private var drawingItems: [String] = []
    private var firstTablePageByItem: [String: String] = [:]
    private var partNameMatchedItems: Set<String> = []

    private init() {}

    func begin(context: MVDDocumentContext) {
        self.context = context
        pagesRead = 0
        isReading = true
        observations = []
        preferredItem = nil
        pageTextByNumber = [:]
        seenObservationIDs = []
        drawingItems = normalizedItems(from: context.item)
        detectedDrawingItems = drawingItems
        firstTablePageByItem = [:]
        partNameMatchedItems = []
    }

    func append(_ snapshot: MVDMatePageSnapshot) {
        guard isReading else { return }
        pagesRead += 1
        let pageKey = snapshot.pageNumber.isEmpty ? "index-\(snapshot.index)" : snapshot.pageNumber
        pageTextByNumber[pageKey] = snapshot.text

        guard let context else { return }

        // Index zero is the immutable drawing anchor. Handle it even when
        // the viewer has not exposed a page number yet; the document context
        // already contains the page opened by Open Doc.
        if snapshot.index == 0 {
            let detected = drawingItems(from: snapshot.text)
            if !detected.isEmpty {
                drawingItems = detected
                detectedDrawingItems = detected
            }
            return
        }
        // Only the ten pages immediately after the anchor may contribute
        // table rows. A later drawing (for example another item 55 on page
        // 485) can never replace the items captured from the opening drawing.
        guard snapshot.index <= 10,
              !snapshot.pageNumber.isEmpty,
              isPartsTable(snapshot.text),
              !drawingItems.isEmpty else { return }

        let upper = snapshot.text.uppercased()
        for item in drawingItems {
            guard let tableLine = matchingTableLine(for: item, in: upper, context: context) else { continue }
            let matchesPartName = lineMatchesPartName(tableLine, context: context)

            if let firstPage = firstTablePageByItem[item] {
                // Keep the first table occurrence for this drawing item. The
                // one deliberate exception is a later row that explicitly
                // names the requested part (for example 55 -> BUMPER). Once
                // that exact match is found, a later occurrence of the same
                // number is ignored permanently for this session.
                guard matchesPartName, !partNameMatchedItems.contains(item) else { continue }
                observations.removeAll { $0.item == item && $0.tablePage == firstPage }
            }
            firstTablePageByItem[item] = snapshot.pageNumber
            let observationID = "\(context.recordId)|\(item)|\(snapshot.pageNumber)"
            guard seenObservationIDs.insert(observationID).inserted else { continue }
            observations.append(MVDMateItemObservation(
                id: observationID,
                item: item,
                drawingPage: context.pageNumber,
                tablePage: snapshot.pageNumber,
                documentURL: context.documentURL
            ))
            if matchesPartName {
                partNameMatchedItems.insert(item)
                if preferredItem == nil { preferredItem = item }
            }
        }
    }

    func finish() { isReading = false }

    func clear() {
        context = nil
        pagesRead = 0
        isReading = false
        observations = []
        preferredItem = nil
        detectedDrawingItems = []
        pageTextByNumber = [:]
        seenObservationIDs = []
        drawingItems = []
        firstTablePageByItem = [:]
        partNameMatchedItems = []
    }

    private func normalizedItems(from value: String) -> [String] {
        let cleaned = value.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
        return cleaned.isEmpty ? [] : [cleaned]
    }

    private func drawingItems(from text: String) -> [String] {
        let upper = text.uppercased()
        var found: [String] = []
        let labeledPattern = #"\bITEM\s*(?:NO\.?|NUMBER)?\s*([A-Z]?\d{1,3}[A-Z]?)\b"#
        if let regex = try? NSRegularExpression(pattern: labeledPattern) {
            let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
            found.append(contentsOf: regex.matches(in: upper, range: range).compactMap { match in
                guard let itemRange = Range(match.range(at: 1), in: upper) else { return nil }
                return String(upper[itemRange])
            })
        }

        // Flatirons drawings commonly expose callouts as standalone numeric
        // text nodes rather than as the literal word "ITEM". Inspect short
        // lines too, while excluding page numbers and long part numbers.
        if let regex = try? NSRegularExpression(pattern: #"\b\d{1,3}\b"#) {
            for line in upper.components(separatedBy: .newlines) {
                let compactLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !compactLine.isEmpty,
                      compactLine.range(of: #"(?:PAGE|SHEET|FIGURE|FIG\.?|DRAWING)\s*\d{1,4}"#, options: .regularExpression) == nil,
                      compactLine.range(of: #"\d{1,4}\s*(?:OF|DE)\s*\d{1,4}"#, options: .regularExpression) == nil else { continue }
                guard line.range(of: #"\b\d{4,}\b"#, options: .regularExpression) == nil else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let values = regex.matches(in: line, range: range).compactMap { match -> String? in
                    guard let valueRange = Range(match.range, in: line) else { return nil }
                    return String(line[valueRange])
                }
                if values.count <= 4 { found.append(contentsOf: values) }
            }
        }

        let sourcePage = normalizedItems(from: context?.pageNumber ?? "")
        let fallback = normalizedItems(from: context?.item ?? "")
        return Array(Set((found + fallback).filter { !sourcePage.contains($0) && $0 != "0" })).sorted { lhs, rhs in
            (Int(lhs.filter(\.isNumber)) ?? Int.max) < (Int(rhs.filter(\.isNumber)) ?? Int.max)
        }
    }

    private func matchingTableLine(for item: String, in upperText: String, context: MVDDocumentContext) -> String? {
        let lines = upperText.components(separatedBy: .newlines).filter { containsItem(item, in: $0) }
        let partTerms = context.partName.uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 }
        if let exactLine = lines.first(where: { line in partTerms.contains { line.contains($0) } }) {
            return exactLine
        }
        if let itemLine = lines.first { return itemLine }

        // Some PDF viewers expose the table as one flattened text block. Use
        // only a bounded neighborhood around the item in that case, never the
        // entire page; otherwise a BUMPER anywhere on the page could be
        // incorrectly assigned to a different item number.
        guard let itemRange = upperText.range(of: "\\b\(NSRegularExpression.escapedPattern(for: item))\\b",
                                              options: .regularExpression) else { return nil }
        let itemOffset = upperText.distance(from: upperText.startIndex, to: itemRange.lowerBound)
        let startOffset = max(0, itemOffset - 180)
        let endOffset = min(upperText.count, itemOffset + 220)
        let start = upperText.index(upperText.startIndex, offsetBy: startOffset)
        let end = upperText.index(upperText.startIndex, offsetBy: endOffset)
        return String(upperText[start..<end])
    }

    private func lineMatchesPartName(_ line: String, context: MVDDocumentContext) -> Bool {
        let terms = context.partName.uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 }
        guard !terms.isEmpty else { return false }
        return terms.contains { line.contains($0) }
    }

    private func isPartsTable(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.range(of: #"\bPART\s+NUMBER\b"#, options: .regularExpression) != nil ||
            upper.range(of: #"\bNOMENCLATURE\b"#, options: .regularExpression) != nil
    }

    private func containsItem(_ item: String, in upperText: String) -> Bool {
        upperText.range(of: "\\b\(NSRegularExpression.escapedPattern(for: item))\\b", options: .regularExpression) != nil
    }
}

/// Local-only store. Real AA resources are imported later into Application Support;
/// this fixture is intentionally sanitized and contains no aircraft data.
struct MVDLibraryOption: Identifiable, Hashable {
    let key: String
    let version: Int?
    let lastUpdated: String?
    let sizeMB: Double

    var id: String { key }

    var parts: (manufacturer: String, model: String)? {
        let values = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard values.count == 2, !values[0].isEmpty, !values[1].isEmpty else { return nil }
        return (values[0], values[1])
    }

    var isSharedCMM: Bool {
        parts?.model.caseInsensitiveCompare("CMM") == .orderedSame
    }
}

/// Stable Audit identity: the source UCID remains searchable, but different
/// components/documents that arrived with a reused UCID are shown separately.
func mvdAuditGroupKey(_ payload: MVDTrainingPayload) -> String {
    func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    let base = clean(payload.ucid.isEmpty ? payload.recordId : payload.ucid)
    let component = clean(payload.partName.isEmpty
        ? (payload.labeledName.isEmpty ? (payload.item.isEmpty ? payload.description : payload.item) : payload.labeledName)
        : payload.partName)
    let ata = clean([payload.ataChapter, payload.subAta].filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: "-"))
    let cmm = clean(payload.cmmNumber)
    let location = clean(payload.cmmLocation ?? "")
    return [base, component, ata, cmm, location].joined(separator: "|")
}

/// Extracts the human ATA from the actual Flatirons document URL.
/// Internal opaque IDs such as L66ACF... are never used as document labels.
func mvdDocumentATA(from raw: String) -> String? {
    let cleanedURL = raw.replacingOccurrences(of: "\\&", with: "&")
    var candidates: [String] = []
    if let url = URL(string: cleanedURL) {
        if let fragment = url.fragment {
            let query = fragment.components(separatedBy: "?").dropFirst().joined(separator: "?")
            if let items = URLComponents(string: "https://smartlookapp.invalid/?" + query)?.queryItems {
                candidates.append(contentsOf: [
                    items.first(where: { $0.name == "documentTitle" })?.value,
                    url.lastPathComponent,
                    items.first(where: { $0.name == "documentID" })?.value
                ].compactMap { $0 })
            }
        }
        candidates.append(url.lastPathComponent)
    }
    candidates.append(cleanedURL)
    for candidate in candidates {
        let decoded = candidate.removingPercentEncoding ?? candidate
        guard let range = decoded.range(of: #"\d{2}[- ]\d{2}[- ]\d{2}"#, options: .regularExpression) else { continue }
        return decoded[range].replacingOccurrences(of: " ", with: "-")
    }
    return nil
}

final class MVDLocalStore: ObservableObject {
    /// Search results must come from private TrainingData imported on the iPad.
    /// Keeping this empty prevents a demo fixture from being presented as a real match.
    @Published private(set) var training: [MVDTrainingPayload] = []
    @Published private(set) var isPreparing = false
    private var routeByTrainingID: [String: MVDTrainingRoute] = [:]

    /// Audit is populated only from imported private training records. There
    /// is intentionally no demo fallback because it could look like real data.
    @Published private(set) var audit: [MVDAuditItem] = []

    @Published private(set) var lastSearchEmbedding: [Double] = []
    @Published private(set) var searchFeedback: [String: Bool] = [:]
    private var pendingTrainingIDs: Set<String> = []
    private var sessionNegativeTrainingIDs: Set<String> = []
    private var lastImageQueryEmbedding: [Float] = []
    private var hasPreparedPrivateTraining = false

    init() {}

    /// Restores the cached index after the login shell is visible. The
    /// expensive scan/rebuild runs only on the first launch or after an
    /// explicit training update, never on every app start.
    func preparePrivateTraining() {
        guard !hasPreparedPrivateTraining, !isPreparing else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Migrate legacy sidecars before restoring the persistent index.
            self.migrateLegacyLearningFilesIfNeeded()
            if let snapshot = self.loadCachedTrainingIndex() {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyTrainingSnapshot(snapshot)
                    self.hasPreparedPrivateTraining = true
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.beginPrivateTrainingLoad(importArchives: true)
                }
            }
        }
    }

    /// Reloads only files already present on the iPad. Nothing is uploaded and
    /// the directory structure remains the Android-compatible search hierarchy.
    func loadPrivateTrainingIndex() {
        beginPrivateTrainingLoad(importArchives: true)
    }

    /// Returns whether the selected fleet has a local published library.
    /// The fleet is resolved from the selected nose; no fleet is requested at
    /// login time. Apple Devices installs the published archive in Documents,
    /// while older local copies may still exist in Application Support.
    func hasTrainingLibrary(customer: String, manufacturer: String, model: String) -> Bool {
        let wanted = [normalized(customer), normalized(manufacturer), normalized(model)]
        let fileManager = FileManager.default
        for root in privateTrainingRoots() {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame else { continue }
                let parts = url.deletingLastPathComponent().pathComponents.map(normalized)
                guard wanted[0].isEmpty || parts.contains(wanted[0]),
                      wanted[1].isEmpty || parts.contains(wanted[1]) else { continue }
                // A shared CMM is a separate library. It must not make an
                // aircraft model appear installed, otherwise the download
                // sheet can skip a missing B777/B787/A320 library.
                if wanted[2].caseInsensitiveCompare("CMM") == .orderedSame {
                    if parts.contains("CMM") { return true }
                } else if !wanted[2].isEmpty && parts.contains(wanted[2]) {
                    return true
                }
            }
        }
        return false
    }

    /// Loads the server manifest used by the iOS fleet selector. CMM appears
    /// as its own shared library entry because it is stored beside aircraft
    /// model folders on the server and is reused by multiple fleets.
    func fetchLibraryManifest(customer: String, completion: @escaping ([MVDLibraryOption]) -> Void) {
        let encodedCustomer = customer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? customer
        guard let url = URL(string: "http://100.109.229.98:5050/fleet-manifest/\(encodedCustomer)") else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            var options: [MVDLibraryOption] = []
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                options = object.keys.sorted().compactMap { key in
                    let value = object[key] as? [String: Any] ?? [:]
                    let version = (value["version"] as? NSNumber)?.intValue
                    let lastUpdated = value["last_updated"] as? String
                    let sizeMB = (value["size_mb"] as? NSNumber)?.doubleValue ?? 0
                    return MVDLibraryOption(key: key, version: version, lastUpdated: lastUpdated, sizeMB: sizeMB)
                }
            }
            DispatchQueue.main.async { completion(options) }
        }.resume()
    }

    private func beginPrivateTrainingLoad(importArchives: Bool) {
        guard !isPreparing else { return }
        isPreparing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // One-time migration of learning sidecars created by older builds.
            // It runs before cache restoration and is skipped thereafter.
            self.migrateLegacyLearningFilesIfNeeded()
            if importArchives {
                MVDPrivateArchiveImporter.importPendingCMMArchives()
            }
            // The cache is invalidated by a local training-file/archive
            // signature. This avoids decoding and hydrating the whole library
            // on every app launch while still picking up a new import.
            let snapshot = self.loadCachedTrainingIndex() ?? {
                let fresh = self.buildPrivateTrainingIndex()
                self.saveCachedTrainingIndex(fresh)
                return fresh
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyTrainingSnapshot(snapshot)
                self.hasPreparedPrivateTraining = true
                self.isPreparing = false
            }
        }
    }

    private struct TrainingIndexCache: Codable {
        let schemaVersion: Int
        let signature: String
        let training: [MVDTrainingPayload]
        let routes: [String: MVDTrainingRoute]
    }

    // Version 3 moves the index cache out of Application Support so an IPA
    // update keeps it together with the user's Documents/TrainingData.
    private static let trainingIndexSchemaVersion = 3

    private var trainingCacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".smartlookapp", isDirectory: true)
            .appendingPathComponent("smartlookapp-training-index-cache.json")
    }

    private var legacyTrainingCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smartlookapp-training-index-cache.json")
    }

    private var learningMigrationMarkerURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".smartlookapp", isDirectory: true)
            .appendingPathComponent("learning-migration-v1.done")
    }

    /// The downloaded libraries and their learning sidecars share one stable
    /// root in Documents. Updating the IPA does not replace this directory.
    private var canonicalTrainingRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrainingData", isDirectory: true)
    }

    private func loadCachedTrainingIndex() -> (training: [MVDTrainingPayload], routes: [String: MVDTrainingRoute])? {
        let candidates = [trainingCacheURL, legacyTrainingCacheURL]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let cache = try? JSONDecoder().decode(TrainingIndexCache.self, from: data),
                  cache.schemaVersion == Self.trainingIndexSchemaVersion,
                  cache.signature == trainingSourceSignature() else { continue }
            return (cache.training, cache.routes)
        }
        return nil
    }

    private struct MVDLocalTrainingChangeQueue: Codable {
        var upserts: [MVDTrainingPayload] = []
        var deletedRecordIDs: [String] = []
        var deletedUCIDs: [String] = []
    }

    private var localTrainingChangesURL: URL {
        trainingCacheURL.deletingLastPathComponent()
            .appendingPathComponent("training-local-changes.json")
    }

    private func loadLocalTrainingChanges() -> MVDLocalTrainingChangeQueue {
        guard let data = try? Data(contentsOf: localTrainingChangesURL),
              let queue = try? JSONDecoder().decode(MVDLocalTrainingChangeQueue.self, from: data) else {
            return MVDLocalTrainingChangeQueue()
        }
        return queue
    }

    private func saveLocalTrainingChanges(_ queue: MVDLocalTrainingChangeQueue) {
        let folder = localTrainingChangesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: localTrainingChangesURL, options: .atomic)
    }

    private func routeForLocalPayload(_ payload: MVDTrainingPayload) -> MVDTrainingRoute {
        MVDTrainingRoute(
            customer: payload.customerCode,
            manufacturer: payload.manufacturer,
            model: payload.model,
            nose: payload.aircraftNose,
            manual: payload.manualType,
            cmmNumber: payload.cmmNumber,
            ataFolder: payload.ataChapter,
            sourceFileName: "local-training-\(payload.id).json"
        )
    }

    private func persistCurrentTrainingState() {
        let snapshot = (training: training, routes: routeByTrainingID)
        audit = makeAuditItems(from: training, routes: routeByTrainingID)
        saveCachedTrainingIndex(snapshot)
        writeAndroidCompatibleIndexes(snapshot)
    }

    private func applyTrainingSnapshot(_ snapshot: (training: [MVDTrainingPayload], routes: [String: MVDTrainingRoute])) {
        var mergedTraining = snapshot.training
        var mergedRoutes = snapshot.routes
        let queue = loadLocalTrainingChanges()
        let deletedIDs = Set(queue.deletedRecordIDs)
        let deletedUCIDs = Set(queue.deletedUCIDs)
        mergedTraining.removeAll {
            deletedIDs.contains($0.id) || (!$0.ucid.isEmpty && deletedUCIDs.contains($0.ucid))
        }
        for payload in queue.upserts {
            mergedTraining.removeAll { $0.id == payload.id }
            mergedTraining.append(payload)
            mergedRoutes[payload.id] = routeForLocalPayload(payload)
        }
        mergedRoutes = mergedRoutes.filter { key, _ in mergedTraining.contains(where: { $0.id == key }) }
        let importedIDs = Set(mergedTraining.map(\.id))
        training.removeAll { importedIDs.contains($0.id) }
        training.append(contentsOf: mergedTraining)
        routeByTrainingID = mergedRoutes
        audit = makeAuditItems(from: mergedTraining, routes: mergedRoutes)
        saveCachedTrainingIndex((training: mergedTraining, routes: mergedRoutes))
        writeAndroidCompatibleIndexes((training: mergedTraining, routes: mergedRoutes))
    }

    private func saveCachedTrainingIndex(_ snapshot: (training: [MVDTrainingPayload], routes: [String: MVDTrainingRoute])) {
        let cache = TrainingIndexCache(
            schemaVersion: Self.trainingIndexSchemaVersion,
            signature: trainingSourceSignature(),
            training: snapshot.training,
            routes: snapshot.routes
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let folder = trainingCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: trainingCacheURL, options: .atomic)
    }

    /// Writes Android's canonical mate_master_index.json beside every downloaded model.
    /// It is rebuilt after an import/update and never replaces the training JSONs.
    private func writeAndroidCompatibleIndexes(_ snapshot: (training: [MVDTrainingPayload], routes: [String: MVDTrainingRoute])) {
        let grouped = Dictionary(grouping: snapshot.training) { record -> String in
            let route = snapshot.routes[record.id]
            return [route?.customer ?? record.customerCode,
                    route?.manufacturer ?? record.manufacturer,
                    route?.model ?? record.model]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "/")
        }
        let fileManager = FileManager.default
        for (key, records) in grouped {
            let parts = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0 != "N/A" }) else { continue }
            for root in privateTrainingRoots() {
                let customerRoot = root.appendingPathComponent(parts[0], isDirectory: true)
                let manufacturerRoot = root.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: true)
                let modelRoot = root.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: true).appendingPathComponent(parts[2], isDirectory: true)
                guard fileManager.fileExists(atPath: customerRoot.path) || fileManager.fileExists(atPath: manufacturerRoot.path) || fileManager.fileExists(atPath: modelRoot.path) else { continue }
                try? fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)

                var master: [String: Any] = [:]
                for record in records {
                    let partName = record.partName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !partName.isEmpty, let documentLink = record.documentURL?.absoluteString, !documentLink.isEmpty else { continue }
                    let route = snapshot.routes[record.id]
                    let manual = normalizedManual(route?.manual ?? record.manualType)
                    guard !manual.isEmpty else { continue }
                    var component = master[partName] as? [String: Any] ?? [
                        "partName": partName,
                        "component": "",
                        "item": record.item,
                        "nose": record.aircraftNose,
                        "description": record.description
                    ]
                    let document: [String: Any] = [
                        "ucid": androidIndex(for: record),
                        "sourceFile": route?.sourceFileName ?? "",
                        "documentLink": documentLink,
                        "labeledName": record.labeledName
                    ]
                    if let previous = component[manual] as? [[String: Any]] {
                        component[manual] = previous + [document]
                    } else if let previous = component[manual] as? [String: Any] {
                        component[manual] = [previous, document]
                    } else {
                        component[manual] = document
                    }
                    master[partName] = component
                }
                guard JSONSerialization.isValidJSONObject(master),
                      let data = try? JSONSerialization.data(withJSONObject: master, options: [.prettyPrinted, .sortedKeys]) else { continue }
                let indexURL = modelRoot.appendingPathComponent("mate_master_index.json")
                if let existing = try? Data(contentsOf: indexURL), existing == data { continue }
                try? data.write(to: indexURL, options: .atomic)
            }
        }
    }

    /// Metadata-only fingerprint: it does not read image or JSON contents.
    /// Any imported/updated file changes the signature and causes one rebuild.
    private func trainingSourceSignature() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let bases = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ]
        for base in bases {
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let inTrainingTree = url.pathComponents.contains {
                    let name = $0.lowercased()
                    return name == "trainingdata" || name == "new trainings"
                }
                let pendingArchive = url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame
                    && url.lastPathComponent.localizedCaseInsensitiveContains("cmm")
                guard inTrainingTree || pendingArchive else { continue }
                // Feedback sidecars are learned data, not library source files.
                // Changing a thumbs-up must not force a full index rebuild.
                let sidecarName = url.lastPathComponent.lowercased()
                guard sidecarName != "_feedback.json",
                      sidecarName != "_positive_embeddings.jsonl",
                      sidecarName != "mate_master_index.json" else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? 0
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                parts.append("\(url.path)|\(size)|\(modified)")
            }
        }
        return parts.sorted().joined(separator: "\n")
    }

    /// Reads only files already present on the iPad. This method is called on a
    /// background queue; only the resulting snapshot is published on main.
    private func buildPrivateTrainingIndex() -> (training: [MVDTrainingPayload], routes: [String: MVDTrainingRoute]) {
        var imported: [MVDTrainingPayload] = []
        var importedRoutes: [String: MVDTrainingRoute] = [:]
        pendingTrainingIDs.removeAll()
        func appendImported(_ original: MVDTrainingPayload, route: MVDTrainingRoute, pending: Bool = false) {
            var payload = original
            // The physical CMM folder is authoritative. Reject exports whose
            // internal document reference points at another CMM; otherwise a
            // 25-02-67 record can pollute the exact 25-02-48 search scope.
            guard cmmTrainingIsConsistent(payload, route: route) else { return }
            // Android libraries can reuse a recordId in different manual
            // folders, and some legacy JSON has no recordId at all. Keep
            // every imported record addressable so its folder route cannot
            // be overwritten by the next JSON file.
            let baseID = payload.id
            if importedRoutes[baseID] != nil || baseID.isEmpty || baseID.hasPrefix("N/A-") {
                payload.recordId = "IMPORTED-\(imported.count + 1)-\(baseID.isEmpty ? "RECORD" : baseID)"
            }
            imported.append(payload)
            importedRoutes[payload.id] = route
            if pending { pendingTrainingIDs.insert(payload.id) }
        }
        let fileManager = FileManager.default
        let baseRoots = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ]
        // Apple Devices exposes the app sandbox Documents directory. Resolve
        // TrainingData case-insensitively because Windows copies can alter case.
        var roots: [URL] = []
        for base in baseRoots {
            if let dirs = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in dirs where ["TrainingData", "New Trainings"].contains(where: { url.lastPathComponent.caseInsensitiveCompare($0) == .orderedSame }) {
                    roots.append(url)
                }
            }
        }
        if roots.isEmpty {
            roots = baseRoots.flatMap { [
                $0.appendingPathComponent("TrainingData", isDirectory: true),
                $0.appendingPathComponent("New Trainings", isDirectory: true)
            ] }
        }
        for root in roots {
            let pending = root.lastPathComponent.caseInsensitiveCompare("New Trainings") == .orderedSame
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" && url.lastPathComponent.caseInsensitiveCompare("mate_master_index.json") != .orderedSame {
                guard let data = try? Data(contentsOf: url) else { continue }
                let route = inferredRoute(for: url)
                // Prefer the Android-compatible adapter for object records. It
                // also understands legacy aliases such as maintMessage, which
                // otherwise decode successfully but leave matMessage empty.
                if let records = try? JSONDecoder().decode([MVDAndroidTrainingRecord].self, from: data) {
                    for record in records {
                        appendImported(hydrateImages(in: record.asPayload(manualType: route.manual, route: route), jsonURL: url), route: route, pending: pending)
                    }
                } else if let values = try? JSONDecoder().decode([MVDTrainingPayload].self, from: data) {
                    for value in values {
                        appendImported(hydrateImages(in: apply(route: route, to: value), jsonURL: url), route: route, pending: pending)
                    }
                } else if let value = try? JSONDecoder().decode(MVDAndroidTrainingRecord.self, from: data) {
                    appendImported(hydrateImages(in: value.asPayload(manualType: route.manual, route: route), jsonURL: url), route: route, pending: pending)
                } else if let value = try? JSONDecoder().decode(MVDTrainingPayload.self, from: data) {
                    appendImported(hydrateImages(in: apply(route: route, to: value), jsonURL: url), route: route, pending: pending)
                } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // MaintMessage and some CMM libraries are dictionaries
                    // keyed by the message/document number rather than one
                    // TrainingPayload per file.
                    for (key, rawValue) in object {
                        guard let nested = rawValue as? [String: Any],
                              JSONSerialization.isValidJSONObject(nested),
                              let nestedData = try? JSONSerialization.data(withJSONObject: nested),
                              var record = try? JSONDecoder().decode(MVDAndroidTrainingRecord.self, from: nestedData) else { continue }
                        var payload = record.asPayload(manualType: route.manual, route: route)
                        if payload.recordId.isEmpty { payload.recordId = key }
                        if payload.matMessage.isEmpty { payload.matMessage = key }
                        appendImported(hydrateImages(in: payload, jsonURL: url), route: route, pending: pending)
                    }
                }
            }
        }
        return (imported, importedRoutes)
    }

    /// Mirrors Android v12.2 `findMaintMessageRecord()` directly on the
    /// private iPad files. MaintMessage is not a normal training collection:
    /// the first two code digits select ATAxx and the code is then matched
    /// against the record's `maintMsg` field or the key of a dictionary JSON.
    /// This direct path keeps the result correct even when a legacy JSON has
    /// not been decoded into the generic training index.
    private func findMaintMessagePayload(code: String, nose: String) -> (MVDTrainingPayload, MVDTrainingRoute)? {
        let cleanedCode = normalized(code)
        guard cleanedCode.count >= 2 else { return nil }
        let ataFolder = "ATA\(cleanedCode.prefix(2))"
        let directories = maintMessageDirectories(nose: nose, ataFolder: ataFolder)
        let decoder = JSONDecoder()

        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )) ?? []
            for file in files where file.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
                guard let data = try? Data(contentsOf: file) else { continue }
                let route = inferredRoute(for: file)

                // Historical Android exports may store one record per JSON.
                if let record = try? decoder.decode(MVDAndroidTrainingRecord.self, from: data),
                   let value = maintPayload(record: record, key: "", route: route) {
                    if normalized(value.matMessage) == cleanedCode {
                        return (value, route)
                    }
                }

                // Other exports store all messages under their message code.
                guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
                if let dictionary = object as? [String: Any] {
                    for (key, rawValue) in dictionary {
                        guard normalized(key) == cleanedCode else { continue }
                        if let nested = rawValue as? [String: Any],
                           let nestedData = try? JSONSerialization.data(withJSONObject: nested),
                           let record = try? decoder.decode(MVDAndroidTrainingRecord.self, from: nestedData),
                           let value = maintPayload(record: record, key: key, route: route) {
                            return (value, route)
                        }
                        if let scalar = rawValue as? String {
                            var value = MVDTrainingPayload()
                            value.recordId = key
                            value.matMessage = key
                            value.description = scalar
                            value.manualType = "FIM"
                            value.ataChapter = String(route.ataFolder.dropFirst(3))
                            value.customerCode = route.customer
                            value.manufacturer = route.manufacturer
                            value.model = route.model
                            value.aircraftNose = route.nose
                            return (value, route)
                        }
                    }

                    // A single object can use maintMsg/maintMessage rather
                    // than a dictionary key. Match the Android field aliases.
                    if let record = try? decoder.decode(MVDAndroidTrainingRecord.self, from: data),
                       let value = maintPayload(record: record, key: "", route: route),
                       normalized(value.matMessage) == cleanedCode {
                        return (value, route)
                    }
                }

                if let array = object as? [[String: Any]] {
                    for entry in array {
                        guard let entryData = try? JSONSerialization.data(withJSONObject: entry),
                              let record = try? decoder.decode(MVDAndroidTrainingRecord.self, from: entryData),
                              let value = maintPayload(record: record, key: "", route: route),
                              normalized(value.matMessage) == cleanedCode else { continue }
                        return (value, route)
                    }
                }
            }
        }
        return nil
    }

    private func maintPayload(record: MVDAndroidTrainingRecord, key: String, route: MVDTrainingRoute) -> MVDTrainingPayload? {
        var value = record.asPayload(manualType: "MAINT", route: route)
        if !key.isEmpty { value.recordId = key }
        if value.matMessage.isEmpty { value.matMessage = key }
        value.manualType = "FIM"
        if !route.ataFolder.isEmpty {
            value.ataChapter = String(route.ataFolder.dropFirst(3))
        }
        return value.matMessage.isEmpty ? nil : value
    }

    /// Finds both customer-first and legacy model-first layouts while keeping
    /// the selected aircraft model in the route. The lookup is case-insensitive
    /// because Windows/Apple Devices copies can change folder casing.
    private func maintMessageDirectories(nose: String, ataFolder: String) -> [URL] {
        let expected = aircraftForNose(nose)
        let expectedModel = expected.map { normalized($0.model) } ?? ""
        let expectedCustomer = normalized(expected?.customer ?? "AA")
        let expectedManufacturer = normalized(expected?.manufacturer ?? "Boeing")
        var result: [URL] = []
        let fileManager = FileManager.default

        for root in privateTrainingRoots() {
            // Fast path for the two layouts used by the Android export and by
            // the current iPad copy. This also avoids relying on a recursive
            // scan when the folder contains a large secure image collection.
            if let model = expected?.model, !model.isEmpty {
                let directBases = [
                    root.appendingPathComponent("\(expectedCustomer)/\(expectedManufacturer)/\(model)", isDirectory: true),
                    root.appendingPathComponent("\(expectedManufacturer)/\(model)/\(expectedCustomer)", isDirectory: true)
                ]
                for base in directBases {
                    for manualName in ["MaintMessage"] {
                        let directory = base
                            .appendingPathComponent(manualName, isDirectory: true)
                            .appendingPathComponent(ataFolder, isDirectory: true)
                        if (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            result.append(directory)
                        }
                    }
                }
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let parts = url.pathComponents
                let normalizedParts = parts.map(normalized)
                guard normalizedParts.contains("MAINTMESSAGE") else { continue }
                guard normalizedParts.contains(normalized(ataFolder)) else { continue }
                if !expectedModel.isEmpty && !normalizedParts.contains(expectedModel) { continue }
                if !expectedCustomer.isEmpty && !normalizedParts.contains(expectedCustomer) { continue }
                if !expectedManufacturer.isEmpty && !normalizedParts.contains(expectedManufacturer) { continue }
                if !result.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    result.append(url)
                }
            }
        }
        return result
    }

    private func privateTrainingRoots() -> [URL] {
        let fileManager = FileManager.default
        let bases = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ]
        var roots: [URL] = []
        for base in bases {
            if let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in enumerator where ["TrainingData", "New Trainings"].contains(where: { url.lastPathComponent.caseInsensitiveCompare($0) == .orderedSame }) {
                    roots.append(url)
                }
            }
        }
        if roots.isEmpty {
            roots = bases.flatMap { [
                $0.appendingPathComponent("TrainingData", isDirectory: true),
                $0.appendingPathComponent("New Trainings", isDirectory: true)
            ] }
        }
        return roots
    }

    /// Builds the same readable technical index used by Android MateTextIndex.
    /// The UCID is the human-facing component index; recordId remains internal.
    private func androidIndex(for record: MVDTrainingPayload) -> String {
        let explicit = record.ucid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit.uppercased() }

        let legacy = record.recordId.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacy.range(of: #"^[A-Z]{2,4}-[A-Z0-9]+-\d{7}$"#, options: .regularExpression) != nil {
            return legacy.uppercased()
        }

        let prefix: String
        switch record.manufacturer.uppercased() {
        case "BOEING": prefix = "BA"
        case "AIRBUS": prefix = "AIRB"
        default: prefix = String(record.manufacturer.uppercased().prefix(3))
        }
        let model = record.model.uppercased().split(separator: "-").first.map(String.init) ?? "MODEL"
        let ataDigits = record.ataChapter.filter(\.isNumber)
        let ata = ataDigits.isEmpty ? "00" : String(repeating: "0", count: max(0, 2 - ataDigits.count)) + ataDigits
        let itemValue = record.item.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = String(repeating: "0", count: max(0, 5 - itemValue.count)) + (itemValue.isEmpty ? "00000" : itemValue)
        return "\(prefix)-\(model)-\(ata)\(item)"
    }

    private func makeAuditItems(from records: [MVDTrainingPayload], routes: [String: MVDTrainingRoute]) -> [MVDAuditItem] {
        let allowedManuals = Set(["AMM", "AIPC", "WDM", "CMM"])
        var orderedKeys: [String] = []
        var grouped: [String: [MVDTrainingPayload]] = [:]
        for record in records {
            let route = routes[record.id]
            let manual = normalizedManual(route?.manual ?? inferredManual(for: record))
            guard allowedManuals.contains(manual) else { continue }
            let key = mvdAuditGroupKey(record)
            if grouped[key] == nil { orderedKeys.append(key) }
            grouped[key, default: []].append(record)
        }
        var baseCounts: [String: Int] = [:]
        for key in orderedKeys {
            let base = key.components(separatedBy: "|").first ?? key
            baseCounts[base, default: 0] += 1
        }
        var baseOrdinals: [String: Int] = [:]
        return orderedKeys.compactMap { key in
            guard let group = grouped[key], let representative = group.first else { return nil }
            let route = routes[representative.id]
            let manual = normalizedManual(route?.manual ?? inferredManual(for: representative))
            let base = key.components(separatedBy: "|").first ?? key
            baseOrdinals[base, default: 0] += 1
            let indexLabel: String
            if (baseCounts[base] ?? 0) > 1 {
                indexLabel = "\(base)-\(String(format: "%02d", baseOrdinals[base] ?? 1))"
            } else {
                indexLabel = base
            }
            let representativeDocument = representative.trainingProcedureLink.isEmpty ? representative.pinpointLink : representative.trainingProcedureLink
            let ata = mvdDocumentATA(from: representativeDocument) ?? [representative.ataChapter, representative.subAta]
                .filter { !$0.isEmpty && $0 != "N/A" }
                .joined(separator: "-")
            let title = representative.partName.isEmpty
                ? (representative.description.isEmpty ? "Training record" : representative.description)
                : representative.partName
            var images: [String] = []
            for record in group {
                for image in record.imageFiles where !images.contains(image) { images.append(image) }
            }
            let manuals = group.compactMap { value -> String? in
                let itemRoute = routes[value.id]
                let valueManual = normalizedManual(itemRoute?.manual ?? inferredManual(for: value))
                let rawDocument = value.trainingProcedureLink.isEmpty ? value.pinpointLink : value.trainingProcedureLink
                let valueATA = mvdDocumentATA(from: rawDocument) ?? [value.ataChapter, value.subAta].filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: "-")
                let ref = [valueManual, valueATA].filter { !$0.isEmpty }.joined(separator: " ")
                return ref.isEmpty ? nil : ref
            }.reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }.joined(separator: " + ")
            return MVDAuditItem(
                id: "AUDIT-\(representative.id)",
                ucid: indexLabel,
                title: title,
                isDone: false,
                boeingLink: representative.documentURL?.absoluteString ?? "",
                manualRef: manuals.isEmpty ? [manual, ata].filter { !$0.isEmpty }.joined(separator: " ") : manuals,
                imageFiles: images,
                originClient: representative.customerCode.isEmpty ? (route?.customer ?? "AA") : representative.customerCode
            )
        }
    }

    /// Folder metadata is authoritative when Android JSON omitted route fields.
    private func apply(route: MVDTrainingRoute, to original: MVDTrainingPayload) -> MVDTrainingPayload {
        var value = original
        if !route.customer.isEmpty { value.customerCode = route.customer }
        if !route.manufacturer.isEmpty { value.manufacturer = route.manufacturer }
        if !route.model.isEmpty && (value.model.isEmpty || value.model == "N/A") { value.model = route.model }
        if !route.nose.isEmpty { value.aircraftNose = route.nose }
        if !route.manual.isEmpty { value.manualType = route.manual }
        if !route.cmmNumber.isEmpty { value.cmmNumber = route.cmmNumber }
        return value
    }

    /// Derives the Android-compatible route from the private folder hierarchy.
    /// Expected forms include AA/Boeing/model/nose/manual and TrainingData/AA/...
    private func inferredRoute(for url: URL) -> MVDTrainingRoute {
        let components = url.pathComponents.map { $0.uppercased() }
        let knownNoses = Set(MVDLocalFleetCatalog.all.map { normalized($0.nose) })
        let nose = components.first(where: { knownNoses.contains(normalized($0)) }) ?? ""
        let manualNames = ["AMM", "AIPC", "WDM", "FIM", "CMM", "MEL", "CDL", "NEF", "TAC", "SRM", "IFE", "AMSAFE", "EO", "SB", "EOSB", "EICAS", "FAULTCODES", "MAINTMESSAGE", "AARD200", "AARD300"]
        let manual = components.first(where: {
            let compact = $0.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            return manualNames.contains(compact)
        }) ?? ""
        let aircraft = MVDLocalFleetCatalog.all.first { normalized($0.nose) == normalized(nose) }
        let customer = components.first(where: { $0 == "AA" }) ?? aircraft?.customer ?? "AA"
        let manufacturer = components.first(where: { $0 == "BOEING" || $0 == "AIRBUS" })?.capitalized ?? aircraft?.manufacturer ?? "Boeing"
        let modelNames = Set(MVDLocalFleetCatalog.all.map { $0.model.uppercased().replacingOccurrences(of: " ", with: "-") })
        let model = components.first(where: { modelNames.contains($0.replacingOccurrences(of: " ", with: "-").uppercased()) }) ?? aircraft?.model ?? ""
        let cmmNumber = components.first(where: { $0.range(of: #"^CMM\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil })?.dropFirst(3).description ?? ""
        let ataFolder = components.first(where: {
            $0.range(of: #"^ATA\d{2}$"#, options: .regularExpression) != nil
        }).map { "ATA\($0.suffix(2))" } ?? ""
        return MVDTrainingRoute(customer: customer, manufacturer: manufacturer, model: model, nose: nose, manual: manual, cmmNumber: cmmNumber, ataFolder: ataFolder, sourceFileName: url.lastPathComponent)
    }

    /// Android compares each JSON record with the real images in its
    /// manual/SECURE_RESOURCES folder. Older exports may omit imageEmbeddings;
    /// generate the same local vectors from those files during import.
    private func hydrateImages(in original: MVDTrainingPayload, jsonURL: URL) -> MVDTrainingPayload {
        var value = original
        guard !value.imageFiles.isEmpty else { return value }
        let jsonDirectory = jsonURL.deletingLastPathComponent()
        var searchRoots: [URL] = [jsonDirectory]
        var ancestor = jsonDirectory
        // Android exports place the reference images in SECURE_RESOURCES;
        // depending on the export, it is beside the JSON folder or beside
        // the selected manual. Probe both layouts, case-insensitively.
        for _ in 0..<6 {
            searchRoots.append(ancestor.appendingPathComponent("SECURE_RESOURCES", isDirectory: true))
            searchRoots.append(ancestor.appendingPathComponent("secure_resources", isDirectory: true))
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        if let secureIndex = jsonDirectory.pathComponents.firstIndex(where: { $0.caseInsensitiveCompare("SECURE_RESOURCES") == .orderedSame }) {
            let secureURL = URL(fileURLWithPath: "/" + jsonDirectory.pathComponents[0...secureIndex].dropFirst().joined(separator: "/"), isDirectory: true)
            searchRoots.insert(secureURL, at: 0)
        }
        var uniqueRoots: [URL] = []
        for root in searchRoots where !uniqueRoots.contains(where: { $0.standardizedFileURL.path == root.standardizedFileURL.path }) {
            uniqueRoots.append(root)
        }
        var vectors = Array(repeating: [Float](), count: value.imageFiles.count)
        for (index, rawName) in value.imageFiles.enumerated() {
            if index < value.imageEmbeddings.count, !value.imageEmbeddings[index].isEmpty {
                vectors[index] = value.imageEmbeddings[index]
                continue
            }
            let name = rawName.replacingOccurrences(of: "\\", with: "/")
            let candidates = uniqueRoots.map { $0.appendingPathComponent(name) } +
                uniqueRoots.map { $0.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent) }
            guard let imageURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let image = UIImage(contentsOfFile: imageURL.path),
                  let vector = MVDOnnxEmbedding.shared.vector(for: image) else { continue }
            vectors[index] = vector
        }
        if vectors.contains(where: { !$0.isEmpty }) { value.imageEmbeddings = vectors }
        return value
    }

    func search(eicas: String, fim: String, maint: String, manual: String, nose: String, cmmNumber: String = "", includePending: Bool = false) -> [MVDTrainingPayload] {
        let e = normalized(eicas)
        let f = normalized(fim)
        let m = normalized(maint)
        // Android routes the single MaintMessage hierarchy independently of
        // the visible manual picker. Preserve that behavior on iOS.
        let selectedManual: String
        if !e.isEmpty { selectedManual = "EICAS" }
        else if !f.isEmpty { selectedManual = "FIM" }
        else if !m.isEmpty { selectedManual = "MAINT" }
        else { selectedManual = normalizedManual(manual) }
        let selectedNose = normalized(nose)
        let selectedCMM = normalized(cmmNumber)
        let aircraft = aircraftForNose(nose)

        // Android's text flow is field-specific. It does not rank arbitrary
        // metadata and it never falls through to an old image search.
        let scoped = training.filter { item in
            guard includePending || !pendingTrainingIDs.contains(item.id) else { return false }
            let route = routeByTrainingID[item.id]
            return matchesManual(item, route: route, wanted: selectedManual, cmmNumber: selectedCMM) &&
            matchesAircraft(item, route: route, expected: aircraft) &&
            matchesNose(item, route: route, wanted: selectedNose)
            && (selectedCMM.isEmpty || normalized(route?.cmmNumber ?? item.cmmNumber) == selectedCMM)
        }
        if !e.isEmpty {
            return scoped.filter { normalized($0.eicasMessage).contains(e) }
        }
        if !f.isEmpty {
            guard f.count >= 2 else { return [] }
            return scoped.filter { normalized($0.faultCode) == f }
        }
        if !m.isEmpty {
            guard m.count >= 2 else { return [] }
            // Follow Android's dedicated MaintMessage lookup before applying
            // generic indexed-record filters.
            if let direct = findMaintMessagePayload(code: m, nose: nose) {
                return [direct.0]
            }
            let wantedATA = ataFolder(for: m)
            return scoped.filter { item in
                let route = routeByTrainingID[item.id]
                guard routeMatchesATA(route, wanted: wantedATA) else { return false }
                return normalized(item.matMessage) == m || normalized(item.description) == m
            }
        }
        return []
    }

    /// Image search using the MobileNet embeddings stored by Android v12.2.
    /// The query embedding is computed once on-device; stored vectors are read
    /// from the imported JSON and never uploaded.
    func searchByImage(_ image: UIImage, manual: String, nose: String, cmmNumber: String = "") -> [MVDTrainingPayload] {
        searchByImages(context: image, extracted: nil, manual: manual, nose: nose, cmmNumber: cmmNumber)
    }

    /// Android v12.2 visual contract: the full context image identifies the
    /// aircraft area, while an optional extracted piece refines the match.
    /// The context remains mandatory so an extraction can never erase the
    /// positional information from the original photograph.
    func searchByImages(context: UIImage, extracted: UIImage?, manual: String, nose: String, cmmNumber: String = "", includePending: Bool = false) -> [MVDTrainingPayload] {
        _ = includePending
        guard let contextQuery = MVDOnnxEmbedding.shared.vector(for: context) else { return [] }
        let extractedQuery = extracted.flatMap { MVDOnnxEmbedding.shared.vector(for: $0) }
        // Android v12.4 learns from the exact bitmap used for the visual
        // search: the extracted piece when available, otherwise the context.
        // Keep this vector alive until the feedback button is pressed so a
        // positive result can be stored as a real field exemplar.
        lastImageQueryEmbedding = extractedQuery ?? contextQuery

        let wantedManual = normalizedManual(manual)
        let wantedNose = normalized(nose)
        let wantedCMM = normalized(cmmNumber)
        let aircraft = aircraftForNose(nose)
        let candidates = training.filter { item in
            guard !sessionNegativeTrainingIDs.contains(item.id) else { return false }
            let route = routeByTrainingID[item.id]
            return matchesManual(item, route: route, wanted: wantedManual, cmmNumber: wantedCMM) &&
            matchesAircraft(item, route: route, expected: aircraft) &&
            matchesNose(item, route: route, wanted: wantedNose) &&
            (wantedCMM.isEmpty || normalized(item.cmmNumber) == wantedCMM || normalized(item.cmmNumber).isEmpty)
        }

        return candidates.compactMap { item -> (Double, MVDTrainingPayload)? in
            let route = routeByTrainingID[item.id]
            let feedback = loadAndroidFeedback(for: route)
            let learnedQuery = extractedQuery ?? contextQuery

            // Original Android-compatible visual score: context plus the
            // extracted piece, with the same 40/60 weighting.
            var best = item.imageEmbeddings.map { stored in
                let contextScore = MVDOnnxEmbedding.cosine(contextQuery, stored)
                guard let extractedQuery else { return contextScore }
                let extractedScore = MVDOnnxEmbedding.cosine(extractedQuery, stored)
                return MVDVisualSearchFormula.contextWeight * contextScore +
                    MVDVisualSearchFormula.extractedWeight * extractedScore
            }.max() ?? 0

            // Android's positive exemplars are a second, pure embedding
            // signal. They compete directly with the original reference
            // images and can therefore correct a recurring wrong first match.
            for exemplar in feedback.exemplars where exemplar.count == learnedQuery.count {
                best = max(best, MVDOnnxEmbedding.cosine(learnedQuery, exemplar))
            }

            guard best > 0 else { return nil }

            // Android stores the score as a distance and subtracts
            // POSITIVE_BOOST_PER_VOTE (8/100) per confirmed thumbs-up. In
            // this similarity representation the equivalent is addition.
            // Do not clamp the result to 1.0: Android deliberately preserves
            // the difference between candidates instead of creating ties.
            let positiveBoost = min(
                MVDVisualSearchFormula.positiveBoostCap,
                Double(feedback.votes) * MVDVisualSearchFormula.positiveBoostPerVote
            )
            return (best + positiveBoost, item)
        }
        .sorted { $0.0 > $1.0 }
        .prefix(10)
        .map(\.1)
    }

    func hasTraining(for manual: String, nose: String) -> Bool {
        let wantedManual = normalizedManual(manual)
        let wantedNose = normalized(nose)
        return training.contains {
            let route = routeByTrainingID[$0.id]
            return normalizedManual(route?.manual ?? $0.manualType) == wantedManual &&
            matchesNose($0, route: route, wanted: wantedNose)
        }
    }

    /// Reports whether the requested Android-compatible search folder exists.
    /// MaintMessage is special: its first two code digits select ATAxx before
    /// the single JSON index in that folder is searched.
    func hasTrainingForSearch(eicas: String, fim: String, maint: String, manual: String, nose: String, cmmNumber: String = "") -> Bool {
        let e = normalized(eicas)
        let f = normalized(fim)
        let m = normalized(maint)
        let wantedManual: String
        if !e.isEmpty { wantedManual = "EICAS" }
        else if !f.isEmpty { wantedManual = "FIM" }
        else if !m.isEmpty { wantedManual = "MAINT" }
        else { wantedManual = normalizedManual(manual) }
        let expected = aircraftForNose(nose)
        let wantedNose = normalized(nose)
        let wantedCMM = normalized(cmmNumber)
        let wantedATA = m.isEmpty ? nil : ataFolder(for: m)
        if !m.isEmpty {
            return !maintMessageDirectories(nose: nose, ataFolder: wantedATA ?? "").isEmpty
        }
        return training.contains { item in
            let route = routeByTrainingID[item.id]
            return matchesManual(item, route: route, wanted: wantedManual, cmmNumber: wantedCMM) &&
                matchesAircraft(item, route: route, expected: expected) &&
                matchesNose(item, route: route, wanted: wantedNose) &&
                routeMatchesATA(route, wanted: wantedATA) &&
                (wantedCMM.isEmpty || normalized(item.cmmNumber) == wantedCMM || normalized(item.cmmNumber).isEmpty)
        }
    }

    func hasMatchOutsideManual(eicas: String, fim: String, maint: String, manual: String, nose: String, cmmNumber: String = "") -> Bool {
        let e = normalized(eicas)
        let f = normalized(fim)
        let m = normalized(maint)
        let selectedManual: String
        if !e.isEmpty { selectedManual = "EICAS" }
        else if !f.isEmpty { selectedManual = "FIM" }
        else if !m.isEmpty { selectedManual = "MAINT" }
        else { selectedManual = normalizedManual(manual) }
        let selectedNose = normalized(nose)
        let selectedCMM = normalized(cmmNumber)
        return training.contains { item in
            let route = routeByTrainingID[item.id]
            guard matchesNose(item, route: route, wanted: selectedNose),
                  (selectedCMM.isEmpty || normalized(item.cmmNumber) == selectedCMM || normalized(item.cmmNumber).isEmpty),
                  normalizedManual(route?.manual ?? item.manualType) != selectedManual else { return false }
            if !e.isEmpty { return normalized(item.eicasMessage).contains(e) }
            if !f.isEmpty { return normalized(item.faultCode) == f }
            if !m.isEmpty { return normalized(item.matMessage) == m || normalized(item.description) == m }
            return false
        }
    }

    /// Compatibility overload for non-search callers.
    func search(eicas: String, fim: String, maint: String, manual: String) -> [MVDTrainingPayload] {
        search(eicas: eicas, fim: fim, maint: maint, manual: manual, nose: "")
    }

    private func normalized(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Keeps every manual pill on its own Android-compatible training scope.
    /// CMM is the only manual whose records carry a CMM number; all other
    /// manuals must reject those records even when an old JSON omitted its
    /// manual metadata. Folder-derived metadata is applied during import.
    private func matchesManual(_ item: MVDTrainingPayload, route: MVDTrainingRoute?, wanted: String, cmmNumber: String) -> Bool {
        let itemManual = normalizedManual(route?.manual ?? inferredManual(for: item))
        guard wanted.isEmpty || itemManual == wanted else { return false }
        let itemCMM = normalized(route?.cmmNumber ?? inferredCMMNumber(for: item))
        if wanted == "CMM" {
            return !cmmNumber.isEmpty && itemCMM == cmmNumber
        }
        return itemCMM.isEmpty
    }

    private func cmmTrainingIsConsistent(_ item: MVDTrainingPayload, route: MVDTrainingRoute) -> Bool {
        guard normalizedManual(route.manual) == "CMM", !route.cmmNumber.isEmpty else { return true }
        let expected = normalized(route.cmmNumber)
        let values = [item.partName, item.description, item.pinpointLink,
                      item.trainingProcedureLink, item.checkLink]
        for value in values {
            let upper = value.uppercased()
            let ns = NSRange(upper.startIndex..<upper.endIndex, in: upper)
            guard let regex = try? NSRegularExpression(pattern: #"CMM\s*\d{2}\s*[-']?\s*\d{2}\s*[-']?\s*\d{2}"#) else { continue }
            for match in regex.matches(in: upper, range: ns) {
                guard let range = Range(match.range, in: upper) else { continue }
                let found = normalized(String(upper[range]).replacingOccurrences(of: "CMM", with: ""))
                if found != expected { return false }
            }
        }
        return true
    }

    private func aircraftForNose(_ nose: String) -> MVDFleetAircraft? {
        let catalog = MVDLocalFleetCatalog.load()
        return catalog.first { normalized($0.nose) == normalized(nose) }
            ?? MVDLocalFleetCatalog.all.first { normalized($0.nose) == normalized(nose) }
    }

    private func matchesNose(_ item: MVDTrainingPayload, route: MVDTrainingRoute?, wanted: String) -> Bool {
        guard !wanted.isEmpty else { return true }
        // The Android hierarchy is model-scoped for AMM/AIPC/WDM/etc.; the
        // folder is TrainingData/AA/Boeing/B777-200/AMM and therefore has no
        // nose component. In that case FleetData has already resolved the
        // requested nose to the model, so a stale JSON nose must not exclude
        // a valid record from the model folder.
        if let route, !route.nose.isEmpty { return normalized(route.nose) == wanted }
        if route != nil { return true }
        let stored = normalized(item.aircraftNose)
        return stored == wanted || stored.isEmpty || stored == "NA"
    }

    private func matchesAircraft(_ item: MVDTrainingPayload, route: MVDTrainingRoute?, expected: MVDFleetAircraft?) -> Bool {
        guard let expected else { return true }
        let itemModel = normalized(route?.model ?? item.model)
        let itemManufacturer = normalized(route?.manufacturer ?? item.manufacturer)
        let itemCustomer = normalized(route?.customer ?? item.customerCode)
        let identityMatches = (itemManufacturer.isEmpty || itemManufacturer == normalized(expected.manufacturer)) &&
            (itemCustomer.isEmpty || itemCustomer == normalized(expected.customer)) &&
            (itemModel.isEmpty || itemModel == "NA" || itemModel == normalized(expected.model))
        // CMM is physically stored beside the model folders, so its folder
        // cannot carry B777-200 in the path. The selected cabin/CMM number
        // still scopes those records; do not reject them merely for that
        // intentionally absent path component.
        return identityMatches
    }

    /// Some Android exports retain a stale manualType in JSON while the
    /// imageFiles still contain the authoritative TrainingData route.
    private func inferredManual(for item: MVDTrainingPayload) -> String {
        let names = ["AMM", "AIPC", "WDM", "FIM", "CMM", "MEL", "CDL", "NEF", "TAC", "SRM", "IFE", "AMSAFE", "EO", "SB", "EOSB", "EICAS", "FAULTCODES", "MAINTMESSAGE", "AARD-200", "AARD-300"]
        for raw in item.imageFiles {
            let components = raw.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
            if let manual = components.reversed().map({ $0.uppercased().replacingOccurrences(of: "_", with: "-") })
                .first(where: { names.contains($0) }) {
                return normalizedManual(manual)
            }
        }
        return normalizedManual(item.manualType)
    }

    private func inferredCMMNumber(for item: MVDTrainingPayload) -> String {
        if !normalized(item.cmmNumber).isEmpty { return normalized(item.cmmNumber) }
        for raw in item.imageFiles {
            let compact = raw.uppercased().replacingOccurrences(of: "_", with: "-")
            if let match = compact.range(of: #"CMM\d{2}-\d{2}-\d{2}"#, options: .regularExpression) {
                return String(compact[match].dropFirst(3))
            }
        }
        return ""
    }

    private func normalizedManual(_ value: String) -> String {
        let compact = value.uppercased().filter { $0.isLetter || $0.isNumber }
        switch compact {
        case "MAINTMESSAGE", "MAINTMSG", "MAINTENANCE": return "MAINT"
        case "FAULTCODES", "FAULTCODE": return "FIM"
        case "EICAS": return "EICAS"
        case "EO", "SB", "EOSB": return "EOSB"
        case "AADR200", "AARD200": return "AARD200"
        case "AADR300", "AARD300": return "AARD300"
        default: return compact
        }
    }

    private func ataFolder(for normalizedMaintCode: String) -> String? {
        guard normalizedMaintCode.count >= 2 else { return nil }
        let prefix = String(normalizedMaintCode.prefix(2))
        guard prefix.allSatisfy({ $0.isNumber }) else { return nil }
        return "ATA\(prefix)"
    }

    private func routeMatchesATA(_ route: MVDTrainingRoute?, wanted: String?) -> Bool {
        guard let wanted, !wanted.isEmpty else { return true }
        return route?.ataFolder.caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Migrates learning sidecars from the old Application Support roots
    /// into Documents/TrainingData. The migration is idempotent and preserves
    /// both vote counts and positive embedding exemplars.
    private func migrateLegacyLearningFilesIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: learningMigrationMarkerURL.path) else { return }
        try? fileManager.createDirectory(at: canonicalTrainingRoot, withIntermediateDirectories: true)

        for root in privateTrainingRoots() {
            let rootPath = root.standardizedFileURL.path
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }

            for case let sourceURL as URL in enumerator {
                let fileName = sourceURL.lastPathComponent.lowercased()
                guard fileName == "_feedback.json" || fileName == "_positive_embeddings.jsonl" else { continue }
                let sourcePath = sourceURL.standardizedFileURL.path
                guard sourcePath.hasPrefix(rootPath + "/") else { continue }
                let relative = String(sourcePath.dropFirst(rootPath.count + 1))
                let destinationURL = canonicalTrainingRoot.appendingPathComponent(relative)
                if destinationURL.standardizedFileURL.path == sourcePath { continue }
                try? fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if fileName == "_feedback.json" {
                    var merged: [String: Int] = [:]
                    if let existing = try? Data(contentsOf: destinationURL),
                       let values = try? JSONDecoder().decode([String: Int].self, from: existing) {
                        merged = values
                    }
                    if let source = try? Data(contentsOf: sourceURL),
                       let values = try? JSONDecoder().decode([String: Int].self, from: source) {
                        for (key, value) in values {
                            merged[key] = max(merged[key] ?? 0, value)
                        }
                    }
                    if let data = try? JSONEncoder().encode(merged) {
                        try? data.write(to: destinationURL, options: .atomic)
                    }
                } else {
                    var lines = Set<String>()
                    if let existing = try? String(contentsOf: destinationURL, encoding: .utf8) {
                        lines.formUnion(existing.split(whereSeparator: \.isNewline).map(String.init))
                    }
                    if let source = try? String(contentsOf: sourceURL, encoding: .utf8) {
                        lines.formUnion(source.split(whereSeparator: \.isNewline).map(String.init))
                    }
                    let merged = lines.sorted().joined(separator: "\n")
                    try? Data((merged + (merged.isEmpty ? "" : "\n")).utf8)
                        .write(to: destinationURL, options: .atomic)
                }
            }
        }

        try? fileManager.createDirectory(
            at: learningMigrationMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("v1\n".utf8).write(to: learningMigrationMarkerURL, options: .atomic)
    }

    private struct AndroidFeedbackSnapshot {
        let votes: Int
        let exemplars: [[Float]]
    }

    /// Reads the Android-compatible sidecars from the stable Documents root
    /// and also from the legacy root for backward compatibility.
    private func loadAndroidFeedback(for route: MVDTrainingRoute?) -> AndroidFeedbackSnapshot {
        guard let route, !route.sourceFileName.isEmpty else {
            return AndroidFeedbackSnapshot(votes: 0, exemplars: [])
        }

        var counts: [String: Int] = [:]
        var exemplarLines = Set<String>()
        var exemplars: [[Float]] = []

        for folder in feedbackFolders(for: route) {
            let feedbackURL = folder.appendingPathComponent("_feedback.json")
            if let data = try? Data(contentsOf: feedbackURL),
               let values = try? JSONDecoder().decode([String: Int].self, from: data) {
                for (key, value) in values {
                    counts[key] = max(counts[key] ?? 0, value)
                }
            }

            let exemplarURL = folder.appendingPathComponent("_positive_embeddings.jsonl")
            guard let text = try? String(contentsOf: exemplarURL, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let rawLine = String(line)
                guard exemplarLines.insert(rawLine).inserted,
                      let data = rawLine.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (object["fileName"] as? String) == route.sourceFileName,
                      let values = object["embedding"] as? [NSNumber] else { continue }
                exemplars.append(values.map(\.floatValue))
            }
        }

        return AndroidFeedbackSnapshot(
            votes: counts[route.sourceFileName] ?? 0,
            exemplars: exemplars
        )
    }

    func registerSearchFeedback(for payload: MVDTrainingPayload, positive: Bool) {
        searchFeedback[payload.id] = positive
        if positive {
            persistAndroidPositiveFeedback(for: payload, embedding: lastImageQueryEmbedding)
        } else {
            // Android 👎 is intentionally session-only. It changes the next
            // result without poisoning future users or the shared index.
            sessionNegativeTrainingIDs.insert(payload.id)
        }
    }

    func resetSearchSessionFeedback() {
        sessionNegativeTrainingIDs.removeAll()
        searchFeedback.removeAll()
        lastImageQueryEmbedding.removeAll()
    }

    private func persistAndroidPositiveFeedback(for payload: MVDTrainingPayload, embedding: [Float]) {
        guard let route = routeByTrainingID[payload.id], !route.sourceFileName.isEmpty else { return }
        let canonicalFolder = canonicalTrainingFolder(for: route)
        try? FileManager.default.createDirectory(at: canonicalFolder, withIntermediateDirectories: true)

        var counts: [String: Int] = [:]
        for folder in feedbackFolders(for: route) {
            let feedbackURL = folder.appendingPathComponent("_feedback.json")
            guard let data = try? Data(contentsOf: feedbackURL),
                  let values = try? JSONDecoder().decode([String: Int].self, from: data) else { continue }
            for (key, value) in values {
                counts[key] = max(counts[key] ?? 0, value)
            }
        }
        counts[route.sourceFileName, default: 0] += 1
        let feedbackURL = canonicalFolder.appendingPathComponent("_feedback.json")
        if let data = try? JSONEncoder().encode(counts) {
            try? data.write(to: feedbackURL, options: .atomic)
        }

        guard !embedding.isEmpty else { return }
        let record: [String: Any] = ["fileName": route.sourceFileName, "embedding": embedding]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let logURL = canonicalFolder.appendingPathComponent("_positive_embeddings.jsonl")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data([10]))
            try? handle.close()
        } else {
            try? (data + Data([10])).write(to: logURL, options: .atomic)
        }
    }

    private func feedbackFolders(for route: MVDTrainingRoute) -> [URL] {
        let canonical = canonicalTrainingFolder(for: route)
        let legacy = legacyTrainingFolder(for: route)
        if canonical.standardizedFileURL.path == legacy.standardizedFileURL.path {
            return [canonical]
        }
        return [canonical, legacy]
    }

    private func canonicalTrainingFolder(for route: MVDTrainingRoute) -> URL {
        var result = canonicalTrainingRoot
            .appendingPathComponent(route.customer)
            .appendingPathComponent(route.manufacturer)
            .appendingPathComponent(route.model)
        if normalizedManual(route.manual) == "CMM" {
            return canonicalTrainingRoot
                .appendingPathComponent(route.customer)
                .appendingPathComponent(route.manufacturer)
                .appendingPathComponent("CMM")
                .appendingPathComponent("cmm\(route.cmmNumber)")
        }
        return result.appendingPathComponent(route.manual)
    }

    private func legacyTrainingFolder(for route: MVDTrainingRoute) -> URL {
        let root = privateTrainingRoots().first ?? canonicalTrainingRoot
        var result = root
            .appendingPathComponent(route.customer)
            .appendingPathComponent(route.manufacturer)
            .appendingPathComponent(route.model)
        if normalizedManual(route.manual) == "CMM" {
            return root
                .appendingPathComponent(route.customer)
                .appendingPathComponent(route.manufacturer)
                .appendingPathComponent("CMM")
                .appendingPathComponent("cmm\(route.cmmNumber)")
        }
        return result.appendingPathComponent(route.manual)
    }

    private func relevance(of item: MVDTrainingPayload, eicas: String, fim: String, maint: String) -> Int {
        let fields = [item.eicasMessage.lowercased(), item.faultCode.lowercased(), item.matMessage.lowercased()]
        let queries = [eicas, fim, maint].filter { !$0.isEmpty }
        guard !queries.isEmpty else { return 1 }
        let lexicalScore = queries.reduce(0) { total, query in
            total + (fields.contains { $0.contains(query) } ? 1 : 0)
        }
        let itemVector = MVDLocalEmbedding.vector(for: fields.joined(separator: " "))
        let queryVector = MVDLocalEmbedding.vector(for: queries.joined(separator: " "))
        let localSimilarity = Int(MVDLocalEmbedding.cosine(itemVector, queryVector) * 10)
        return lexicalScore * 10 + localSimilarity
    }

    func toggleAudit(id: String) {
        guard let index = audit.firstIndex(where: { $0.id == id }) else { return }
        audit[index].isDone.toggle()
    }

    func saveTraining(_ payload: MVDTrainingPayload) {
        training.removeAll { $0.id == payload.id }
        training.append(payload)
        routeByTrainingID[payload.id] = routeForLocalPayload(payload)
        pendingTrainingIDs.remove(payload.id)

        let folder = MVDTrainingPaths.pendingAircraftFolder(
            model: payload.model,
            customer: payload.customerCode.isEmpty ? "AA" : payload.customerCode,
            manufacturer: payload.manufacturer
        ).appendingPathComponent(payload.manualType, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            let name = "training-\(payload.id.replacingOccurrences(of: "/", with: "-"))"
            try? data.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        }

        var queue = loadLocalTrainingChanges()
        queue.upserts.removeAll { $0.id == payload.id }
        queue.upserts.append(payload)
        queue.deletedRecordIDs.removeAll { $0 == payload.id }
        if !payload.ucid.isEmpty { queue.deletedUCIDs.removeAll { $0 == payload.ucid } }
        saveLocalTrainingChanges(queue)
        hasPreparedPrivateTraining = true
        isPreparing = false
        persistCurrentTrainingState()
    }

    /// Removes one manual/document record locally and leaves a tombstone so a
    /// later library scan cannot resurrect it before server synchronization.
    func deleteTraining(recordId: String) {
        guard !recordId.isEmpty else { return }
        training.removeAll { $0.id == recordId }
        routeByTrainingID.removeValue(forKey: recordId)
        pendingTrainingIDs.remove(recordId)
        removePendingTrainingFiles(matching: [recordId])
        var queue = loadLocalTrainingChanges()
        queue.upserts.removeAll { $0.id == recordId }
        if !queue.deletedRecordIDs.contains(recordId) { queue.deletedRecordIDs.append(recordId) }
        saveLocalTrainingChanges(queue)
        hasPreparedPrivateTraining = true
        persistCurrentTrainingState()
    }

    /// Removes every manual/photo record belonging to the selected index. The
    /// UCID tombstone also hides the published copy until the server consumes
    /// the queued deletion.
    func deleteTrainingIndex(ucid: String, recordId: String? = nil) {
        let ids = training.filter { record in
            (!ucid.isEmpty && record.ucid == ucid) || (recordId != nil && record.id == recordId!)
        }.map(\.id)
        training.removeAll { ids.contains($0.id) }
        for id in ids {
            routeByTrainingID.removeValue(forKey: id)
            pendingTrainingIDs.remove(id)
        }
        removePendingTrainingFiles(matching: ids)
        var queue = loadLocalTrainingChanges()
        queue.upserts.removeAll { ids.contains($0.id) }
        for id in ids where !queue.deletedRecordIDs.contains(id) { queue.deletedRecordIDs.append(id) }
        if !ucid.isEmpty && !queue.deletedUCIDs.contains(ucid) { queue.deletedUCIDs.append(ucid) }
        saveLocalTrainingChanges(queue)
        hasPreparedPrivateTraining = true
        persistCurrentTrainingState()
    }

    /// Deletes only the semantic Audit group, not every record that happens
    /// to reuse the same source UCID.
    func deleteTrainingGroup(groupKey: String, recordId: String) {
        let ids = training.filter { mvdAuditGroupKey($0) == groupKey }.map(\.id)
        if ids.isEmpty { deleteTraining(recordId: recordId); return }
        training.removeAll { ids.contains($0.id) }
        for id in ids {
            routeByTrainingID.removeValue(forKey: id)
            pendingTrainingIDs.remove(id)
        }
        removePendingTrainingFiles(matching: ids)
        var queue = loadLocalTrainingChanges()
        queue.upserts.removeAll { ids.contains($0.id) }
        for id in ids where !queue.deletedRecordIDs.contains(id) { queue.deletedRecordIDs.append(id) }
        saveLocalTrainingChanges(queue)
        hasPreparedPrivateTraining = true
        persistCurrentTrainingState()
    }

    private func removePendingTrainingFiles(matching ids: [String]) {
        guard !ids.isEmpty else { return }
        let fileManager = FileManager.default
        for root in privateTrainingRoots() where root.lastPathComponent.caseInsensitiveCompare("New Trainings") == .orderedSame {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
                let base = url.deletingPathExtension().lastPathComponent
                if ids.contains(where: { base.contains($0.replacingOccurrences(of: "/", with: "-")) }) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Downloads the published library for the selected fleet and installs it
    /// in Documents/TrainingData, which is also visible through Apple Devices.
    /// The archive is normalized into the requested route so legacy ZIPs cannot
    /// put a shared CMM inside an aircraft model folder.
    func downloadTrainingLibrary(customer: String, manufacturer: String, model: String,
                                 rebuildIndex: Bool = true,
                                 completion: @escaping (String) -> Void) {
        guard !isPreparing else { completion("TRAINING INDEX BUSY"); return }
        let encodedCustomer = customer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? customer
        let encodedManufacturer = manufacturer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? manufacturer
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "http://100.109.229.98:5050/fleet-download/\(encodedCustomer)/\(encodedManufacturer)/\(encodedModel)") else {
            completion("INVALID DOWNLOAD URL")
            return
        }
        let alternateURL = URL(string: "http://100.109.229.98:5050/fleet-download/\(encodedCustomer)/\(encodedManufacturer)/\(encodedModel).zip")
        completion("DOWNLOADING \(model) TRAINING…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var downloadedURL: URL?
            var statusCode = 0
            // Some running server instances still expose the legacy .zip
            // route while the current route omits the suffix. Try both and
            // retry transient ZIP-generation failures before reporting the
            // error to the user.
            for attempt in 0..<3 where downloadedURL == nil {
                for candidate in [url, alternateURL].compactMap({ $0 }) {
                    let semaphore = DispatchSemaphore(value: 0)
                    URLSession.shared.downloadTask(with: candidate) { location, response, _ in
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        statusCode = code
                        if let location, (200..<300).contains(code) { downloadedURL = location }
                        semaphore.signal()
                    }.resume()
                    semaphore.wait()
                    if downloadedURL != nil { break }
                }
                if downloadedURL == nil && attempt < 2 {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
            guard let downloadedURL, (200..<300).contains(statusCode) else {
                DispatchQueue.main.async { completion("TRAINING DOWNLOAD FAILED (\(statusCode))") }
                return
            }
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TrainingData", isDirectory: true)
            do {
                try MVDTrainingArchiveInstaller.install(
                    zipURL: downloadedURL,
                    into: destination,
                    customer: customer,
                    manufacturer: manufacturer,
                    model: model
                )
                DispatchQueue.main.async {
                    self.hasPreparedPrivateTraining = false
                    // Batch downloads defer indexing until every selected
                    // archive is installed. Indexing after the first ZIP
                    // makes the next download see TRAINING INDEX BUSY.
                    if rebuildIndex {
                        self.loadPrivateTrainingIndex()
                    }
                    completion("TRAINING LIBRARY INSTALLED")
                }
            } catch {
                DispatchQueue.main.async { completion("TRAINING INSTALL FAILED: \(error.localizedDescription)") }
            }
        }
    }

    /// Installs several manifest entries sequentially. Separate archives are
    /// intentional: the server keeps shared CMM outside model folders, while
    /// the installer merges every archive into the same Documents/TrainingData
    /// tree without overwriting unrelated fleets.
    func downloadTrainingLibraries(customer: String, selections: [MVDLibraryOption],
                                   completion: @escaping (String) -> Void) {
        var unique: [String: MVDLibraryOption] = [:]
        selections.forEach { unique[$0.key] = $0 }
        // Keep the shared manufacturer CMM coupled to every aircraft
        // selection. The UI already marks this row as required, but enforcing
        // it here also protects other callers from downloading a model alone.
        let manufacturers = Set(selections.compactMap { option -> String? in
            guard let parts = option.parts, !option.isSharedCMM else { return nil }
            return parts.manufacturer
        })
        for manufacturer in manufacturers {
            // The shared CMM is stored at the manufacturer level, not under a
            // model folder. Keep the real manufacturer in the route; using
            // the old placeholder "(manufacturer)" produced a guaranteed
            // 404 when the iPad requested the CMM archive.
            let cmmKey = "\(manufacturer)/CMM"
            if unique[cmmKey] == nil {
                unique[cmmKey] = MVDLibraryOption(
                    key: cmmKey,
                    version: nil,
                    lastUpdated: nil,
                    sizeMB: 0
                )
            }
        }
        let ordered = unique.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        guard !ordered.isEmpty else {
            completion("NO LIBRARIES SELECTED")
            return
        }

        func downloadNext(_ index: Int) {
            guard index < ordered.count else {
                // Build one complete index after the fleet and shared CMM
                // archives have all been installed.
                self.loadPrivateTrainingIndex()
                completion("TRAINING LIBRARIES INSTALLED")
                return
            }
            let option = ordered[index]
            guard let parts = option.parts else {
                completion("INVALID LIBRARY ROUTE: \(option.key)")
                return
            }
            // Be defensive with selections persisted by an older build that
            // may still contain the placeholder key.
            let manufacturer = parts.manufacturer == "(manufacturer)"
                ? (manufacturers.sorted().first ?? parts.manufacturer)
                : parts.manufacturer
            completion("DOWNLOADING \(option.key) (\(index + 1)/\(ordered.count))…")
            downloadTrainingLibrary(customer: customer, manufacturer: manufacturer, model: parts.model,
                                    rebuildIndex: false) { status in
                guard status == "TRAINING LIBRARY INSTALLED" else {
                    completion(status)
                    return
                }
                downloadNext(index + 1)
            }
        }

        downloadNext(0)
    }

    func syncPendingTrainings(completion: @escaping (String) -> Void) {
        let root = MVDTrainingPaths.newTrainingsRoot
        let customers = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?.filter { $0.hasDirectoryPath } ?? []
        let files = customers.flatMap { customer in
            (FileManager.default.enumerator(at: customer, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { !$0.hasDirectoryPath }.map { (customer.lastPathComponent, $0) }
        }
        guard !files.isEmpty else { completion("NO PENDING TRAININGS"); return }
        DispatchQueue.global(qos: .utility).async {
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("training-pending-(UUID().uuidString).zip")
            guard let archive = Archive(url: zipURL, accessMode: .create) else { DispatchQueue.main.async { completion("ZIP ERROR") }; return }
            for (customer, file) in files {
                let relative = file.path.replacingOccurrences(of: customer, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
                    .replacingOccurrences(of: "\\", with: "/")
                try? archive.addEntry(with: "\(customer)/\(relative)", relativeTo: root, compressionMethod: .deflate)
            }
            guard let data = try? Data(contentsOf: zipURL) else { DispatchQueue.main.async { completion("ZIP ERROR") }; return }
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"training.zip\"\r\nContent-Type: application/zip\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let iosDeviceID = UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
            var request = URLRequest(url: URL(string: "http://100.109.229.98:5050/fleet-upload/global/\(iosDeviceID)")!)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if let token = UserDefaults.standard.string(forKey: "fleet_upload_token") { request.setValue(token, forHTTPHeaderField: "X-SmartLook-Upload-Token") }
            request.httpBody = body
            URLSession.shared.dataTask(with: request) { responseData, response, _ in
                defer { try? FileManager.default.removeItem(at: zipURL) }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = responseData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let acknowledged = code >= 200 && code < 300 && json?["processed"] as? Bool == true && json?["published"] as? Bool == true
                if acknowledged { customers.forEach { try? FileManager.default.removeItem(at: $0) } }
                DispatchQueue.main.async { completion(acknowledged ? "TRAININGS SENT AND PUBLISHED" : "SYNC FAILED (\(code))") }
            }.resume()
        }
    }
}

private enum MVDTrainingArchiveInstaller {
    /// Installs one server library into its canonical route. ZIP entries are
    /// accepted in customer-first, model-first, or legacy nested layouts,
    /// but the resulting tree is always:
    /// TrainingData/<customer>/<manufacturer>/<model> and
    /// TrainingData/<customer>/<manufacturer>/CMM.
    static func install(zipURL: URL, into destinationRoot: URL,
                        customer: String, manufacturer: String, model: String) throws {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw InstallerError.invalidArchive
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let normalizedCustomer = normalizedComponent(customer)
        let normalizedManufacturer = normalizedComponent(manufacturer)
        let normalizedModel = normalizedComponent(model)
        let isCMM = normalizedModel.caseInsensitiveCompare("CMM") == .orderedSame
        let modelRoot = destinationRoot
            .appendingPathComponent(normalizedCustomer, isDirectory: true)
            .appendingPathComponent(normalizedManufacturer, isDirectory: true)
            .appendingPathComponent(normalizedModel, isDirectory: true)
        let sharedCMMRoot = destinationRoot
            .appendingPathComponent(normalizedCustomer, isDirectory: true)
            .appendingPathComponent(normalizedManufacturer, isDirectory: true)
            .appendingPathComponent("CMM", isDirectory: true)
        let rootPath = destinationRoot.standardizedFileURL.path
        for entry in archive where entry.type == .file {
            guard let components = safeComponents(entry.path) else { continue }
            let cmmIndex = components.firstIndex { $0.caseInsensitiveCompare("CMM") == .orderedSame }
            let relativeComponents: [String]
            let targetRoot: URL

            if let cmmIndex {
                // A CMM found anywhere in the archive belongs to the shared
                // manufacturer library, even when an old ZIP put it under a
                // model folder (for example B777-300/CMM/...).
                targetRoot = sharedCMMRoot
                relativeComponents = Array(components.dropFirst(cmmIndex + 1))
            } else {
                targetRoot = modelRoot
                let modelIndex = components.firstIndex { $0.caseInsensitiveCompare(normalizedModel) == .orderedSame }
                if let modelIndex {
                    relativeComponents = Array(components.dropFirst(modelIndex + 1))
                } else {
                    // Bare model archives contain entries such as
                    // "ATA32/file.json". Remove only known route prefixes.
                    let prefixes = Set([normalizedCustomer, normalizedManufacturer, "TrainingData"].map { $0.lowercased() })
                    relativeComponents = components.filter {
                        !prefixes.contains(normalizedComponent($0).lowercased())
                    }
                }
            }

            guard !relativeComponents.isEmpty else { continue }
            let relative = relativeComponents.joined(separator: "/")
            let output = targetRoot.appendingPathComponent(relative)
            let outputPath = output.standardizedFileURL.path
            guard outputPath == rootPath || outputPath.hasPrefix(rootPath + "/") else { continue }
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: output)
        }
    }

    private static func safeComponents(_ rawPath: String) -> [String]? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return components
    }

    private static func normalizedComponent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    private enum InstallerError: LocalizedError {
        case invalidArchive
        var errorDescription: String? { "The training archive is invalid." }
    }
}

/// Imports archives copied by Apple Devices into the app's Documents folder.
/// The archive is kept entirely on-device; no training data is sent to GitHub.
private enum MVDPrivateArchiveImporter {
    static func importPendingCMMArchives() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for archiveURL in files where archiveURL.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
            guard archiveURL.lastPathComponent.lowercased().contains("cmm") else { continue }
            importArchive(archiveURL, documents: documents)
        }
    }

    private static func importArchive(_ archiveURL: URL, documents: URL) {
        guard let archive = Archive(url: archiveURL, accessMode: .read) else { return }
        let regularEntries = archive.filter { $0.type == .file }
        guard let firstPath = regularEntries.first?.path else { return }
        let firstComponents = firstPath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map(String.init)
        guard let cmmIndex = firstComponents.firstIndex(where: {
            $0.caseInsensitiveCompare("CMM") == .orderedSame
        }) else { return }
        let manufacturers = Set(["BOEING", "AIRBUS", "EMBRAER", "BOMBARDIER", "DEHAVILLAND"])
        let manufacturerIndex = firstComponents.firstIndex {
            manufacturers.contains($0.uppercased().replacingOccurrences(of: "-", with: ""))
        }
        let manufacturer = manufacturerIndex.map { firstComponents[$0] } ?? "Boeing"
        let customer = manufacturerIndex.flatMap { index in
            index > 0 ? firstComponents[index - 1] : nil
        } ?? "AA"
        let trainingRoot = documents.appendingPathComponent("TrainingData", isDirectory: true)
        let destinationRoot = trainingRoot
            .appendingPathComponent(customer, isDirectory: true)
            .appendingPathComponent(manufacturer, isDirectory: true)
            .appendingPathComponent("CMM", isDirectory: true)
        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for entry in regularEntries {
            let components = entry.path.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  let entryCMMIndex = components.firstIndex(where: {
                      $0.caseInsensitiveCompare("CMM") == .orderedSame
                  }) else { continue }
            let relativeComponents = Array(components.dropFirst(entryCMMIndex + 1))
            guard !relativeComponents.isEmpty else { continue }
            let relative = relativeComponents.joined(separator: "/")
            let output = destinationRoot.appendingPathComponent(relative)
            let resolvedDestination = output.standardizedFileURL.path
            guard resolvedDestination.hasPrefix(destinationRoot.standardizedFileURL.path) else { continue }
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try? archive.extract(entry, to: output)
        }
    }
}

/// Local compatibility adapter for the Android TrainingPayload JSON shape.
/// Every property is optional so older Android records remain readable when a
/// field was introduced in a later version.
private struct MVDAndroidTrainingRecord: Decodable {
    let ucid: String?
    let recordId: String?
    let customerCode: String?
    let employeeId: String?
    let cmmLocation: String?
    let seat: String?
    let aircraftNose: String?
    let model: String?
    let partName: String?
    let ataChapter: String?
    let subAta: String?
    let unit: String?
    let item: String?
    let faultCode: String?
    let matMessage: String?
    let maintMessage: String?
    let maintenanceMessage: String?
    let maintMsg: String?
    let messageCode: String?
    let eicasMessage: String?
    let eicasLevel: String?
    let pinpointLink: String?
    let trainingProcedureLink: String?
    let pageNumber: String?
    let isRii: Bool?
    let isEwis: Bool?
    let ewisLink: String?
    let isLmp: Bool?
    let isEtops: Bool?
    let isAadr: Bool?
    let isGpm: Bool?
    let isEo: Bool?
    let isAard200: Bool?
    let aard200Link: String?
    let isAard300: Bool?
    let aard300Link: String?
    let isRvsm: Bool?
    let rvsmLink: String?
    let gpmLink: String?
    let checkLink: String?
    let riiLink: String?
    let lmpLink: String?
    let etopsLink: String?
    let eoLink: String?
    let aadrLink: String?
    let boeing_doc_link: String?
    let rii_link: String?
    let lmp_link: String?
    let etops_link: String?
    let eo_link: String?
    let aadr_link: String?
    let is_aard_200: Bool?
    let aard_200_link: String?
    let is_aard_300: Bool?
    let aard_300_link: String?
    let is_rvsm: Bool?
    let rvsm_link: String?
    let gpm_link: String?
    let description: String?
    let imageFiles: [String]?
    let imageEmbeddings: [[Float]]?
    let labeledName: String?
    let level: String?
    let reference: String?
    let ata: String?
    let task: String?
    let fimTask: String?
    let boeingDocLink: String?

    func asPayload(manualType: String, route: MVDTrainingRoute? = nil) -> MVDTrainingPayload {
        var result = MVDTrainingPayload()
        result.ucid = ucid ?? recordId ?? ""
        result.recordId = recordId ?? ucid ?? UUID().uuidString
        result.aircraftNose = aircraftNose ?? route?.nose ?? "N/A"
        result.model = model ?? route?.model ?? "N/A"
        result.manufacturer = route?.manufacturer ?? "Boeing"
        result.customerCode = customerCode ?? route?.customer ?? "AA"
        result.trainerID = employeeId ?? ""
        result.cmmLocation = cmmLocation ?? seat ?? ""
        result.manualType = manualType.isEmpty ? (route?.manual ?? "AMM") : manualType.uppercased()
        result.cmmNumber = route?.cmmNumber ?? ""
        result.ataChapter = ataChapter ?? "N/A"
        result.subAta = subAta ?? ""
        result.labeledName = labeledName ?? ""
        result.partName = partName ?? labeledName ?? ""
        result.faultCode = faultCode ?? ""
        result.matMessage = matMessage ?? maintMessage ?? maintenanceMessage ?? maintMsg ?? messageCode ?? ""
        result.eicasMessage = eicasMessage ?? ""
        result.eicasLevel = eicasLevel ?? level ?? ""
        result.pinpointLink = pinpointLink ?? boeingDocLink ?? boeing_doc_link ?? ""
        result.trainingProcedureLink = trainingProcedureLink ?? ""
        result.pageNumber = pageNumber ?? ""
        result.isRii = isRii ?? false
        result.isEwis = isEwis ?? false
        result.ewisLink = ewisLink ?? ""
        result.isLmp = isLmp ?? false
        result.isEtops = isEtops ?? false
        result.isAadr = isAadr ?? false
        result.isGpm = isGpm ?? false
        result.isEo = isEo ?? false
        result.isAard200 = isAard200 ?? is_aard_200 ?? false
        result.aard200Link = aard200Link ?? aard_200_link ?? ""
        result.isAard300 = isAard300 ?? is_aard_300 ?? false
        result.aard300Link = aard300Link ?? aard_300_link ?? ""
        result.isRvsm = isRvsm ?? is_rvsm ?? false
        result.rvsmLink = rvsmLink ?? rvsm_link ?? ""
        result.gpmLink = gpmLink ?? gpm_link ?? ""
        result.checkLink = checkLink ?? ""
        result.riiLink = riiLink ?? rii_link ?? ""
        result.lmpLink = lmpLink ?? lmp_link ?? ""
        result.etopsLink = etopsLink ?? etops_link ?? ""
        result.eoLink = eoLink ?? eo_link ?? ""
        result.aadrLink = aadrLink ?? aadr_link ?? ""
        result.description = description ?? reference ?? task ?? fimTask ?? ""
        if result.ataChapter == "N/A", let ata { result.ataChapter = ata }
        if result.faultCode.isEmpty, let reference, reference.range(of: #"\d{2}\s+\d{3}\s+\d{2}"#, options: .regularExpression) != nil { result.faultCode = reference }
        result.imageFiles = imageFiles ?? []
        result.imageEmbeddings = imageEmbeddings ?? []
        return result
    }
}

private struct MVDTrainingRoute: Codable {
    let customer: String
    let manufacturer: String
    let model: String
    let nose: String
    let manual: String
    let cmmNumber: String
    let ataFolder: String
    let sourceFileName: String
}

/// Small offline vector fingerprint used until a Core ML embedding model is added.
/// It is deterministic, has no network dependency, and is safe for sanitized MVD data.
private enum MVDLocalEmbedding {
    static let dimensions = 32

    static func vector(for text: String) -> [Double] {
        return fallbackVector(for: text)
    }

    private static func fallbackVector(for text: String) -> [Double] {
        var result = Array(repeating: 0.0, count: dimensions)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            var hash = 5381
            for scalar in token.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(scalar.value) }
            let index = abs(hash) % dimensions
            result[index] += 1.0
        }
        return result
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let dot = zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
        let left = sqrt(lhs.reduce(0) { $0 + ($1 * $1) })
        let right = sqrt(rhs.reduce(0) { $0 + ($1 * $1) })
        guard left > 0, right > 0 else { return 0 }
        return dot / (left * right)
    }
}
