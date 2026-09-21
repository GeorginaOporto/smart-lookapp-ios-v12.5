import Foundation

struct MVDEditTrainingContext: Codable, Hashable {
    var editMode: Bool = false
    var originalClient: String = ""
    var originalUCID: String = ""
    var originalRecordId: String = ""
    var manufacturer: String = ""
    var model: String = ""
}

/// Local fleet manifest. The shipped values are sanitized demo entries; a private
/// manifest can be imported later into Application Support without GitHub access.
struct MVDPrivateFleetManifest: Codable {
    var aircraft: [MVDFleetAircraft]
}

struct MVDFleetAircraft: Codable, Identifiable, Hashable {
    var id: String { "\(customer)-\(nose)" }
    let nose: String
    let model: String
    let customer: String
    let manufacturer: String
    let folderPath: String
    let trainingPath: String
    let riiLink: String
    let lmp: String
    let lmpLink: String
    let etopsLink: String
    let eoLink: String

    init(nose: String, model: String, customer: String, manufacturer: String = "Boeing",
         folderPath: String = "", trainingPath: String = "", riiLink: String = "",
         lmp: String = "LMP-DEFAULT", lmpLink: String = "", etopsLink: String = "", eoLink: String = "") {
        self.nose = nose; self.model = model; self.customer = customer; self.manufacturer = manufacturer
        self.folderPath = folderPath; self.trainingPath = trainingPath; self.riiLink = riiLink
        self.lmp = lmp; self.lmpLink = lmpLink; self.etopsLink = etopsLink; self.eoLink = eoLink
    }

    enum CodingKeys: String, CodingKey {
        case nose, model, customer, customerCode, manufacturer, folderPath, trainingPath
        case riiLink, lmp, lmpLink, etopsLink, eoLink
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let primaryCustomer = try values.decodeIfPresent(String.self, forKey: .customer)
        let legacyCustomer = try values.decodeIfPresent(String.self, forKey: .customerCode)
        let decodedNose = try values.decode(String.self, forKey: .nose)
        let decodedModel = try values.decode(String.self, forKey: .model)
        let decodedManufacturer = try values.decodeIfPresent(String.self, forKey: .manufacturer) ?? "Boeing"
        let decodedFolder = try values.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        let decodedTraining = try values.decodeIfPresent(String.self, forKey: .trainingPath) ?? ""
        let decodedRii = try values.decodeIfPresent(String.self, forKey: .riiLink) ?? ""
        let decodedLmp = try values.decodeIfPresent(String.self, forKey: .lmp) ?? "LMP-DEFAULT"
        let decodedLmpLink = try values.decodeIfPresent(String.self, forKey: .lmpLink) ?? ""
        let decodedEtops = try values.decodeIfPresent(String.self, forKey: .etopsLink) ?? ""
        let decodedEo = try values.decodeIfPresent(String.self, forKey: .eoLink) ?? ""
        self.init(
            nose: decodedNose,
            model: decodedModel,
            customer: primaryCustomer ?? legacyCustomer ?? "DEMO",
            manufacturer: decodedManufacturer,
            folderPath: decodedFolder,
            trainingPath: decodedTraining,
            riiLink: decodedRii,
            lmp: decodedLmp,
            lmpLink: decodedLmpLink,
            etopsLink: decodedEtops,
            eoLink: decodedEo
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nose, forKey: .nose)
        try values.encode(model, forKey: .model)
        try values.encode(customer, forKey: .customer)
        try values.encode(manufacturer, forKey: .manufacturer)
        try values.encode(folderPath, forKey: .folderPath)
        try values.encode(trainingPath, forKey: .trainingPath)
        try values.encode(riiLink, forKey: .riiLink)
        try values.encode(lmp, forKey: .lmp)
        try values.encode(lmpLink, forKey: .lmpLink)
        try values.encode(etopsLink, forKey: .etopsLink)
        try values.encode(eoLink, forKey: .eoLink)
    }
}

enum MVDLocalFleetCatalog {
    // The server's authoritative hierarchy is customer-first. On iPad this
    // is relative to Documents/TrainingData.
    private static let root = "TrainingData"

    private static let b777200AA = "7AA 7AB 7AC 7AD 7AE 7AF 7AG 7AH 7AJ 7AK 7AL 7AM 7AN 7AP 7AR 7AS 7AT 7AU 7AV 7AW 7AX 7AY 7BA 7BB 7BC 7BD 7BE 7BF 7BG 7BH 7BJ 7BK 7BL 7BM 7BN 7BP 7BR 7BS 7BT 7BU 7BV 7BW 7BX 7BY 7CA 7CB 7CC".split(separator: " ").map(String.init)
    private static let b777300AA = "7LA 7LB 7LC 7LD 7LE 7LF 7LG 7LH 7LJ 7LK 7LL 7LM 7LN 7LP 7LR 7LS 7LT 7LU 7LV 7LW".split(separator: " ").map(String.init)
    private static let b7878AA = "8AA 8AB 8AC 8AD 8AE 8AF 8AG 8AH 8AJ 8AK 8AL 8AM 8AN 8AP 8AR 8AS 8AT 8AU 8AV 8AW 8AX 8AY 8BA 8BB 8BC 8BD 8BE 8BF 8BG 8BH 8BJ 8BK 8BL 8BM 8BN 8BP 8BR".split(separator: " ").map(String.init)
    private static let b7879AA = "8LA 8LB 8LC 8LD 8LE 8LF 8LG 8LH 8LJ 8LK 8LL 8LM 8LN 8LP 8LR 8LS 8LT 8LU 8LV 8LW 8LX 8LY 8MA 8MB 8MC 8MD 8ME 8MF 8MG 8MH 8MJ 8MK 8ML 8MM 8MN 8MP 8MR 8MS 8MT 8MU 8MV 8MW 8MX 8MY 8NA 8NB 8NC 8ND 8NE 8NF 8NG 8NH".split(separator: " ").map(String.init)

    private static func aircraft(_ noses: [String], model: String, customer: String, manufacturer: String = "Boeing", training: String) -> [MVDFleetAircraft] {
        noses.map { MVDFleetAircraft(nose: $0, model: model, customer: customer, manufacturer: manufacturer,
                                     folderPath: "\(root)/\(customer)/\(manufacturer)/\(training)",
                                     trainingPath: "\(root)/\(customer)/\(manufacturer)/\(training)") }
    }

    private static func b737823() -> [String] {
        let first = Array("ABCDEFGHJKLMNP")
        let second = Array("ABCDEFGHJKLMNPRSTUVWXY")
        return first.flatMap { a in
            let allowed = a == "P" ? second.filter { $0 <= "X" } : second
            return allowed.map { "3\(a)\($0)" }
        }
    }

    private static func b737Max8() -> [String] {
        let pattern: [String] = Array("ABCDEFGHJKLMNPRSTUVWXY").map(String.init)
        var result: [String] = []
        let rSuffixes = pattern.filter { $0 >= "H" }.map { "3R\($0)" }
        result.append("3RRA")
        result.append(contentsOf: rSuffixes)
        for prefix: String in ["S", "T", "U"] {
            result.append(contentsOf: pattern.map { "3\(prefix)\($0)" })
        }
        result.append(contentsOf: ["A", "B", "C", "D", "E"].map { "3V\($0)" })
        return result
    }

    private static func makeAll() -> [MVDFleetAircraft] {
        var result: [MVDFleetAircraft] = []
        result += aircraft(b777200AA, model: "B777-200", customer: "AA", training: "B777-200")
        result += aircraft(b777300AA, model: "B777-300", customer: "AA", training: "B777-300")
        result += aircraft(b7878AA, model: "B787-8", customer: "AA", training: "B787-8")
        result += aircraft(b7879AA, model: "B787-9", customer: "AA", training: "B787-9")
        result += aircraft(b737823(), model: "B737-823", customer: "AA", training: "B737-800")
        result += aircraft(b737Max8(), model: "B737-MAX8", customer: "AA", training: "B737-MAX8")
        result += aircraft(Array(1...32).map { String(format: "%03d", $0) }, model: "A319-115", customer: "AA", manufacturer: "Airbus", training: "A319")
        result += aircraft(["300","301","302","303","304","305","306","313"], model: "A321-253NY", customer: "AA", manufacturer: "Airbus", training: "A321NY")
        result += aircraft(Array(400...474).map(String.init), model: "A321-253NX", customer: "AA", manufacturer: "Airbus", training: "A321NX")
        result += aircraft(Array(950...959).map(String.init), model: "A321-253N", customer: "AA", manufacturer: "Airbus", training: "A321N")
        var a321: [String] = []
        a321 += (784...799).map(String.init)
        a321 += (850...910).map(String.init)
        a321 += (928...934).map(String.init)
        a321 += (986...998).map(String.init)
        result += aircraft(a321, model: "A321-231", customer: "AA", manufacturer: "Airbus", training: "A321")
        result += aircraft(Array(279...293).map(String.init), model: "A330-243", customer: "AA", manufacturer: "Airbus", training: "A330")
        return result
    }

    static let all: [MVDFleetAircraft] = makeAll()

    static let demo = all

    static func load() -> [MVDFleetAircraft] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateFleet", isDirectory: true)
            .appendingPathComponent("fleet-manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(MVDPrivateFleetManifest.self, from: data),
              !manifest.aircraft.isEmpty else { return demo }
        let aaAircraft = manifest.aircraft.filter { $0.customer.uppercased() == "AA" }
        guard !aaAircraft.isEmpty else { return demo }
        return aaAircraft.sorted { $0.nose.localizedStandardCompare($1.nose) == .orderedAscending }
    }
}

struct MVDPrivateSeatManifest: Codable {
    var nose: String
    var seats: [String]
}

enum MVDLocalSeatCatalog {
    static func seats(for nose: String) -> [String] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateFleet", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
           let url = files.first(where: { $0.lastPathComponent == "seat-\(nose.uppercased()).json" }),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(MVDPrivateSeatManifest.self, from: data) {
            return manifest.seats.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        // Android v12.2 cabin configuration is the authoritative fallback
        // when a private seat manifest has not yet been imported.
        let aircraft = MVDLocalFleetCatalog.all.first { $0.nose.caseInsensitiveCompare(nose) == .orderedSame }
        return MVDLocationData.configuration(manufacturer: aircraft?.manufacturer ?? "Boeing", model: aircraft?.model ?? "B777-200", nose: nose)?.seats
            .flatMap { entry -> [String] in
                guard entry.fromRow <= entry.toRow else { return [] }
                return (entry.fromRow...entry.toRow).flatMap { row in
                    entry.positions.sorted().map { "\(row)\($0)" }
                }
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? []
    }
}

/// Mirrors the Android TrainingPayload without embedding operational data.
struct MVDTrainingPayload: Codable, Identifiable {
    var id: String { recordId.isEmpty ? "\(aircraftNose)-\(ataChapter)-\(partName)" : recordId }
    var recordId: String = ""
    var aircraftNose: String = "N/A"
    var model: String = "N/A"
    var manufacturer: String = "Boeing"
    var customerCode: String = ""
    var manualType: String = "AMM"
    /// Shared CMM document selected from the cabin/seat configuration.
    var cmmNumber: String = ""
    var ataChapter: String = "N/A"
    var subAta: String = ""
    var unit: String = ""
    var item: String = ""
    var partName: String = ""
    var faultCode: String = ""
    var matMessage: String = ""
    var eicasMessage: String = ""
    var eicasLevel: String = ""
    var pinpointLink: String = ""
    var trainingProcedureLink: String = ""
    var pageNumber: String = ""
    var isRii: Bool = false
    var riiLink: String = ""
    var isEwis: Bool = false
    var ewisLink: String = ""
    var isLmp: Bool = false
    var lmpLink: String = ""
    var isEtops: Bool = false
    var isGpm: Bool = false
    var etopsLink: String = ""
    var isEo: Bool = false
    var checkLink: String = ""
    var eoLink: String = ""
    var isAadr: Bool = false
    var aadrLink: String = ""; var isAard200: Bool? = false; var aard200Link: String? = ""; var isAard300: Bool? = false; var aard300Link: String? = ""; var isRvsm: Bool? = false; var rvsmLink: String? = ""; var gpmLink: String? = ""
    var description: String = ""
    var imageFiles: [String] = []
    var imageEmbeddings: [[Float]] = []

    /// First real web document link, matching Android's extractDocumentUrl().
    var documentURL: URL? {
        [pinpointLink, trainingProcedureLink, checkLink, riiLink, lmpLink, etopsLink, eoLink, aadrLink]
            .compactMap { raw in
                guard let match = raw.range(of: #"https?://[^\s)\]]+"#, options: .regularExpression) else { return nil }
                return URL(string: String(raw[match]).replacingOccurrences(of: "\\&", with: "&"))
            }.first
    }

    var relatedDocumentURL: URL? {
        guard let match = description.range(of: #"https?://[^\s)\]]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(description[match]).replacingOccurrences(of: "\\&", with: "&"))
    }
}

/// Contexto local del resultado que abrió el usuario. Se conserva separado del
/// HTML para que Mate pueda leer el documento y volver a vincularlo con la
/// tarjeta original y, más adelante, con la verificación de stock.
struct MVDDocumentContext: Codable, Hashable {
    let recordId: String
    let customerCode: String
    let aircraftNose: String
    let model: String
    let manualType: String
    let ata: String
    let item: String
    let pageNumber: String
    let partName: String
    let searchTerm: String
    let documentURL: String
}

/// Page snapshot kept only in memory while Mate reads the open document.
/// It is deliberately not Codable so raw document text cannot be persisted by
/// the survey cache.
struct MVDMatePageSnapshot {
    let index: Int
    let pageNumber: String
    let url: String
    let title: String
    let text: String
}

/// A local cross-reference between the item selected in the drawing and the
/// later parts table. Part numbers are intentionally absent from this model.
struct MVDMateItemObservation: Identifiable, Hashable {
    let id: String
    let item: String
    let drawingPage: String
    let tablePage: String
    let documentURL: String
}

struct MVDTrainingLink: Codable, Identifiable {
    let id = UUID()
    var manualType: String
    var ata: String
    var subAta: String
    var url: String
}

struct MVDAuditItem: Codable, Identifiable {
    let id: String
    var ucid: String
    var title: String
    var isDone: Bool
    var boeingLink: String
    var manualRef: String
    var imageFiles: [String]
    var originClient: String
}

enum MVDAuthRole: String, Codable {
    case admin = "ADMIN"
    case moc = "MOC"
    case manager = "MANAGER"
    case trainer = "TRAINER"
    case mechanic = "MECH"
}

struct MVDAuthResult {
    let role: MVDAuthRole
    let firstName: String
}

/// Demo-only authentication mirror. Production credentials must stay local/private.
enum MVDLocalAuth {
    static func authenticate(employeeID: String, password: String) -> MVDAuthResult? {
        let id = employeeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (id, pass) {
        case ("admin@smartlookapp.com", "admin123"): return MVDAuthResult(role: .admin, firstName: "Admin")
        case ("224170", "moc1"): return MVDAuthResult(role: .moc, firstName: "Dave")
        case ("224160", "manager1"): return MVDAuthResult(role: .manager, firstName: "Adrian")
        case ("trainer1", "trainer1"): return MVDAuthResult(role: .trainer, firstName: "Gaston")
        case ("trainer2", "trainer2"): return MVDAuthResult(role: .trainer, firstName: "Jon")
        case ("224150", "user1"): return MVDAuthResult(role: .mechanic, firstName: "Gaston")
        case ("224140", "user2"): return MVDAuthResult(role: .mechanic, firstName: "Mechanic")
        default: return nil
        }
    }
}

enum MVDAircraftConfigurationType: String, Codable {
    case group1 = "GROUP_1"
    case group2 = "GROUP_2"
    case preOlympus = "PRE_OLYMPUS"
    case postOlympus = "POST_OLYMPUS"
    case unknown = "UNKNOWN"
}

struct MVDAircraftCabinConfiguration: Codable, Identifiable {
    let id = UUID()
    let aircraftModel: String
    let customerCode: String
    let configurationType: MVDAircraftConfigurationType
    let configurationName: String
    let noseIDs: Set<String>
    let firstClassSeats: Int
    let businessClassSeats: Int
    let flightAttendantStations: Int
    let flightDeckStations: Int
}

/// Configuration authority: aircraft identity comes from the fleet, then the
/// Android v12.2 cabin seat map resolves the CMM number.
enum MVDAircraftConfiguration {
    static let demo7AD = MVDAircraftCabinConfiguration(
        aircraftModel: "B777-200",
        customerCode: "DEMO",
        configurationType: .unknown,
        configurationName: "Local MVD configuration pending verified import",
        noseIDs: ["7AD"],
        firstClassSeats: 0,
        businessClassSeats: 10,
        flightAttendantStations: 8,
        flightDeckStations: 2
    )

    static func findByNose(_ nose: String) -> MVDAircraftCabinConfiguration? {
        demo7AD.noseIDs.contains(nose.uppercased()) ? demo7AD : nil
    }
}

enum MVDCMMComponentType: String, Codable {
    case firstClassSuite = "FIRST_CLASS_SUITE"
    case businessClassSuite = "BUSINESS_CLASS_SUITE"
    case businessClassShell = "BUSINESS_CLASS_SHELL"
    case seatRestraint = "SEAT_RESTRAINT"
    case seatBelt = "SEAT_BELT"
    case flightAttendantSeat = "FLIGHT_ATTENDANT_SEAT"
}

struct MVDCMMDocument: Codable, Identifiable {
    let id = UUID()
    let cmmNumber: String
    var filename: String { "cmm\(cmmNumber.lowercased())" }
    var displayName: String { "CMM \(cmmNumber)" }
}

struct MVDCMMApplicabilityContext: Codable {
    let manufacturer: String
    let aircraftModel: String
    let nose: String
    let configurationType: MVDAircraftConfigurationType?
    let componentType: MVDCMMComponentType
    let location: MVDCMMLocationSelection?
}

struct MVDCMMRoutingResult: Codable {
    let document: MVDCMMDocument
    let aircraftModel: String
    let nose: String
    let trainingFolder: String
}

/// Central CMM router. It intentionally returns nil until a verified private seat/CMM map is imported.
enum MVDCMMApplicability {
    static func resolve(_ context: MVDCMMApplicabilityContext) -> MVDCMMRoutingResult? {
        guard context.manufacturer.caseInsensitiveCompare("Boeing") == .orderedSame,
              MVDAircraftConfiguration.findByNose(context.nose) != nil else { return nil }
        return nil
    }

    static func buildTrainingFolder(document: MVDCMMDocument, customerCode: String = "AA") -> String {
        "Documents/TrainingData/\(customerCode)/Boeing/CMM/\(document.filename)"
    }
}

enum MVDCMMLocationDomain: String, Codable {
    case none = "NONE"
    case seat = "SEAT"
    case galley = "GALLEY"
    case lavatory = "LAVATORY"
    case flightDeck = "FLIGHT_DECK"
    case attendantStation = "ATTENDANT_STATION"
    case stowageBin = "STOWAGE_BIN"
    case emergencyEquipment = "EMERGENCY_EQUIPMENT"
}

struct MVDCMMLocationSelection: Codable {
    let domain: MVDCMMLocationDomain
    let location: String
}

struct MVDSeatMapEntry: Codable, Identifiable {
    let id = UUID()
    let fromRow: Int
    let toRow: Int
    let positions: Set<String>
    let cabinClass: String
    let cmmNumber: String?

    func contains(seat: String) -> Bool {
        let normalized = seat.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digits = normalized.prefix { $0.isNumber }
        let column = String(normalized.drop { $0.isNumber })
        guard let row = Int(digits), !column.isEmpty else { return false }
        return row >= fromRow && row <= toRow && positions.contains(column)
    }
}

struct MVDLocationConfiguration: Codable, Identifiable {
    let id = UUID()
    let manufacturer: String
    let aircraftModel: String
    let nose: String
    let seats: [MVDSeatMapEntry]
    let attendantStations: [String]
}

/// Resolver port of Android SeatData.kt. Private manifests can override it,
/// but the known B777 maps remain available offline on the iPad.
enum MVDLocationData {
    static func configuration(manufacturer: String, model: String, nose: String) -> MVDLocationConfiguration? {
        guard manufacturer.caseInsensitiveCompare("Boeing") == .orderedSame else { return nil }
        let normalizedModel = model.replacingOccurrences(of: " ", with: "-").uppercased()
        if normalizedModel == "B777-200" {
            return MVDLocationConfiguration(
                manufacturer: "Boeing", aircraftModel: "B777-200", nose: nose,
                seats: [
                    MVDSeatMapEntry(fromRow: 1, toRow: 10, positions: Set(Array("ADHL").map(String.init)), cabinClass: "BUSINESS", cmmNumber: "25-25-71"),
                    MVDSeatMapEntry(fromRow: 13, toRow: 15, positions: Set(Array("ACDEGHJL").map(String.init)), cabinClass: "PREMIUM ECONOMY", cmmNumber: "25-20-82"),
                    MVDSeatMapEntry(fromRow: 17, toRow: 40, positions: Set(Array("ABCDEFGHJKL").map(String.init)), cabinClass: "MAIN CABIN", cmmNumber: "25-29-63")
                ], attendantStations: ["L1", "R1", "L2", "R2", "L3", "R3", "L4", "R4"]
            )
        }
        if normalizedModel == "B777-300" {
            return MVDLocationConfiguration(
                manufacturer: "Boeing", aircraftModel: "B777-300", nose: nose,
                seats: [
                    MVDSeatMapEntry(fromRow: 1, toRow: 2, positions: Set(Array("ADGJ").map(String.init)), cabinClass: "FIRST CLASS", cmmNumber: "25-25-20"),
                    MVDSeatMapEntry(fromRow: 3, toRow: 15, positions: Set(Array("ADGJ").map(String.init)), cabinClass: "BUSINESS", cmmNumber: "25-02-48"),
                    MVDSeatMapEntry(fromRow: 16, toRow: 19, positions: Set(Array("ACDEGHJL").map(String.init)), cabinClass: "PREMIUM ECONOMY", cmmNumber: "25-20-82"),
                    MVDSeatMapEntry(fromRow: 20, toRow: 44, positions: Set(Array("ACDEGHJL").map(String.init)), cabinClass: "MAIN CABIN", cmmNumber: "25-29-33")
                ], attendantStations: ["L1", "R1", "L2", "R2", "L3", "R3", "L4", "R4"]
            )
        }
        return nil
    }

    static func resolveCMM(for selection: MVDCMMLocationSelection, configuration: MVDLocationConfiguration) -> String? {
        guard selection.domain == .seat else { return nil }
        return configuration.seats.first { $0.contains(seat: selection.location) }?.cmmNumber
    }
}

