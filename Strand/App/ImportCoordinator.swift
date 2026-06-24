import Foundation
import WhoopStore
import StrandImport
import StrandAnalytics

/// Coordinates all data source imports: WHOOP CSV, Apple Health, Xiaomi/Mi Band.
/// Handles file materialization, security-scoped resource access, and import state.
@MainActor
final class ImportCoordinator: ObservableObject {
    // MARK: - Published State
    
    @Published private(set) var activeImportSource: DataSourceImportKind?
    @Published var whoopImportSummary: String?
    @Published var appleHealthImportSummary: String?
    @Published var xiaomiImportSummary: String?
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false
    
    var hasActiveImport: Bool { activeImportSource != nil }
    
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }
    
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }
    
    // MARK: - Dependencies
    
    private let repo: Repository
    private let deviceId: String
    private let appleDeviceId: String
    private let log: (String) -> Void
    
    // MARK: - Init
    
    init(repo: Repository, deviceId: String, appleDeviceId: String, log: @escaping (String) -> Void) {
        self.repo = repo
        self.deviceId = deviceId
        self.appleDeviceId = appleDeviceId
        self.log = log
    }
    
    // MARK: - Public API
    
    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                let summary = try await WhoopImporter.importExport(url: local.url, into: store, deviceId: deviceId)
                try? await store.checkpointWAL()
                await repo.refresh()
                let span = formatSpan(earliest: summary.earliest, latest: summary.latest)
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }
    
    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        // Run at .utility priority so large imports don't block UI
        Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store, deviceId: appleDeviceId)
                try? await store.checkpointWAL()
                await repo.refresh()
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }
    
    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.xiaomi, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store)
                try? await store.checkpointWAL()
                await repo.refresh()
                let span = formatSpan(earliest: summary.earliest, latest: summary.latest)
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                finishImport(.xiaomi, summary: "Imported \(days) days · \(sleeps) sleeps\(span)")
            } catch {
                finishImport(.xiaomi, summary: "Import failed: \(error)", failed: true)
            }
        }
    }
    
    // MARK: - Internal
    
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        // Clear previous summary for this source
        switch source {
        case .whoop: whoopImportSummary = nil; whoopImportFailed = false
        case .appleHealth: appleHealthImportSummary = nil; appleHealthImportFailed = false
        case .xiaomi: xiaomiImportSummary = nil; xiaomiImportFailed = false
        }
        log("Import started: \(source)")
    }
    
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        activeImportSource = nil
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        log("Import finished: \(source) - \(summary)")
    }
    
    private func formatSpan(earliest: Date?, latest: Date?) -> String {
        guard let a = earliest, let b = latest else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return " · \(f.string(from: a))–\(f.string(from: b))"
    }
    
    // MARK: - File Materialization (iOS security-scoped resource handling)
    
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        private let inboxOriginal: URL?
        
        init(url: URL, temp: URL?, inboxOriginal: URL? = nil) {
            self.url = url; self.temp = temp; self.inboxOriginal = inboxOriginal
        }
        
        func cleanup() {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let inboxOriginal, Self.isInImportInbox(inboxOriginal) {
                try? FileManager.default.removeItem(at: inboxOriginal)
            }
        }
        
        static func isInImportInbox(_ url: URL) -> Bool {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let inbox = docs.appendingPathComponent("Inbox").standardizedFileURL.path
            let candidate = url.standardizedFileURL.path
            return candidate.hasPrefix(inbox + "/")
        }
    }
    
    nonisolated static func materializeForImport(_ picked: URL) async throws -> ImportFile {
        #if os(iOS)
        let ext = picked.pathExtension.isEmpty ? "dat" : picked.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        var coordError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(readingItemAt: picked, options: [.forUploading], error: &coordError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
            } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        return ImportFile(url: dst, temp: dst, inboxOriginal: picked)
        #else
        return ImportFile(url: picked, temp: nil)
        #endif
    }
}