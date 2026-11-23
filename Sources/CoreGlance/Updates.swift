import Foundation

/// Looks for a newer release on GitHub, at most once a day.
///
/// This is the app's only network request. It asks GitHub for the latest release number and
/// sends nothing about the user or the Mac. It can be turned off in Settings. The app never
/// downloads or installs anything itself: it only tells the user and links to the release.
enum Updates {
    static let latestAPI = URL(string: "https://api.github.com/repos/amritadasbijoy/CoreGlance/releases/latest")!
    static let releasePage = URL(string: AppInfo.sourceURL + "/releases/latest")!
    static let brewCommand = "brew upgrade --cask coreglance"
    static let checkEvery: TimeInterval = 24 * 3600

    /// The version of this copy of the app. nil for a bare development binary, which never checks.
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// True when this copy was installed with Homebrew (Apple Silicon keeps casks here).
    static var installedWithHomebrew: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/coreglance")
    }

    /// The latest released version, such as "1.0.7". nil when offline or on any error.
    static func latestVersion() async -> String? {
        var request = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Calc.releaseVersion(fromJSON: data)
    }
}
