import AppKit
import Observation

/// Over-the-air updates from GitHub Releases, with no dependency: the public
/// `releases/latest` endpoint carries the version, the notes and the .zip.
///
/// Trust model: the same as the original download — TLS to github.com plus the
/// integrity of the repository. A URLSession download carries no quarantine flag,
/// so the ad-hoc signature is not an obstacle (Gatekeeper only inspects
/// quarantined files).
///
/// Installing: the .zip is expanded with `ditto` (which preserves the signature),
/// the extracted bundle is validated (identifier and version), the old version
/// goes to the Trash, the new one takes its place and the app relaunches.
@MainActor
@Observable
final class UpdateService {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String, pageURL: URL?)
    }

    struct Release: Equatable, Sendable {
        /// "0.2.0" — the tag without its "v".
        var version: String
        var notes: String
        /// Absent when the release has no .zip asset.
        var zipURL: URL?
        var pageURL: URL
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var lastCheck: ContinuousClock.Instant?

    /// Outside a bundle (`swift run`), updating itself makes no sense.
    nonisolated static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Who owns the copy on disk.
    ///
    /// Replacing our own bundle behind Homebrew's back is how you end up with
    /// `brew list --versions` reporting a version that is not installed, and a later
    /// `brew upgrade` quietly putting the cask's older build back. So when the
    /// Caskroom holds a receipt for us, the updater still *looks* — knowing there is
    /// something new is useful — but the installing is left to brew.
    enum Ownership: Equatable {
        case standalone
        case homebrew(command: String)
    }

    nonisolated static let caskToken = "papersift"

    /// True when a Homebrew cask receipt for this app exists.
    ///
    /// The receipt, not the location: an app in `/Applications` says nothing, since
    /// that is where both a cask and a hand-dragged copy land. `--prefix` is not run
    /// either — spawning brew on every launch to learn a path that has two possible
    /// values is not worth it.
    nonisolated static var ownership: Ownership {
        let prefixes = ["/opt/homebrew", "/usr/local", "\(NSHomeDirectory())/homebrew"]
        for prefix in prefixes {
            let caskroom = "\(prefix)/Caskroom/\(caskToken)"
            guard FileManager.default.fileExists(atPath: caskroom) else { continue }
            return .homebrew(command: "brew upgrade --cask \(caskToken)")
        }
        return .standalone
    }

    nonisolated static var isHomebrewManaged: Bool {
        ownership != .standalone
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    nonisolated static let repository = "imadhy/paper-sift"

    nonisolated static let defaultFeed =
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Overridable for testing: PAPERSIFT_UPDATE_FEED=file:///…/latest.json
    nonisolated static var feedURL: URL {
        if let raw = ProcessInfo.processInfo.environment["PAPERSIFT_UPDATE_FEED"],
           let url = URL(string: raw) {
            return url
        }
        return defaultFeed
    }

    nonisolated static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    init() {
        guard Self.isBundled else { return }
        // A quiet check at launch and then daily: it only speaks up when there is
        // something new (the phase moves to `available`).
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.checkQuietly()
                try? await Task.sleep(for: .seconds(24 * 3_600), tolerance: .seconds(3_600))
            }
        }
    }

    // MARK: - Checking

    /// Opportunistic check when a view appears: silent, and at most hourly. The
    /// daily loop is the safety net; this just makes discovery quicker.
    func checkIfStale() {
        guard Self.isBundled else { return }
        if let lastCheck, lastCheck.duration(to: .now) < .seconds(3_600) { return }
        Task { await checkQuietly() }
    }

    /// A manual check (the Settings button): every outcome is shown, including
    /// "up to date" and errors.
    func check() async {
        phase = .checking
        lastCheck = .now
        do {
            let release = try await Self.fetchLatest(from: Self.feedURL)
            phase = Self.isNewer(release.version, than: Self.currentVersion)
                ? .available(release) : .upToDate
        } catch {
            phase = .failed(error.localizedDescription, pageURL: Self.releasesPage)
        }
    }

    private func checkQuietly() async {
        guard phase == .idle || phase == .upToDate else { return }
        lastCheck = .now
        guard let release = try? await Self.fetchLatest(from: Self.feedURL),
              Self.isNewer(release.version, than: Self.currentVersion) else { return }
        phase = .available(release)
    }

    // MARK: - Installing

    /// Downloads, replaces the bundle and relaunches. On failure the installed app
    /// is untouched — replacement is the very last step.
    func install() async {
        guard case .available(let release) = phase else { return }
        if case .homebrew(let command) = Self.ownership {
            phase = .failed(
                "This copy is managed by Homebrew. Run \(command) instead.",
                pageURL: release.pageURL)
            return
        }
        phase = .installing(release)
        do {
            try await Self.downloadAndInstall(release, replacing: Bundle.main.bundleURL)
            relaunch()
        } catch {
            phase = .failed(error.localizedDescription, pageURL: release.pageURL)
        }
    }

    /// Relaunches the (freshly replaced) bundle as soon as this process dies.
    private func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2""#,
            "_", "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundleURL.path,
        ]
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: - Shared machinery (GUI and --check-update / --install-update)

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
    }

    nonisolated static func fetchLatest(from feed: URL) async throws -> Release {
        do {
            return try await fetchFromAPI(feed)
        } catch {
            // The unauthenticated API allows 60 requests an hour PER IP: on a
            // shared network someone else can exhaust it. Fall back to the
            // quota-free redirect — but not for a test feed, which must stay
            // hermetic.
            guard feed == defaultFeed else { throw error }
            return try await fetchFromRedirect()
        }
    }

    private nonisolated static func fetchFromAPI(_ feed: URL) async throws -> Release {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered \(http.statusCode) — try again later.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let github = try decoder.decode(GitHubRelease.self, from: data)
        let version = github.tagName.hasPrefix("v")
            ? String(github.tagName.dropFirst()) : github.tagName
        return Release(
            version: version,
            notes: github.body ?? "",
            zipURL: github.assets.first { $0.name.hasSuffix(".zip") }?.browserDownloadUrl,
            pageURL: github.htmlUrl)
    }

    /// Without the API: /releases/latest redirects to /releases/tag/vX.Y.Z, and the
    /// .zip follows make-dmg.sh's convention (PaperSift-X.Y.Z.zip). Its existence
    /// is probed with HEAD so nothing unreachable is ever promised.
    private nonisolated static func fetchFromRedirect() async throws -> Release {
        let latest = URL(string: "https://github.com/\(repository)/releases/latest")!
        let (_, response) = try await URLSession.shared.data(from: latest)
        guard let page = response.url, page.path.contains("/releases/tag/") else {
            throw UpdateError("Could not work out the latest release.")
        }
        let tag = page.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zip = URL(string:
            "https://github.com/\(repository)/releases/download/\(tag)/PaperSift-\(version).zip")!

        var probe = URLRequest(url: zip)
        probe.httpMethod = "HEAD"
        let zipExists = await (try? URLSession.shared.data(for: probe))
            .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } == 200
        return Release(version: version, notes: "",
                       zipURL: zipExists ? zip : nil, pageURL: page)
    }

    /// "0.10.1" > "0.9.9": compared component by component as numbers, not
    /// alphabetically.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let new = parts(candidate)
        let old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Downloads the .zip, validates the extracted bundle and replaces
    /// `bundleURL`. The old version goes to the Trash, so it is recoverable.
    nonisolated static func downloadAndInstall(
        _ release: Release, replacing bundleURL: URL
    ) async throws {
        guard let zipURL = release.zipURL else {
            throw UpdateError(
                "Release \(release.version) has no .zip asset — install it from the GitHub page.")
        }
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("papersift-update")
        try? files.removeItem(at: work)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("Download refused (HTTP \(http.statusCode)).")
        }
        let zip = work.appendingPathComponent("update.zip")
        try files.moveItem(at: downloaded, to: zip)

        // ditto preserves symlinks and the signature, which unzip does not.
        let staged = work.appendingPathComponent("staged")
        let extraction = try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path])
        guard extraction.status == 0 else {
            throw UpdateError("Could not expand the archive: \(extraction.output.prefix(200))")
        }
        guard let app = try files.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The archive holds no application.")
        }

        // Guard rail: same identifier and the version it claimed, or nothing is
        // touched.
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The downloaded bundle does not match the announced release.")
        }

        try files.trashItem(at: bundleURL, resultingItemURL: nil)
        do {
            try files.moveItem(at: app, to: bundleURL)
        } catch {
            // The temporary directory can be on another volume; copying works.
            try files.copyItem(at: app, to: bundleURL)
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Runs a command and collects its output. Only used by the updater.
enum Shell {
    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
