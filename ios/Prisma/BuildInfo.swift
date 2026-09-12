import Foundation

/// Identifies the exact build that is running, so an installed .ipa can be matched
/// to the CI run that produced it.
///
/// - `version` is `MARKETING_VERSION`.
/// - `build` is `CURRENT_PROJECT_VERSION`; CI sets it to the workflow run number.
/// - `commit` is `PRISMA_COMMIT_SHA`, expanded into Info.plist by `Prisma-Info.plist`;
///   CI sets it to the short commit SHA, local builds show "local".
struct BuildInfo {
    let version: String
    let build: String
    let commit: String

    init(bundle: Bundle) {
        version = bundle.infoString("CFBundleShortVersionString")
        build = bundle.infoString("CFBundleVersion")
        commit = bundle.infoString("PrismaCommitSHA")
    }
}

private extension Bundle {
    func infoString(_ key: String) -> String {
        guard let value = object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return "unknown"
        }
        return value
    }
}
