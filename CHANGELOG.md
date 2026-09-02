# Changelog

All notable changes to Hangyeol will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.17] - 2026-09-02

### Fixed
- 일반 업데이트에서 한결 프로세스를 종료·재기동한 뒤 로그인 때부터 실행 중인 macOS 입력 메뉴가 교체 전 번들 상태를 계속 참조해 `한결 설정...`과 `한결 정보`가 사라지던 문제를 수정했습니다. 등록 구조가 같으면 현재 IMK와 메뉴 연결을 유지하고 새 실행 파일은 다음 로그인부터 적용합니다.
- 패키지에 새 버전의 등록 메타데이터를 포함해 교체 전에 일반 업데이트와 등록 구조 변경을 구분합니다. 최초 설치나 bundle ID·IMK connection·input mode schema 변경에서는 기존 fallback·등록 복구 절차를 그대로 수행하며, macOS 입력 시스템 프로세스는 강제 재시작하지 않습니다.
- 한/영 전환 직후 navigation key 이벤트에 Shift 비트가 빠져 들어오면, 물리적으로 Shift를 누른 상태여도 `Shift+Home`이 단순 Home으로 전달되던 문제를 수정했습니다. 오래된 Command는 제거하면서 현재 눌린 Shift·Option·Control 등 다른 modifier는 다시 반영합니다.

## [3.0.16] - 2026-09-02

### Fixed
- 우측 Command 같은 modifier-only 한/영 전환키를 놓은 뒤 다음 문자 이벤트에 오래된 Command 플래그가 남아 `f`/`ㄹ` 입력이 찾기 단축키로 실행되던 문제를 수정했습니다. 다음 입력의 modifier를 실제 물리 키 상태로 다시 구성하되, 누르고 있는 좌측 Command 단축키는 그대로 유지합니다.

## [3.0.15] - 2026-08-31

### Fixed
- Installer가 기존 한결 IMK의 실제 종료와 TIS 복구 완료 전에 설치 성공을 표시하던 문제를 수정했습니다. 서명된 helper로 제품 프로세스 종료를 확인한 뒤 새 IMK를 열고, 별도 프로세스의 등록·활성화 확인을 통과한 복구 marker가 정리될 때까지 최대 20초 동안 조건 기반으로 기다립니다.
- 현재 로그인 세션에서 활성화가 완료되지 않으면 임시 ABC, 복구 marker, 1회성 LaunchAgent를 그대로 보존해 다음 로그인에서 안전하게 재시도합니다. 실행 중인 IMK와 경쟁하는 두 번째 서버나 macOS 입력 시스템 agent는 시작·종료하지 않습니다.

## [3.0.14] - 2026-08-31

### Fixed
- 설치 직후 한 번의 TIS 검증 성공을 최종 상태로 오인해 복구 marker를 지운 뒤 한결 등록과 설정 메뉴가 다시 사라지던 문제를 수정했습니다. 별도 프로세스 검증이 5.5초 동안 5회 연속 유지되어야 완료하며, 중간에 상태가 흔들리면 등록·활성화·선택을 다시 수렴시킵니다.
- 임시 ABC는 한결의 안정된 활성화가 확인된 뒤 별도 마지막 단계에서만 제거하고, 제거 검증에서도 한결 parent·mode 활성화와 선택 상태를 함께 확인합니다. macOS 입력 메뉴나 다른 시스템 입력 프로세스는 강제 재시작하지 않습니다.
- 장기 복구 작업과 짧은 요청 세대 잠금을 분리해 새 설치 게시가 TIS 재시도를 기다리지 않게 했습니다. 겹친 복구는 백그라운드에서 차례대로 실행하고, 최신 marker 토큰을 확인한 같은 세대 안에서만 임시 ABC와 marker를 정리합니다. ABC 정리는 1초 제한의 단일 action·verify로 끝내며 실패 시 다음 로그인 재시도를 남깁니다.

## [3.0.13] - 2026-08-31

### Fixed
- Chrome에서 Tab으로 필드를 옮긴 직후 연속된 same-client activation이 두 번 발생하면 첫 자모가 유실되던 문제를 수정했습니다. 각 activation은 계속 분석을 무효화하되, 한 입력 경계에서 최대 3회 안에 얻은 첫 안정된 필드 분석만 허용하고 계속 바뀌면 쓰기를 차단합니다.
- 새 창 활성화가 전환 적용 중 재진입해 같은 전환 의도를 두 번 적용하던 문제를 수정했습니다. 메인 스레드의 한 전환 트랜잭션이 끝날 때까지 중첩 적용을 차단하고, 실패한 전환은 다음 안전한 입력 경계까지 유지합니다.
- macOS 26에서 실행 중인 IMK 서버가 유효해도 `codesign --verify +PID`가 `Invalid argument`로 실패하던 E2E 사전 검사를 Security.framework의 동적 코드 검증 API로 교체했습니다.

## [3.0.12] - 2026-08-31

### Fixed
- 설치 직후 입력 소스 메뉴의 `한결 설정...`이 빈 제목으로 `...`만 남던 문제를 수정했습니다. 설치된 리소스 번들을 찾아 메뉴 제목을 채우고, 문자열이 비면 제품명과 `설정`으로 표시합니다.
- 기존 창에서만 한/영 전환이 되고 새로 연 창에서는 전환키가 버려지던 문제를 수정했습니다. 활성 controller가 없어도 물리 전환 의도를 유지하고, 새 창의 첫 keyDown에서 적용합니다.

## [3.0.11] - 2026-08-31

### Fixed
- ABC를 꺼 둔 설치에서 임시 fallback 복원이 TIS 비활성만 확인하고 끝나, 사용자 목록의 ABC와 설치 복구가 남던 문제를 수정했습니다. 한결이 선택된 뒤 설정 창의 `ABC 끄기`와 같이 HIToolbox enabled 목록에서 ABC를 제거한 다음에만 복구를 완료합니다.

## [3.0.10] - 2026-08-30

### Fixed
- 설치 직후 같은 로그인 세션에서 한결 IMK를 다시 띄우지 않고 LaunchAgent bootstrap에만 맡겨, 설정 창과 입력 소스가 다음 로그인까지 비던 문제를 수정했습니다. 2.8.18과 같이 PackageKit이 교체한 앱을 `open`으로 기동하고, TIS 복구는 그 IMK 서버가 마커를 소비한 뒤에 수행합니다. LaunchAgent는 `open` 실패 시 다음 로그인 재시도로만 남습니다.

## [3.0.9] - 2026-08-28

### Fixed
- 설치 복구 명령이 정상 IMK 서버를 만들기 전에 TIS 등록·활성화·선택을 끝내려 해, 각 명령은 성공해도 짧은 프로세스 종료 후 입력 소스가 사라지고 ABC만 남던 문제를 수정했습니다. 복구 LaunchAgent가 먼저 현재 로그인 세션의 IMK 런타임을 시작한 뒤 백그라운드에서 TIS 상태를 수렴합니다.

## [3.0.8] - 2026-08-28

### Fixed
- 일반 업데이트에서 이미 등록·활성화·선택된 입력 소스를 먼저 검증해 불필요한 TIS 쓰기와 재승인 요청을 피하고, 설치 복구 프로세스가 성공 후 정상 IMK 런타임으로 이어져 같은 로그인 세션에서 교체된 한결을 바로 사용하도록 수정했습니다.

## [3.0.7] - 2026-08-28

### Fixed
- 설치 전 스크립트가 macOS에 없는 `/bin/printf`를 호출해 패키지 설치가 중단되던 문제를 수정하고, 설치 스크립트의 절대 명령 경로가 현재 macOS에서 실행 가능한지 검증하는 회귀 테스트를 추가했습니다.

## [3.0.6] - 2026-08-28

### Fixed
- 업데이트 전에 서명된 설치 도우미가 한결 및 이전 식별자에서 안전한 ASCII 입력 소스로 먼저 이탈한 뒤 한결 소유 프로세스만 종료하도록 변경했습니다. ABC가 꺼져 있으면 설치 중에만 임시 활성화하고, 새 한결 선택이 확인된 마지막 단계에서 다시 끕니다. 교체 후에는 로그인 사용자 소유의 1회성 작업이 등록·parent 활성화·mode 활성화·이전 선택 복원을 각각 별도 프로세스에서 검증하며, 실패한 세대는 다음 로그인에 재시도합니다.
- 설치 패키지 안의 도우미도 앱과 같은 인증서로 서명·검증하고, PackageKit은 느린 TIS 전파나 사용자 승인을 기다리지 않고 복구 작업 등록까지만 수행하도록 변경했습니다. macOS의 텍스트 입력 agent와 다른 앱은 종료하지 않습니다.

## [3.0.5] - 2026-08-28

### Fixed
- 최초 설치·등록 구조 변경·일반 업데이트를 분리했습니다. 최초 설치에서만 TIS 등록과 활성화를 수행합니다. 일반 업데이트는 실행 중인 한결과 입력 소스 등록을 유지해 현재 앱의 입력 연결을 보호하고, 새 실행 파일은 다음 로그인 또는 재시동부터 적용합니다. 등록 구조가 바뀐 경우도 현재 세션을 수정하지 않고 다음 로그인에 적용합니다.

## [3.0.4] - 2026-08-28

### Fixed
- 입력 소스 활성화 동의와 TIS 전파 확인을 PackageKit의 동기 `postinstall`에서 독립된 서명 앱 프로세스로 옮겨, 승인을 기다리는 동안 Installer가 멈춘 것처럼 보이던 문제를 해결했습니다. 설정 창 표시는 짧은 별도 명령으로 먼저 예약하며, 준비 실패 시에만 입력 소스 설정을 안내합니다.

## [3.0.3] - 2026-08-28

### Added
- 설치 앱·PKG·실행 중인 IMK 서버의 버전·build·코드 서명을 먼저 대조하고 실제 `CGEvent` 입력과 `AXUIElement` 결과를 확인하는 TextEdit·Chrome E2E 러너를 추가했습니다. Chrome field·브라우저 탭 전환 직후 첫 음절도 대기 없이 반복 검증합니다.
- controller 활성화·늦은 keyDown/deactivate·같은 client의 field 이동·Secure Input·mode 전환·session 교체·늦은 한자 callback을 고정 seed 연산열로 검증하는 수명주기 모델 테스트를 추가했습니다.

### Fixed
- macOS 26의 입력 소스 활성화 동의가 아직 저장되지 않았는데 `TISEnableInputSource` 호출 프로세스의 로컬 캐시만 보고 설치 성공으로 끝내던 문제를 해결했습니다. 서명된 설치 도우미가 동의 요청을 유지하고, 별도 프로세스에서 parent·mode 활성화가 확인된 뒤에만 설치 준비를 완료합니다.
- 업데이트 도중 실행 중인 한결 IMK 서버를 종료해 Chrome·Codex가 stale controller에 연결되고 전환·설정 메뉴가 고장 나던 문제를 해결했습니다. 기존 로그인 세션은 현재 서버를 보존하고, 새 실행 파일은 다음 로그인 또는 재시동부터 적용합니다.
- 실제 입력 E2E가 사용자의 기존 TextEdit 프로세스를 재사용해 열기 창과 문서를 남기던 문제를 해결했습니다. 테스트마다 별도 TextEdit 인스턴스를 만들고 종료까지 확인합니다.
- 전환키를 놓은 직후 Chrome 탭·field를 바꾸며 입력하면 메인 큐보다 첫 keyDown이 앞서 영어 1~2자 또는 `ㄱㅖ`처럼 분리 자모가 입력되던 문제를 해결했습니다. Event Tap과 IOKit은 물리 전환 의도를 즉시 큐에 보존하고, IMK client write와 mode 변경만 메인 스레드에서 수행합니다.
- Chrome·Codex·Slack에서 조합 직후 Forward Delete를 빠르게 누르면 합성 키 재전달이 유실되어 뒤 글자가 남던 문제를 해결했습니다. 조합 시작 위치는 후보로만 보존하고, 확정 문자열·문서 길이·caret·뒤 글자가 모두 일치할 때만 명시적 range 삭제를 수행합니다.
- Chrome field·브라우저 탭 전환 직후 첫 키 처리와 늦은 same-client 활성화가 교차하면 첫 자모의 write lease가 취소되거나 아직 지연된 marked range를 근거로 조합이 폐기되어 `ㄱㅖ`처럼 분리되던 문제를 해결했습니다. 이미 확인된 host field handoff에 속한 활성화만 첫 음절 경계에서 합치고, 이후 활성화는 기존 marked-text 소유권 검사를 유지합니다.

## [3.0.2] - 2026-08-27

### Changed
- 앱·입력 소스 ID를 macOS가 신규 입력기로 분류하는 `com.thlim.inputmethod.Hangyeol`로 변경하고, 설정 prefix와 설치 패키지 ID는 `com.thlim.hangyeol`로 통일했습니다.
- 기존 `com.meapri` 3.0.x와 잘못 배치된 `com.thlim.hangyeol.inputmethod`의 설정·입력 소스 등록은 설치 시 새 식별자로 한 번 이전·정리합니다.

### Fixed
- 3.0 로컬 패키지의 Apple Development 서명에 허용되지 않은 InputMethodKit entitlement가 포함되어, macOS가 앱을 실행 전에 종료하고 입력 소스를 등록하지 못하던 문제를 해결했습니다.
- 모든 서명 경로에서 해당 entitlement를 제거하고, 로컬 패키징 중 실제 서명된 실행 파일이 시작되는지 확인하는 무상태 launch probe를 추가했습니다.
- 제품명이 `inputmethod` 앞에 온 3.0 식별자를 TIS가 신규 입력기로 분류하지 않아 입력 소스 목록에 나타나지 않던 문제를 수정했습니다.
- 리뉴얼 전 한결과 온글·구름에서 검증된 `LSUIElement` 실행 계약을 복원해 Dock 아이콘 없이 설정 창을 유지합니다.
- 식별자 변경 설치에서 PackageKit이 새 앱을 `Hangyeol.localized` 아래로 재배치하던 문제를 없애고, 기존 번들을 표준 `/Library/Input Methods/Hangyeol.app` 경로에서 원자적으로 교체하도록 수정했습니다.

## [3.0.1] - 2026-08-26

### Fixed
- 공식 소스·릴리스 저장소와 업데이트 확인 경로를 `thlim-cube/Hangyeol`로 통일했습니다.
- 3.0 이전 변경 이력에 새 제품명과 3.x 식별자를 소급 적용하지 않고, 당시 2.x 동작을 중립적인 표기로 보존했습니다.

## [3.0.0] - 2026-08-26

### Changed
- 제품 이름을 `한결`로, 시스템·코드 표기를 `Hangyeol`로 전환하고 앱·실행 파일·Swift 모듈·문서·빌드 산출물에서 2.x 제품명을 제거했습니다.
- 앱과 입력 소스 ID를 `com.meapri.hangyeol.inputmethod`, 설치 패키지 ID를 `com.meapri.hangyeol`로 변경했습니다.
- 기존 `P` 앱 아이콘을 새 `한` 아이콘으로 교체하고 반복 생성 가능한 벡터 드로잉 도구를 추가했습니다.

### Migration
- 3.0 설치 시 지원하는 2.x 사용자 설정을 새 키로 한 번 이전하고, 이전 앱·입력 소스 등록·설치 영수증을 정리합니다.
- 새 앱 ID에는 macOS 손쉬운 사용 권한을 한 번 다시 승인해야 하며, 이후 3.x 업데이트에서는 동일한 앱 ID를 유지합니다.

> 3.0 이전 항목은 당시 2.x 제품·코드·입력 소스를 설명합니다. 현재 3.x 제품명과 식별자를 과거 버전에 소급 적용하지 않습니다.

## [2.8.26] - 2026-08-26

### Fixed
- 2.8.24 또는 2.8.25 설치 실패로 2.x 입력기 선택이 ABC로 떨어진 상태에서 업데이트해도, 해당 두 버전에서만 2.x 입력기를 한 번 다시 선택해 전환 불가 상태를 복구합니다.

## [2.8.25] - 2026-08-26

### Fixed
- PKG가 교체 직후의 캐시된 TIS 상태를 설치 완료로 오인하지 않도록, 부모 입력기와 Korean mode의 활성화를 항상 재확인하고 비동기 등록 변경 뒤 다시 조회합니다.
- 업데이트 중 macOS가 2.x 입력기에서 ABC로 임시 전환해도 설치 직전 2.x 입력기 선택 상태를 복구하며, 원래 ABC나 다른 입력 소스를 사용 중이었다면 그 선택을 유지합니다.

## [2.8.24] - 2026-08-26

### Fixed
- ABC와 2.x 입력기만 등록한 구성에서도 macOS의 `Caps Lock 키로 ABC 입력 소스 전환` 옵션이 나타나도록, 단일 Korean mode를 유지한 채 시스템 언어 전환 capability를 복구했습니다.

## [2.8.23] - 2026-08-26

### Fixed
- Chrome 등 Blink 편집기에서 마지막 한글 조합이 문서 텍스트로 확정되기 전에 Shift+Enter를 재전달해 마지막 글자가 사라지던 문제를 수정했습니다.
- 문장 중간 조합 직후 Forward Delete가 아직 확인되지 않은 임시 caret을 조합 위치로 오인해 방금 입력한 글자를 지우던 문제를 수정했습니다.

## [2.8.22] - 2026-08-26

### Fixed
- Chrome·Confluence의 새 controller activation에서 이전 Blink web client proxy가 새 field를 가리킬 때, 이전 조합 문자열이 새 field에 확정되어 `제ㅇ`처럼 복사되거나 한글 입력이 중단되던 문제를 수정했습니다.

## [2.8.21] - 2026-08-25

### Fixed
- Chrome 등에서 포커스 이동 뒤 늦게 도착한 첫 `keyDown`이 이전 field의 조합을 새 field에 확정해 `나나`로 중복되거나, controller 인계 실패로 영문·분리 자모가 입력되던 문제를 수정했습니다.
- 입력 소스 메뉴의 `2.x 입력기 설정...`과 `2.x 입력기 정보`를 InputMethodKit command-dispatch 경로로 연결해 회색 비활성 항목으로 표시되던 문제를 수정했습니다.

## [2.8.20] - 2026-08-25

### Fixed
- 탭·앱·필드 전환 직후 이전 IMK controller의 해제가 늦어져도, 실제 첫 `keyDown`을 받은 controller가 안전하게 소유권을 인계받아 한글 상태의 첫 1~2개 키가 영문으로 통과하지 않도록 했습니다.

## [2.8.19] - 2026-08-25

### Fixed
- 기존 손쉬운 사용 권한이 유지된 업데이트에서도 설치 직후 2.x 입력기 설정 창을 정확히 한 번 표시하도록, 설치 완료 안내와 권한 요청 조건을 분리했습니다.

## [2.8.18] - 2026-08-25

### Changed
- PKG 설치가 PackageKit의 원자적 앱 교체를 유지한 채, 현재 사용자 세션에서 표준 TIS API로 2.x 입력기 번들을 등록하고 부모 입력기와 한글 모드를 순서대로 활성화합니다.
- 처음 설치해 2.x 입력기 등록 기록이 없는 경우 한글 모드를 바로 선택하고, 업데이트에서는 사용자가 선택한 기존 입력 소스를 유지합니다.

### Fixed
- 설치 전에 현재 2.x 앱 번들을 삭제해 입력 소스 등록 공백을 만들고, 설치 후 입력기 agent 4개를 강제 재시작해 2.x 입력기가 사라지거나 재시동 후에도 전환되지 않던 2.8.17 설치 회귀를 해결했습니다.

## [2.8.17] - 2026-08-25

### Changed
- PKG 설치가 현재 로그인한 사용자 세션에서 2.x 입력기의 stale 입력 소스를 동기 정리하고 Launch Services와 입력 관련 agent를 다시 등록해, 기존 업데이트를 로그아웃이나 재시동 없이 적용합니다.
- 설치 전후 프로세스 정리를 로그인 사용자의 정확한 2.x 입력기 프로세스로 제한하고, 다른 사용자 세션과 다른 입력 소스는 변경하지 않습니다.

### Fixed
- 2.x 입력기가 enabled 목록에는 없고 selected/history 목록에만 있는 업데이트를 신규 설치로 오인해 입력 소스 설정을 다시 열던 문제를 해결했습니다.
- 손쉬운 사용 권한이 없는 설치 직후 2.x 입력기 설정을 함께 열어 macOS가 요구하는 사용자 승인 단계를 바로 확인할 수 있습니다.
- Blink에서 첫 조합 시점의 marked range가 지연되거나 임시 caret을 반환해도 이후 자모·Backspace 갱신에서 실제 소유 range를 회복해, `맑 → Backspace → 말 → Forward Delete`가 `말` 대신 뒤쪽 글자를 삭제합니다.

## [2.8.16] - 2026-08-24

### Fixed
- Chrome, Codex, Slack에서 문장 중간의 한글 조합 직후 Forward Delete를 빠르게 눌러도, adapter가 보존한 조합 range로 현재 글자를 확정하고 뒤쪽 글자만 같은 트랜잭션에서 삭제합니다.

## [2.8.15] - 2026-08-24

### Changed
- Blink에서 문장 중간의 한글 조합 직후 Forward Delete를 빠르게 누르는 회귀 검증이 실제 marked-range retirement와 키 재전달 순서를 통과하도록 강화했습니다.

## [2.8.14] - 2026-08-24

### Fixed
- Chrome 등 Blink 웹 편집기에서 한글 조합 직후 Shift+Enter를 누르면 마지막 조합 글자가 사라지던 문제를 해결했습니다.

## [2.8.13] - 2026-08-21

### Added
- Caps Lock이 한글 자음을 쌍자음으로 바꾸는 동작을 설정에서 끌 수 있습니다. 실제 Shift 키를 이용한 쌍자음 입력은 그대로 유지됩니다.

### Fixed
- 한/영 전환 콜백과 입력 controller 교체가 겹쳐도 전환 의도를 보존하고, 새 필드의 첫 안전한 입력 전에 한 번만 적용합니다.
- Blink/Codex에서 조합 직후 Shift+Enter 재전달을 준비하지 못한 경우 marked text를 먼저 지워 마지막 한글이 유실되던 문제를 해결했습니다.

## [2.8.12] - 2026-08-21

### Added
- 설정의 한/영 전환키와 한자 입력키에 `Control + Space` 같은 modifier 조합키를 직접 녹화하고 저장할 수 있습니다. 단일 modifier 키는 기존처럼 키를 눌렀다 놓으면 저장됩니다.

## [2.8.11] - 2026-08-21

### Fixed
- Codex처럼 Blink의 marked range가 늦게 갱신되는 편집기에서도, 문장 중간의 한글 조합 직후 Forward Delete를 빠르게 누르면 조합 글자 대신 뒤쪽 글자를 일관되게 삭제하도록 보완했습니다.

## [2.8.9] - 2026-08-20

### Changed
- 실제 `IMKTextInput` capability를 기준으로 AppKit, Blink 웹, Blink 네이티브, Finder 비텍스트 입력 표면을 분류하고, 입력 전달 어댑터 선택을 단일 resolver로 통합했습니다.
- Blink 웹의 Return·Shift+Return·Forward Delete를 조합 확정과 호스트 키 재전달이 한 경계에서 처리되는 트랜잭션으로 통합했습니다.

### Fixed
- Confluence와 Codex에서 한글 조합 직후 Enter를 누르면 마지막 음절이 사라지거나 Enter를 두 번 눌러야 하던 문제를 해결했습니다.
- 기존 문장 중간에서 입력 중인 한글 뒤를 빠르게 Forward Delete할 때 현재 조합이 삭제되던 문제를 해결했습니다. 조합한 글자가 문서에 반영된 것을 확인한 뒤 뒤쪽 글자만 삭제합니다.
- Finder 이름 변경 필드를 데스크톱 비텍스트 영역으로 오분류해 키 입력이 막히는 경로를 capability와 실제 caret 정보로 분리했습니다.

## [2.8.8] - 2026-08-18

### Fixed
- Confluence 등 Blink 웹 편집기에서 한글 조합 직후 일반 Enter를 누르면 마지막 음절이 사라지던 문제를 해결하고, Shift+Enter 예외는 해당 경로에만 적용되도록 좁혔습니다.

## [2.8.7] - 2026-08-18

### Changed
- Serena 프로젝트 설정을 현재 언어 서버 및 워크스페이스 설정 스키마로 갱신했습니다.

## [2.8.6] - 2026-08-18

### Fixed
- 한글 조합 중 Forward Delete나 앱 전달 키를 누를 때 중복된 빈 marked-text 갱신이 현재 입력을 지우거나 커서를 어긋나게 하던 문제를 해결했습니다.

## [2.8.5] - 2026-08-14

### Fixed
- Slack 등 Blink/Electron 편집기에서 한글 조합 직후 Shift+Enter를 누르면 중복된 빈 marked-text 갱신이 마지막 음절을 지우던 문제를 해결했습니다.

## [2.8.4] - 2026-08-14

### Fixed
- Chrome 등 Chromium 브라우저에서 웹 콘텐츠와 주소 표시줄 같은 native text field의 전달 경로를 분리하되, Slack·Codex·VS Code 같은 Electron 편집기는 직접 삽입으로 오분류되지 않도록 해 커서 위치 오류와 입력 중단을 막았습니다.
- Shift·Backspace를 누른 채 한/영 전환키를 사용해도 즉시 전환되도록 하고, 좌우 Command 동시 입력의 Codex 화면 캡처 동작은 유지했습니다.
- macOS 입력 소스 표시와 겹치던 2.x 입력기의 별도 메뉴 막대 키보드 아이콘을 숨겼습니다.

## [2.8.2] - 2026-08-13

### Fixed
- 단일 IMK 입력 모드 callback이 일반 조합 갱신 경로로 전달되어 전환 직후 marked text가 흔들릴 수 있던 문제를 차단했습니다.
- 우측 Command 한/영 전환이 좌우 Command를 함께 누르는 Codex 화면 캡처 단축키를 가로막지 않도록, modifier-only 전환키는 단독 release에서만 전환하고 전체 키 쌍을 원래 앱에 전달합니다.

## [2.8.1] - 2026-08-12

### Fixed
- 한글 조합 직후 영어로 전환하면 AppKit의 marked-text readback 지연 때문에 마지막 한글 음절이 사라지던 문제를 해결했습니다.
- 일부 외장 키보드와 HID modifier 재매핑 환경에서 전역 키 상태 조회가 실제 `flagsChanged` 이벤트와 어긋나 우측 Command 한/영 전환이 무시되던 문제를 해결했습니다.
- macOS 입력 소스 표시와 2.x 입력기 상태 메뉴가 모두 `한`으로 보여 중복 설치처럼 보이던 문제를 해결하고, 2.x 입력기 상태 메뉴를 고유한 키보드 아이콘으로 구분했습니다.
- 앱 번들·실행 파일·설치 파일 이름을 하나로 통일하고, 설치 시 이전 버전 번들을 제거하도록 정리했습니다.

## [2.8.0] - 2026-08-11

### 입력 정확도
- 같은 물리 keyDown이 IMK에서 재전달될 때 이전 처리 결과와 관계없이 중복을 소비하도록 바꿨습니다. 50ms 추정 대신 이벤트 identity·전체 signature·동일 main-queue delivery turn을 사용해 Return 이중 실행을 막으면서 실제 빠른 연타는 보존합니다. 빈 `characters`의 Return/Numpad Enter도 keyCode로 조합을 확정합니다.
- libhangul 조합을 client별 `InputSession`이 소유하고, process active controller는 이전 session을 retire한 뒤 교체합니다. 현재 field generation이 비보안으로 확인된 경우에만 조합을 client에 확정하고, stale·미확인 generation은 client write 없이 폐기합니다. activate/deactivate 순서 역전과 인계 중 lifecycle 재진입이 새 owner를 덮어쓰지 않습니다.
- 직접 삽입의 marked fallback, delivery mode 변경, 무효 selection 이후 fail-closed 복구를 보강했습니다. 검증하지 못한 문서 범위는 삭제하지 않으며, 손상 대신 현재 미검증 타건을 버린 뒤 다음 조합 경계에서 입력을 재개합니다.
- 한자 후보창은 client/session/generation 수명주기를 검증하고 모든 클릭·모드·포커스·Secure pass-through 경계에서 stale 선택과 늦은 callback을 무효화합니다. 음수 좌표의 보조 화면, 화면별 AX 변환, 하단 mouse fallback을 지원합니다.
- 일반키·조합키 한자 바인딩은 현재 필드가 비보안으로 확인된 경우에만 소비하고, Secure Input 또는 unknown 상태에서는 전체 press pair를 host로 통과시킵니다. modifier-only 한자키의 전역 단축키 동작은 유지합니다.

### 한/영 전환과 상태
- CGEventTap이 반복 실패하면 tap을 완전히 해제한 뒤 IOKit으로 한 번만 인계합니다. down/repeat/up 쌍, 좌우 modifier 상태와 fallback press 수명주기를 추적해 한 물리키가 두 번 전환되는 경로를 막았습니다.
- IOKit fallback의 modifier-only 지원 범위를 중앙 상태에 기록하고, regular/combo 미지원과 시작 실패를 메뉴 막대 상태에 표시합니다.
- Caps Lock 입력 소스 전환 설정을 hot path 밖에서 캐시하고, macOS 소유권 활성화 또는 ABC→2.x 입력기 복귀 때 다음 비보안 입력 전에 내부 모드를 한국어로 정합화합니다. 일반 탭·앱·필드 전환은 마지막 2.x 입력기 모드를 유지합니다.
- 앱 시작 시 `한`/`A` 상태 표시를 생성하고, 평소에는 실제 mode를, macOS 소유권 정합화가 pending이면 실제 mode write 전 예상 `한`을 우선 표시합니다. 메뉴에서 현재 backend, 제한 사항, 손쉬운 사용 권한, Secure Input 상태를 확인할 수 있으며, 연속 상태 알림은 중앙 저장소의 최신 snapshot을 main actor에서 순서대로 적용합니다.

### 설정과 진단
- 영어 편의 처리는 명시적 선택 기능으로 전환하고, 영어 모드에서 현재 Dvorak·AZERTY 등 ASCII-capable 자판을 존중하는 옵션을 추가했습니다.
- DEBUG 입력 로그를 문자·preedit·문서 내용·bundle ID가 없는 구조화 metadata로 제한했습니다. 전환 요청부터 main 실행, 조합 확정, Roman layout override, mode write, 첫 handle까지 monotonic 지연을 추적하며 Release에서는 trace 비용이 없습니다.

### 검증 제한
- Unreleased 입력 경계의 저장소 내 회귀 근거는 fake `IMKTextInput`, synthetic `NSEvent`, mock candidate presenter 기반입니다. 설치된 IME의 실제 InputMethodKit callback 순서와 앱별 동작은 아직 문서화되지 않았으므로 릴리스 전 실기기 매트릭스 검증이 필요합니다.

## [2.7.5] - 2026-07-31

### 수정 (탭 전환 시 마지막 한/영 모드 유지)
- 탭이나 입력 필드가 바뀔 때 새 IMK 세션의 기본 Korean mode가 공유 `HangulComposer.inputMode`를 덮어쓰던 문제를 수정했습니다. 2.x 입력기 등록을 canonical 단일 mode로 복구하고, custom toggle이 더 이상 현재 클라이언트의 `selectInputMode:`를 호출하지 않으며, IMK `setValue` callback도 내부 한/영 상태를 변경하지 않습니다.
- 제거된 `2.x에서 제거한 영어 입력 모드 ID`는 입력 소스 환경설정 정리 시 stale mode로 삭제됩니다.

### 조사 (한글 조합 밑줄 — macOS 26에서는 marked text로 제거 불가)
- 조합 밑줄을 모든 앱에서 없애기 위해 marked text 속성을 엔진별로 조정했으나(`PreeditUnderline`: Blink는 `underlineStyle 1 + alpha 1/255`, 그 외는 `underlineStyle 0 + NSColor.clear`), **macOS 26에서는 효과가 없음을 실측으로 확인했습니다**. NSTextInputClient 프로브로 실제 IMK 전송 경로를 측정한 결과, IME가 보내는 모든 속성 조합 — underline 0+clear, alpha 1/255, `NSMarkedClauseSegment` 1~9(kNoHilite 포함 전체 TSM hilite 카테고리), 심지어 속성 없는 문자열까지 13종 전부 — 이 앱에는 동일한 `NSUnderline=2 + 액센트 블루`로 재생성되어 도착합니다. 수신 측 프레임워크가 IME 스타일을 폐기하고 시스템 표준 스타일을 합성하므로, **macOS 26에서는 어떤 IME도 marked text 밑줄을 숨길 수 없습니다**(애플 한글 IME도 동일한 밑줄). 엔진별 속성 튜닝은 속성이 통과되는 구버전 macOS에서만 유효하며 코드에 유지합니다(오분류·부작용 없음). 밑줄 없는 입력은 marked text를 쓰지 않는 직접 삽입 모드(`2.x 직접 삽입 설정 키`)로 제공됩니다. 측정 과정은 `PreeditUnderline` 주석에 기록했습니다.

### 구조 (end-to-end 입력 파이프라인 개편)
- 세션 스코프 상태(클라이언트, `ClientContext`, delivery 어댑터, 중복 keyDown 상태, 포커스 상실 안전망)를 단일 소유자 `InputSession`으로 통합했습니다. `2.x 입력 컨트롤러`는 IMK 수명 주기만 담당하는 얇은 edge가 되었고, 흩어져 있던 `lastClient`/`lastKnownInputClient`/`cachedContext`/`currentAdapter`/옵저버 필드 간 drift 가능성이 사라졌습니다.
- 조합 종료를 `InputSession.finalize(reason:)` **단일 경로**로 통일했습니다. 앱 비활성, IMK `deactivateServer`, 마우스 클릭 commit, 사용자 한/영 전환키, 자판 배열 변경 — 다섯 가지 종료 이벤트가 전부 같은 멱등 1-op commit(`insertText` + `NSNotFound`)을 사용합니다. 과거 KakaoTalk에서 검증된 시퀀스를 모든 경로에 적용한 것으로, 번들 ID 하드코딩이 전혀 없습니다.
- 조합 출력 전달(어댑터 3종: marked text / 직접 삽입 / immediate)을 `TextDelivery.swift`로 분리하고, 모드 결정을 `TextDeliveryPolicy.mode(for:)` 한 곳으로 모았습니다.
- 한자 후보창 좌표 전략 체인(firstRect → attributes → 캐시 → AX → 마우스)을 `CursorRectResolver.swift`로 분리해 `HangulComposer`가 조합에만 집중하도록 했습니다(약 280줄 감소).

### 수정 (KakaoTalk 한글 커밋 문제, 하드코딩 없이)
- 한/영 전환·Caps Lock 전환·자판 변경 중 조합 종료가 기존에는 별도 2-op commit 경로(`forceCommit` + `setMarkedText("")`)를 사용해, KakaoTalk 등 일부 네이티브 호스트에서 마지막 글자 유실/stranded preedit/이모티콘 팝업 깜빡임이 재발할 수 있었습니다. 모든 종료 경로가 검증된 1-op commit으로 수렴하면서 이 잔여 표면이 제거되었습니다.
- 중복 keyDown 억제(동일 물리 키 이벤트를 2회 전달하는 호스트 — KakaoTalk에서 관찰, 예: 백스페이스 1회에 자모 2개 분해)를 실험적 직접 삽입 모드 전용에서 **모든 delivery 모드 공통**으로 일반화했습니다. 중복 전달은 호스트 이벤트 전달의 속성이지 렌더링 방식의 속성이 아니기 때문입니다.
- 포커스 상실 안전망(NSWorkspace 비활성 옵저버)을 세션 소유로 옮기고, `deactivateServer`에서 반드시 disarm하도록 했습니다. 이전 구조에서는 stale 옵저버가 늦게 발화하면 공유 composer의 새 조합을 이전 앱 클라이언트로 흘릴 수 있는 cross-app commit-leak 가능성이 있었습니다.
- `deactivateServer` 이후 같은 클라이언트 객체로 `handle()`이 먼저 도착하는 경우(컨텍스트 stale — 같은 앱의 다른 필드로 포커스 이동 가능) 컨텍스트를 재분석한 뒤 처리하도록 명시했습니다.

### 변경
- 한글 조합 중 표시되던 밑줄(preedit underline)을 제거하고 평문 marked text로 표시하도록 했습니다.
- 앱 포커스 상실 시 조합을 강제 커밋하던 호환성 로직(과거 KakaoTalk 대응에서 일반화한 NSWorkspace 비활성 옵저버)을 완전히 제거했습니다. 정상 포커스 전환 commit은 IMK `deactivateServer`가 담당합니다.
- libhangul-swift 최신(main)에 맞춰 통합을 점검했습니다. 새 기본값(`outputMode .syllable`, `combinationOnDoubleStroke` OFF, `fineGrainedBackspace` ON, NFC 정규화)이 표준 2벌식 동작과 일치하여 코드 변경은 없으며, 기본값이 바뀌어도 조합이 깨지지 않도록 회귀 테스트(ㄱㄱ↛ㄲ, 와→오 단계 백스페이스)를 추가했습니다.

### 수정
- 한글 입력이 전혀 되지 않던 회귀를 고쳤습니다. 통합 아키텍처 작업 중 `Info.plist`의 입력기 등록에 최상위 `TISInputSourceID`(자식 입력 모드와 동일 ID)와 모드별 `TISInputSourceID`/`tsInputModeDefaultStateKey` 등 불필요한 키가 추가되면서 TIS 등록이 깨져, 입력 소스를 선택해도 조합이 동작하지 않았습니다. 등록을 검증된 2.6.5의 최소 `ComponentInputModeDict` 구조로 복원했습니다(단일 모드 `2.x 단일 입력 모드 ID`, `smKorean`). 조합 엔진 자체는 정상이었고(유닛 테스트 통과) 원인은 등록부였습니다.

### 구조
- 한/영 입력 구조를 `v2.6.5`의 단일 상태기계와 `v2.7.2`의 macOS 통합 장점을 결합한 **단일 소스 하이브리드**로 정식화했습니다. 2.x 입력기 단일 입력 소스가 IMK 세션을 영구 소유하고, 한/영은 `HangulComposer.inputMode` 하나로 내부 전환합니다. 정식 명세를 [Docs/UnifiedInputArchitecture.md](Docs/UnifiedInputArchitecture.md)로 추가하고, 기존 RollbackPlan(가짜 모드 2개 등록 안)은 superseded 처리했습니다.

### 개선
- 영어 모드를 순수 pass-through로 정리했습니다. 2.x 입력기가 영문 입력에서 로컬 버퍼를 추적하거나 텍스트를 직접 삽입하지 않으며, 더블스페이스 마침표 등 영문 텍스트 편의는 macOS가 담당합니다. 버퍼-커서 불일치로 인한 잠재 버그 경로를 제거했습니다.
- 사용되지 않던 입력 소스 헬퍼(`ensureDefaultEnglishInputSourceEnabled`, `당시 입력 모드 활성화 헬퍼`)를 제거하고, stale 정리는 `cleanupStaleInputSources` 한 곳으로 정리했습니다.
- 앱 포커스 상실 시 한글 조합을 강제 커밋하던 동작에서 KakaoTalk 번들 ID 하드코딩을 제거했습니다. 이제 특정 앱에 의존하지 않고 모든 앱에 대해 동작하는 멱등 안전망(이미 커밋된 호스트에서는 no-op)으로 일반화했습니다.
- 사용자 지정 한/영 전환키 경로를 `InputModeCoordinator → 2.x 입력 컨트롤러 → HangulComposer` 한 줄로 일원화해, Caps Lock 정책·활성 컨트롤러 가드·전환 전 1회 commit을 한 곳에서 보장하도록 정리했습니다(전환 콜백은 검증된 2.6.5 기준선대로 메인 런루프에 올립니다).
- `HangulComposer.inputMode`의 write 경로를 토글 전환과 외부 입력소스 선택(ingress) 두 곳으로 한정한다는 계약을 코드 주석으로 명문화했습니다.

### 안정성
- `activateServer`가 `deactivateServer` 없이 반복 호출(Electron/Chromium 계열에서 흔함)될 때 자판 변경 옵저버가 중복 등록돼 `handleLayoutChange`가 여러 번 실행될 수 있던 문제를 막았습니다(재등록 전 기존 등록 제거).
- `2.x 입력 컨트롤러`에 `deinit`을 추가해 자판 변경 옵저버와 앱 비활성 옵저버(block 기반은 자동 제거되지 않음)를 정리하도록 했습니다.
- 손쉬운 사용 권한 요청 후 권한을 polling하던 타이머가 권한을 끝내 허용하지 않으면 무한정 돌거나, 버튼을 반복 누르면 중첩되던 문제를 수정했습니다. 타이머를 저장해 재요청 시 교체하고, 상한(약 2분) 후 자동 종료하며, 설정 창이 사라질 때 무효화합니다.

### UX
- 2.x 설정 창 제목을 한국어와 영어로 로컬라이즈했습니다. 시각적으로는 숨겨져 있지만 Window 메뉴·Mission Control·VoiceOver가 사용하는 값이라 언어에 맞게 읽히도록 정리했습니다.

### 테스트
- 그동안 커버리지가 없던 순수 함수에 회귀 테스트를 추가했습니다(9개): 한자 후보창 좌표 유효성 검증(`isValidCursorRect` — Chromium 쓰레기 좌표 거부)과 초성↔호환 자모 변환(`isChoseongJamo`/`choseongToCompatibility`/`isJamoConsonant`).
- AX 좌표 경로의 유일한 강제 언랩(`AXValueCreate(...)!`)을 graceful fallback으로 바꿔 잠재 크래시 경로를 제거했습니다.

### 검증
- 2.x 당시 Debug 앱 빌드
- `swift test` (121개 통과)
- 2.x 당시 Debug 검증 도구 실행
- 2.x 당시 Release 앱 빌드

## [2.7.4] - 2026-05-21 (Stable)

### 수정
- 시작 시 2.x 입력기가 자기 입력 소스를 다시 enable 하던 경로를 제거해, 부팅 후 macOS가 입력 소스 추가/허용 확인창을 띄울 수 있는 부작용을 줄였습니다.
- KakaoTalk에서 앱 포커스를 잃을 때 남은 한글 조합을 강제 커밋하도록 알려진 앱 호환성 정책을 추가했습니다.
- 업데이트 알림 권한 요청을 앱 시작 시점이 아니라 실제 업데이트 알림을 보낼 때로 늦춰, 시작 시 불필요한 권한 팝업이 뜰 수 있는 경로를 제거했습니다.
- 입력 hot path의 디버그 카운터를 DEBUG 빌드에만 포함되도록 정리했습니다.

### 개선
- 설정창 폭과 상태 표시를 조정해 Caps Lock 안내, 키 설정, 손쉬운 사용 권한 상태가 덜 잘리고 더 안정적으로 보이도록 정리했습니다.

### 검증
- 2.x 당시 Debug 앱 빌드
- 2.x 당시 Debug 검증 도구 실행
- 2.x 당시 Release 앱 빌드
- 2.x 당시 Release 검증 도구 실행
- 2.x 당시 Release 벤치마크 실행
- Release PKG 서명, Apple 공증, 스테이플, Gatekeeper 검증

## [2.7.3] - 2026-05-20 (Stable)

### 수정
- KakaoTalk에서 한글 조합 중 다른 앱으로 포커스를 옮겼다가 돌아오면 마지막 조합 글자가 확정되지 않고 다음 입력으로 덮어써지던 문제를 보완했습니다.
- KakaoTalk이 앱 비활성화 후에도 IMK marked composition을 오래 붙잡는 경우를 처리하기 위해, KakaoTalk 비활성화 시 조합 중인 글자를 즉시 커밋하도록 호환성 정책을 추가했습니다.
- 2.x 입력기 실행 시 자기 입력 소스를 다시 활성화하던 자동 입력 소스 제어 경로를 제거했습니다. 재부팅할 때마다 macOS가 2.x 입력기 입력 소스 추가 확인창을 반복 표시할 수 있던 원인을 줄였습니다.

### 검증
- `swift test`
- 2.x 당시 Debug 검증 도구 실행
- 2.x 당시 Release 벤치마크 실행

## [2.7.2] - 2026-05-18 (Stable)

### 수정
- 조합 중 Return/Enter 처리 시 조합을 확정하고 marked text를 명시적으로 정리한 뒤 원래 Return 이벤트를 앱에 그대로 전달하도록 단순화했습니다. 추가 클라이언트 속성 조회나 synthetic key 재전달을 제거해 입력 지연 가능성을 줄였습니다.
- GoodNotes의 IMK Return 재진입 문제를 알려진 앱 호환성 정책으로 처리합니다. GoodNotes에서 조합 중 Return은 조합을 확정한 뒤 줄바꿈을 직접 삽입하고 원래 Return을 소비해 중복 줄바꿈을 막습니다.
- MapleStory/Wine 전용 입력 호환 실험 경로를 제거하고 일반 IMK 조합 처리로 되돌렸습니다.

## [2.7.1] - 2026-05-18 (Stable)

### 수정
- 한글 조합 중 Return/Enter를 눌렀을 때 일부 앱에서 줄바꿈이 두 번 입력되던 문제를 수정했습니다.
- 조합 중 Enter는 2.x 입력기가 조합을 확정하고 줄바꿈을 한 번만 삽입한 뒤 원래 Enter 이벤트를 소비합니다.
- 조합이 없는 상태의 Enter는 기존처럼 앱에 그대로 전달합니다.

### 호환성
- 최소 지원 버전을 macOS 14.0 Sonoma로 낮췄습니다.
- macOS 26 Tahoe 전용 Liquid Glass API는 Tahoe 이상에서만 사용하고, Sonoma/Sequoia에서는 기본 vibrancy fallback을 사용하도록 정리했습니다.

### 문서
- Release 빌드 기준으로 벤치마크를 다시 측정하고 `BENCHMARK.md`를 갱신했습니다.
- README를 현재 설치 방식, Caps Lock 전환 정책, Sonoma 지원 기준에 맞게 정리했습니다.

### 검증
- `swift build -c release`
- 2.x 당시 Release 검증 도구 실행
- 2.x 당시 Debug 앱 빌드
- 2.x 벤치마크 도구 실행 및 macOS 최소 버전 `14.0` 확인

## [2.7] - 2026-05-18 (Stable)

### 핵심 변경
- 영어 입력은 2.x 입력기 내부 영어 모드가 아니라 macOS 기본 `ABC` 입력 소스를 사용하도록 전환했습니다. 2.x 입력기는 한글 입력 소스 역할에 집중합니다.
- Caps Lock 한/영 전환을 2.x 입력기 자체 키 가로채기 경로에서 제거하고 macOS 입력 소스 전환 설정을 따르도록 정리했습니다.
- 2.x 입력기 입력 소스 등록을 단일 한글 입력 소스(`2.x 한글 입력 모드 ID`)로 정리해 메뉴 막대에 `한글`이 중복 표시되던 문제를 해결했습니다.
- 오래된 2.x 입력기 영어 입력 소스, component input mode, Apple Korean 입력 모드 잔여 등록을 정리하는 복구 로직을 추가했습니다.

### 개선
- 우측 Command/우측 Option 등 2.x 입력기 사용자 지정 전환키는 CGEventTap/IOKit 경로를 유지하면서 실제 macOS 입력 소스 선택과 동기화되도록 정리했습니다.
- 자동 문장 대문자 옵션을 제거했습니다. 영어 입력이 macOS `ABC`로 이동했기 때문에 해당 동작은 macOS 기본 입력기가 담당합니다.
- 스페이스 두 번으로 마침표를 입력하는 동작은 2.x 입력기 별도 설정 대신 macOS `NSAutomaticPeriodSubstitutionEnabled` 설정을 따르도록 변경했습니다.
- 앱 활성화, 창 전환, 키 입력 중 불필요한 Accessibility/컨텍스트 검사를 줄여 입력 지연이 발생할 수 있는 경로를 완화했습니다.
- 비밀번호/보안 입력 필드에서는 조합 상태를 정리하고 즉시 패스스루하도록 보강했습니다.

### 설정 및 UX
- 설정창을 macOS Liquid Glass 스타일에 맞게 정리하고, 기본 시스템 폰트와 당시 새 앱 아이콘 헤더를 사용하도록 변경했습니다.
- Caps Lock은 2.x 입력기 전환키로 직접 지정하지 못하게 막고 macOS 입력 소스 설정 상태, 안내 문구, 설정 바로가기를 제공하도록 변경했습니다.
- 키 설정 충돌 시 기존 설정을 복원했다는 피드백을 표시하도록 했습니다.
- 더 이상 필요하지 않은 기본 영어 입력기 제거 기능, 자동 대문자 옵션, 2.x 입력기 전용 더블스페이스 옵션을 제거했습니다.

### 아이콘 및 입력 소스 표시
- 앱 아이콘과 입력 소스 메뉴/팔레트 아이콘을 새 자산으로 교체했습니다.
- 한글 입력 소스 이름과 아이콘 리소스를 패키지와 로컬 설치 경로에 함께 포함하도록 정리했습니다.

### 패키징
- 릴리즈/디버그 패키징 스크립트가 임시 payload 디렉터리를 사용하도록 변경해 빌드 잔여물이 LaunchServices에 등록되지 않게 했습니다.
- 설치 후 Script Editor 알림을 띄우던 AppleScript 의존성을 제거하고 TextInput 관련 프로세스 재등록 범위를 보강했습니다.
- 버전을 `2.7`, 빌드를 `35`, 릴리즈 채널을 `stable`로 갱신했습니다.

### 검증
- `swift build -c release`
- 2.x 당시 Release 검증 도구 실행
- Release/Debug PKG 서명, 공증, 스테이플, Gatekeeper 검증

## [2.6.5] - 2026-05-10 (Stable)

### 추가
- 앱 버전에 `stable`/`beta` 릴리즈 채널을 구분하는 메타데이터를 추가했습니다.
- 설정/정보 화면에서 현재 버전을 `v2.6.5 (Stable)`처럼 채널과 함께 표시합니다.
- GitHub Releases 목록에서 stable 후보만 고르는 업데이트 검증 테스트를 추가했습니다.
- SwiftPM 테스트와 검증 도구에서도 한자 사전 리소스가 실제로 로드되는지 확인하는 테스트를 추가했습니다.

### 개선
- 업데이트 확인 로직이 더 높은 beta 버전이 있어도 stable 릴리즈만 표시하도록 변경했습니다.
- `v3.0.0-beta.1`처럼 beta 표기가 붙은 태그는 GitHub의 prerelease 플래그가 빠져 있어도 stable 업데이트 후보에서 제외합니다.
- 릴리즈 워크플로우가 태그 버전과 `Info.plist`의 버전/채널을 함께 검증하도록 강화했습니다.
- 릴리즈 패키징 스크립트가 서명, 공증, 스테이플, Gatekeeper 검증을 필수 단계로 수행하도록 정리했습니다.
- 성능 벤치마크가 `Info.plist`의 실제 앱 버전을 기준으로 표시되도록 개선했습니다.

### 수정
- 비밀번호창에서 `selectedRange == NSNotFound`인 경우 Accessibility 검사 없이 즉시 패스스루하도록 단순화해, 한글 상태 비밀번호 입력 시 경고음과 렉이 발생할 수 있던 경로를 제거했습니다.
- 비밀번호/보안 입력창에서 macOS Secure Event Input은 켜져 있지만 Accessibility 포커스 판별이 `unknown`인 경우를 예전 안정 동작처럼 즉시 패스스루하도록 복원해, 한글 입력 시 경고음이 발생할 수 있던 경로를 수정했습니다.
- 일부 비밀번호 입력창에서 매 키 입력마다 Accessibility 포커스 검사를 타며 심한 렉이 발생할 수 있던 문제를 수정했습니다.
- 비밀번호/보안 입력 필드에서 불필요한 조합 입력으로 경고음이 발생할 수 있는 경로를 보강했습니다.
- Wine/게임 환경 감지와 입력 경로를 강화해 일부 게임 런타임에서 한글 조합이 깨지는 위험을 줄였습니다.
- 한자 후보창 위치 계산에서 Chromium 계열 앱과 Accessibility fallback 경로를 더 안정적으로 처리했습니다.
- SwiftPM 테스트/검증 환경에서 `hanja.txt`와 localization 리소스를 못 찾아 한자 사전 로딩 경고가 반복되던 문제를 수정했습니다.
- 오래된 실험용 `sim*.swift` 파일을 제거하고 재추적되지 않도록 정리했습니다.

### 검증
- Swift 테스트 121개 통과
- SwiftLint strict 0건
- 2.x 검증 도구 통과
- 2.x 벤치마크 도구 통과
- 릴리즈 PKG 서명, Apple 공증, 스테이플, Gatekeeper 검증 통과

## [1.0.0] - 2025-12-11

### Added
- Initial release
- Hangul composition using libhangul-swift
- Korean/English toggle via Right Command or Control+Space
- SwiftUI-based settings window
- Auto-capitalize and double-space period features
- Finder desktop detection for floating window prevention
- Secure input field detection (password fields)
- Debug-only logging with complete release removal
