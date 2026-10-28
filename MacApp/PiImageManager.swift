import AppKit
import SwiftUI
import CryptoKit
import Darwin

struct StagedImage: Identifiable, Hashable {
    let name: String
    let bytes: Int64
    let modified: String
    var id: String { name }
    var display: String {
        "\(name)  •  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))  •  \(modified)"
    }
}

struct PiProfile: Codable, Identifiable {
    var id: String
    var name: String
    var host: String
    var user: String
    var folder: String
    var journal: Bool
    var apt: Bool
    var userCache: Bool
    var downloads: Bool
    var customPaths: String
}

struct ExclusionPreview: Identifiable {
    let path: String
    let bytes: Int64
    let status: String
    var id: String { path }
}

@MainActor
final class BackupManager: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "raspberrypi.local"
    @Published var user = UserDefaults.standard.string(forKey: "user") ?? "pi"
    @Published var localFolder = UserDefaults.standard.string(forKey: "localFolder") ?? (NSHomeDirectory() + "/PiBackups")
    @Published var profileName = "My Raspberry Pi"
    @Published var profiles: [PiProfile] = []
    @Published var selectedProfileID = ""
    @Published var excludeJournal = true
    @Published var excludeApt = false
    @Published var excludeUserCache = false
    @Published var excludeDownloads = false
    @Published var customPaths = ""
    @Published var previewSummary = "Click Preview Backup to estimate what will be archived."
    @Published var previewRows: [ExclusionPreview] = []
    @Published var previewWarnings: [String] = []
    @Published var helperVersion = "Not checked"
    @Published var browseDirectory = "/home"
    @Published var browseResults: [String] = []
    private var loadingProfile = false
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var space = "—"
    @Published var progress: Double = 0
    @Published var transferProgress = ""
    @Published var staged: [StagedImage] = []
    @Published var selectedStaged = ""
    @Published var selectedArchive = ""
    @Published var log = "Pi Image Manager v0.2.2 — responsive layout, backup naming, Pi profiles, exclusions and backup preview.\n"
    @Published var lastError: String? = nil
    // Direct-stream telemetry. Percent completion is intentionally NOT invented:
    // the final size of a compressed tar stream cannot be known in advance.
    @Published var streamVisible = false
    @Published var streamStarted: Date? = nil
    @Published var rootPhase = "Pending"
    @Published var bootPhase = "Pending"
    @Published var verifyPhase = "Pending"
    @Published var conversionPhase = "Not requested"
    @Published var rootBytes: Int64 = 0
    @Published var bootBytes: Int64 = 0
    @Published var rootRate: Int64 = 0
    @Published var bootRate: Int64 = 0
    @Published var rootSeconds = 0
    @Published var bootSeconds = 0
    @Published var streamPhase = "Idle"
    @Published var rootExpected: Int64 = 0
    @Published var bootExpected: Int64 = 0
    @Published var rootProcessed: Int64 = 0
    @Published var bootProcessed: Int64 = 0
    @Published var abortRequested = false
    @Published var abortAvailable = false
    // Retained while streaming, so Abort targets only the process started by this app.
    private var activeStreamProcess: Process? = nil

    var estimatedFraction: Double? {
        // Stage-weighted estimate: root 0–90%, boot 90–97%, verification
        // 97–100%. Never display 100% while a stage is still running.
        guard rootExpected > 0, bootExpected > 0 else { return nil }
        if verifyPhase == "Complete" { return 1 }
        if verifyPhase == "In progress" { return 0.97 }
        if rootPhase != "Complete" {
            let fraction = min(0.999, Double(max(0, rootProcessed)) / Double(rootExpected))
            return max(0, 0.90 * fraction)
        }
        if bootPhase != "Complete" {
            let fraction = min(0.999, Double(max(0, bootProcessed)) / Double(bootExpected))
            return 0.90 + 0.07 * max(0, fraction)
        }
        return 0.97
    }
    var estimatedRemaining: String {
        guard rootExpected > 0, bootExpected > 0 else { return "Estimating source size…" }
        if conversionPhase == "In progress" { return "Archive complete · image conversion running (ETA unavailable)" }
        if verifyPhase == "In progress" { return "Archive transfer complete · verifying checksums…" }
        if verifyPhase == "Complete" { return "Archive transfer and verification complete" }
        if rootPhase == "Complete" && bootPhase == "Complete" { return "Finishing transfer · preparing verification…" }
        let processed = min(max(0, rootProcessed), rootExpected) + min(max(0, bootProcessed), bootExpected)
        let elapsed = rootSeconds + bootSeconds
        // An ETA is meaningful only after multiple samples of source data.
        guard processed > 20 * 1024 * 1024, elapsed >= 8 else { return "Calibrating ETA…" }
        let rate = Double(processed) / Double(elapsed)
        guard rate > 0 else { return "Calibrating ETA…" }
        let remaining = Double(max(0, rootExpected + bootExpected - processed)) / rate
        if !remaining.isFinite { return "ETA unavailable" }
        // du's size is an estimate, and the final files/metadata may take
        // substantially longer: do not claim 00:00 while still streaming.
        if remaining < 20 { return "Finishing archive stream · ETA uncertain (verification extra)" }
        return "About " + prettyTime(Int(min(remaining, 86_400 * 7))) + " remaining · streaming only; verification extra"
    }
    private func streamCompleteCleanup() {
        activeStreamProcess = nil
        abortAvailable = false
        abortRequested = false
    }
    func abortStream() {
        guard busy, abortAvailable, !abortRequested, let process = activeStreamProcess else { return }
        abortRequested = true
        streamPhase = "Aborting backup…"
        status = "Stopping SSH transfer and removing incomplete archive…"
        addLog("Abort requested by user. Stopping SSH and cleaning incomplete Mac backup.")
        if process.isRunning { process.terminate() }
    }

    func prettyBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
    func prettyRate(_ bytesPerSecond: Int64) -> String {
        prettyBytes(bytesPerSecond) + "/s"
    }
    func prettyTime(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600
        let m = (max(0, seconds) % 3600) / 60
        let s = max(0, seconds) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
    private func resetStreamTelemetry(convert: Bool) {
        streamVisible = true
        streamStarted = Date()
        rootPhase = "Pending"; bootPhase = "Pending"
        verifyPhase = "Pending"
        conversionPhase = convert ? "Pending" : "Not requested"
        rootBytes = 0; bootBytes = 0
        rootRate = 0; bootRate = 0
        rootSeconds = 0; bootSeconds = 0
        streamPhase = "Connecting"
        rootExpected = 0; bootExpected = 0
        rootProcessed = 0; bootProcessed = 0
        abortRequested = false
        abortAvailable = false
    }
    // Called on the main queue, from the stdout line reader. Telemetry is
    // separate from human-readable log output to avoid thousands of log lines.
    private func consumeProgress(_ line: String) -> Bool {
        // GNU tar emits source checkpoints on SSH stderr; unlike gzip byte counts,
        // these approximate how much uncompressed tar data has been processed.
        if let marker = line.range(of: "PIIM_SOURCE|") {
            let suffix = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int64(suffix), number >= 0, number <= Int64.max / 10_240 {
                // GNU tar %u is the cumulative archive *record* number,
                // not the number of 512-record checkpoint intervals. GNU tar's
                // default record is 20 blocks × 512 bytes = 10,240 bytes.
                // First checkpoint: %u=512 -> 5 MiB, NOT 2.5 GiB.
                let sourceBytes = number * 10_240
                if rootPhase == "In progress" {
                    rootProcessed = max(rootProcessed, sourceBytes)
                } else if bootPhase == "In progress" {
                    bootProcessed = max(bootProcessed, sourceBytes)
                }
            }
            return true
        }
        guard line.hasPrefix("PIIM|") else { return false }
        let fields = line.components(separatedBy: "|")
        guard fields.count >= 4 else { return true }
        if fields[1] == "ESTIMATE", fields.count == 4,
           let root = Int64(fields[2]), let boot = Int64(fields[3]), root > 0, boot > 0 {
            rootExpected = root
            bootExpected = boot
            streamPhase = "Estimated source sizes received"
        } else if fields[1] == "TRANSFER", fields.count == 6,
           let bytes = Int64(fields[3]), let rate = Int64(fields[4]),
           let elapsed = Int(fields[5]), bytes >= 0, rate >= 0, elapsed >= 0 {
            switch fields[2] {
            case "root":
                rootBytes = bytes; rootRate = rate; rootSeconds = elapsed
            case "boot":
                bootBytes = bytes; bootRate = rate; bootSeconds = elapsed
            default: break
            }
        } else if fields[1] == "PHASE", fields.count == 4 {
            let phase = fields[2], state = fields[3]
            let title = state == "running" ? "In progress" :
                        state == "done" ? "Complete" : "Failed"
            switch phase {
            case "layout":
                streamPhase = state == "running" ? "Reading disk layout" : "Disk layout saved"
            case "root":
                rootPhase = title
                if state == "done" { rootProcessed = rootExpected }
                streamPhase = state == "running" ? "Streaming root filesystem" : "Root filesystem saved"
            case "boot":
                bootPhase = title
                if state == "done" { bootProcessed = bootExpected }
                streamPhase = state == "running" ? "Streaming boot filesystem" : "Boot filesystem saved"
            case "verify":
                abortAvailable = false // Stream finished; checksums cannot be interrupted safely here.
                verifyPhase = title
                streamPhase = state == "running" ? "Verifying archives" : "Archives verified"
            case "conversion":
                conversionPhase = title
                streamPhase = state == "running" ? "Building disk image on Mac" : "Image conversion complete"
            case "complete":
                streamPhase = "Backup complete"
            default: break
            }
            if phase != "layout" { addLog("[Status] \(phase): \(title)") }
        }
        return true
    }
    private func processTextOutput(_ chunk: String, pending: inout String,
                                   completeLog: inout String) {
        pending += chunk
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .newlines)
            pending.removeSubrange(...newline)
            completeLog += line + "\n"
            if completeLog.count > 20_000 { completeLog = String(completeLog.suffix(15_000)) }
            if !consumeProgress(line) { addLog(line) }
        }
    }

    private var profilesFile: URL {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PiImageManager", isDirectory: true)
        return parent.appendingPathComponent("profiles.json")
    }
    init() {
        if let data = try? Data(contentsOf: profilesFile),
           let stored = try? JSONDecoder().decode([PiProfile].self, from: data), !stored.isEmpty {
            profiles = stored
        } else {
            profiles = [PiProfile(id: UUID().uuidString, name: "My Raspberry Pi",
                    host: host, user: user, folder: localFolder,
                    journal: true, apt: false, userCache: false,
                    downloads: false, customPaths: "")]
        }
        if let selected = profiles.first { loadProfile(selected.id) }
        try? FileManager.default.createDirectory(atPath: localFolder, withIntermediateDirectories: true)
    }
    func loadProfile(_ id: String) {
        guard !busy, let profile = profiles.first(where: { $0.id == id }) else { return }
        loadingProfile = true
        selectedProfileID = id
        profileName = profile.name
        host = profile.host; user = profile.user; localFolder = profile.folder
        excludeJournal = profile.journal; excludeApt = profile.apt
        excludeUserCache = profile.userCache; excludeDownloads = profile.downloads
        customPaths = profile.customPaths
        previewRows = []
        previewWarnings = []
        previewSummary = "Click Preview Backup to calculate exclusions."
        loadingProfile = false
    }
    func saveSettings() {
        guard !loadingProfile else { return }
        if let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
            profiles[index] = PiProfile(id: selectedProfileID, name: profileName,
                host: host, user: user, folder: localFolder,
                journal: excludeJournal, apt: excludeApt, userCache: excludeUserCache,
                downloads: excludeDownloads, customPaths: customPaths)
        }
        do {
            try FileManager.default.createDirectory(at: profilesFile.deletingLastPathComponent(),
                         withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profilesFile, options: .atomic)
        } catch { lastError = "Cannot save backup profiles: \(error.localizedDescription)" }
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(user, forKey: "user")
        UserDefaults.standard.set(localFolder, forKey: "localFolder")
    }
    func newProfile() {
        guard !busy else { return }
        saveSettings()
        let fresh = PiProfile(id: UUID().uuidString, name: "New Raspberry Pi", host: "raspberrypi.local",
             user: "pi", folder: NSHomeDirectory() + "/PiBackups", journal: true,
             apt: false, userCache: false, downloads: false, customPaths: "")
        profiles.append(fresh); loadProfile(fresh.id); saveSettings()
    }
    func deleteProfile() {
        guard !busy, profiles.count > 1 else { return }
        profiles.removeAll(where: { $0.id == selectedProfileID })
        if let first = profiles.first { loadProfile(first.id) }
        saveSettings()
    }
    func addExclusion(_ path: String) {
        guard !busy else { return }
        let existing = Set(customPaths.split(separator: "\n").map(String.init))
        if !existing.contains(path) {
            if !customPaths.isEmpty && !customPaths.hasSuffix("\n") { customPaths += "\n" }
            customPaths += path
            saveSettings()
        }
    }
    private func presetCSV() -> String {
        var keys: [String] = []
        if excludeJournal { keys.append("journal") }
        if excludeApt { keys.append("apt") }
        if excludeUserCache { keys.append("usercache") }
        if excludeDownloads { keys.append("downloads") }
        return keys.isEmpty ? "-" : keys.joined(separator: ",")
    }
    private func encodedExclusions() -> String {
        let paths = customPaths.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                               .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return "-" }
        return Data(paths.joined(separator: "\n").utf8).base64EncodedString()
    }
    func previewBackup() {
        guard !busy && valid() else { return }
        busy = true
        status = "Previewing backup on Pi…"
        runText(["preview", presetCSV(), encodedExclusions()], label: "Preview Backup") { code, text in
            guard code == 0 else { self.failure("Cannot preview exclusions. Check the paths and activity log."); return }
            var items: [ExclusionPreview] = []
            var warnings: [String] = []
            var rootSize: Int64 = 0, bootSize: Int64 = 0
            for line in text.components(separatedBy: .newlines) {
                let cols = line.components(separatedBy: "|")
                if cols.count == 3, cols[0] == "ESTIMATE" {
                    rootSize = Int64(cols[1]) ?? 0; bootSize = Int64(cols[2]) ?? 0
                } else if cols.count == 4, cols[0] == "EXCLUDE" {
                    items.append(ExclusionPreview(path: cols[1], bytes: Int64(cols[2]) ?? 0, status: cols[3]))
                } else if cols.count == 3, cols[0] == "WARN" {
                    warnings.append("\(cols[1]): \(cols[2])")
                }
            }
            self.previewRows = items
            self.previewWarnings = warnings
            self.previewSummary = "Estimated uncompressed archive work: \(self.prettyBytes(rootSize + bootSize)) (root \(self.prettyBytes(rootSize)), boot \(self.prettyBytes(bootSize))). Compressed size may differ."
            self.status = "Backup preview ready"
            self.busy = false
        }
    }
    func browsePi() {
        guard !busy && valid() else { return }
        busy = true
        runText(["browse", browseDirectory], label: "Browsing Pi directories") { code, result in
            guard code == 0 else { self.failure("Cannot browse this directory; try /home or /opt."); return }
            self.browseResults = result.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("DIR|") }.map { String($0.dropFirst(4)) }
            self.busy = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a local folder where your Mac should save Raspberry Pi images"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            localFolder = url.path
            saveSettings()
        }
    }
    func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: localFolder, isDirectory: true))
    }
    private func addLog(_ text: String, newline: Bool = true) {
        log += text + (newline ? "\n" : "")
        if log.count > 75_000 { log = String(log.suffix(60_000)) }
    }
    private func failure(_ message: String) {
        lastError = message
        status = "Operation failed"
        busy = false
        progress = 0
        transferProgress = ""
        if streamVisible {
            streamPhase = "Failed"
            if rootPhase == "In progress" { rootPhase = "Failed" }
            if bootPhase == "In progress" { bootPhase = "Failed" }
            if verifyPhase == "In progress" { verifyPhase = "Failed" }
            if conversionPhase == "In progress" { conversionPhase = "Failed" }
        }
        addLog("ERROR: " + message)
    }
    private func valid() -> Bool {
        let hostPattern = "^[A-Za-z0-9][A-Za-z0-9.-]*$"
        let userPattern = "^[A-Za-z_][A-Za-z0-9_.-]*$"
        guard host.range(of: hostPattern, options: .regularExpression) != nil,
              user.range(of: userPattern, options: .regularExpression) != nil else {
            lastError = "Enter a valid Pi hostname/IP and SSH username."
            return false
        }
        guard FileManager.default.fileExists(atPath: localFolder) else {
            lastError = "Choose an existing local Mac backup folder (or create ~/PiBackups)."
            return false
        }
        guard FileManager.default.isWritableFile(atPath: localFolder) else {
            lastError = "The Mac backup folder is not writable."
            return false
        }
        saveSettings()
        return true
    }
    private func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private func sshArguments(_ parts: [String]) -> [String] {
        let command = (["sudo", "-n", "/usr/local/sbin/pi-image-helper"] + parts).map(quote).joined(separator: " ")
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=3", "--", "\(user)@\(host)", command]
    }
    // Text commands only. Image data is handled by a separate binary-safe download routine.
    private func runText(_ parts: [String], label: String, finished: @escaping (Int32, String) -> Void) {
        addLog("===== \(label) =====")
        let args = sshArguments(parts)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = args
            let outputPipe = Pipe()
            proc.standardOutput = outputPipe
            proc.standardError = outputPipe
            do {
                try proc.run()
                var collected = ""
                while true {
                    // availableData wakes when status text arrives; readData(ofLength:)
                    // can wait to fill a large buffer, hiding progress until EOF.
                    let data = outputPipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    let s = String(decoding: data, as: UTF8.self)
                    collected += s
                    if collected.count > 500_000 { collected = String(collected.suffix(350_000)) }
                    DispatchQueue.main.async { self.addLog(s, newline: false) }
                }
                proc.waitUntilExit()
                let result = proc.terminationStatus
                DispatchQueue.main.async { finished(result, collected) }
            } catch {
                DispatchQueue.main.async {
                    self.addLog("ERROR launching SSH: \(error.localizedDescription)")
                    finished(-1, error.localizedDescription)
                }
            }
        }
    }
    func checkConnection() {
        guard !busy && valid() else { return }
        busy = true
        status = "Connecting to Pi…"
        runText(["status"], label: "Checking Pi connection") { code, response in
            let statusLine = response.components(separatedBy: .newlines).first(where: { $0.hasPrefix("STATUS|") })
            let fields = statusLine?.components(separatedBy: "|") ?? []
            guard code == 0, fields.count >= 7, fields[1] == "ready", fields[6] == "0.2.0" else {
                self.failure("Could not connect to the Pi helper. Install the new helper and verify SSH keys. See log.")
                return
            }
            self.status = "Connected to \(fields[2])"
            self.space = "Pi staging: \(fields[3]) MiB free (root used: \(fields[4]) MiB; device: \(fields[5]))"
            self.helperVersion = fields.count >= 7 ? fields[6] : "Legacy helper (upgrade required)"
            self.busy = false
        }
    }
    func refreshStaged() {
        guard !busy && valid() else { return }
        busy = true
        status = "Checking Pi staging area…"
        runText(["list"], label: "Listing staged images") { code, result in
            guard code == 0 else { self.failure("Cannot list staged images. See log."); return }
            self.staged = result.components(separatedBy: .newlines).compactMap { line in
                let x = line.components(separatedBy: "|")
                guard x.count == 4, x[0] == "STAGED", let bytes = Int64(x[2]) else { return nil }
                return StagedImage(name: x[1], bytes: bytes, modified: x[3])
            }
            if !self.staged.contains(where: { $0.name == self.selectedStaged }) {
                self.selectedStaged = self.staged.first?.name ?? ""
            }
            self.status = "\(self.staged.count) image(s) staged on Pi"
            self.busy = false
        }
    }
    func createImage(filename: String) {
        guard !busy && valid() else { return }
        guard Self.validImageFilename(filename) else {
            lastError = "Invalid image filename. Use letters, digits, dot, dash or underscore, ending in .img."
            return
        }
        // Do not overwrite a completed or partially downloaded local backup.
        let path = (localFolder as NSString).appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: path + ".partial") else {
            lastError = "The backup filename already exists. Try again after a moment."
            return
        }
        busy = true
        streamVisible = false
        progress = 0
        status = "Building image on Pi…"
        runText(["create", filename, "0", presetCSV(), encodedExclusions()], label: "Creating full live Pi image") { code, reply in
            guard code == 0, reply.contains("STAGED_OK|\(filename)|") else {
                self.failure("Pi image creation or filesystem verification failed. Check the log. Any staged image will remain on the Pi for inspection.")
                return
            }
            self.downloadImage(filename)
        }
    }
    static func validBackupBase(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 96, !name.contains(".."), !name.hasPrefix(".") else { return false }
        return name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
    static func validImageFilename(_ name: String) -> Bool {
        guard name.count <= 120, !name.contains(".."), name.hasSuffix(".img") else { return false }
        return name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.img$", options: .regularExpression) != nil
    }
    func suggestedBackupBase() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeHost = host.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return "\(safeHost)-\(formatter.string(from: Date()))"
    }
    func createStreamedArchive(andBuildImage: Bool = false, folderBase: String, imageFilename: String? = nil) {
        guard !busy && valid() else { return }
        guard Self.validBackupBase(folderBase),
              (!andBuildImage || (imageFilename.map(Self.validImageFilename) ?? false)) else {
            lastError = "Enter a valid recovery folder name and .img filename."
            return
        }
        // A streamed recovery archive is not a flashable .img. No Pi staging needed.
        busy = true
        progress = 0
        resetStreamTelemetry(convert: andBuildImage)
        status = "Streaming system archive directly to Mac…"
        addLog("===== Streaming backup (no image staging on Pi) =====")
        let bundleScript = Bundle.main.resourceURL?.appendingPathComponent("stream-backup.sh")
        guard let script = bundleScript, FileManager.default.isExecutableFile(atPath: script.path) else {
            failure("Missing stream-backup.sh in app bundle; rebuild from v0.2.2 sources.")
            return
        }
        let args = [host, user, localFolder, presetCSV(), encodedExclusions(), folderBase]
        let process = Process()
        activeStreamProcess = process
        DispatchQueue.global(qos: .userInitiated).async {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                DispatchQueue.main.async {
                    self.abortAvailable = true
                    if self.abortRequested, process.isRunning { process.terminate() }
                }
                var lines = ""
                var pending = ""
                while true {
                    // Read each available status chunk immediately rather than waiting
                    // for a 16 KB buffer or process completion.
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    let string = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.sync { self.processTextOutput(string, pending: &pending, completeLog: &lines) }
                }
                if !pending.isEmpty {
                    DispatchQueue.main.sync {
                        lines += pending
                        if !self.consumeProgress(pending) { self.addLog(pending) }
                    }
                }
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    let wasAborted = self.abortRequested
                    self.streamCompleteCleanup()
                    if wasAborted && status != 0 {
                        self.status = "Backup aborted"
                        self.streamPhase = "Aborted"
                        if self.rootPhase == "In progress" { self.rootPhase = "Aborted" }
                        if self.bootPhase == "In progress" { self.bootPhase = "Aborted" }
                        self.busy = false
                        self.addLog("Backup aborted. Incomplete Mac archive removed; completed backups unchanged.")
                        return
                    }
                    if status == 0 {
                        let line = lines.components(separatedBy: .newlines).first(where: { $0.hasPrefix("SUCCESS: ") })
                        let savedPath = line.map { String($0.dropFirst(9)) } ?? ""
                        guard FileManager.default.fileExists(atPath: savedPath) else {
                            self.failure("Archive succeeded but its saved directory could not be found.")
                            return
                        }
                        self.selectedArchive = savedPath
                        self.addLog("Archive saved at \(savedPath).")
                        if andBuildImage {
                            self.startConversion(savedPath, fromStream: true, imageFilename: imageFilename)
                        } else {
                            self.status = "Recovery archive saved on Mac"
                            self.streamPhase = "Backup complete"
                            self.busy = false
                            self.addLog("Use 'Create .img from Archive' to reconstruct a flashable disk image.")
                        }
                    } else {
                        self.failure("Streaming backup failed (exit \(status)). See log. No Pi staging file was created.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.streamCompleteCleanup()
                    self.failure("Cannot launch streaming backup: \(error.localizedDescription)")
                }
            }
        }
    }
    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.message = "Select a Pi Image Manager -recovery folder within your backup destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: localFolder, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            selectedArchive = url.path
        }
    }
    func convertSelectedArchive(imageFilename: String) {
        guard !busy && valid() else { return }
        guard Self.validImageFilename(imageFilename) else {
            lastError = "Enter a valid image filename ending in .img."
            return
        }
        guard !selectedArchive.isEmpty else {
            lastError = "Choose an existing -recovery archive folder first."
            return
        }
        busy = true
        startConversion(selectedArchive, imageFilename: imageFilename)
    }
    private func startConversion(_ path: String, fromStream: Bool = false, imageFilename: String? = nil) {
        progress = 0
        if !fromStream { resetStreamTelemetry(convert: true) }
        conversionPhase = "In progress"
        streamPhase = "Building disk image on Mac"
        status = "Converting archive to .img using Linux VM on Mac…"
        addLog("===== Reconstructing a bootable .img on Mac =====")
        guard let resources = Bundle.main.resourceURL else {
            failure("Cannot locate application resources.")
            return
        }
        let launcher = resources.appendingPathComponent("build-image-mac.sh")
        let guestScript = resources.appendingPathComponent("guest-build-image.sh")
        guard FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.fileExists(atPath: guestScript.path) else {
            failure("Missing image conversion scripts; rebuild the v0.2.2 app.")
            return
        }
        let args = [launcher.path, path, localFolder, guestScript.path] + (imageFilename.map { [$0] } ?? [])
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                var response = ""
                var pending = ""
                while true {
                    // Read each available status chunk immediately rather than waiting
                    // for a 16 KB buffer or process completion.
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    let chunk = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.sync { self.processTextOutput(chunk, pending: &pending, completeLog: &response) }
                }
                if !pending.isEmpty {
                    DispatchQueue.main.sync {
                        response += pending
                        if !self.consumeProgress(pending) { self.addLog(pending) }
                    }
                }
                proc.waitUntilExit()
                let code = proc.terminationStatus
                DispatchQueue.main.async {
                    if code == 0, response.contains("SUCCESS: Bootable image candidate saved at ") {
                        self.status = "Reconstructed .img saved on Mac"
                        self.conversionPhase = "Complete"
                        self.streamPhase = "Backup complete"
                        self.busy = false
                        self.addLog("Verify by flashing a spare SD card or SSD and booting the Pi.")
                    } else {
                        self.failure("Archive-to-image conversion failed (exit \(code)). See the activity log. Original archives are unchanged.")
                    }
                }
            } catch {
                DispatchQueue.main.async { self.failure("Cannot launch image builder: \(error.localizedDescription)") }
            }
        }
    }
    func transferSelected() {
        guard !busy && valid() && !selectedStaged.isEmpty else { return }
        busy = true
        streamVisible = false
        downloadImage(selectedStaged)
    }
    private func downloadImage(_ name: String) {
        status = "Verifying staged image…"
        runText(["meta", name], label: "Filesystem verification and SHA-256 on Pi") { code, response in
            let metaLine = response.components(separatedBy: .newlines).first(where: { $0.hasPrefix("META|") })
            let x = metaLine?.components(separatedBy: "|") ?? []
            guard code == 0, x.count == 4, x[1] == name,
                  let size = Int64(x[2]), size > 0,
                  x[3].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                self.failure("Image filesystem check or checksum calculation failed. The staged file was retained on the Pi.")
                return
            }
            self.pullBinary(name: name, expectedSize: size, expectedSHA: x[3])
        }
    }
    private func pullBinary(name: String, expectedSize: Int64, expectedSHA: String) {
        let folder = localFolder
        let args = sshArguments(["send", name])
        let finalURL = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name)
        let partialURL = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name + ".partial")
        status = "Downloading to Mac…"
        progress = 0
        addLog("Transferring \(ByteCountFormatter.string(fromByteCount: expectedSize, countStyle: .file)) over SSH to \(finalURL.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            var transferred: Int64 = 0
            let fm = FileManager.default
            var fd: Int32 = -1
            var ownsPartial = false
            do {
                guard !fm.fileExists(atPath: finalURL.path), !fm.fileExists(atPath: partialURL.path) else {
                    throw NSError(domain: "PiImageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "A local file with this name already exists. Nothing was overwritten."])
                }
                let attrs = try fm.attributesOfFileSystem(forPath: folder)
                let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > expectedSize + 512 * 1024 * 1024 else {
                    throw NSError(domain: "PiImageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not enough space on the Mac destination drive (512 MiB safety reserve required)."])
                }
                fd = open(partialURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard fd >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
                ownsPartial = true
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = args
                let stdout = Pipe()
                let stderr = Pipe()
                proc.standardOutput = stdout
                proc.standardError = stderr
                try proc.run()
                let errorGroup = DispatchGroup()
                errorGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let chunk = stderr.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        let message = String(decoding: chunk, as: UTF8.self)
                        DispatchQueue.main.async { self.addLog(message, newline: false) }
                    }
                    errorGroup.leave()
                }
                var digest = SHA256()
                var lastUpdate: Int64 = 0
                var streamError: Error? = nil
                while true {
                    let data = stdout.fileHandleForReading.readData(ofLength: 256 * 1024)
                    if data.isEmpty { break }
                    do { try file.write(contentsOf: data) }
                    catch { streamError = error; break }
                    digest.update(data: data)
                    transferred += Int64(data.count)
                    if transferred - lastUpdate >= 4 * 1024 * 1024 || transferred == expectedSize {
                        let received = transferred
                        DispatchQueue.main.async {
                            self.progress = min(1, Double(received) / Double(expectedSize))
                            self.transferProgress = "\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: expectedSize, countStyle: .file))"
                        }
                        lastUpdate = transferred
                    }
                    if transferred > expectedSize {
                        streamError = NSError(domain: "PiImageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Received more bytes than expected. SSH output may be contaminated."])
                        break
                    }
                }
                if streamError != nil && proc.isRunning { proc.terminate() }
                proc.waitUntilExit()
                errorGroup.wait()
                try file.synchronize()
                try file.close()
                fd = -1
                if let streamError = streamError { throw streamError }
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "PiImageManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "SSH transfer failed (exit \(proc.terminationStatus))."])
                }
                let actualSHA = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard transferred == expectedSize && actualSHA == expectedSHA else {
                    throw NSError(domain: "PiImageManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "File size or SHA-256 mismatch. Staged image retained; incomplete Mac file removed."])
                }
                try fm.moveItem(at: partialURL, to: finalURL)
                DispatchQueue.main.async { self.cleanupAfterTransfer(name) }
            } catch {
                if fd >= 0 { close(fd) }
                if ownsPartial { try? fm.removeItem(at: partialURL) }
                DispatchQueue.main.async { self.failure("Mac transfer failed: \(error.localizedDescription). Staged image remains available on the Pi.") }
            }
        }
    }
    private func cleanupAfterTransfer(_ name: String) {
        addLog("✓ Transfer complete: matching SHA-256 verified on Mac. Saved to \(localFolder)/\(name)")
        status = "Saved and verified on Mac; clearing Pi staging…"
        progress = 1
        runText(["remove", name], label: "Removing verified Pi staging copy") { code, response in
            self.busy = false
            self.transferProgress = ""
            if code == 0, response.contains("REMOVED|\(name)") {
                self.status = "Backup saved and Pi staging cleaned up"
            } else {
                self.status = "Backup saved on Mac; staging cleanup needed"
                self.addLog("The Mac image is complete, but Pi staging cleanup failed. Use Refresh and Remove Staged Image later.")
            }
            self.addLog("Restore-test this image on spare media before relying on it.")
        }
    }
    func removeSelected() {
        guard !busy && valid() && !selectedStaged.isEmpty else { return }
        busy = true
        let name = selectedStaged
        status = "Removing staged image…"
        runText(["remove", name], label: "Removing Pi staging copy") { code, response in
            self.busy = false
            if code == 0, response.contains("REMOVED|\(name)") {
                self.status = "Staged file removed"
                self.refreshStaged()
            } else {
                self.failure("Unable to remove staged file; see log.")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = BackupManager()
    @State private var confirmRemove = false
    @State private var confirmAbort = false
    @State private var showPiBrowser = false
    private enum NamingMode: String, Identifiable {
        case streamOnly, streamAndImage, existingArchive, stagedImage
        var id: String { rawValue }
    }
    @State private var namingMode: NamingMode? = nil
    @State private var draftFolderName = ""
    @State private var draftImageName = ""
    @State private var showPreview = true
    @State private var showConversion = true
    @State private var showActivityLog = true

    private func requestNaming(_ mode: NamingMode) {
        guard !manager.busy else { return }
        let base: String
        if mode == .existingArchive, !manager.selectedArchive.isEmpty {
            let folder = URL(fileURLWithPath: manager.selectedArchive).lastPathComponent
            base = folder.hasSuffix("-recovery") ? String(folder.dropLast("-recovery".count)) : manager.suggestedBackupBase()
        } else {
            base = manager.suggestedBackupBase()
        }
        draftFolderName = base
        draftImageName = base + ".img"
        namingMode = mode
    }

    private func startNamedBackup(_ mode: NamingMode) {
        let folder = draftFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = draftImageName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .streamOnly:
            manager.createStreamedArchive(folderBase: folder)
        case .streamAndImage:
            manager.createStreamedArchive(andBuildImage: true, folderBase: folder, imageFilename: image)
        case .existingArchive:
            manager.convertSelectedArchive(imageFilename: image)
        case .stagedImage:
            manager.createImage(filename: image)
        }
        namingMode = nil
    }

    private func streamStage(_ label: String, state: String, bytes: Int64,
                             rate: Int64, seconds: Int,
                             processed: Int64, expected: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline.bold())
                Spacer()
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
            if expected > 0 {
                // Clamp the bar below 100% until the remote tar stream ends.
                let displayedFraction = state == "Complete" ? 1.0 :
                    min(0.99, max(0, Double(processed) / Double(expected)))
                ProgressView(value: displayedFraction)
                    .tint(state == "Complete" ? .green : .blue)
                Text(state == "Complete" ? "100% of estimated archive work complete" :
                     "~" + String(format: "%.0f", displayedFraction * 100) + "% of estimated archive work")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state == "In progress" {
                ProgressView().controlSize(.mini)
            }
            Text(manager.prettyBytes(bytes) + " compressed data received")
                .font(.system(.callout, design: .monospaced))
            HStack {
                Text(manager.prettyRate(rate))
                Spacer()
                Text(manager.prettyTime(seconds))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var stagedAndRecoveryPanels: some View {
                GroupBox("Create Full Image") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Creates a flashable .img on the Pi, verifies it, then downloads it to your Mac. Requires Pi temporary disk space.")
                            .foregroundStyle(.secondary).font(.callout)
                        Button { requestNaming(.stagedImage) } label: {
                            Label("Create and Download Image", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(manager.busy)
                        Text("Swap file is excluded automatically by image-backup. Requires staging space on Pi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
                GroupBox("Recover a Staged Image") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Staged image", selection: $manager.selectedStaged) {
                                Text("Choose staged image").tag("")
                                ForEach(manager.staged) { item in Text(item.display).tag(item.name) }
                            }.labelsHidden()
                            Button { manager.refreshStaged() } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(manager.busy).help("Find images left on Pi after an interrupted transfer")
                        }
                        HStack {
                            Button("Download Staged Image") { manager.transferSelected() }
                                .disabled(manager.busy || manager.selectedStaged.isEmpty)
                            Button("Remove Staged…") { confirmRemove = true }
                                .disabled(manager.busy || manager.selectedStaged.isEmpty)
                        }
                        Text("Transfer resumes from Pi staging if the Mac download was interrupted. Updates to existing images are not supported in this SSH mode.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
    }

    private var profileSelector: some View {
        Picker("Profile", selection: $manager.selectedProfileID) {
            ForEach(manager.profiles) { item in Text(item.name).tag(item.id) }
        }
        .onChange(of: manager.selectedProfileID) { value in manager.loadProfile(value) }
        .disabled(manager.busy)
    }

    private var profileNameEditor: some View {
        TextField("Profile name", text: $manager.profileName)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .onChange(of: manager.profileName) { _ in manager.saveSettings() }
            .disabled(manager.busy)
    }

    private var profileActions: some View {
        HStack(spacing: 8) {
            Button("Add Pi") { manager.newProfile() }.disabled(manager.busy)
            Button("Remove Pi") { manager.deleteProfile() }
                .disabled(manager.busy || manager.profiles.count < 2)
            Button("Save Profile") { manager.saveSettings() }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 34)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi Image Manager").font(.title.bold())
                    Text("Raspberry Pi recovery archives and full images over SSH")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.busy { ProgressView().controlSize(.small) }
                Text(manager.status).font(.callout).foregroundStyle(.secondary)
            }
            GroupBox("Raspberry Pi Profiles") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        profileSelector
                        profileNameEditor
                        profileActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { profileSelector; profileNameEditor }
                        profileActions
                    }
                }
                .padding(.vertical, 4)
            }
            GroupBox("Connection and Mac Destination") {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Pi host / IP").frame(width: 95, alignment: .trailing)
                            TextField("raspberrypi.local", text: $manager.host)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: manager.host) { _ in manager.saveSettings() }
                            Text("SSH user").frame(width: 75, alignment: .trailing)
                            TextField("pi", text: $manager.user)
                                .textFieldStyle(.roundedBorder).frame(width: 110)
                                .onChange(of: manager.user) { _ in manager.saveSettings() }
                            Button("Check Connection") { manager.checkConnection() }.disabled(manager.busy)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Pi host / IP")
                                TextField("raspberrypi.local", text: $manager.host)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: manager.host) { _ in manager.saveSettings() }
                            }
                            HStack {
                                Text("SSH user")
                                TextField("pi", text: $manager.user)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 145)
                                    .onChange(of: manager.user) { _ in manager.saveSettings() }
                                Spacer()
                                Button("Check Connection") { manager.checkConnection() }.disabled(manager.busy)
                            }
                        }
                    }
                    HStack {
                        Text("Save images").frame(width: 95, alignment: .trailing)
                        Text(manager.localFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Folder…") { manager.chooseFolder() }.disabled(manager.busy)
                        Button("Open in Finder") { manager.openFolder() }
                    }
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("SSH pull; no SMB or Mac file sharing needed")
                        Spacer()
                        Text("Helper: " + manager.helperVersion + " · " + manager.space).lineLimit(2)
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            GroupBox("Backup Exclusions — Per Pi") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Always omitted: virtual filesystems, temporary mountpoints and /var/swap. Presets below are optional; original Pi files are never deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                        Toggle("Journal history", isOn: $manager.excludeJournal)
                        Toggle("APT download cache", isOn: $manager.excludeApt)
                        Toggle("User caches", isOn: $manager.excludeUserCache)
                        Toggle("User Downloads", isOn: $manager.excludeDownloads)
                    }
                    .onChange(of: manager.excludeJournal) { _ in manager.saveSettings() }
                    .onChange(of: manager.excludeApt) { _ in manager.saveSettings() }
                    .onChange(of: manager.excludeUserCache) { _ in manager.saveSettings() }
                    .onChange(of: manager.excludeDownloads) { _ in manager.saveSettings() }
                    Text("Additional Pi directories to omit (one absolute path per line):")
                        .font(.subheadline.bold())
                    TextEditor(text: $manager.customPaths)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 75)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                        .onChange(of: manager.customPaths) { _ in manager.saveSettings() }
                    HStack {
                        Button("Browse Pi…") { showPiBrowser = true; manager.browsePi() }
                            .disabled(manager.busy)
                        Button("Preview Backup") { manager.previewBackup() }.disabled(manager.busy)
                            .buttonStyle(.borderedProminent)
                        Text("Essential OS paths are protected. Exclusions affect the estimate, archive and staged-image backup.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    DisclosureGroup("Backup Preview", isExpanded: $showPreview) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(manager.previewSummary)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(manager.previewWarnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if !manager.previewRows.isEmpty {
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(manager.previewRows) { item in
                                            HStack(spacing: 9) {
                                                Text(item.path)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .lineLimit(2)
                                                Spacer(minLength: 8)
                                                Text(manager.prettyBytes(item.bytes))
                                                Text(item.status).foregroundStyle(.secondary)
                                            }.font(.caption)
                                        }
                                    }.padding(8)
                                }
                                .frame(height: min(185, CGFloat(manager.previewRows.count * 27 + 20)))
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }.padding(.vertical, 4)
                    }
                }.padding(.vertical, 4)
            }
            GroupBox("Stream Directly to Mac — Recovery Archive") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Streams root and boot files directly over SSH to compressed archives on your Mac. No SMB, staging space, or image file on the Pi. Includes ownership, permissions, ACLs and extended attributes.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button { requestNaming(.streamOnly) } label: {
                            Label("Stream Backup Only", systemImage: "network.badge.shield.half.filled")
                        }.buttonStyle(.borderedProminent).disabled(manager.busy)
                        Button { requestNaming(.streamAndImage) } label: {
                            Label("Stream Backup + Create .img", systemImage: "externaldrive.fill.badge.plus")
                        }.buttonStyle(.borderedProminent).disabled(manager.busy)
                    }
                    Text("A streamed backup saves recovery archives. Image conversion runs in a Linux VM on the Mac, not on the Pi. Live database consistency is not guaranteed.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
            if manager.streamVisible {
                GroupBox("Live Streaming Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(manager.streamPhase).font(.headline)
                            Spacer()
                            if let started = manager.streamStarted {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("Total elapsed: " + manager.prettyTime(Int(context.date.timeIntervalSince(started))))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if manager.estimatedFraction != nil {
                            HStack {
                                Text("Backup status (estimated)").font(.subheadline.bold())
                                Spacer()
                                Text(String(format: "~%.0f%%", (manager.estimatedFraction ?? 0) * 100))
                                    .font(.system(.subheadline, design: .monospaced))
                            }
                            ProgressView(value: manager.estimatedFraction ?? 0)
                                .tint(.blue)
                            Text(manager.estimatedRemaining)
                                .font(.caption).foregroundStyle(.secondary)
                        } else if manager.busy { ProgressView().controlSize(.small) }
                        Group {
                            if geometry.size.width < 950 {
                                VStack(spacing: 12) {
                                    streamStage("Root filesystem", state: manager.rootPhase,
                                        bytes: manager.rootBytes, rate: manager.rootRate,
                                        seconds: manager.rootSeconds,
                                        processed: manager.rootProcessed, expected: manager.rootExpected)
                                    streamStage("Boot filesystem", state: manager.bootPhase,
                                        bytes: manager.bootBytes, rate: manager.bootRate,
                                        seconds: manager.bootSeconds,
                                        processed: manager.bootProcessed, expected: manager.bootExpected)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    streamStage("Root filesystem", state: manager.rootPhase,
                                        bytes: manager.rootBytes, rate: manager.rootRate,
                                        seconds: manager.rootSeconds,
                                        processed: manager.rootProcessed, expected: manager.rootExpected)
                                    streamStage("Boot filesystem", state: manager.bootPhase,
                                        bytes: manager.bootBytes, rate: manager.bootRate,
                                        seconds: manager.bootSeconds,
                                        processed: manager.bootProcessed, expected: manager.bootExpected)
                                }
                            }
                        }
                        HStack(spacing: 16) {
                            Label("Archive verification: " + manager.verifyPhase,
                                  systemImage: "checkmark.shield")
                            Label("Image conversion: " + manager.conversionPhase,
                                  systemImage: "externaldrive")
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Stage-weighted progress: root 0–90%, boot 90–97%, verification to 100%. Checkpoints measure uncompressed tar records; totals/ETA are approximate. Conversion is separate.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if manager.busy && manager.abortAvailable {
                                Button { confirmAbort = true } label: {
                                    Label(manager.abortRequested ? "Aborting…" : "Abort Backup", systemImage: "stop.circle")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .disabled(manager.abortRequested)
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
            GroupBox {
                DisclosureGroup("Conversion Settings", isExpanded: $showConversion) {
                    VStack(alignment: .leading, spacing: 9) {
                    Text("Uses an isolated Lima Linux VM on your Mac to rebuild FAT32 boot and ext4 root partitions. Requires Homebrew Lima (brew install lima) and Mac disk space; the Pi is not involved.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(manager.selectedArchive.isEmpty ? "No recovery archive selected" : manager.selectedArchive)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Recovery Folder…") { manager.chooseArchive() }.disabled(manager.busy)
                        Button("Create .img from Archive") { requestNaming(.existingArchive) }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.busy || manager.selectedArchive.isEmpty)
                    }
                    Text("For automatic conversion, use 'Stream Backup + Create .img' above. A generated image must be test-booted before relying on it.")
                        .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
            } label: { Text("Convert Recovery Archive to Bootable .img — on Mac") }
            Group {
                if geometry.size.width < 950 {
                    VStack(alignment: .leading, spacing: 12) {
                        stagedAndRecoveryPanels
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        stagedAndRecoveryPanels
                    }
                }
            }
            if manager.busy && manager.progress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: manager.progress)
                    Text(manager.transferProgress).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Activity Log", isExpanded: $showActivityLog) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH key authentication • files stored on Mac only after checksum verification")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(manager.log).font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(9)
                }
                .frame(height: 230)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .onReceive(manager.$log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            Text("Important: a live image isn't an atomic snapshot. Docker databases and active services may need a consistent export. Verify restoration by booting spare media.")
                .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 620, minHeight: 490)
        .sheet(isPresented: $showPiBrowser) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse Raspberry Pi directories").font(.title3.bold())
                HStack {
                    TextField("/home", text: $manager.browseDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Open") { manager.browsePi() }.disabled(manager.busy)
                    Button("Up") {
                        let parent = (manager.browseDirectory as NSString).deletingLastPathComponent
                        manager.browseDirectory = parent.isEmpty ? "/" : parent
                        manager.browsePi()
                    }.disabled(manager.busy)
                }
                List(manager.browseResults, id: \.self) { directory in
                    HStack {
                        Button(directory) { manager.browseDirectory = directory; manager.browsePi() }
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Exclude") { manager.addExclusion(directory); showPiBrowser = false }
                    }
                }
                HStack {
                    Text("Only home, application and data directories can be browsed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { showPiBrowser = false }
                }
            }.padding(18).frame(width: 700, height: 480)
        }
        .sheet(item: $namingMode) { mode in
            VStack(alignment: .leading, spacing: 14) {
                Text(mode == .existingArchive ? "Name the converted disk image" :
                     mode == .stagedImage ? "Name the full disk image" : "Name this backup")
                    .font(.title2.bold())
                Text("Names can contain letters, numbers, periods, hyphens and underscores. Existing files are never overwritten.")
                    .font(.callout).foregroundStyle(.secondary)
                if mode == .streamOnly || mode == .streamAndImage {
                    Text("Recovery folder name").font(.subheadline.bold())
                    TextField("Backup folder name", text: $draftFolderName).textFieldStyle(.roundedBorder)
                    Text("The app adds -recovery to this name. No .partial directory is retained after success.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mode != .streamOnly {
                    Text("Disk image filename").font(.subheadline.bold())
                    TextField("Disk image filename.img", text: $draftImageName).textFieldStyle(.roundedBorder)
                    Text("Include .img. This name is used for the downloaded/staged image or the rebuilt Mac image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let folderValid = mode == .existingArchive || mode == .stagedImage ||
                    BackupManager.validBackupBase(draftFolderName.trimmingCharacters(in: .whitespacesAndNewlines))
                let imageValid = mode == .streamOnly ||
                    BackupManager.validImageFilename(draftImageName.trimmingCharacters(in: .whitespacesAndNewlines))
                if !folderValid || !imageValid {
                    Label("Please enter valid, safe filenames.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { namingMode = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(mode == .existingArchive ? "Create Image" : "Start Backup") {
                        startNamedBackup(mode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!folderValid || !imageValid || manager.busy)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 510)
        }
        .alert("Abort streaming backup?", isPresented: $confirmAbort) {
            Button("Keep Running", role: .cancel) { }
            Button("Abort Backup", role: .destructive) { manager.abortStream() }
        } message: {
            Text("Stops the SSH transfer and deletes ONLY this backup's incomplete *.partial recovery folder on the Mac. Existing completed backups remain untouched. Conversion cannot be safely aborted with this button.")
        }
        .alert("Remove staged image?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) { }
            Button("Remove from Pi", role: .destructive) { manager.removeSelected() }
        } message: {
            Text("This deletes \(manager.selectedStaged) from the Pi staging area. Download it first if you need the backup.")
        }
        .alert("Pi Image Manager", isPresented: Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.lastError = nil } }
        )) {
            Button("OK") { manager.lastError = nil }
        } message: {
            Text(manager.lastError ?? "")
        }
    }
}

@main
struct PiImageManagerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
