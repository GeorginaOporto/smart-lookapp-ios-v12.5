import SwiftUI
import PhotosUI
import Foundation
import UIKit
import Vision
import ImageIO
import CoreImage
import WebKit
import MessageUI

// MARK: - Sanitized MVD session

typealias MVDSampleAircraft = MVDFleetAircraft

private var sampleFleet: [MVDSampleAircraft] { MVDLocalFleetCatalog.load() }

struct MVDSession: Codable {
    var employeeID = "224170"
    var station = "CLT"
    var role = "MOC"
    var nose = "7LA"
    var accessToken = ""
    var aircraft: MVDSampleAircraft? { sampleFleet.first { $0.nose == nose } }
}

private enum MVDSessionStore {
    private static let key = "mvd_session_v1"
    static func load() -> MVDSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MVDSession.self, from: data)
    }
    static func save(_ session: MVDSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct MVDSearchSnapshot: Codable {
    var eicas: String; var fim: String; var maint: String; var manual: String
    var selectedSeat: String; var selectedCMM: String; var resultShown: Bool
    var results: [MVDTrainingPayload]; var resultIndex: Int; var searchStatus: String
    var imageStatus: String; var sourceImageFile: String?; var extractedImageFile: String?
}

private enum MVDSearchStateStore {
    private static let folderName = "SmartLookApp/LastSearch"
    private static var folderURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName, isDirectory: true) }
    static func load() -> (MVDSearchSnapshot, UIImage?, UIImage?)? {
        let stateURL = folderURL.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL), let snapshot = try? JSONDecoder().decode(MVDSearchSnapshot.self, from: data) else { return nil }
        let source = snapshot.sourceImageFile.flatMap { UIImage(contentsOfFile: folderURL.appendingPathComponent($0).path) }
        let extracted = snapshot.extractedImageFile.flatMap { UIImage(contentsOfFile: folderURL.appendingPathComponent($0).path) }
        return (snapshot, source, extracted)
    }
    static func save(_ snapshot: MVDSearchSnapshot, sourceImage: UIImage?, extractedImage: UIImage?) {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var value = snapshot; value.sourceImageFile = sourceImage == nil ? nil : "context.jpg"; value.extractedImageFile = extractedImage == nil ? nil : "extracted.jpg"
        if let sourceImage, let data = sourceImage.jpegData(compressionQuality: 0.9) { try? data.write(to: folderURL.appendingPathComponent("context.jpg"), options: .atomic) } else { try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("context.jpg")) }
        if let extractedImage, let data = extractedImage.jpegData(compressionQuality: 0.9) { try? data.write(to: folderURL.appendingPathComponent("extracted.jpg"), options: .atomic) } else { try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("extracted.jpg")) }
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: folderURL.appendingPathComponent("state.json"), options: .atomic) }
    }
    static func clear() { try? FileManager.default.removeItem(at: folderURL) }
}

private struct MVDLogo: View {
    private var logoImage: UIImage? {
        UIImage(named: "SmartLookAppLogo")
    }

    var body: some View {
        Group {
            if let logoImage {
                Image(uiImage: logoImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "airplane.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18)))
    }
}
struct ContentView: View {
    @State private var session: MVDSession?
    init() { _session = State(initialValue: MVDSessionStore.load()) }
    var body: some View {
        Group {
            if let session {
                MainShell(session: session) {
                    MVDSessionStore.clear()
                    MVDSearchStateStore.clear()
                    self.session = nil
                }
            }
            else { LoginView { newSession in MVDSessionStore.save(newSession); session = newSession } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Login

struct LoginView: View {
    let onLogin: (MVDSession) -> Void
    @State private var employeeID = ""
    @State private var station = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isSigningIn = false

    private let stations = ["CLT", "DFW", "EZE", "GIG", "GRU", "JFK", "LHR", "MIA", "PHI", "SCL"]

    private var loginRole: String {
        switch employeeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "admin", "admin@smartlookapp.com": return "ADMIN"
        case "224150", "224140": return "MECHANIC"
        case "224170": return "MOC"
        case "224160": return "MANAGER"
        case "trainer1", "trainer2": return "TRAINER"
        default: return "MOC"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MVDLogo()
                    .frame(width: 170, height: 170)
                    .padding(.top, 18)

                Text("Smart Lookapp")
                    .font(.system(size: 30, weight: .heavy))
                Text("AI-POWERED FLEET MAINTENANCE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 14) {
                    Label("ACCESS CONTROL", systemImage: "person.badge.key.fill")
                        .font(.headline.weight(.bold))

                    TextField("Employee ID", text: $employeeID)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)

                    Picker("Station", selection: $station) {
                        Text("Select station").tag("")
                        ForEach(stations, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    if let error {
                        Text(error)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                    }

                    Button(isSigningIn ? "SIGNING IN…" : "LOGIN") {
                        guard !employeeID.isEmpty, !station.isEmpty, !password.isEmpty else {
                            error = "Complete Employee ID, Station and Password."
                            return
                        }
                        isSigningIn = true
                        error = nil
                        Task {
                            do {
                                let token = try await PortalAuth.login(user: employeeID, role: loginRole, password: password)
                                await MainActor.run {
                                    isSigningIn = false
                                    onLogin(MVDSession(employeeID: employeeID.trimmingCharacters(in: .whitespacesAndNewlines), station: station, role: loginRole, accessToken: token))
                                }
                            } catch {
                                await MainActor.run {
                                    isSigningIn = false
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(isSigningIn)
                }
                .padding(20)
                .background(Color(red: 0.09, green: 0.11, blue: 0.15), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
            }
            .padding(22)
        }
        .background(MVDTheme.background.ignoresSafeArea())
    }
}

private enum PortalAuth {
    private static let endpoint = URL(string: "https://aeronexares.tail027590.ts.net/api/auth/login")!

    static func login(user: String, role: String, password: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user": user, "role": role, "password": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PortalAuthError.invalidCredentials
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["accessToken"] as? String, !token.isEmpty else { throw PortalAuthError.invalidResponse }
        return token
    }

    private enum PortalAuthError: LocalizedError {
        case invalidCredentials, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidCredentials: return "Invalid credentials or unavailable portal."
            case .invalidResponse: return "The portal returned an invalid session."
            }
        }
    }
}

// MARK: - Header and navigation shell

struct MainShell: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var session: MVDSession
    @StateObject private var store = MVDLocalStore()
    @State private var selectedTab = 0
    @State private var showFleet = false
    let onSignOff: () -> Void

    init(session: MVDSession, onSignOff: @escaping () -> Void) {
        _session = State(initialValue: session)
        self.onSignOff = onSignOff
        let role = session.role.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        _selectedTab = State(initialValue: ["MECH", "MECHANIC", "MOC"].contains(role) ? 1 : 0)
    }

    private var isMechanic: Bool {
        ["MECH", "MECHANIC"].contains(
            session.role.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(session: session, onFleet: { showFleet = true }, onSignOff: onSignOff)
                TabView(selection: $selectedTab) {
                    if !isMechanic {
                        DashboardView(session: session, store: store, selectedTab: $selectedTab)
                            .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }
                            .tag(0)
                    }
                    SearchView(session: session, store: store)
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(1)
                    if !isMechanic {
                        TrainingView(session: session, store: store)
                            .tabItem { Label("Training", systemImage: "brain.head.profile") }
                            .tag(2)
                        AuditView(session: session, store: store)
                            .tabItem { Label("Audit", systemImage: "checklist") }
                            .tag(3)
                    }
                }
            }
            .background(MVDTheme.background.ignoresSafeArea())
            .sheet(isPresented: $showFleet) {
                FleetSelector(session: session) { chosen in
                    session.nose = chosen.nose
                    MVDSessionStore.save(session)
                    showFleet = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .inactive || phase == .background else { return }
            MVDSessionStore.save(session)
        }
        .task {
            // Keep the login transition responsive. Private resources are loaded
            // immediately after the shell is visible, without blocking login.
            await Task.yield()
            store.preparePrivateTraining()
        }
    }
}

struct AppHeader: View {
    let session: MVDSession
    let onFleet: () -> Void
    let onSignOff: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MVDLogo()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("SMART LOOKAPP").font(.system(size: 14, weight: .black))
                    Text(session.role).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4))
                }
                Text("AERONEXARES MAINTENANCE SYSTEMS")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(session.employeeID, systemImage: "person.circle").font(.system(size: 10, weight: .bold))
                    Label(session.station, systemImage: "location.fill").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.secondary)
                Text("\(session.aircraft?.model ?? "N/A") • \(session.aircraft?.customer ?? "DEMO")")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onFleet) {
                VStack(spacing: 2) {
                    Text(session.nose).font(.system(size: 21, weight: .black)).foregroundStyle(.blue)
                    Text("FLEET ▾").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.5)))
            }
            Button(action: onSignOff) {
                Label("SIGN OFF", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 9, weight: .black))
                    .frame(width: 82, height: 34)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .accessibilityLabel("SIGN OFF")
            .accessibilityHint("Closes the current session and returns to login")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(MVDTheme.background)
    }
}

struct FleetSelector: View {
    let session: MVDSession
    let onSelect: (MVDSampleAircraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var filtered: [MVDSampleAircraft] { sampleFleet.filter { query.isEmpty || $0.nose.localizedCaseInsensitiveContains(query) || $0.model.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        NavigationStack {
            List(filtered) { aircraft in
                Button { onSelect(aircraft) } label: {
                    HStack {
                        Text(aircraft.nose).font(.headline).foregroundStyle(.blue)
                        VStack(alignment: .leading) { Text(aircraft.model); Text(aircraft.customer).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if aircraft.nose == session.nose { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search Nose (UA, DL, AF, LH, AA)...")
            .navigationTitle("AIRCRAFT SELECTOR")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    let session: MVDSession
    @ObservedObject var store: MVDLocalStore
    @Binding var selectedTab: Int
    @State private var syncStatus = ""
    @State private var downloadStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI ENGINE STATUS").sectionTitle()
                HStack {
                    Label("LOCAL / READY", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    Spacer()
                    Text("Sanitized MVD").font(.caption).foregroundStyle(.secondary)
                }
                .card()

                Text("CORE OPERATIONS").sectionTitle()
                ActionButton(title: "AI Training", icon: "brain.head.profile", color: .blue) { selectedTab = 2 }
                ActionButton(title: "Visual Intelligence Search", icon: "camera.viewfinder", color: .blue) { selectedTab = 1 }
                ActionButton(title: "Audit Checklist", icon: "checklist", color: .purple) { selectedTab = 3 }

                Text("MANAGEMENT & ANALYTICS").sectionTitle()
                ActionButton(title: "MOC Control Panel", icon: "antenna.radiowaves.left.and.right", color: .orange) { }
                ActionButton(title: "System Performance", icon: "chart.bar.xaxis", color: .orange) { }

                Text("SYSTEM UTILITIES").sectionTitle()
                Button {
                    guard let aircraft = session.aircraft else {
                        downloadStatus = "NO FLEET SELECTED"
                        return
                    }
                    store.downloadTrainingLibrary(
                        customer: aircraft.customer,
                        manufacturer: aircraft.manufacturer,
                        model: aircraft.model
                    ) { downloadStatus = $0 }
                } label: {
                    Label("DOWNLOAD TRAINING UPDATE", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if !downloadStatus.isEmpty { Text(downloadStatus).font(.caption).foregroundStyle(.green) }
                if session.role.uppercased() == "TRAINER" {
                    Button {
                        store.syncPendingTrainings { syncStatus = $0 }
                    } label: {
                        Label("SYNC NOW — ALL PENDING TRAININGS", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if !syncStatus.isEmpty { Text(syncStatus).font(.caption).foregroundStyle(.green) }
                }
                HStack { Label("Fleet", systemImage: "airplane"); Spacer(); Text(session.aircraft?.model ?? "Unknown").foregroundStyle(.secondary) }
                    .card()
            }
            .padding(16)
        }
        .background(MVDTheme.background.ignoresSafeArea())
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent).tint(color).controlSize(.large)
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: MVDSession
    @ObservedObject var store: MVDLocalStore
    @State private var eicas = ""
    @State private var fim = ""
    @State private var maint = ""
    @State private var manual = "AMM"
    @State private var selectedSeat = ""
    @State private var selectedCMM = ""
    @State private var resultShown = false
    @State private var results: [MVDTrainingPayload] = []
    @State private var resultIndex = 0
    @State private var searchStatus = ""
    @State private var isSearching = false
    @State private var searchGeneration = 0
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var sourceImage: UIImage?
    @State private var extractedImage: UIImage?
    @State private var showCamera = false
    @State private var showAppLibrary = false
    @State private var showExtractor = false
    @State private var showTrainingRequest = false
    @State private var showLibraryDownload = false
    @State private var libraryDownloadStatus = ""
    @State private var imageStatus = "No image selected"
    @State private var didRestoreLastSearch = false

    private var trainingRequestBody: String {
        "REQUEST DOCUMENT NOT FOUND\n\nUSER ID: \(session.employeeID)\nSTATION: \(session.station)\nAIRCRAFT NOSE: \(session.nose)\nLOCATION: AIRCRAFT NOSE / \(session.nose)\nMANUAL: \(manual)\nEICAS/FIM/MAINT: \(eicas) / \(fim) / \(maint)\nSTATUS: \(searchStatus)"
    }

    private var trainingAttachments: [MailAttachment] {
        var files: [MailAttachment] = []
        if let sourceImage, let data = sourceImage.jpegData(compressionQuality: 0.85) {
            files.append(MailAttachment(data: data, mimeType: "image/jpeg", fileName: "contextImage.jpg"))
        }
        if let extractedImage, let data = extractedImage.jpegData(compressionQuality: 0.85) {
            files.append(MailAttachment(data: data, mimeType: "image/jpeg", fileName: "extractedImage.jpg"))
        }
        return files
    }
    private var primaryManuals: [String] {
        let aard = session.aircraft?.model.contains("777-300") == true ? "AARD-300" : "AARD-200"
        return ["AMM", "AIPC", "WDM", "FIM", "SRM", aard, "EO / SB"]
    }

    private let componentManuals = ["CMM", "IFE", "AMSAFE"]
    private let groupedSafetyManuals = ["MEL", "CDL", "NEF", "TAC"]

    private var primaryManualSelection: String {
        primaryManuals.contains(manual) ? manual : primaryManuals[0]
    }

    private var safetyManualSelection: String {
        groupedSafetyManuals.contains(manual) ? manual : groupedSafetyManuals[0]
    }

    private var componentManualSelection: String {
        componentManuals.contains(manual) ? manual : componentManuals[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("AMERICAN AIRLINES").font(.title3.weight(.black))
                Text("Aircraft: \(session.nose) • \(session.aircraft?.model ?? "B777-300")").foregroundStyle(.secondary)
                if !libraryDownloadStatus.isEmpty {
                    Text(libraryDownloadStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(libraryDownloadStatus.contains("FAILED") ? .red : .green)
                }
                HStack {
                    Spacer()
                    Button("RELOAD") { store.loadPrivateTrainingIndex() }
                        .font(.caption.weight(.bold)).buttonStyle(.bordered)
                }
                if store.isPreparing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("LOADING PRIVATE TRAINING…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("IMAGE SEARCH").sectionTitle()
                Group {
                    if let sourceImage {
                        HStack(alignment: .top, spacing: 10) {
                            MVDImagePreview(title: "ORIGINAL", image: sourceImage)
                            if let extractedImage {
                                MVDImagePreview(title: "EXTRACTED PIECE", image: extractedImage)
                            } else {
                                VStack(spacing: 8) {
                                    Text("EXTRACTED PIECE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.55))
                                        .overlay(Text("USE VISION EXTRACTOR").font(.caption).foregroundStyle(.secondary))
                                }
                                .frame(maxWidth: .infinity, minHeight: 300)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.55))
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .overlay(Text("PHOTO PREVIEW\nCAMERA OR PHOTO LIBRARY").multilineTextAlignment(.center).foregroundStyle(.secondary))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.blue.opacity(0.65), lineWidth: 1))
                HStack {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("CAMERA", systemImage: "camera") }
                            .buttonStyle(.borderedProminent)
                    }
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 1, matching: .images) {
                        Label("PHOTO LIBRARY", systemImage: "photo.on.rectangle")
                    }.buttonStyle(.bordered)
                    Button { showAppLibrary = true } label: {
                        Label("APP LIBRARY", systemImage: "folder")
                    }.buttonStyle(.bordered)
                    if sourceImage != nil {
                        Button("EXTRACT (VISION)") { showExtractor = true }.buttonStyle(.borderedProminent)
                    }
                }
                Text(imageStatus).font(.caption).foregroundStyle(.green)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(primaryManuals, id: \.self) { item in
                                Button {
                                    manual = item
                                } label: {
                                    if primaryManualSelection == item {
                                        Label(item, systemImage: "checkmark")
                                    } else {
                                        Text(item)
                                    }
                                }
                            }
                        } label: {
                            Label(primaryManualSelection, systemImage: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(primaryManuals.contains(manual) ? .blue : .gray)

                        Menu {
                            ForEach(componentManuals, id: \.self) { item in
                                Button {
                                    manual = item
                                } label: {
                                    if componentManualSelection == item {
                                        Label(item, systemImage: "checkmark")
                                    } else {
                                        Text(item)
                                    }
                                }
                            }
                        } label: {
                            Label(componentManualSelection, systemImage: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(componentManuals.contains(manual) ? .blue : .gray)

                        Menu {
                            ForEach(groupedSafetyManuals, id: \.self) { item in
                                Button {
                                    manual = item
                                } label: {
                                    if safetyManualSelection == item {
                                        Label(item, systemImage: "checkmark")
                                    } else {
                                        Text(item)
                                    }
                                }
                            }
                        } label: {
                            Label(safetyManualSelection, systemImage: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(groupedSafetyManuals.contains(manual) ? .blue : .gray)
                    }
                }
                cmmSelector
                TextField("EICAS MESSAGE", text: $eicas)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: eicas) { value in eicas = value.uppercased() }
                TextField("FIM CODE (XX-XX-XX)", text: Binding(
                    get: { fim }, set: { fim = MVDSearchFormatter.fim($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                TextField("MAINT MSG (XX-XXXX)", text: Binding(
                    get: { maint }, set: { maint = MVDSearchFormatter.maint($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                HStack {
                    Spacer()
                    Button {
                        clearSearch()
                    } label: {
                        Label("CLEAR SEARCH", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                Button {
                    guard !isSearching else { return }
                    guard let aircraft = session.aircraft else {
                        searchStatus = "NO FLEET SELECTED"
                        resultShown = true
                        return
                    }
                    if !store.hasTrainingLibrary(customer: aircraft.customer, manufacturer: aircraft.manufacturer, model: aircraft.model) {
                        searchStatus = "TRAINING LIBRARY REQUIRED FOR \(aircraft.model)"
                        resultShown = true
                        showLibraryDownload = true
                        return
                    }

                    let hasTextQuery = !eicas.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !fim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !maint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let context = sourceImage
                    let extracted = extractedImage
                    let searchManual = manual
                    let searchNose = session.nose
                    let searchCMM = selectedCMM
                    let includePending = session.role.uppercased() == "TRAINER"
                    let searchEicas = eicas
                    let searchFim = fim
                    let searchMaint = maint
                    let generation = searchGeneration

                    // Run embeddings/index traversal off the main thread so the
                    // progress indicator remains visible during the search.
                    isSearching = true
                    resultShown = true
                    results = []
                    resultIndex = 0
                    searchStatus = "SEARCHING…"

                    DispatchQueue.global(qos: .userInitiated).async {
                        let found: [MVDTrainingPayload]
                        if !hasTextQuery, let context {
                            found = store.searchByImages(
                                context: context,
                                extracted: extracted,
                                manual: searchManual,
                                nose: searchNose,
                                cmmNumber: searchCMM,
                                includePending: includePending
                            )
                        } else {
                            found = store.search(
                                eicas: searchEicas,
                                fim: searchFim,
                                maint: searchMaint,
                                manual: searchManual,
                                nose: searchNose,
                                cmmNumber: searchCMM,
                                includePending: includePending
                            )
                        }
                        let outsideManual = store.hasMatchOutsideManual(
                            eicas: searchEicas,
                            fim: searchFim,
                            maint: searchMaint,
                            manual: searchManual,
                            nose: searchNose,
                            cmmNumber: searchCMM
                        )
                        let hasTraining = store.hasTrainingForSearch(
                            eicas: searchEicas,
                            fim: searchFim,
                            maint: searchMaint,
                            manual: searchManual,
                            nose: searchNose,
                            cmmNumber: searchCMM
                        )

                        DispatchQueue.main.async {
                            guard generation == searchGeneration else { return }
                            results = found
                            resultIndex = 0
                            if found.isEmpty {
                                searchStatus = outsideManual
                                    ? "NOT FOUND IN \(searchManual)"
                                    : (hasTraining ? "NO RESULTS FOUND" : "FOLDER NOT FOUND")
                            } else {
                                searchStatus = "MATCH FOUND"
                            }
                            isSearching = false
                            persistLastSearch()
                        }
                    }
                } label: {
                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("SEARCHING…")
                        }
                        .frame(width: 150)
                    } else {
                        Label("SEARCH", systemImage: "magnifyingglass")
                            .frame(width: 150)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSearching || store.isPreparing ||
                    (eicas.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                     fim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                     maint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                     sourceImage == nil) ||
                    (manual == "CMM" && selectedCMM.isEmpty))
                if isSearching {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView().progressViewStyle(.linear)
                        Label("SEARCH IN PROGRESS — WAIT FOR RESULTS", systemImage: "hourglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                    .padding(.vertical, 4)
                }
                if resultShown {
                    if isSearching {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView().progressViewStyle(.linear)
                            Text("SEARCHING… THE RESULT WILL APPEAR HERE")
                                .font(.headline)
                                .foregroundStyle(.yellow)
                        }
                        .card()
                    } else if results.indices.contains(resultIndex) {
                        SearchResult(
                            session: session,
                            payload: results[resultIndex],
                            manual: manual,
                            eicas: eicas,
                            fim: fim,
                            maint: maint,
                            store: store,
                            status: searchStatus,
                            position: resultIndex + 1,
                            total: results.count,
                            selectedSeat: selectedSeat,
                            selectedCMM: selectedCMM,
                            sourceImage: sourceImage,
                            extractedImage: extractedImage,
                            onNegativeFeedback: {
                                store.registerSearchFeedback(for: results[resultIndex], positive: false)
                                guard resultIndex + 1 < results.count else {
                                    searchStatus = "NO MORE MATCHES"
                                    return
                                }
                                resultIndex += 1
                                searchStatus = "NEXT MATCH"
                                persistLastSearch()
                            }
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(searchStatus).font(.headline).foregroundStyle(searchStatus == "FOLDER NOT FOUND" ? .red : .yellow)
                            Button { showTrainingRequest = true } label: {
                                Label("REQUEST DOCUMENT NOT FOUND", systemImage: "envelope.badge")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        .card()
                    }
                }
            }
            .padding(16)
        }
        .background(MVDTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showLibraryDownload) {
            if let aircraft = session.aircraft {
                LibraryDownloadSheet(
                    store: store,
                    customer: aircraft.customer,
                    requiredManufacturer: aircraft.manufacturer,
                    requiredModel: aircraft.model
                ) { status in
                    libraryDownloadStatus = status
                    searchStatus = status
                }
                .presentationDetents([.medium, .large])
            } else {
                Text("NO FLEET SELECTED")
                    .padding()
            }
        }
        .onChange(of: session.nose) { _ in
            if manual.hasPrefix("AARD") { manual = "AMM" }
        }
        .onChange(of: selectedPhotos) { items in
            guard let item = items.first else { return }
            // Clear the PhotosPicker selection immediately. The picker can
            // otherwise remain presented while the transferable is decoded,
            // making the gallery appear frozen for several seconds.
            selectedPhotos.removeAll()
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    let oriented = image.normalizedForVision()
                    await MainActor.run {
                         resetSearchResultsPreservingImages()
                         sourceImage = oriented
                         extractedImage = nil
                         imageStatus = "Full image loaded locally"
                         persistLastSearch()
                     }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let image {
                    resetSearchResultsPreservingImages()
                    sourceImage = image.normalizedForVision()
                    extractedImage = nil
                    imageStatus = "Camera image loaded locally"
                    persistLastSearch()
                }
                showCamera = false
            }
        }
        .sheet(isPresented: $showAppLibrary) {
            AppLibraryPicker { image, name in
                resetSearchResultsPreservingImages()
                sourceImage = image.normalizedForVision()
                extractedImage = nil
                imageStatus = "App image loaded locally: \(name)"
                persistLastSearch()
                showAppLibrary = false
            }
        }
        .sheet(isPresented: $showExtractor) {
            if let image = sourceImage {
                // Android v12.4 displays and segments the same safe bitmap,
                // capped at 1024 px. Keeping one bitmap for both operations
                // removes any full-resolution/display coordinate drift.
                VisionExtractionView(
                    image: image.normalizedForVision().downsampled(maxDimension: 1024)
                ) { cropped in
                    // A new extraction is a new query. Keep the original
                    // context image, but never reuse the previous result list
                    // or its feedback/result index.
                    resetSearchResultsPreservingImages()
                    extractedImage = cropped
                    imageStatus = "Piece extracted locally; SEARCH is ready"
                    persistLastSearch()
                    showExtractor = false
                } onCancel: { showExtractor = false }
            }
        }
        .sheet(isPresented: $showTrainingRequest) {
            MailComposeView(
                recipients: ["gaston.jimenez@aeronexares.com"],
                subject: "SMART Lookapp - Request Document Not Found",
                body: trainingRequestBody,
                attachments: trainingAttachments
            )
        }
        .onAppear { restoreLastSearchIfNeeded() }
        .onChange(of: scenePhase) { phase in
            guard phase == .inactive || phase == .background else { return }
            persistLastSearch()
        }
        .onDisappear { persistLastSearch() }
    }

    private func restoreLastSearchIfNeeded() {
        guard !didRestoreLastSearch else { return }
        didRestoreLastSearch = true
        guard let (snapshot, source, extracted) = MVDSearchStateStore.load() else { return }
        eicas = snapshot.eicas; fim = snapshot.fim; maint = snapshot.maint; manual = snapshot.manual
        selectedSeat = snapshot.selectedSeat; selectedCMM = snapshot.selectedCMM; results = snapshot.results
        resultIndex = min(max(snapshot.resultIndex, 0), max(snapshot.results.count - 1, 0))
        resultShown = snapshot.resultShown; searchStatus = snapshot.searchStatus.isEmpty ? "LAST SEARCH RESTORED" : snapshot.searchStatus
        imageStatus = snapshot.imageStatus; sourceImage = source; extractedImage = extracted
    }

    private func persistLastSearch() {
        var compactResults = results
        for index in compactResults.indices { compactResults[index].imageEmbeddings = [] }
        MVDSearchStateStore.save(MVDSearchSnapshot(eicas: eicas, fim: fim, maint: maint, manual: manual, selectedSeat: selectedSeat, selectedCMM: selectedCMM, resultShown: resultShown, results: compactResults, resultIndex: resultIndex, searchStatus: searchStatus, imageStatus: imageStatus, sourceImageFile: nil, extractedImageFile: nil), sourceImage: sourceImage, extractedImage: extractedImage)
    }

    /// Clears only the previous search state. The original context image
    /// remains available when the technician selects a new extracted piece.
    private func resetSearchResultsPreservingImages() {
        store.resetSearchSessionFeedback()
        results = []
        resultIndex = 0
        resultShown = false
        searchStatus = ""
        isSearching = false
        searchGeneration += 1
    }

    private func clearSearch() {
        resetSearchResultsPreservingImages()
        eicas = ""
        fim = ""
        maint = ""
        manual = "AMM"
        selectedSeat = ""
        selectedCMM = ""
        selectedPhotos = []
        sourceImage = nil
        extractedImage = nil
        resultShown = false
        results = []
        resultIndex = 0
        searchStatus = ""
        imageStatus = "No image selected"
        MVDSearchStateStore.clear()
    }

    @ViewBuilder
    private var cmmSelector: some View {
        if manual == "CMM" {
            let model = session.aircraft?.model ?? ""
            let seats = MVDLocalSeatCatalog.seats(for: session.nose)
            VStack(alignment: .leading, spacing: 8) {
                Text("CMM APPLICABILITY / SEAT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Picker("SEAT", selection: $selectedSeat) {
                    Text("SELECT SEAT").tag("")
                    ForEach(seats, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedSeat) { seat in
                    guard !seat.isEmpty,
                          let configuration = MVDLocationData.configuration(manufacturer: session.aircraft?.manufacturer ?? "Boeing", model: model, nose: session.nose) else {
                        selectedCMM = ""
                        return
                    }
                    selectedCMM = MVDLocationData.resolveCMM(for: MVDCMMLocationSelection(domain: .seat, location: seat), configuration: configuration) ?? ""
                }
                if selectedCMM.isEmpty {
                    Text("CMM will be resolved from the selected seat")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("ROUTE: CMM \(selectedCMM)")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct LibraryDownloadSheet: View {
    @ObservedObject var store: MVDLocalStore
    let customer: String
    let requiredManufacturer: String
    let requiredModel: String
    let onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [MVDLibraryOption] = []
    @State private var selectedKeys: Set<String> = []
    @State private var isLoading = true
    @State private var isDownloading = false
    @State private var status = "LOADING AVAILABLE LIBRARIES…"

    private var requiredKey: String { "\(requiredManufacturer)/\(requiredModel)" }
    private var sharedCMMKey: String { "\(requiredManufacturer)/CMM" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("You must download the library fleet and interior CMM for the selected NOSE")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(status).font(.caption.weight(.semibold))
                        }
                    }
                } else if options.isEmpty {
                    Section {
                        Text("NO LIBRARIES AVAILABLE FROM SERVER")
                            .foregroundStyle(.red)
                        Text("Verify that the server is running and reachable through Tailscale.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("SELECT LIBRARIES") {
                        ForEach(options) { option in
                            let installed = isInstalled(option)
                            let required = isRequired(option)
                            Button {
                                if selectedKeys.contains(option.id) {
                                    selectedKeys.remove(option.id)
                                } else {
                                    selectedKeys.insert(option.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedKeys.contains(option.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedKeys.contains(option.id) ? .blue : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.key).font(.headline)
                                        if installed {
                                            Text("INSTALLED")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.green)
                                        } else if required {
                                            Text("REQUIRED")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.orange)
                                        } else if option.sizeMB > 0 {
                                            Text(String(format: "%.1f MB", option.sizeMB))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(installed || required || isDownloading)
                        }
                    }
                }

                if !status.isEmpty && !isLoading {
                    Section {
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.contains("FAILED") ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("DOWNLOAD TRAINING")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("CANCEL") { dismiss() }
                        .disabled(isDownloading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let selected = options.filter { selectedKeys.contains($0.id) }
                    guard !selected.isEmpty else { return }
                    isDownloading = true
                    status = "STARTING DOWNLOAD…"
                    store.downloadTrainingLibraries(customer: customer, selections: selected) { update in
                        status = update
                        if update == "TRAINING LIBRARIES INSTALLED" || update.contains("FAILED") {
                            isDownloading = false
                            onFinished(update)
                            if update == "TRAINING LIBRARIES INSTALLED" { dismiss() }
                        }
                    }
                } label: {
                    Label("DOWNLOAD SELECTED (\(selectedKeys.count))", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLoading || isDownloading || selectedKeys.isEmpty)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
        .task {
            store.fetchLibraryManifest(customer: customer) { fetched in
                var byKey = Dictionary(uniqueKeysWithValues: fetched.map { ($0.key, $0) })
                byKey[requiredKey] = byKey[requiredKey] ?? MVDLibraryOption(key: requiredKey, version: nil, lastUpdated: nil, sizeMB: 0)
                byKey[sharedCMMKey] = byKey[sharedCMMKey] ?? MVDLibraryOption(key: sharedCMMKey, version: nil, lastUpdated: nil, sizeMB: 0)
                let loaded = byKey.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                options = loaded
                selectedKeys = Set(loaded.filter { !isInstalled($0) && isRequired($0) }.map(\.id))
                isLoading = false
                status = loaded.isEmpty ? "NO LIBRARIES AVAILABLE FROM SERVER" : "SELECT THE LIBRARIES TO INSTALL"
            }
        }
    }

    private func isRequired(_ option: MVDLibraryOption) -> Bool {
        option.id == requiredKey || option.id == sharedCMMKey
    }

    private func isInstalled(_ option: MVDLibraryOption) -> Bool {
        guard let parts = option.parts else { return false }
        return store.hasTrainingLibrary(customer: customer, manufacturer: parts.manufacturer, model: parts.model)
    }
}

private struct AppLibraryPicker: View {
    let onSelect: (UIImage, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        Text("No images in SmartLookApp").font(.headline)
                        Text("Copy JPG or PNG files into SmartLookApp Documents using Apple Devices.")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(files, id: \.path) { file in
                                Button {
                                    if let image = UIImage(contentsOfFile: file.path) {
                                        onSelect(image, file.lastPathComponent)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if let image = UIImage(contentsOfFile: file.path) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                                .frame(height: 105).clipped().cornerRadius(8)
                                        } else {
                                            Color.gray.frame(height: 105).cornerRadius(8)
                                        }
                                        Text(file.lastPathComponent).font(.caption2).lineLimit(2)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("SmartLookApp Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { files = appImageFiles() }
    }

    private func appImageFiles() -> [URL] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let urls = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }) ?? []
        return urls.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

private struct MVDImagePreview: View {
    let title: String
    let image: UIImage

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 430)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity)
    }
}

private enum MOCIssueSender {
    private static let hubURL = URL(string: "https://aeronexares.tail027590.ts.net")!

    static func send(accessToken: String, eventId: String, userId: String, station: String, nose: String,
                     manual: String, ata: String, fleet: String, location: String, partName: String,
                     documentLink: String, contextImage: UIImage?, extractedImage: UIImage?) async throws {
        guard !accessToken.isEmpty else { throw MOCSendError.noSession }
        let payload: [String: Any] = [
            "eventId": eventId, "event": "moc_issue", "userId": userId,
            "station": station, "nose": nose, "manual": manual, "ata": ata,
            "fleet": fleet, "location": location, "status": "PENDING_MOC_HUB",
            "contextImage": "", "extractedImage": "", "partName": partName,
            "documentLink": documentLink, "createdAtMs": Int(Date().timeIntervalSince1970 * 1000)
        ]
        var issue = URLRequest(url: hubURL.appendingPathComponent("api/moc/issues"))
        issue.httpMethod = "POST"
        issue.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        issue.setValue("application/json", forHTTPHeaderField: "Content-Type")
        issue.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: issue)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MOCSendError.issueRejected }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"eventId\"\r\n\r\n\(eventId)\r\n".utf8))
        for (name, image) in [("contextImage", contextImage), ("extractedImage", extractedImage)] {
            guard let data = image?.jpegData(compressionQuality: 0.85) else { continue }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var upload = URLRequest(url: hubURL.appendingPathComponent("api/moc/issues/upload"))
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = body
        let (_, uploadResponse) = try await URLSession.shared.data(for: upload)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, (200..<300).contains(uploadHTTP.statusCode) else { throw MOCSendError.imagesRejected }
    }

    private enum MOCSendError: LocalizedError {
        case noSession, issueRejected, imagesRejected
        var errorDescription: String? {
            switch self { case .noSession: return "No active portal session."; case .issueRejected: return "Issue rejected."; case .imagesRejected: return "Images rejected." }
        }
    }
}

private enum MVDSearchFormatter {
    /// Mirrors Android v12.2: eight alphanumeric characters, separators after positions 3 and 6.
    static func fim(_ value: String) -> String {
        format(value, maximum: 8, separatorAfter: [3, 6])
    }

    /// Mirrors Android v12.2: seven alphanumeric characters, separator after position 2.
    static func maint(_ value: String) -> String {
        format(value, maximum: 7, separatorAfter: [2])
    }

    private static func format(_ value: String, maximum: Int, separatorAfter: Set<Int>) -> String {
        let characters = value.filter { $0.isLetter || $0.isNumber }
            .uppercased().prefix(maximum)
        var result = ""
        for (index, character) in characters.enumerated() {
            if separatorAfter.contains(index) { result.append("-") }
            result.append(character)
        }
        return result
    }
}

private struct MailAttachment {
    let data: Data
    let mimeType: String
    let fileName: String
}

private struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachments: [MailAttachment]

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        attachments.forEach { controller.addAttachmentData($0.data, mimeType: $0.mimeType, fileName: $0.fileName) }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}


private func mvdActualDocumentTitle(_ url: URL, fallbackManual: String) -> String {
    let fallback = fallbackManual.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if let ata = mvdDocumentATA(from: url.absoluteString) {
        return fallback.isEmpty ? ata : "\(fallback) \(ata)"
    }
    var candidates: [String] = []
    if let fragment = url.fragment {
        let query = fragment.components(separatedBy: "?").dropFirst().joined(separator: "?")
        if let items = URLComponents(string: "https://smartlookapp.invalid/?" + query)?.queryItems {
            candidates.append(contentsOf: [
                items.first(where: { $0.name == "documentTitle" })?.value,
                url.lastPathComponent
            ].compactMap { $0 })
        }
    }
    candidates.append(url.lastPathComponent)
    for raw in candidates {
        let decoded = (raw.removingPercentEncoding ?? raw)
            .components(separatedBy: "__").last ?? raw
        let cleaned = decoded.replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeInternalID = cleaned.count > 16 && cleaned.range(of: #"^[A-Z0-9_-]+$"#, options: .regularExpression) != nil
        if !cleaned.isEmpty, cleaned.lowercased() != "document.pdf", !looksLikeInternalID {
            return fallback.isEmpty ? cleaned : "\(fallback) \(cleaned)"
        }
    }
    return fallback.isEmpty ? "DOCUMENT" : fallback
}

/// Resolves the Android-compatible local photo layouts used by both the
/// Audit reel and the Training editor.
private func mvdResolvedImageCandidates(for payload: MVDTrainingPayload, name: String) -> [URL] {
    let normalized = name.replacingOccurrences(of: "\\", with: "/")
    var candidates: [URL] = []
    if normalized.hasPrefix("/") { candidates.append(URL(fileURLWithPath: normalized)) }
    let fileName = URL(fileURLWithPath: normalized).lastPathComponent
    let bases = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    for base in bases {
        for root in [base.appendingPathComponent("New Trainings", isDirectory: true),
                     base.appendingPathComponent("TrainingData", isDirectory: true)] {
            let modelRoot = root
                .appendingPathComponent(payload.customerCode.isEmpty ? "AA" : payload.customerCode, isDirectory: true)
                .appendingPathComponent(payload.manufacturer, isDirectory: true)
                .appendingPathComponent(payload.model, isDirectory: true)
            for folder in [payload.manualType, "SECURE_RESOURCES"] {
                let folderURL = modelRoot.appendingPathComponent(folder, isDirectory: true)
                candidates.append(folderURL.appendingPathComponent(normalized))
                candidates.append(folderURL.appendingPathComponent(fileName))
            }
            if !payload.cmmNumber.isEmpty {
                let cmmRoot = modelRoot.appendingPathComponent("CMM", isDirectory: true)
                    .appendingPathComponent("cmm\(payload.cmmNumber)", isDirectory: true)
                candidates.append(cmmRoot.appendingPathComponent(normalized))
                candidates.append(cmmRoot.appendingPathComponent(fileName))
            }
        }
    }
    var unique: [URL] = []
    for url in candidates where !unique.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
        unique.append(url)
    }
    return unique
}

private func mvdResolvedImage(for payload: MVDTrainingPayload, name: String) -> UIImage? {
    mvdResolvedImageCandidates(for: payload, name: name)
        .compactMap { UIImage(contentsOfFile: $0.path) }
        .first
}

struct SearchResult: View {
    let session: MVDSession
    let payload: MVDTrainingPayload
    let manual: String
    let eicas: String
    let fim: String
    let maint: String
    @ObservedObject var store: MVDLocalStore
    let status: String
    let position: Int
    let total: Int
    let selectedSeat: String
    let selectedCMM: String
    let sourceImage: UIImage?
    let extractedImage: UIImage?
    let onNegativeFeedback: () -> Void
    @State private var feedback: Bool?
    @State private var showQualificationStatus = false
    @State private var documentTarget: MVDDocumentTarget?
    @State private var isSendingToMOC = false
    @State private var mocMessage = ""

    private func sendToMOC() {
        guard !isSendingToMOC else { return }
        isSendingToMOC = true
        mocMessage = "Sending issue to MOC Hub…"
        Task {
            do {
                try await MOCIssueSender.send(
                    accessToken: session.accessToken,
                    eventId: UUID().uuidString.lowercased(),
                    userId: session.employeeID,
                    station: session.station,
                    nose: session.nose,
                    manual: displayedManual,
                    ata: payload.ataChapter,
                    fleet: payload.model,
                    location: selectedSeat.isEmpty ? "AIRCRAFT NOSE / \(session.nose)" : "SEAT / \(selectedSeat)",
                    partName: payload.partName,
                    documentLink: payload.documentURL?.absoluteString ?? "",
                    contextImage: sourceImage,
                    extractedImage: extractedImage
                )
                await MainActor.run { isSendingToMOC = false; mocMessage = "Issue sent to MOC Hub." }
            } catch {
                await MainActor.run { isSendingToMOC = false; mocMessage = "Unable to send to MOC Hub: \(error.localizedDescription)" }
            }
        }
    }

    private var qualificationRequirements: [MVDQualificationKind] {
        var requirements: [MVDQualificationKind] = []
        if payload.isRii { requirements.append(.rii) }
        if payload.isLmp { requirements.append(.lmp) }
        if payload.isEtops { requirements.append(.etops) }
        return requirements
    }

    private var aardManualLabel: String {
        let normalizedManual = manual.uppercased().replacingOccurrences(of: "AADR", with: "AARD")
        if normalizedManual.contains("AARD-300") { return "AARD-300" }
        if normalizedManual.contains("AARD-200") { return "AARD-200" }

        let fleetAircraft = MVDLocalFleetCatalog.all.first {
            $0.nose.caseInsensitiveCompare(payload.aircraftNose) == .orderedSame
        }
        let model = (fleetAircraft?.model ?? payload.model).uppercased().replacingOccurrences(of: " ", with: "-")
        return model.contains("300") ? "AARD-300" : "AARD-200"
    }

    private var displayedManual: String {
        if payload.isAadr { return aardManualLabel }
        if !payload.matMessage.isEmpty && payload.manualType.caseInsensitiveCompare("FIM") == .orderedSame {
            return "FIM"
        }
        let value = (manual.isEmpty ? payload.manualType : manual).uppercased()
        return value.replacingOccurrences(of: "AADR", with: "AARD")
    }

    private var ataLabel: String {
        [payload.ataChapter, payload.subAta]
            .filter { !$0.isEmpty && $0 != "N/A" }
            .joined(separator: "-")
    }

    private var primaryDocumentTitle: String {
        let normalized = displayedManual.isEmpty ? "DOCUMENT" : displayedManual
        if normalized == "CMM", !payload.cmmNumber.isEmpty { return "CMM \(payload.cmmNumber)" }
        return ataLabel.isEmpty ? normalized : "\(normalized) \(ataLabel)"
    }

    private func safetyTitle(_ name: String) -> String {
        ataLabel.isEmpty ? name : "\(name) \(ataLabel)"
    }

    private var aard200Enabled: Bool {
        payload.isAard200 == true || (payload.isAadr && aardManualLabel == "AARD-200")
    }

    private var aard200RawLink: String {
        if let link = payload.aard200Link, !link.isEmpty { return link }
        return aard200Enabled ? payload.aadrLink : ""
    }

    private var aard300Enabled: Bool {
        payload.isAard300 == true || (payload.isAadr && aardManualLabel == "AARD-300")
    }

    private var aard300RawLink: String {
        if let link = payload.aard300Link, !link.isEmpty { return link }
        return aard300Enabled ? payload.aadrLink : ""
    }

    private var hasSafetyDocument: Bool {
        payload.isRii || payload.isLmp || payload.isEtops || payload.isEwis ||
        payload.isRvsm == true || payload.isAard200 == true || payload.isAard300 == true ||
        payload.isAadr || payload.isGpm
    }

    @ViewBuilder
    private func safetyDocumentButton(_ title: String, enabled: Bool, rawLink: String, tint: Color) -> some View {
        if enabled, let url = documentURL(from: rawLink) {
            openDocumentButton(mvdActualDocumentTitle(url, fallbackManual: title), url: url, tint: tint)
        }
    }

    private func documentURL(from raw: String) -> URL? {
        guard let match = raw.range(of: #"https?://[^\s)\]]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(raw[match]).replacingOccurrences(of: "\\&", with: "&"))
    }

    private func documentContext(for url: URL) -> MVDDocumentContext {
        let ata = [payload.ataChapter, payload.subAta]
            .filter { !$0.isEmpty && $0 != "N/A" }
            .joined(separator: "-")
        let searchTerm = [eicas, fim, maint].first { !$0.isEmpty } ?? payload.partName
        return MVDDocumentContext(
            recordId: payload.id,
            customerCode: payload.customerCode.isEmpty ? "AA" : payload.customerCode,
            aircraftNose: session.nose,
            model: session.aircraft?.model ?? payload.model,
            manualType: displayedManual,
            ata: ata,
            item: payload.item,
            pageNumber: payload.pageNumber,
            partName: payload.partName,
            searchTerm: searchTerm,
            documentURL: url.absoluteString
        )
    }

    private func openDocument(_ url: URL, title: String) {
        let context = documentContext(for: url)
        documentTarget = MVDDocumentTarget(
            title: title, url: url, finalURL: nil,
            context: context
        )
    }

    @ViewBuilder
    private func openDocumentButton(_ title: String, url: URL, tint: Color? = nil) -> some View {
        Button { openDocument(url, title: title) } label: {
            Label(title, systemImage: "safari")
                .frame(width: 150)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint ?? .blue)
        .accessibilityHint("Opens the document in the integrated browser")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI EXTRACTED", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(.purple)
            if !payload.partName.isEmpty { Text(payload.partName).font(.headline).foregroundStyle(.blue) }
            Text("Manual: \(displayedManual.isEmpty ? "—" : displayedManual)")
            if !eicas.isEmpty {
                Text("EICAS: \(payload.eicasMessage.isEmpty ? "—" : payload.eicasMessage)").foregroundStyle(.secondary)
            }
            if !fim.isEmpty {
                Text("FIM: \(payload.faultCode.isEmpty ? "—" : payload.faultCode)").foregroundStyle(.secondary)
            }
            if !maint.isEmpty {
                Text("FIM: \(payload.matMessage.isEmpty ? "—" : payload.matMessage)").foregroundStyle(.secondary)
            }
            if let url = payload.documentURL {
                openDocumentButton(mvdActualDocumentTitle(url, fallbackManual: displayedManual), url: url)
            } else {
                Label("\(primaryDocumentTitle) — LINK NOT AVAILABLE", systemImage: "link.slash").foregroundStyle(.secondary)
            }
            safetyDocumentButton("RII", enabled: payload.isRii, rawLink: payload.riiLink, tint: .red)
            safetyDocumentButton("LMP", enabled: payload.isLmp, rawLink: payload.lmpLink, tint: .orange)
            safetyDocumentButton("ETOPS", enabled: payload.isEtops, rawLink: payload.etopsLink, tint: .blue)
            safetyDocumentButton("RVSM", enabled: payload.isRvsm == true, rawLink: payload.rvsmLink ?? "", tint: .purple)
            safetyDocumentButton("EWIS", enabled: payload.isEwis, rawLink: payload.ewisLink, tint: .yellow)
            safetyDocumentButton("AARD-200", enabled: aard200Enabled, rawLink: aard200RawLink, tint: .orange)
            safetyDocumentButton("AARD-300", enabled: aard300Enabled, rawLink: aard300RawLink, tint: .orange)
            safetyDocumentButton("GPM", enabled: payload.isGpm, rawLink: payload.gpmLink ?? "", tint: .indigo)
            safetyDocumentButton("EO", enabled: payload.isEo, rawLink: payload.eoLink, tint: .orange)
            if !qualificationRequirements.isEmpty {
                Button {
                    showQualificationStatus = true
                } label: {
                    Label("Qualification Status", systemImage: "person.badge.shield.checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityHint("Opens the live qualification report for the selected aircraft and alert type")
            }
            HStack {
                Spacer()
                Button(action: sendToMOC) {
                    if isSendingToMOC {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .frame(width: 52, height: 46)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(isSendingToMOC ? "Sending to MOC" : "Send to MOC")
                .accessibilityHint("Sends the selected result and images to the MOC Hub")
                .disabled(isSendingToMOC)
            }
            if !mocMessage.isEmpty {
                Text(mocMessage).font(.caption).foregroundStyle(mocMessage.hasPrefix("Unable") ? .red : .green)
            }
            if let related = payload.relatedDocumentURL, !hasSafetyDocument {
                openDocumentButton("RELATED DOCUMENT / CHECK LINK", url: related, tint: .green)
            }
            Text(status).font(.caption.weight(.bold)).foregroundStyle(status == "MATCH FOUND" ? .green : .yellow)
            if total > 1 {
                Text("MATCH \\(position) OF \\(total)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Was this result useful?").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { feedback = true; store.registerSearchFeedback(for: payload, positive: true) } label: {
                    Image(systemName: feedback == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                }.tint(.green)
                Button { feedback = false; onNegativeFeedback() } label: {
                    Image(systemName: feedback == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }.tint(.red)
            }
        }
        .card()
        .sheet(isPresented: $showQualificationStatus) {
            QualificationStatusOverlay(session: session, requirements: qualificationRequirements)
        }
        .fullScreenCover(item: $documentTarget) { target in
            MVDDocumentBrowser(target: target)
        }
    }
}

private struct MVDDocumentTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let finalURL: URL?
    let context: MVDDocumentContext
}

private struct MVDPageJumpRequest: Identifiable {
    let id = UUID()
    let page: String
    let item: String?
}

/// Visor web interno. Mantiene el documento y la sesión del portal dentro de
/// SmartLookApp; no entrega credenciales ni contenido a un navegador externo.
private struct MVDDocumentBrowser: View {
    let target: MVDDocumentTarget
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mateSession = MVDMateReadingSession.shared
    @State private var isLoading = true
    @State private var loadedTitle = ""
    @State private var documentText = ""
    @State private var scanRequestID: UUID?
    @State private var pageJumpRequest: MVDPageJumpRequest?
    @State private var portalLoginCompleted = false
    @State private var supplementsAcknowledged = false
    @State private var manualOpenRequestID: UUID?

    private var isCMM: Bool {
        target.context.manualType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CMM"
    }

    /// All manuals use the same two-stage portal flow. CMM starts at the
    /// Flatirons application entry point, which redirects to PFLogin with a
    /// fresh flowId; other manuals establish the site's origin first. The
    /// exact document route is loaded only in a second web view after sign-in.
    private var portalAuthenticationURL: URL {
        if target.context.manualType.uppercased().contains("CMM") {
            // The Flatirons entry point creates the valid PFLogin flowId.
            // Loading the bare PFLogin home or a stale /loginb2e flowId only
            // shows the welcome page or an error.
            return URL(string: "https://aa.flatironscloud.com/")!
        }
        guard var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false) else {
            return target.url
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? target.url
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DOCUMENT CONTEXT")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.blue)
                    Text("\(target.context.customerCode) • \(target.context.model) • \(target.context.aircraftNose) • \(target.context.manualType)")
                        .font(.caption.weight(.semibold))
                    Text("ATA \(target.context.ata.isEmpty ? "—" : target.context.ata) • \(target.context.partName.isEmpty ? target.context.recordId : target.context.partName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !target.context.item.isEmpty {
                        Text("Selected item: \(target.context.item) • source page \(target.context.pageNumber.isEmpty ? "—" : target.context.pageNumber)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !documentText.isEmpty {
                        Label("Document text captured locally for Mate (\(documentText.count) characters)", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)

                ZStack {
                    // Keep one WKWebView for both sign-in and the document.
                    // Flatirons PDF.js also uses in-page/session state, not
                    // only cookies; opening a second web view can therefore
                    // authenticate successfully but leave CMM at 0/0.
                    if isCMM {
                        MVDExternalCMMDocumentView(target: target)
                    } else {
                    MVDDocumentWebView(
                        url: portalLoginCompleted
                            ? (supplementsAcknowledged ? (target.finalURL ?? target.url) : target.url)
                            : portalAuthenticationURL,
                        scanRequestID: nil,
                        pageJumpRequest: nil,
                        portalAuthenticationURL: portalAuthenticationURL,
                        shouldDetectPortalLogin: !portalLoginCompleted,
                        autoOpenDocument: portalLoginCompleted && (target.finalURL == nil || supplementsAcknowledged),
                        openDocumentRequestID: manualOpenRequestID,
                        onPortalLogin: {
                            guard !portalLoginCompleted else { return }
                            portalLoginCompleted = true
                            isLoading = true
                            loadedTitle = ""
                            documentText = ""
                        },
                        onStateChange: { loading, title, text in
                            isLoading = loading
                            loadedTitle = title
                            documentText = text
                            MVDDocumentSession.shared.update(context: target.context, text: text)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.blue.opacity(0.55)))
                    }
                    if isLoading && !isCMM {
                        ProgressView("Loading document…")
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isCMM && !portalLoginCompleted {
                    VStack(spacing: 6) {
                        Text("PORTAL SIGN-IN REQUIRED")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.orange)
                        Text("Sign in above. SmartLookApp will continue to the trained document automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            portalLoginCompleted = true
                            isLoading = true
                            loadedTitle = ""
                            documentText = ""
                        } label: {
                            Label("CONTINUE IF ALREADY SIGNED IN", systemImage: "arrow.right.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    .padding(.horizontal, 10)
                }

                if !isCMM, portalLoginCompleted, let finalURL = target.finalURL, !supplementsAcknowledged {
                    VStack(spacing: 6) {
                        Text("SUPPLEMENTS ACKNOWLEDGEMENT REQUIRED")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.orange)
                        Text("Press I Acknowledge in the portal above. Then open the exact match page.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            supplementsAcknowledged = true
                            isLoading = true
                            loadedTitle = ""
                            documentText = ""
                        } label: {
                            Label("OPEN MATCH PAGE", systemImage: "arrow.right.doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityHint("Opens the CMM page after acknowledging supplements")
                        Text(finalURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                }

                if !isCMM, portalLoginCompleted, (target.finalURL == nil || supplementsAcknowledged) {
                    Button { manualOpenRequestID = UUID() } label: {
                        Label("OPEN DOCUMENT MANUALLY", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }

                if portalLoginCompleted, !loadedTitle.isEmpty {
                    Text(loadedTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isCMM {
                    Button {
                        mateSession.begin(context: target.context)
                        scanRequestID = UUID()
                    } label: {
                        Label("MATE • READ CMM OPEN PAGE + 50", systemImage: "text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mateSession.isReading || !portalLoginCompleted)

                    if !mateSession.detectedDrawingItems.isEmpty {
                        Text("DRAWING ITEMS: \(mateSession.detectedDrawingItems.joined(separator: ", "))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if mateSession.pagesRead > 0 {
                        Text(mateSession.isReading
                             ? "Mate reading CMM pages: \(mateSession.pagesRead)/51…"
                             : "Mate read \(mateSession.pagesRead) CMM page(s) locally.")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(mateSession.isReading ? .blue : .green)
                    }
                    ForEach(mateSession.observations) { observation in
                        Button {
                            pageJumpRequest = MVDPageJumpRequest(page: observation.tablePage, item: observation.item)
                        } label: {
                            HStack {
                                Label("ITEM \(observation.item) → TABLE PAGE \(observation.tablePage)\(observation.item == mateSession.preferredItem ? " • MATCH \(target.context.partName)" : "")", systemImage: observation.item == mateSession.preferredItem ? "checkmark.circle.fill" : "arrow.turn.down.right")
                                    .font(.caption2.weight(.bold))
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(observation.item == mateSession.preferredItem ? .green : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Sign in manually if the portal requests credentials; SmartLookApp does not store them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .padding(10)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct MVDDocumentWebView: UIViewRepresentable {
    let url: URL
    let scanRequestID: UUID?
    let pageJumpRequest: MVDPageJumpRequest?
    let portalAuthenticationURL: URL
    let shouldDetectPortalLogin: Bool
    let autoOpenDocument: Bool
    let openDocumentRequestID: UUID?
    let onPortalLogin: () -> Void
    let onStateChange: (Bool, String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: onStateChange, portalAuthenticationURL: portalAuthenticationURL, onPortalLogin: onPortalLogin)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "mateScan")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastLoadedURL = url
        var request = URLRequest(url: url)
        if url.host?.caseInsensitiveCompare("aa.flatironscloud.com") == .orderedSame {
            request.setValue("https://aa.flatironscloud.com/", forHTTPHeaderField: "Referer")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.portalAuthenticationURL = portalAuthenticationURL
        context.coordinator.shouldDetectPortalLogin = shouldDetectPortalLogin
        context.coordinator.autoOpenDocument = autoOpenDocument
        context.coordinator.onPortalLogin = onPortalLogin
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.didStartAutoOpen = false
            context.coordinator.lastLoadedURL = url
            var request = URLRequest(url: url)
            if url.host?.caseInsensitiveCompare("aa.flatironscloud.com") == .orderedSame {
                request.setValue("https://aa.flatironscloud.com/", forHTTPHeaderField: "Referer")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            }
            webView.load(request)
        }
        if let openDocumentRequestID, context.coordinator.lastOpenDocumentRequestID != openDocumentRequestID {
            context.coordinator.lastOpenDocumentRequestID = openDocumentRequestID
            context.coordinator.openTrainedDocument(in: webView)
        }
        if let scanRequestID, context.coordinator.lastScanRequestID != scanRequestID {
            context.coordinator.lastScanRequestID = scanRequestID
            context.coordinator.scanNextPages(in: webView, limit: 51)
        }
        if let pageJumpRequest, context.coordinator.lastPageJumpID != pageJumpRequest.id {
            context.coordinator.lastPageJumpID = pageJumpRequest.id
            context.coordinator.goToPage(pageJumpRequest, in: webView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let onStateChange: (Bool, String, String) -> Void
        var onPortalLogin: () -> Void
        var portalAuthenticationURL: URL
        var shouldDetectPortalLogin = false
        var autoOpenDocument = false
        var portalDetectionInProgress = false
        var didReportPortalLogin = false
        var didStartAutoOpen = false
        var lastOpenDocumentRequestID: UUID?
        var lastScanRequestID: UUID?
        var lastPageJumpID: UUID?
        var lastLoadedURL: URL?

        init(onStateChange: @escaping (Bool, String, String) -> Void, portalAuthenticationURL: URL, onPortalLogin: @escaping () -> Void) {
            self.onStateChange = onStateChange
            self.portalAuthenticationURL = portalAuthenticationURL
            self.onPortalLogin = onPortalLogin
        }

        func scanNextPages(in webView: WKWebView, limit: Int) {
            webView.evaluateJavaScript(scanScript(limit: limit), completionHandler: nil)
        }

        func goToPage(_ request: MVDPageJumpRequest, in webView: WKWebView) {
            let pageJSON = (try? JSONSerialization.data(withJSONObject: request.page))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let itemJSON = (try? JSONSerialization.data(withJSONObject: request.item ?? ""))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let script = """
            (() => {
              const wanted = \(pageJSON);
              const wantedItem = \(itemJSON).toUpperCase().replace(/[^A-Z0-9]/g, '');
              const inputs = Array.from(document.querySelectorAll('input'));
              const input = inputs.find(node => /page|pagina/i.test(node.getAttribute('aria-label') || '') || /page|pagina/i.test(node.getAttribute('placeholder') || ''));
              if (input) {
                const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
                if (setter) setter.call(input, wanted); else input.value = wanted;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
              }
              if (wantedItem) {
                const revealItem = (attempt = 0) => {
                  const nodes = Array.from(document.querySelectorAll('tr,td,li,div,span,p')).filter(node => {
                    const text = (node.innerText || node.textContent || '').toUpperCase();
                    return text.replace(/[^A-Z0-9]/g, ' ').split(/\\s+/).includes(wantedItem);
                  });
                  const match = nodes.sort((a, b) => (a.innerText || '').length - (b.innerText || '').length)[0];
                  if (match) {
                    match.scrollIntoView({ block: 'center', behavior: 'smooth' });
                    match.style.outline = '3px solid #28a745';
                    match.style.outlineOffset = '3px';
                  } else if (attempt < 6) {
                    window.setTimeout(() => revealItem(attempt + 1), 1000);
                  }
                };
                window.setTimeout(() => revealItem(), 1500);
              }
              return !!input;
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private func scanScript(limit: Int) -> String {
            """
            (() => {
              const maxPages = \(limit);
              const post = (payload) => {
                try { window.webkit.messageHandlers.mateScan.postMessage(payload); } catch (_) {}
              };
              // Preserve line boundaries so a table row keeps its item number
              // next to its nomenclature. Collapsing the whole page to one
              // line can make item 55 match a nomenclature from another row.
              const normalized = value => (value || '').toString()
                .split(/\\r?\\n/)
                .map(line => line.replace(/[\\t ]+/g, ' ').trim())
                .filter(Boolean)
                .join('\\n');
              const pageNumber = body => {
                const match = body.match(/(?:^|\\s)(\\d{1,4})\\s*(?:of|de)\\s*\\d{1,4}(?:\\s|$)/i);
                return match ? match[1] : '';
              };
              const visible = node => !!node && !!(node.offsetWidth || node.offsetHeight || node.getClientRects().length);
              const nextControl = () => Array.from(document.querySelectorAll('button,a,[role=button],input'))
                .filter(visible)
                .find(node => {
                  const text = normalized(node.innerText || node.textContent || node.value || '').toUpperCase();
                  const label = normalized(node.getAttribute('aria-label') || node.getAttribute('title') || '').toUpperCase();
                  return /^(NEXT|>|›|»)$/.test(text) || /NEXT|PAGE DOWN|NEXT PAGE|SIGUIENTE/.test(label);
                });
              let index = 0;
              const visited = new Set();
              const capture = () => {
                const body = normalized(document.body ? document.body.innerText || '' : '');
                const currentURL = location.href;
                const currentPage = pageNumber(body);
                const key = currentURL + '|' + currentPage + '|' + body.slice(0, 160);
                if (visited.has(key)) { post({ kind: 'done' }); return; }
                visited.add(key);
                post({ kind: 'page', index, pageNumber: currentPage, url: currentURL, title: document.title || '', text: body });
                if (index + 1 >= maxPages) { post({ kind: 'done' }); return; }
                const next = nextControl();
                if (!next) { post({ kind: 'done' }); return; }
                index += 1;
                next.click();
                window.setTimeout(capture, 1500);
              };
              capture();
            })();
            """
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mateScan", let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            if kind == "done" {
                DispatchQueue.main.async { MVDMateReadingSession.shared.finish() }
                return
            }
            guard kind == "page" else { return }
            let index = (body["index"] as? NSNumber)?.intValue ?? 0
            let snapshot = MVDMatePageSnapshot(
                index: index,
                pageNumber: body["pageNumber"] as? String ?? "",
                url: body["url"] as? String ?? "",
                title: body["title"] as? String ?? "",
                text: body["text"] as? String ?? ""
            )
            DispatchQueue.main.async { MVDMateReadingSession.shared.append(snapshot) }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onStateChange(true, "", "") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            captureText(from: webView, remainingAttempts: 8)
            if shouldDetectPortalLogin && !didReportPortalLogin && !portalDetectionInProgress {
                portalDetectionInProgress = true
                detectPortalLogin(in: webView, attempt: 0)
            }
            if autoOpenDocument && !didStartAutoOpen {
                didStartAutoOpen = true
                openTrainedDocument(in: webView)
            }
        }

        private func detectPortalLogin(in webView: WKWebView, attempt: Int) {
            guard shouldDetectPortalLogin, !didReportPortalLogin, attempt < 180 else {
                portalDetectionInProgress = false
                return
            }
            webView.evaluateJavaScript("!!document.querySelector('#libraryTree')") { value, _ in
                if (value as? Bool) == true, self.shouldDetectPortalLogin, !self.didReportPortalLogin {
                    self.didReportPortalLogin = true
                    self.portalDetectionInProgress = false
                    DispatchQueue.main.async { self.onPortalLogin() }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.detectPortalLogin(in: webView, attempt: attempt + 1)
                }
            }
        }

        func openTrainedDocument(in webView: WKWebView) {
            didStartAutoOpen = true
            let script = """
            (() => {
              let attempts = 0;
              const visible = node => !!node && !!(node.offsetWidth || node.offsetHeight || node.getClientRects().length) && getComputedStyle(node).visibility !== 'hidden';
              const windows = (win, depth = 0) => {
                const all = [win];
                if (depth < 3) for (const frame of win.document.querySelectorAll('iframe')) {
                  try { if (visible(frame) && frame.contentWindow.document) all.push(...windows(frame.contentWindow, depth + 1)); } catch (_) {}
                }
                return all;
              };
              const tryOpen = () => {
                attempts += 1;
                for (const win of windows(window)) {
                  const controls = Array.from(win.document.querySelectorAll('button,a,[role="button"],input[type="button"],input[type="submit"]'));
                  const button = controls.find(node => {
                    if (!visible(node)) return false;
                    const label = (node.innerText || node.textContent || node.value || node.getAttribute('aria-label') || node.title || '').replace(/\s+/g, ' ').trim();
                    return /^open\s+(this\s+)?document$/i.test(label);
                  });
                  if (button) { button.click(); return; }
                }
                if (attempts < 60) window.setTimeout(tryOpen, 750);
              };
              tryOpen();
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private func captureText(from webView: WKWebView, remainingAttempts: Int) {
            webView.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''") { value, _ in
                let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.onStateChange(false, webView.title ?? "", text)
                    if text.isEmpty && remainingAttempts > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.captureText(from: webView, remainingAttempts: remainingAttempts - 1)
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onStateChange(false, "", "") }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onStateChange(false, "", "") }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowedSchemes = ["http", "https", "blob", "data", "about"]
            if let scheme = navigationAction.request.url?.scheme?.lowercased(), allowedSchemes.contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Algunos visores usan target=_blank: se mantiene dentro del mismo
            // overlay y no se delega a otra aplicación.
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}


// CMM navigation keeps the portal shell and the trained page as separate goals.
// No direct viewer navigation occurs after sign-in or acknowledgement.
private struct MVDExternalCMMDocumentView: View {
    let target: MVDDocumentTarget
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mvd_external_cmm_open_url") private var openedURL = ""
    @State private var launchInProgress = false
    @State private var returnedFromSafari = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text("CMM OPENED IN SAFARI")
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
            Text(target.title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(returnedFromSafari ? "Returned from Safari. The current search remains open." : "Safari is opening the selected CMM document.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { openInSafari() } label: {
                Label("OPEN CMM IN SAFARI", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(launchInProgress)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if openedURL == target.url.absoluteString {
                returnedFromSafari = true
            } else {
                openedURL = target.url.absoluteString
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { openInSafari() }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && openedURL == target.url.absoluteString { returnedFromSafari = true }
        }
    }

    private func openInSafari() {
        guard !launchInProgress else { return }
        launchInProgress = true
        UIApplication.shared.open(target.url, options: [:]) { _ in
            DispatchQueue.main.async { launchInProgress = false }
        }
    }
}

private struct MVDCMMPortalView: View {
    let target: MVDDocumentTarget
    @State private var status = "Sign in to American Airlines to open the selected CMM."
    @State private var openMatch = false

    var body: some View {
        VStack(spacing: 8) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)

            MVDCMMPortalWebView(
                target: target,
                openMatch: openMatch,
                onStatus: { status = $0 }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.blue.opacity(0.55)))

            Button { openMatch = true } label: {
                Label("OPEN DOCUMENT", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Text("Accept Knowledge in the portal first, then press OPEN DOCUMENT to load the trained match link.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct MVDCMMPortalWebView: UIViewRepresentable {
    let target: MVDDocumentTarget
    let openMatch: Bool
    let onStatus: (String) -> Void

    private var configurationJSON: String {
        let original = target.context.documentURL
        let outer = URLComponents(string: original)
        let nested = outer?.queryItems?.first(where: { $0.name == "file" })?.value
        let document = URL(string: nested ?? original)
        let filename = document?.lastPathComponent ?? ""
        let portalQuery = outer?.fragment?.components(separatedBy: "?").dropFirst().joined(separator: "?") ?? ""
        let portalItems = URLComponents(string: "https://aa.flatironscloud.com/?" + portalQuery)?.queryItems ?? []
        let portalTitle = portalItems.first(where: { $0.name == "documentTitle" })?.value
        let title = portalTitle ?? filename.components(separatedBy: "__").last ?? filename
        let cleanTitle = title.removingPercentEncoding ?? title
        let publication = cleanTitle.hasSuffix(".pdf") ? String(cleanTitle.dropLast(4)) : cleanTitle
        let pageFragment = outer?.fragment ?? ""
        let pageValue = pageFragment.components(separatedBy: "&").first(where: { $0.hasPrefix("page=") })?
            .dropFirst(5)
        let page = Int(pageValue.map(String.init) ?? "") ?? Int(target.context.pageNumber) ?? 0
        let range = publication.range(of: #"\d{2}-\d{2}-\d{2,4}"#, options: .regularExpression)
        let cmm = range.map { String(publication[$0]) } ?? ""
        var route = original.contains("#/main/goto?") ? original : ""
        if route.isEmpty, !cmm.isEmpty, !publication.isEmpty {
            let group = String(cmm.prefix(5))
            let resource = "COMPONENTS/\(group)/\(cmm)/\(publication)"
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
            route = "https://aa.flatironscloud.com/pinpoint/#/main/goto?resourcePath="
                + (resource.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        // Exact portal links verified with the signed-in integrated browser.
        if cmm == "25-20-82" {
            route = "https://aa.flatironscloud.com/pinpoint/#/main/goto?library=c8e41757-f55c-43f3-b384-c9f6e79cc4da&publicationID=e7ebba41-59a6-4e3b-9e9a-5474b6769e98&documentID=1293233776__BE%20AEROSPACE%2025-20-82&revision=5&documentTitle=BE%20AEROSPACE%2025-20-82.pdf&newViewer=true"
        } else if cmm == "25-25-71" {
            route = "https://aa.flatironscloud.com/pinpoint/#/main/goto?library=f7c4714c-8295-47b6-aa3e-8c959a8cb5ce&publicationID=b5aaf261-fdfd-4928-ab3b-f158c226a58c&documentID=1387798187__BE%20AEROSPACE%2025-25-71&revision=2&documentTitle=BE%20AEROSPACE%2025-25-71.pdf&newViewer=true"
        } else if cmm == "25-21-25" {
            route = "https://aa.flatironscloud.com/pinpoint/#/main/goto?library=50e89648-00f8-4b6b-8ef4-8e61d92e69e7&publicationID=ad5fcf63-fced-4aea-92d5-590947380a8b&documentID=-973187066__ELEVATE%2025-21-25&revision=1&documentTitle=ELEVATE%2025-21-25.pdf&newViewer=true"
        }
        let is777200 = target.context.model.uppercased().replacingOccurrences(of: " ", with: "-").contains("777-200")
        let preflight = is777200
            ? "https://aa.flatironscloud.com/pinpoint/#/main/goto?library=c9c65771-2510-4b78-96a3-1791f5bcf558&publicationID=2afe588a-13ca-4d0b-9c94-27b31261e099&documentID=2102982549__B777-200%20IPC%20Addendum&revision=61&documentTitle=B777-200%20IPC%20Addendum.pdf&newViewer=true"
            : ""
        let values: [String: Any] = ["route": route, "preflight": preflight, "page": page,
                                     "title": publication, "cmm": cmm, "matchURL": original,
                                     "allowMatch": openMatch]
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func makeCoordinator() -> Coordinator { Coordinator(onStatus: onStatus) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "cmmFlow")
        let script = """
        (() => {
          if (location.hostname !== 'aa.flatironscloud.com' || window !== window.top) return;
          const goal = \(configurationJSON);
          let phase = 'start', navigationAt = Date.now(), completed = false;
          let lastStatus = '', readySince = 0, finalNavigationStarted = false;
          const report = text => {
            if (text === lastStatus) return;
            lastStatus = text;
            window.webkit.messageHandlers.cmmFlow.postMessage(text);
          };
          const decode = s => { try { return decodeURIComponent(s); } catch (_) { return s; } };
          const normalize = s => decode(decode(s || '')).toLowerCase().replace(/\\s+/g, ' ').trim();
          const visible = n => !!n && !!(n.offsetWidth || n.offsetHeight || n.getClientRects().length)
            && getComputedStyle(n).visibility !== 'hidden';
          const windows = (w, depth = 0) => {
            const all = [w];
            if (depth < 4) {
              for (const f of w.document.querySelectorAll('iframe')) {
                if (!visible(f)) continue;
                try { if (f.contentWindow.document) all.push(...windows(f.contentWindow, depth + 1)); } catch (_) {}
              }
            }
            return all;
          };
          const navigate = route => {
            navigationAt = Date.now(); readySince = 0;
            // Hash navigation preserves the authenticated Angular portal.
            location.hash = new URL(route).hash;
          };
          const tick = () => {
            if (completed) return;
            if (!document.querySelector('#libraryTree')) {
              report('Sign in to American Airlines. The selected CMM and match page are saved.');
              return;
            }
            if (!goal.route) {
              report('Unable to resolve this CMM portal link. The trained link has been preserved.');
              return;
            }
            if (phase === 'start') {
              phase = goal.preflight ? 'preflight' : 'cmm';
              navigate(goal.preflight || goal.route);
              report(phase === 'preflight' ? 'Opening B777-200 IPC Addendum…' : 'Opening selected CMM…');
              return;
            }
            const frames = windows(window);
            const manualOpen = goal.allowMatch || window.__mvdOpenMatch === true;
            // OPEN DOCUMENT is an explicit user command. It must win over
            // stale/duplicated Knowledge nodes left in an iframe.
            if (phase === 'cmm' && !finalNavigationStarted && manualOpen && goal.matchURL) {
              finalNavigationStarted = true;
              navigate(goal.matchURL);
              report('Opening the trained match page…');
              return;
            }
            const barrier = frames.some(w => Array.from(w.document.querySelectorAll('button,a,[role=button],input'))
              .some(n => visible(n) && /^i\\s+acknowledge$/i.test((n.innerText || n.value || n.textContent || '').trim())));
            if (barrier) {
              readySince = 0;
              report('Review Important Attachments and press I Acknowledge, then press OPEN DOCUMENT.');
              return;
            }
            if (phase === 'cmm' && !manualOpen) {
              report('Knowledge accepted. Press OPEN DOCUMENT to load the trained match link.');
              return;
            }
            // Pinpoint first renders the IPC Addendum as an HTML shell (welcome/tree/TOC).
            // It is not PDF.js yet, so waiting only for PDFViewerApplication leaves the flow on page 0.
            if (phase === 'preflight') {
              const portalText = frames.map(w => {
                try { return normalize((w.document.title || '') + ' ' + (w.document.body ? w.document.body.innerText || '' : '')); }
                catch (_) { return ''; }
              }).join(' ');
              const ipcShellReady = portalText.includes('b777-200 ipc addendum')
                && (portalText.includes('welcome to pinpoint')
                    || portalText.includes('table of content')
                    || portalText.includes('b777-200 ipc addendum.pdf'));
              if (ipcShellReady) {
                if (!readySince) { readySince = Date.now(); report('B777-200 IPC Addendum loaded. Checking Important Attachments…'); return; }
                if (Date.now() - readySince < 1500) return;
                phase = 'cmm';
                navigate(goal.route);
                report('Opening selected CMM…');
                return;
              }
            }
            const expected = normalize(phase === 'preflight' ? 'B777-200 IPC Addendum' : goal.title);
            const portalSnapshot = frames.map(w => {
              try {
                return normalize((w.document.title || '') + ' ' + w.location.href + ' '
                  + (w.document.body ? w.document.body.innerText || '' : ''));
              } catch (_) { return ''; }
            }).join(' ');
            const viewer = frames.map(w => {
              const app = w.PDFViewerApplication;
              if (!app || !app.pdfDocument || !app.pdfDocument.numPages) return null;
              const identity = normalize((app.url || '') + ' ' + (app.baseUrl || '') + ' ' + w.location.href);
              // Once the CMM route has been opened, the first valid PDF.js
              // document is the selected CMM. Its internal title can differ
              // from the trained title, so do not reject it on a strict match.
              return phase === 'cmm' || (expected && identity.includes(expected)) ? app : null;
            }).find(Boolean);
            if (!viewer) {
              report(Date.now() - navigationAt > 60000
                ? 'Waiting for the selected document. Complete any portal prompts above; the match page is saved.'
                : 'Waiting for the selected document and supplements…');
              return;
            }
            // Give asynchronously rendered attachment dialogs time to appear.
            if (!readySince) { readySince = Date.now(); return; }
            if (Date.now() - readySince < 2000) return;
            if (phase === 'preflight') {
              phase = 'cmm'; navigate(goal.route); report('Opening selected CMM…'); return;
            }
            if (!goal.page) { completed = true; report('CMM opened. No numeric match page was stored in this training.'); return; }
            if (goal.page < 1 || goal.page > viewer.pdfDocument.numPages) {
              report('The trained page is outside this document revision. Check the training link.');
              return;
            }
            if (viewer.page !== goal.page) { viewer.page = goal.page; return; }
            completed = true;
            report('CMM opened at match page ' + goal.page + '.');
          };
          tick();
          const timer = setInterval(tick, 750);
          window.addEventListener('pagehide', () => clearInterval(timer), { once: true });
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://aa.flatironscloud.com/pinpoint/")!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        if openMatch {
            view.evaluateJavaScript("window.__mvdOpenMatch = true;")
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cmmFlow")
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onStatus: (String) -> Void
        init(onStatus: @escaping (String) -> Void) { self.onStatus = onStatus }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "aa.flatironscloud.com",
                  let text = message.body as? String else { return }
            DispatchQueue.main.async { self.onStatus(text) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onStatus("Portal could not load: \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

// MARK: - Training

struct TrainingView: View {
    let session: MVDSession
    @ObservedObject var store: MVDLocalStore
    @Environment(\.dismiss) private var dismiss
    private let editingPayload: MVDTrainingPayload?
    @State private var partName = ""
    @State private var faultCode = ""
    @State private var page = ""
    @State private var eicas = ""
    @State private var level = ""
    @State private var description = ""
    @State private var selectedManualType = "AMM"
    @State private var trainingLink = ""
    @State private var manualAta = ""
    @State private var subAta = ""
    @State private var ocrText = ""
    @State private var rii = false
    @State private var lmp = false
    @State private var etops = false
    @State private var rvsm = false
    @State private var ewis = false
    @State private var aard200 = false
    @State private var aard300 = false
    @State private var gpm = false
    @State private var riiLink = ""
    @State private var lmpLink = ""
    @State private var etopsLink = ""
    @State private var rvsmLink = ""
    @State private var ewisLink = ""
    @State private var aard200Link = ""
    @State private var aard300Link = ""
    @State private var gpmLink = ""
    @State private var selectedSeat = ""
    @State private var saved = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var importedPhotoNames: [String] = []
    @State private var photoStatus = ""
    @State private var extractedText = ""
    @State private var showCamera = false
    @State private var createNewIndex = false
    @State private var cmmLocation = ""
    @State private var deletedPhotoNames: Set<String> = []
    @State private var deletedDocumentIDs: Set<String> = []
    @State private var deleteEntireIndex = false

    init(session: MVDSession, store: MVDLocalStore, editingPayload: MVDTrainingPayload? = nil) {
        self.session = session
        self.store = store
        self.editingPayload = editingPayload
        _partName = State(initialValue: editingPayload?.partName ?? "")
        _faultCode = State(initialValue: editingPayload?.faultCode ?? "")
        _page = State(initialValue: editingPayload?.pageNumber ?? "")
        _eicas = State(initialValue: editingPayload?.eicasMessage ?? "")
        _level = State(initialValue: editingPayload?.eicasLevel ?? "")
        _description = State(initialValue: editingPayload?.description ?? "")
        _selectedManualType = State(initialValue: editingPayload?.manualType.isEmpty == false ? editingPayload!.manualType : "AMM")
        _trainingLink = State(initialValue: editingPayload?.trainingProcedureLink.isEmpty == false ? editingPayload!.trainingProcedureLink : (editingPayload?.pinpointLink ?? ""))
        _manualAta = State(initialValue: editingPayload?.ataChapter == "N/A" ? "" : (editingPayload?.ataChapter ?? ""))
        _subAta = State(initialValue: editingPayload?.subAta ?? "")
        _ocrText = State(initialValue: editingPayload?.eicasMessage ?? "")
        _rii = State(initialValue: editingPayload?.isRii ?? false)
        _lmp = State(initialValue: editingPayload?.isLmp ?? false)
        _etops = State(initialValue: editingPayload?.isEtops ?? false)
        _rvsm = State(initialValue: editingPayload?.isRvsm ?? false)
        _ewis = State(initialValue: editingPayload?.isEwis ?? false)
        _aard200 = State(initialValue: editingPayload?.isAard200 ?? false)
        _aard300 = State(initialValue: editingPayload?.isAard300 ?? false)
        _gpm = State(initialValue: editingPayload?.isGpm ?? false)
        _riiLink = State(initialValue: editingPayload?.riiLink ?? "")
        _lmpLink = State(initialValue: editingPayload?.lmpLink ?? "")
        _etopsLink = State(initialValue: editingPayload?.etopsLink ?? "")
        _rvsmLink = State(initialValue: editingPayload?.rvsmLink ?? "")
        _ewisLink = State(initialValue: editingPayload?.ewisLink ?? "")
        _aard200Link = State(initialValue: editingPayload?.aard200Link ?? "")
        _aard300Link = State(initialValue: editingPayload?.aard300Link ?? "")
        _gpmLink = State(initialValue: editingPayload?.gpmLink ?? "")
        _selectedSeat = State(initialValue: editingPayload?.cmmLocation ?? "")
        _saved = State(initialValue: false)
        _selectedPhotos = State(initialValue: [])
        _importedPhotoNames = State(initialValue: editingPayload?.imageFiles ?? [])
        _photoStatus = State(initialValue: editingPayload == nil ? "" : "Existing training photos loaded.")
        _extractedText = State(initialValue: editingPayload?.eicasMessage ?? "")
        _showCamera = State(initialValue: false)
        _createNewIndex = State(initialValue: false)
        _cmmLocation = State(initialValue: editingPayload?.cmmLocation ?? "")
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        let limited = Array(items.prefix(10))
        importedPhotoNames = limited.indices.map { "local-photo-\($0 + 1)" }
        photoStatus = "Preparing local photo storage…"
        Task {
            let folder = MVDTrainingPaths.pendingAircraftFolder(
                model: session.aircraft?.model ?? "B777-200",
                customer: session.aircraft?.customer ?? "AA",
                manufacturer: session.aircraft?.manufacturer ?? "Boeing"
            ).appendingPathComponent("AMM", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var savedCount = 0
            var extractedParts: [String] = []
            for (index, item) in limited.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let destination = folder.appendingPathComponent("local-photo-\(index + 1).jpg")
                    try? data.write(to: destination, options: .atomic)
                    let text = await MVDLocalExtraction.text(from: data)
                    if !text.isEmpty { extractedParts.append(text) }
                    savedCount += 1
                }
            }
            let finalCount = savedCount
            let finalText = extractedParts.joined(separator: " ")
            await MainActor.run {
                extractedText = finalText
                photoStatus = "\(finalCount) photo(s) staged locally for \(session.nose)."
            }
        }
    }

    private func saveCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let folder = MVDTrainingPaths.pendingAircraftFolder(
            model: session.aircraft?.model ?? "B777-200",
            customer: session.aircraft?.customer ?? "AA",
            manufacturer: session.aircraft?.manufacturer ?? "Boeing"
        ).appendingPathComponent("AMM", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = importedPhotoNames.count + 1
        let destination = folder.appendingPathComponent("camera-photo-\(index).jpg")
        try? data.write(to: destination, options: .atomic)
        importedPhotoNames.append("camera-photo-\(index)")
        photoStatus = "Camera photo staged locally for \(session.nose)."
    }

    private var relatedEditablePayloads: [MVDTrainingPayload] {
        guard let editingPayload else { return [] }
        let groupKey = mvdAuditGroupKey(editingPayload)
        let sameIndex = store.training.filter { mvdAuditGroupKey($0) == groupKey }
        return sameIndex.sorted { $0.manualType.localizedStandardCompare($1.manualType) == .orderedAscending }
    }

    private func editorImage(for name: String) -> UIImage? {
        guard let editingPayload else { return nil }
        return mvdResolvedImage(for: editingPayload, name: name)
    }

    private func documentDisplayTitle(for record: MVDTrainingPayload) -> String {
        let raw = record.trainingProcedureLink.isEmpty ? record.pinpointLink : record.trainingProcedureLink
        if let url = URL(string: raw), !raw.isEmpty {
            return mvdActualDocumentTitle(url, fallbackManual: record.manualType)
        }
        let ata = [record.ataChapter, record.subAta].filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: "-")
        return [record.manualType, ata].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private let manualTypes = ["AMM", "AIPC", "FIM", "CMM", "WDM", "MEL"]
    private var saveButtonTitle: String { editingPayload == nil ? "ADD MANUAL TO PAYLOAD" : (createNewIndex ? "SAVE AS NEW INDEX" : "SAVE CHANGES") }

    private var selectedCMMNumber: String {
        guard selectedManualType.uppercased() == "CMM",
              !selectedSeat.isEmpty,
              let aircraft = session.aircraft,
              let configuration = MVDLocationData.configuration(
                manufacturer: aircraft.manufacturer,
                model: aircraft.model,
                nose: session.nose
              ) else { return "" }
        return MVDLocationData.resolveCMM(
            for: MVDCMMLocationSelection(domain: .seat, location: selectedSeat),
            configuration: configuration
        ) ?? ""
    }

    private func parseATAFromLink() {
        let decoded = trainingLink.removingPercentEncoding ?? trainingLink
        guard let match = decoded.range(of: #"(\d{2})-(\d{2})-(\d{2})"#, options: .regularExpression) else { return }
        let value = String(decoded[match])
        let pieces = value.split(separator: "-")
        guard pieces.count == 3 else { return }
        manualAta = String(pieces[0])
        subAta = "\(pieces[1])-\(pieces[2])"
    }

    private func safetyRow(_ title: String, isOn: Binding<Bool>, link: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: isOn)
                .font(.caption.weight(.semibold))
                .frame(width: 108, alignment: .leading)
            TextField("\(title) DOCUMENT LINK", text: link)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    var body: some View {
        Form {
            Section(editingPayload == nil ? "AI TRAINING CENTER" : "EDIT TRAINING RECORD") {
                MVDLogo().frame(width: 72, height: 72)
                Text("ROOT: Application Support / TrainingData + New Trainings").font(.caption).foregroundStyle(.green)
                Text("Aircraft: \(session.nose) • \(session.aircraft?.model ?? "B777-300")")
            }
            if let editingPayload {
                Section("INDEX PRESERVATION") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("INDEX: \(editingPayload.ucid.isEmpty ? editingPayload.recordId : editingPayload.ucid)")
                                .font(.caption.weight(.bold)).foregroundStyle(.purple)
                            Text("Saving updates this record with all current photos and documents.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { deleteEntireIndex = true } label: {
                            Image(systemName: "trash.fill").font(.title3)
                        }
                        .accessibilityLabel("DELETE ENTIRE INDEX")
                    }
                    if deleteEntireIndex {
                        Text("The entire index will be deleted when you tap SAVE CHANGES.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if session.role.uppercased() == "TRAINER" {
                        Toggle("CREATE NEW INDEX", isOn: $createNewIndex)
                        Text(createNewIndex ? "A new UCID will be generated." : "The current recordId and UCID will be preserved.")
                            .font(.caption2).foregroundStyle(createNewIndex ? .orange : .green)
                    }
                }
            }
            Section(editingPayload == nil ? "PHOTO LABELING (MAX 10)" : "PHOTOS • ADD OR KEEP EXISTING") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        Label("CAPTURE WITH CAMERA", systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                    Label("SELECT PHOTOS", systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: selectedPhotos) { newItems in importPhotos(newItems) }
                if importedPhotoNames.isEmpty {
                    Text("Photos remain local to this device in this MVD step.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(importedPhotoNames, id: \.self) { name in
                        HStack(spacing: 8) {
                            if let image = editorImage(for: name) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 78, height: 58).clipped().cornerRadius(6)
                            } else {
                                Image(systemName: "photo").frame(width: 78, height: 58)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                                if editorImage(for: name) == nil {
                                    Text("IMAGE NOT FOUND IN LOCAL LIBRARY").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                deletedPhotoNames.insert(name)
                                importedPhotoNames.removeAll { $0 == name }
                            } label: { Image(systemName: "trash.fill") }
                            .accessibilityLabel("DELETE PHOTO \(name)")
                        }
                    }
                    if !deletedPhotoNames.isEmpty {
                        Text("\(deletedPhotoNames.count) photo(s) marked for deletion.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(photoStatus).font(.caption).foregroundStyle(.green)
                    if !extractedText.isEmpty {
                        Text("AI EXTRACTED (LOCAL OCR): \(extractedText)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            Section("SEAT / CMM LOCATOR") {
                let seats = MVDLocalSeatCatalog.seats(for: session.nose)
                if seats.isEmpty {
                    Text("Import PrivateFleet/seat-\(session.nose).json to show the complete seat list.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Seat", selection: $selectedSeat) {
                        Text("Select seat").tag("")
                        ForEach(seats, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if editingPayload != nil {
                Section("DOCUMENTS IN THIS INDEX") {
                    ForEach(relatedEditablePayloads) { record in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.manualType.isEmpty ? "DOCUMENT" : record.manualType)
                                    .font(.subheadline.weight(.bold))
                                Text(documentDisplayTitle(for: record))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                deletedDocumentIDs.insert(record.id)
                            } label: { Image(systemName: "trash.fill") }
                            .accessibilityLabel("DELETE \(record.manualType) DOCUMENT")
                        }
                        .opacity(deletedDocumentIDs.contains(record.id) ? 0.45 : 1)
                    }
                    if !deletedDocumentIDs.isEmpty {
                        Text("Selected documents will be removed from this index when you save.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("MANUAL DOCUMENT") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(manualTypes, id: \.self) { type in
                            Button(type) { selectedManualType = type }
                                .buttonStyle(.borderedProminent)
                                .tint(selectedManualType == type ? .blue : .gray)
                                .controlSize(.small)
                        }
                    }
                }
                if selectedManualType.uppercased() == "CMM" {
                    Button {
                        if selectedSeat.isEmpty { selectedSeat = MVDLocalSeatCatalog.seats(for: session.nose).first ?? "" }
                    } label: {
                        VStack(spacing: 2) {
                            Text("CMM LOCATION").font(.caption.weight(.bold))
                            Text(selectedSeat.isEmpty ? "SELECT AIRCRAFT LOCATION" : "SEAT: \(selectedSeat)\(selectedCMMNumber.isEmpty ? "" : " • CMM \(selectedCMMNumber)")")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                }
                HStack(spacing: 8) {
                    TextField("DOCUMENT LINK", text: $trainingLink)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(action: parseATAFromLink) { Image(systemName: "wand.and.stars") }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                }
                TextField("PAGE", text: $page)
                HStack(spacing: 8) {
                    TextField("ATA", text: $manualAta)
                    TextField("SUB-ATA", text: $subAta)
                }
                TextField("PART NAME / COMPONENT", text: $partName)
                TextField("TEXTO OCR (P/N, S/N, FABRICANTE)", text: $ocrText)
                Divider()
                Text("WARNINGS").font(.caption.weight(.bold))
                safetyRow("RII", isOn: $rii, link: $riiLink)
                safetyRow("LMP", isOn: $lmp, link: $lmpLink)
                safetyRow("EWIS", isOn: $ewis, link: $ewisLink)
                safetyRow("ETOPS", isOn: $etops, link: $etopsLink)
                safetyRow("RVSM", isOn: $rvsm, link: $rvsmLink)
                safetyRow("AARD-200", isOn: $aard200, link: $aard200Link)
                safetyRow("AARD-300", isOn: $aard300, link: $aard300Link)
                safetyRow("GPM", isOn: $gpm, link: $gpmLink)
            }
            Section("GENERAL INFORMATION") {
                HStack { TextField("FAULT CODE", text: $faultCode); TextField("EICAS MESSAGE", text: $eicas) }
                HStack { TextField("EICAS LEVEL", text: $level); TextField("DESCRIPTION / NOTES", text: $description) }
            }
            Button {
                if deleteEntireIndex, let current = editingPayload {
                    store.deleteTrainingGroup(groupKey: mvdAuditGroupKey(current), recordId: current.recordId)
                    saved = true
                    dismiss()
                    return
                }
                let currentID = editingPayload?.id
                for id in deletedDocumentIDs where id != currentID {
                    store.deleteTraining(recordId: id)
                }
                if let currentID, deletedDocumentIDs.contains(currentID) {
                    store.deleteTraining(recordId: currentID)
                    saved = true
                    dismiss()
                    return
                }
                if editingPayload == nil && trainingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                let remainingPhotos = importedPhotoNames.filter { !deletedPhotoNames.contains($0) }
                let updatedPayload = MVDTrainingPayload(
                    recordId: (editingPayload != nil && !createNewIndex) ? (editingPayload?.recordId ?? "") : "TRAINING-\(session.nose)-\(selectedManualType)-\(UUID().uuidString)",
                    ucid: (editingPayload != nil && !createNewIndex) ? (editingPayload?.ucid ?? "") : "",
                    aircraftNose: session.nose,
                    model: session.aircraft?.model ?? "N/A",
                    manufacturer: session.aircraft?.manufacturer ?? "Boeing",
                    customerCode: session.aircraft?.customer ?? "DEMO",
                    trainerID: session.employeeID,
                    cmmLocation: selectedSeat,
                    manualType: selectedManualType,
                    cmmNumber: selectedCMMNumber,
                    ataChapter: manualAta.isEmpty ? "N/A" : manualAta,
                    subAta: subAta,
                    partName: partName.isEmpty ? "Sanitized component" : partName,
                    faultCode: faultCode,
                    eicasMessage: eicas.isEmpty ? ocrText : eicas,
                    eicasLevel: level,
                    pinpointLink: trainingLink,
                    trainingProcedureLink: trainingLink,
                    pageNumber: page,
                    isRii: rii,
                    riiLink: riiLink,
                    isEwis: ewis,
                    ewisLink: ewisLink,
                    isLmp: lmp,
                    lmpLink: lmpLink,
                    isEtops: etops,
                    isGpm: gpm,
                    etopsLink: etopsLink,
                    isAadr: aard200 || aard300,
                    aadrLink: aard200 ? aard200Link : aard300Link,
                    isAard200: aard200,
                    aard200Link: aard200Link,
                    isAard300: aard300,
                    aard300Link: aard300Link,
                    isRvsm: rvsm,
                    rvsmLink: rvsmLink,
                    gpmLink: gpmLink,
                    description: description.isEmpty ? ocrText : description,
                    imageFiles: remainingPhotos
                )
                store.saveTraining(updatedPayload)
                importedPhotoNames = remainingPhotos
                deletedPhotoNames.removeAll()
                if editingPayload == nil || createNewIndex {
                    trainingLink = ""
                    page = ""
                }
                saved = true
            } label: {
                Label(saveButtonTitle, systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if saved { Text("Sanitized training record staged locally.").foregroundStyle(.green) }
        }
        .scrollContentBackground(.hidden)
        .background(MVDTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let image { saveCapturedImage(image) }
                showCamera = false
            }
        }
    }
}

private struct MVDExtractionCanvas: UIViewRepresentable {
    let image: UIImage
    let zoomScale: CGFloat
    let pan: CGSize
    var onTapPixel: (CGPoint) -> Void

    func makeUIView(context: Context) -> MVDExtractionCanvasView {
        let view = MVDExtractionCanvasView()
        view.image = image
        view.zoomScale = zoomScale
        view.panOffset = pan
        view.onTapPixel = onTapPixel
        return view
    }

    func updateUIView(_ uiView: MVDExtractionCanvasView, context: Context) {
        uiView.image = image
        uiView.zoomScale = zoomScale
        uiView.panOffset = pan
        uiView.onTapPixel = onTapPixel
        uiView.setNeedsDisplay()
    }
}

private final class MVDExtractionCanvasView: UIView {
    var image: UIImage? { didSet { setNeedsDisplay() } }
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var onTapPixel: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = true
        clipsToBounds = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fitRect(imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func draw(_ rect: CGRect) {
        guard let image else { return }
        let imageSize = CGSize(
            width: image.cgImage?.width ?? Int(image.size.width * image.scale),
            height: image.cgImage?.height ?? Int(image.size.height * image.scale)
        )
        let base = fitRect(imageSize: imageSize)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scaled = CGRect(
            x: center.x + (base.minX - center.x) * zoomScale + panOffset.width,
            y: center.y + (base.minY - center.y) * zoomScale + panOffset.height,
            width: base.width * zoomScale,
            height: base.height * zoomScale
        )
        image.draw(in: scaled)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let image else { return }
        let imageSize = CGSize(
            width: image.cgImage?.width ?? Int(image.size.width * image.scale),
            height: image.cgImage?.height ?? Int(image.size.height * image.scale)
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let base = fitRect(imageSize: imageSize)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let safeZoom = max(zoomScale, 0.0001)
        let location = gesture.location(in: self)
        let unzoomed = CGPoint(
            x: center.x + (location.x - panOffset.width - center.x) / safeZoom,
            y: center.y + (location.y - panOffset.height - center.y) / safeZoom
        )
        let localX = unzoomed.x - base.minX
        let localY = unzoomed.y - base.minY
        guard localX >= 0, localY >= 0, localX <= base.width, localY <= base.height else { return }
        onTapPixel?(CGPoint(
            x: min(max(localX / max(base.width, 1) * imageSize.width, 0), imageSize.width - 1),
            y: min(max(localY / max(base.height, 1) * imageSize.height, 0), imageSize.height - 1)
        ))
    }
}

private struct VisionExtractionView: View {
    let image: UIImage
    let onAccept: (UIImage) -> Void
    let onCancel: () -> Void
    private var visionImage: UIImage { image.normalizedForVision() }
    @State private var selectedPoint: CGPoint?
    @State private var isProcessing = false
    @State private var extractionMessage = "Tap the piece you want to extract"
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var scaleStart: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    // Use the pixel-accurate UIKit canvas for both drawing
                    // and hit-testing. SwiftUI's gesture location belongs to
                    // the whole container, while the image itself is
                    // letterboxed by scaledToFit; that made off-centre taps
                    // resolve to the wrong source pixel.
                    MVDExtractionCanvas(
                        image: visionImage,
                        zoomScale: zoomScale,
                        pan: panOffset,
                        onTapPixel: { pixel in
                            guard !isProcessing,
                                  let cgImage = visionImage.cgImage,
                                  cgImage.width > 0,
                                  cgImage.height > 0 else { return }
                            let point = CGPoint(
                                x: min(max(pixel.x / CGFloat(cgImage.width), 0), 1),
                                y: min(max(pixel.y / CGFloat(cgImage.height), 0), 1)
                            )
                            selectedPoint = point
                            extractionMessage = "Segmenting the tapped piece…"
                            segment(at: point)
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    if let selectedPoint {
                        let baseRect = displayedImageRect(in: proxy.size)
                        let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        let imagePoint = CGPoint(
                            x: baseRect.minX + selectedPoint.x * baseRect.width,
                            y: baseRect.minY + selectedPoint.y * baseRect.height
                        )
                        let targetPoint = CGPoint(
                            x: center.x + (imagePoint.x - center.x) * zoomScale + panOffset.width,
                            y: center.y + (imagePoint.y - center.y) * zoomScale + panOffset.height
                        )
                        Circle().fill(.cyan).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(targetPoint)
                    }
                    if isProcessing { ProgressView().tint(.white).scaleEffect(1.5) }
                }
                .contentShape(Rectangle())
                // Keep taps independent from panning. This avoids DragGesture's
                // transformed coordinates selecting a different object after a
                // small finger movement, while still matching Android's zoom/pan
                // coordinate inversion.
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard zoomScale > 1, !isProcessing else { return }
                            panOffset = clampedPan(
                                CGSize(
                                    width: panStart.width + value.translation.width,
                                    height: panStart.height + value.translation.height
                                ),
                                in: proxy.size
                            )
                        }
                        .onEnded { _ in
                            panStart = panOffset
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            guard !isProcessing else { return }
                            zoomScale = min(max(scaleStart * value, 1), 6)
                            panOffset = clampedPan(panOffset, in: proxy.size)
                        }
                        .onEnded { _ in
                            scaleStart = zoomScale
                            if zoomScale <= 1 {
                                zoomScale = 1
                                scaleStart = 1
                                panOffset = .zero
                                panStart = .zero
                            } else {
                                panStart = panOffset
                            }
                        }
                )
            }
            .navigationTitle("EXTRACTION (VISION)")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text(extractionMessage).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button {
                        if let selectedPoint { segment(at: selectedPoint) }
                    } label: { Label("RETRY EXTRACTION", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).disabled(isProcessing || selectedPoint == nil)
                }.padding().background(.black.opacity(0.82))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
    }

    private func segment(at point: CGPoint) {
        guard !isProcessing else { return }
        isProcessing = true
        extractionMessage = "Segmenting piece…"
        print(
            "EXTRACTION_TAP normalized=(\(String(format: "%.4f", point.x)),\(String(format: "%.4f", point.y))) " +
            "zoom=\(String(format: "%.2f", zoomScale)) " +
            "pan=(\(String(format: "%.1f", panOffset.width)),\(String(format: "%.1f", panOffset.height)))"
        )
        // Run MobileSAM against the complete normalized image. Cropping a
        // 52%-sized window around the tap made edge selections ambiguous: a
        // part could be clipped by that temporary window and the model then
        // had no context to distinguish it from a neighboring part. Passing
        // the original image keeps the tap in the same coordinate system from
        // the screen all the way through the model and final crop.
        DispatchQueue.global(qos: .userInitiated).async {
            let promptResult = autoreleasepool {
                MVDImageExtractor.extractTouchWindowWithMobileSAM(
                    visionImage,
                    normalizedPoint: point
                )
            }
            // Vision is an expensive fallback. Do not run it after MobileSAM
            // already succeeded; doing both passes for every tap retained two
            // large masks and could make a second attempt terminate the app.
            let extracted: UIImage?
            let usedVisionFallback: Bool
            if let promptResult {
                extracted = promptResult
                usedVisionFallback = false
            } else {
                extracted = autoreleasepool {
                    MVDImageExtractor.extract(visionImage, normalizedPoint: point)
                }
                usedVisionFallback = true
            }
            DispatchQueue.main.async {
                isProcessing = false
                if let extracted {
                    extractionMessage = usedVisionFallback
                        ? "Silhouette extracted with Vision fallback"
                        : "Silhouette extracted from the tapped component"
                    onAccept(extracted)
                } else {
                    extractionMessage = "Could not segment that point; tap the piece and retry"
                }
            }
        }
    }

    private func normalizedPoint(at location: CGPoint, in containerSize: CGSize) -> CGPoint? {
        let imageRect = displayedImageRect(in: containerSize)
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let untransformed = CGPoint(
            x: center.x + (location.x - center.x - panOffset.width) / zoomScale,
            y: center.y + (location.y - center.y - panOffset.height) / zoomScale
        )
        guard imageRect.contains(untransformed), imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CGPoint(
            x: min(max((untransformed.x - imageRect.minX) / imageRect.width, 0), 1),
            y: min(max((untransformed.y - imageRect.minY) / imageRect.height, 0), 1)
        )
    }

    private func clampedPan(_ proposed: CGSize, in containerSize: CGSize) -> CGSize {
        let imageRect = displayedImageRect(in: containerSize)
        let maxX = max(0, (imageRect.width * zoomScale - imageRect.width) / 2)
        let maxY = max(0, (imageRect.height * zoomScale - imageRect.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func displayedImageRect(in size: CGSize) -> CGRect {
        let imageSize = visionImage.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (size.width - displayed.width) / 2,
            y: (size.height - displayed.height) / 2,
            width: displayed.width,
            height: displayed.height
        )
    }
}

extension UIImage {
    /// Photos from the iPad can carry a camera orientation in metadata while the
    /// underlying CGImage remains unrotated. Render once with orientation .up so
    /// the visible tap coordinates and Vision coordinates use the same pixels.
    func normalizedForVision() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Bounds the temporary segmentation image to avoid memory spikes on iPad
    /// when the user retries several extractions in one session.
    func downsampled(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return self }
        let factor = maxDimension / longestSide
        let targetSize = CGSize(width: max(1, size.width * factor), height: max(1, size.height * factor))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private enum MVDImageExtractor {
    /// Runs MobileSAM on the complete image. Keeping the original image and
    /// normalized point together avoids a second crop coordinate transform at
    /// the edges of the displayed photo.
    static func extractTouchWindowWithMobileSAM(_ image: UIImage, normalizedPoint: CGPoint) -> UIImage? {
        return MVDMobileSAM.shared.extract(image.normalizedForVision(), normalizedPoint: CGPoint(
            x: min(max(normalizedPoint.x, 0), 1),
            y: min(max(normalizedPoint.y, 0), 1)
        ))
    }

    static func extract(_ image: UIImage, normalizedPoint: CGPoint?) -> UIImage? {
        guard #available(iOS 17.0, *), let sourceCGImage = image.cgImage else { return nil }
        var workingImage = image
        var workingPoint = normalizedPoint
        if let normalizedPoint {
            // Vision works better when a small foreground object occupies more
            // of the input. Keep a broad touch-centered window so the whole
            // nearby assembly remains available to the instance segmenter.
            let width = max(1, Int(CGFloat(sourceCGImage.width) * 0.52))
            let height = max(1, Int(CGFloat(sourceCGImage.height) * 0.52))
            let centerX = min(max(Int(normalizedPoint.x * CGFloat(sourceCGImage.width)), 0), sourceCGImage.width - 1)
            let centerY = min(max(Int(normalizedPoint.y * CGFloat(sourceCGImage.height)), 0), sourceCGImage.height - 1)
            let left = min(max(centerX - width / 2, 0), sourceCGImage.width - width)
            let top = min(max(centerY - height / 2, 0), sourceCGImage.height - height)
            let rect = CGRect(x: left, y: top, width: width, height: height)
            guard let cropped = sourceCGImage.cropping(to: rect) else { return nil }
            workingImage = UIImage(cgImage: cropped, scale: 1, orientation: .up)
            workingPoint = CGPoint(
                x: min(max(CGFloat(centerX - left) / CGFloat(width), 0), 1),
                y: min(max(CGFloat(centerY - top) / CGFloat(height), 0), 1)
            )
        }
        guard let cgImage = workingImage.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNInstanceMaskObservation else { return nil }
            let instances: IndexSet
            if let normalizedPoint = workingPoint {
                // Vision uses a bottom-left origin; the UI point uses a top-left origin.
                let visionPoint = CGPoint(x: normalizedPoint.x, y: 1 - normalizedPoint.y)
                let maskBuffer = observation.instanceMask
                let width = CVPixelBufferGetWidth(maskBuffer)
                let height = CVPixelBufferGetHeight(maskBuffer)
                let pixelX = min(max(Int(visionPoint.x * CGFloat(width)), 0), width - 1)
                let pixelY = min(max(Int(visionPoint.y * CGFloat(height)), 0), height - 1)
                CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
                guard let baseAddress = CVPixelBufferGetBaseAddress(maskBuffer) else { return nil }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
                let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
                var selectedInstance: UInt8 = 0
                // A tap can land on an anti-aliased edge. Search a small neighborhood,
                // while still preferring the exact tapped pixel.
                for radius in 0...4 where selectedInstance == 0 {
                    for offsetY in -radius...radius where selectedInstance == 0 {
                        for offsetX in -radius...radius {
                            let x = pixelX + offsetX
                            let y = pixelY + offsetY
                            guard x >= 0, x < width, y >= 0, y < height else { continue }
                            let value = pixels[y * bytesPerRow + x]
                            if value > 0 {
                                selectedInstance = value
                                break
                            }
                        }
                    }
                }
                guard selectedInstance > 0 else { return nil }
                instances = IndexSet(integer: Int(selectedInstance))
            } else {
                instances = observation.allInstances
            }
            guard let mask = try? observation.generateScaledMaskForImage(forInstances: instances, from: handler) else { return nil }
            let source = CIImage(cgImage: cgImage)
            // Vision's instance mask is intentionally generous around object
            // boundaries. A very small minimum morphology removes that halo
            // while preserving thin connected details on the selected part.
            let maskImage = CIImage(cvPixelBuffer: mask)
                .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 0.7])
            let background = CIImage(color: .black).cropped(to: source.extent)
            let output = source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: maskImage
            ])
            let context = CIContext()
            guard let result = context.createCGImage(output, from: output.extent) else { return nil }
            return UIImage(cgImage: result, scale: 1, orientation: .up)
        } catch {
            return nil
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void

        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
    }
}

private enum MVDLocalExtraction {
    static func text(from data: Data) async -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            }
        }
    }
}

// MARK: - Live Qualification Status

private enum MVDQualificationKind: String, CaseIterable, Codable, Identifiable {
    case rii = "RII"
    case lmp = "LMP"
    case etops = "ETOPS"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

private struct MVDQualificationResult: Identifiable {
    let id = UUID()
    let kind: MVDQualificationKind
    let qualified: Bool?
    let detail: String
}

private enum MVDQualificationPortal {
    static let reportURL = URL(string: "https://aa.sumtotal.host/jasperserver-pro/flow.html?_flowId=viewReportFlow&standAlone=true&ParentFolderUri=%2FCustom%2FReports%2FBusiness_Units%2FTechnical_Operations%2FMy_Reports_TO&reportUnit=%2FCustom%2FReports%2FBusiness_Units%2FTechnical_Operations%2FMy_Reports_TO%2FT01_Main_report_1&Portal=1")!

    static func automationScript(model: String, requirements: [String]) -> String {
        let modelJSON = jsonLiteral(model)
        let requirementsJSON = jsonLiteral(requirements)
        return """
        (() => {
          const aircraftModel = \(modelJSON);
          const requested = \(requirementsJSON);
          const messageName = "qualificationStatus";
          const normalized = value => (value || "").toString().replace(/[\\u2013\\u2014]/g, "-").replace(/\\s+/g, " ").trim().toUpperCase();
          const post = (event, states, status) => {
            try { window.webkit.messageHandlers[messageName].postMessage({ event, states, status }); } catch (_) {}
          };
          const textOf = element => normalized(element && (element.innerText || element.textContent));
          const visible = element => !!element && !!(element.offsetWidth || element.offsetHeight || element.getClientRects().length);
          const modelText = normalized(aircraftModel).replace(/-/g, " ");
          const aliases = kind => [
            modelText + " " + kind,
            normalized(aircraftModel) + " " + kind,
            modelText + "-" + kind,
            "B777 " + kind
          ];
          const clickText = candidates => {
            const wanted = candidates.map(normalized);
            const nodes = Array.from(document.querySelectorAll("button,[role=button],a,label,li,option,span,div"));
            const match = nodes.find(node => visible(node) && wanted.some(value => textOf(node) === value));
            if (match) { match.click(); return true; }
            return false;
          };
          const selectOption = candidates => {
            const wanted = candidates.map(normalized);
            for (const select of document.querySelectorAll("select")) {
              const option = Array.from(select.options).find(item => wanted.some(value => normalized(item.textContent) === value || normalized(item.textContent).includes(value)));
              if (option) {
                select.value = option.value;
                select.dispatchEvent(new Event("change", { bubbles: true }));
                return true;
              }
            }
            return false;
          };
          const parseStates = bodyText => {
            const upper = normalized(bodyText);
            return requested.map(kind => {
              const index = upper.indexOf(kind);
              if (index < 0) return { kind, qualified: null, detail: "Qualification not present in report" };
              const excerpt = upper.slice(index, index + 320);
              const notQualified = /NOT QUALIFIED|UNQUALIFIED|NOT\\s+CURRENT/.test(excerpt);
              const qualified = !notQualified && /\\bQUALIFIED\\b/.test(excerpt) ? true : (notQualified ? false : null);
              return { kind, qualified, detail: excerpt.slice(0, 180) };
            });
          };
          let controlsApplied = false;
          const run = () => {
            const bodyText = document.body ? document.body.innerText || "" : "";
            const upper = normalized(bodyText);
            if (upper.includes("SSO ERROR") || upper.includes("ERR-6ERR-4")) {
              post("sso_error", [], "The qualification portal requires American Airlines sign-in.");
              return;
            }
            const hasControls = upper.includes("INPUT CONTROLS") || upper.includes("QUALIFICATION TYPE");
            if (!hasControls) {
              post("waiting", [], "Sign in to the qualification portal; SmartLookApp will continue after the report loads.");
              return;
            }
            if (controlsApplied) {
              post("result", parseStates(bodyText), "Qualification status read from the live report.");
              return;
            }
            requested.forEach(kind => {
              const candidates = aliases(kind);
              selectOption(candidates);
              clickText(candidates);
            });
            selectOption([modelText + " RUN", normalized(aircraftModel) + " RUN", "B777 RUN"]);
            clickText(["APPLY"]);
            controlsApplied = true;
            const states = parseStates(document.body ? document.body.innerText || "" : "");
            post("scan", states, "Qualification report loaded; applying requested filters…");
            window.setTimeout(() => {
              clickText(["OK"]);
              const finalStates = parseStates(document.body ? document.body.innerText || "" : "");
              post("result", finalStates, "Qualification status read from the live report.");
            }, 4500);
          };
          run();
          window.setInterval(run, 7000);
        })();
        """
    }

    private static func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "null" }
        return string
    }
}

private struct QualificationStatusOverlay: View {
    let session: MVDSession
    let requirements: [MVDQualificationKind]
    @Environment(\.dismiss) private var dismiss
    @State private var results: [MVDQualificationResult] = []
    @State private var portalStatus = "Opening live Qualification Status report…"

    private var model: String { session.aircraft?.model ?? "B777-200" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE QUALIFICATION STATUS")
                        .font(.headline.weight(.black))
                    Text("Aircraft: \(model) • Nose: \(session.nose)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Requested: \(requirements.map(\.displayName).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { result in
                            HStack {
                                Text("USER \(result.kind.displayName)")
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                if result.qualified == true {
                                    Label("QUALIFIED", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if result.qualified == false {
                                    Label("NOT QUALIFIED", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                                } else {
                                    Label("NOT DETECTED", systemImage: "questionmark.circle.fill").foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }

                Text(portalStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(portalStatus.localizedCaseInsensitiveContains("requires") ? .orange : .secondary)

                QualificationStatusWebView(
                    session: session,
                    requirements: requirements,
                    onUpdate: { states, status in
                        results = states
                        portalStatus = status
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.blue.opacity(0.55)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("La contraseña se introduce únicamente en el portal y no se almacena en SmartLookApp.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .navigationTitle("Qualification Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

private struct QualificationStatusWebView: UIViewRepresentable {
    let session: MVDSession
    let requirements: [MVDQualificationKind]
    let onUpdate: ([MVDQualificationResult], String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUpdate: onUpdate) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "qualificationStatus")
        let script = WKUserScript(
            source: MVDQualificationPortal.automationScript(
                model: session.aircraft?.model ?? "B777-200",
                requirements: requirements.map(\.rawValue)
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: MVDQualificationPortal.reportURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onUpdate: ([MVDQualificationResult], String) -> Void

        init(onUpdate: @escaping ([MVDQualificationResult], String) -> Void) { self.onUpdate = onUpdate }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "qualificationStatus",
                  let body = message.body as? [String: Any] else { return }
            let status = body["status"] as? String ?? "Qualification report updated."
            let rawStates = body["states"] as? [[String: Any]] ?? []
            let parsed = rawStates.compactMap { state -> MVDQualificationResult? in
                guard let kindRaw = state["kind"] as? String,
                      let kind = MVDQualificationKind(rawValue: kindRaw.uppercased()) else { return nil }
                let qualified = state["qualified"] as? Bool
                return MVDQualificationResult(kind: kind, qualified: qualified, detail: state["detail"] as? String ?? "")
            }
            DispatchQueue.main.async { self.onUpdate(parsed, status) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let scheme = navigationAction.request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onUpdate([], "The portal requested an external application; it was blocked inside SmartLookApp.") }
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Audit

private struct AuditTrainingDetailView: View {
    let session: MVDSession
    @ObservedObject var store: MVDLocalStore
    let item: MVDAuditItem
    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    private var selectedRecordID: String {
        item.id.hasPrefix("AUDIT-") ? String(item.id.dropFirst("AUDIT-".count)) : item.id
    }

    private var records: [MVDTrainingPayload] {
        guard let selected = store.training.first(where: { $0.id == selectedRecordID }) else { return [] }
        let groupKey = mvdAuditGroupKey(selected)
        let grouped = store.training.filter { mvdAuditGroupKey($0) == groupKey }
        return grouped.isEmpty ? [selected] : grouped
    }

    private func documentEntries(for payload: MVDTrainingPayload) -> [(String, String)] {
        var entries: [(String, String)] = []
        func append(_ label: String, _ raw: String?) {
            let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let cleaned = value.replacingOccurrences(of: "\\&", with: "&")
            let actualLabel = URL(string: cleaned).map { mvdActualDocumentTitle($0, fallbackManual: label) } ?? label
            if !entries.contains(where: { $0.1 == value }) { entries.append((actualLabel, value)) }
        }
        let primary = payload.trainingProcedureLink.isEmpty ? payload.pinpointLink : payload.trainingProcedureLink
        append(payload.manualType.isEmpty ? "DOCUMENT" : payload.manualType, primary)
        append("RII WARNING", payload.riiLink)
        append("LMP WARNING", payload.lmpLink)
        append("EWIS WARNING", payload.ewisLink)
        append("ETOPS WARNING", payload.etopsLink)
        append("RVSM WARNING", payload.rvsmLink)
        append("AARD-200 WARNING", payload.aard200Link)
        append("AARD-300 WARNING", payload.aard300Link)
        append("GPM WARNING", payload.gpmLink)
        append("RELATED DOCUMENT", payload.checkLink)
        append("EO", payload.eoLink)
        append("AADR", payload.aadrLink)
        return entries
    }

    private func openDocument(_ raw: String) {
        let cleaned = raw.replacingOccurrences(of: "\\&", with: "&")
        guard let url = URL(string: cleaned) else { return }
        UIApplication.shared.open(url)
    }

    private func imageCandidates(for payload: MVDTrainingPayload, name: String) -> [URL] {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        var candidates: [URL] = []
        if normalized.hasPrefix("/") { candidates.append(URL(fileURLWithPath: normalized)) }
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        let bases = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        for base in bases {
            let roots = [
                base.appendingPathComponent("New Trainings", isDirectory: true),
                base.appendingPathComponent("TrainingData", isDirectory: true)
            ]
            for root in roots {
                let modelRoot = root
                    .appendingPathComponent(payload.customerCode.isEmpty ? "AA" : payload.customerCode, isDirectory: true)
                    .appendingPathComponent(payload.manufacturer, isDirectory: true)
                    .appendingPathComponent(payload.model, isDirectory: true)
                candidates.append(modelRoot.appendingPathComponent(payload.manualType, isDirectory: true).appendingPathComponent(normalized))
                candidates.append(modelRoot.appendingPathComponent(payload.manualType, isDirectory: true).appendingPathComponent(fileName))
                candidates.append(modelRoot.appendingPathComponent("SECURE_RESOURCES", isDirectory: true).appendingPathComponent(normalized))
                candidates.append(modelRoot.appendingPathComponent("SECURE_RESOURCES", isDirectory: true).appendingPathComponent(fileName))
                if !payload.cmmNumber.isEmpty {
                    let cmmRoot = modelRoot.appendingPathComponent("CMM", isDirectory: true)
                        .appendingPathComponent("cmm\(payload.cmmNumber)", isDirectory: true)
                    candidates.append(cmmRoot.appendingPathComponent(normalized))
                    candidates.append(cmmRoot.appendingPathComponent(fileName))
                }
            }
        }
        var unique: [URL] = []
        for url in candidates where !unique.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
            unique.append(url)
        }
        return unique
    }

    private func imageFor(payload: MVDTrainingPayload, name: String) -> UIImage? {
        imageCandidates(for: payload, name: name).compactMap { UIImage(contentsOfFile: $0.path) }.first
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.ucid).font(.caption.weight(.black)).foregroundStyle(.purple)
                        Text(item.title).font(.title3.weight(.bold))
                        Text("AUDIT TRAINING DETAIL").font(.caption.weight(.bold)).foregroundStyle(.green)
                    }
                    .card()

                    if let primary = records.first {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("HEADER").sectionTitle()
                            valueRow("NOSE", primary.aircraftNose)
                            valueRow("TRAINER ID", primary.trainerID ?? session.employeeID)
                            valueRow("FLEET", primary.customerCode.isEmpty ? "AA" : primary.customerCode)
                            valueRow("MODEL", primary.model)
                            valueRow("MANUFACTURER", primary.manufacturer)
                            valueRow("MANUALS", records.map { $0.manualType }.joined(separator: ", "))
                            if !primary.cmmNumber.isEmpty { valueRow("CMM", primary.cmmNumber) }
                            if !(primary.cmmLocation ?? "").isEmpty { valueRow("CMM LOCATION", primary.cmmLocation ?? "") }
                        }
                        .card()

                        if !primary.imageFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TRAINING PHOTOS").sectionTitle()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(primary.imageFiles, id: \.self) { name in
                                            if let image = imageFor(payload: primary, name: name) {
                                                Image(uiImage: image).resizable().scaledToFill().frame(width: 118, height: 88).clipped().cornerRadius(8)
                                            } else {
                                                VStack { Image(systemName: "photo"); Text(name).font(.caption2).lineLimit(2) }
                                                    .frame(width: 118, height: 88).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .card()
                        }

                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            VStack(alignment: .leading, spacing: 7) {
                                Text("DOCUMENT • \(record.manualType)").sectionTitle()
                                valueRow("ATA", [record.ataChapter, record.subAta].filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: "-"))
                                valueRow("PART / ITEM", record.partName.isEmpty ? record.item : record.partName)
                                valueRow("PAGE", record.pageNumber)
                                valueRow("APPLICABILITY", [record.faultCode, record.eicasMessage, record.eicasLevel].filter { !$0.isEmpty }.joined(separator: " • "))
                                if !record.description.isEmpty { Text(record.description).font(.caption).foregroundStyle(.secondary) }
                                ForEach(Array(documentEntries(for: record).enumerated()), id: \.offset) { _, entry in
                                    Button { openDocument(entry.1) } label: {
                                        HStack {
                                            Image(systemName: entry.0.contains("WARNING") ? "exclamationmark.triangle.fill" : "doc.text.fill")
                                            Text(entry.0).font(.subheadline.weight(.bold))
                                            Spacer()
                                            Image(systemName: "arrow.up.right.square")
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(entry.0.contains("WARNING") ? .orange : .green)
                                }
                            }
                            .card()
                        }
                    } else {
                        Text("The selected audit record is no longer present in the local training index.")
                            .font(.caption).foregroundStyle(.secondary).card()
                    }
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
            .background(MVDTheme.background.ignoresSafeArea())
            .navigationTitle("AUDIT DETAIL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("CLOSE") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if records.first != nil { Button("EDIT") { showEditor = true } }
                }
            }
            .sheet(isPresented: $showEditor) {
                if let primary = records.first {
                    TrainingView(session: session, store: store, editingPayload: primary)
                }
            }
        }
    }
}

struct AuditView: View {
    let session: MVDSession
    @ObservedObject var store: MVDLocalStore
    @State private var client = "AA"
    @State private var selectedItem: MVDAuditItem?

    var body: some View {
        List {
            Section {
                HStack { Text("AUDIT CHECKLIST").font(.headline.weight(.black)); Spacer(); Picker("Client", selection: $client) { Text("AA").tag("AA") }.labelsHidden() }
            }
            Section("INDEX • PART NAME • DONE") {
                if store.isPreparing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("LOADING AUDIT FROM PRIVATE TRAINING…").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                } else if store.audit.isEmpty {
                    Text("No AMM, AIPC, WDM or CMM training records found on this iPad.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.audit.filter { $0.originClient.uppercased() == client }) { item in
                        HStack(spacing: 8) {
                            Button { selectedItem = item } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.ucid).font(.caption.weight(.bold)).foregroundStyle(.purple)
                                    Text(item.title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            Button { store.toggleAudit(id: item.id) } label: {
                                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.isDone ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section { Text("Selected aircraft: \(session.nose) • \(session.aircraft?.model ?? "B777-300")").font(.caption).foregroundStyle(.secondary) }
        }
        .scrollContentBackground(.hidden)
        .background(MVDTheme.background.ignoresSafeArea())
        .sheet(item: $selectedItem) { item in
            AuditTrainingDetailView(session: session, store: store, item: item)
        }
    }
}

private extension View {
    func card() -> some View { self.padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
    func sectionTitle() -> some View { self.font(.caption.weight(.bold)).foregroundStyle(.secondary) }
}

private enum MVDTheme {
    /// Dark graphite/metal treatment matching the Android v12.2 visual language.
    static let background = LinearGradient(
        colors: [
            Color(red: 0.19, green: 0.21, blue: 0.23),
            Color(red: 0.10, green: 0.12, blue: 0.14),
            Color(red: 0.16, green: 0.17, blue: 0.18),
            Color(red: 0.07, green: 0.08, blue: 0.09)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
