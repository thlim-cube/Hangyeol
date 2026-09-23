import Foundation
import HangyeolE2ESupport

private func usage() -> Never {
    FileHandle.standardError.write(Data("""
    사용법:
      swift run -c debug HangyeolE2E --package /absolute/path/Hangyeol_<version>_Local.pkg [--preflight-only] [--scenario 이름일부]
      swift run -c debug HangyeolE2E --app /absolute/path/Hangyeol.app [--scenario 이름일부]
      swift run -c debug HangyeolE2E --app /absolute/path/Hangyeol.app --scenario 'Slack 현재 입력창'

    Slack 검증은 이미 실행 중인 앱의 수신인 없는 새 메시지, 빈 본문에서만 실행합니다.
    실제 키 입력과 한영 전환·입력기 재연결 후 초점 유지를 확인하며 메시지를 전송하지 않습니다.

    실제 설치본 /Library/Input Methods/Hangyeol.app과 지정한 PKG의 버전, build,
    bundle ID, 코드 서명을 먼저 대조합니다. TCC DB나 SIP 설정은 변경하지 않습니다.

    """.utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var packagePath: String?
var appPath: String?
var preflightOnly = false
var scenarioFilter: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--package":
        guard !arguments.isEmpty else { usage() }
        packagePath = arguments.removeFirst()
    case "--app":
        guard !arguments.isEmpty else { usage() }
        appPath = arguments.removeFirst()
    case "--preflight-only":
        preflightOnly = true
    case "--scenario":
        guard !arguments.isEmpty, !arguments[0].isEmpty else { usage() }
        scenarioFilter = arguments.removeFirst()
    case "--help", "-h":
        usage()
    default:
        FileHandle.standardError.write(Data("알 수 없는 인자: \(argument)\n".utf8))
        usage()
    }
}

guard packagePath != nil || appPath != nil else { usage() }

do {
    let runner = HangyeolE2ERunner(
        configuration: HangyeolE2EConfiguration(
            packageURL: packagePath.map { URL(fileURLWithPath: $0) },
            installedAppURL: appPath.map { URL(fileURLWithPath: $0) }
                ?? ArtifactInspector.defaultInstalledAppURL,
            preflightOnly: preflightOnly,
            scenarioFilter: scenarioFilter
        )
    )
    let results = try runner.run()
    let passed = results.filter(\.passed).count
    let failed = results.count - passed
    if !results.isEmpty {
        print("\nE2E 결과: \(passed)/\(results.count) 통과, \(failed) 실패")
    }
    exit(failed == 0 ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("E2E 중단: \(error.localizedDescription)\n".utf8))
    exit(1)
}
