import SwiftUI

/// Settings > 앱 정보 > 빌드 상세 정보: which build this is, for diagnosing a report -- the product
/// version and build number again, whether it is a development or a release build, and which
/// sources it was made from (docs/versioning.md).
///
/// Everything here is read from the app's own bundle. A value the build did not record is shown
/// as "알 수 없음"; nothing is guessed, and nothing about a hub, a Power Base or a sensor is shown
/// here (the app does not collect their versions).
struct BuildDetailsView: View {
    var info = AppBuildInfo.current

    private typealias T = BuildDetailsText

    var body: some View {
        List {
            Section {
                LabeledContent { Text(verbatim: info.version) } label: { Text(verbatim: T.version) }
                LabeledContent { Text(verbatim: info.buildNumber) } label: { Text(verbatim: T.buildNumber) }
                LabeledContent { Text(verbatim: T.kind(info.kind)) } label: { Text(verbatim: T.kindLabel) }
            } header: {
                Text(verbatim: T.buildHeader)
            } footer: {
                Text(verbatim: T.kindFooter(info.kind))
            }

            Section {
                valueRow(T.buildID, info.buildID)
                valueRow(T.commit, info.commit)
                LabeledContent { Text(verbatim: T.sourceState(info.isDirty)) } label: { Text(verbatim: T.sourceStateLabel) }
                valueRow(T.fingerprint, info.sourceFingerprint)
            } header: {
                Text(verbatim: T.sourceHeader)
            } footer: {
                Text(verbatim: T.sourceFooter)
            }
        }
        .listScreenBackground()
        .navigationTitle(Text(verbatim: T.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A long identifier under its label, selectable, in a monospaced face; or "알 수 없음".
    private func valueRow(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
            Text(verbatim: value ?? T.unknown)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The wording of the build details, in the app's language.
nonisolated enum BuildDetailsText {
    static var title: String { String(localized: "빌드 상세 정보", comment: "Settings > App info: row and screen title of the build details") }
    static var buildHeader: String { String(localized: "빌드", comment: "Build details: section header") }
    static var version: String { String(localized: "버전", comment: "Build details / app info: product version label") }
    static var buildNumber: String { String(localized: "빌드 번호", comment: "Build details / app info: build number label") }
    static var kindLabel: String { String(localized: "빌드 종류", comment: "Build details: development or release") }
    static var sourceHeader: String { String(localized: "소스", comment: "Build details: section header for the source identity") }
    static var buildID: String { String(localized: "빌드 식별자", comment: "Build details: the build id (commit + source fingerprint, shortened)") }
    static var commit: String { String(localized: "커밋", comment: "Build details: the Git commit the build was made from") }
    static var sourceStateLabel: String { String(localized: "소스 상태", comment: "Build details: clean or with uncommitted changes") }
    static var fingerprint: String { String(localized: "소스 지문", comment: "Build details: the source fingerprint (a hash of the sources)") }
    static var unknown: String { String(localized: "알 수 없음", comment: "Build details: a value the build did not record") }
    static var sourceFooter: String { String(localized: "소스 정보는 빌드 도구로 만든 빌드에만 기록됩니다. 기록되지 않은 값은 '알 수 없음'으로 표시하며 추정하지 않습니다. 같은 커밋이라도 커밋하지 않은 변경이 다르면 소스 지문이 다릅니다.", comment: "Build details: where the source identity comes from; nothing is guessed") }

    static func kind(_ kind: AppBuildInfo.Kind) -> String {
        switch kind {
        case .development: return String(localized: "개발 빌드", comment: "Build details: a development build")
        case .release: return String(localized: "배포 빌드", comment: "Build details: a release build")
        case .unknown: return unknown
        }
    }

    static func kindFooter(_ kind: AppBuildInfo.Kind) -> String {
        switch kind {
        case .development:
            return String(localized: "개발·시험용으로 만든 빌드입니다. 배포 후보가 아닙니다.", comment: "Build details: what a development build is")
        case .release:
            return String(localized: "커밋된 소스 그대로 배포 모드에서 만든 빌드입니다.", comment: "Build details: what a release build is")
        case .unknown:
            return String(localized: "빌드 도구를 거치지 않고 만든 빌드라 종류가 기록되지 않았습니다. 배포 빌드로 보지 않습니다.", comment: "Build details: a build without recorded kind is not treated as a release")
        }
    }

    static func sourceState(_ isDirty: Bool?) -> String {
        switch isDirty {
        case true?: return String(localized: "커밋하지 않은 변경 포함", comment: "Build details: built from a tree with uncommitted changes")
        case false?: return String(localized: "커밋된 소스 그대로", comment: "Build details: built from a clean tree")
        case nil: return unknown
        }
    }
}
