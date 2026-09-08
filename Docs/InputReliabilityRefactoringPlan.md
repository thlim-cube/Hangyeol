# 한결 입력 신뢰성 리팩토링 계획

작성: 2026-09-05 · 기준 HEAD `ff44a84` · 설치된 앱 3.0.18/build 101
초안: `grok-oauth/grok-4.6`, reasoning `high` 하위 에이전트. 근거 확인·통합 검토: 부모 에이전트.
상태: 사용자 수정 승인 후 구현 진행 중. Grok 4.6·high가 구현하고 부모 에이전트가 근거·검증·통합을 담당한다.

## 2026-09-08 추가 요구 (이전 계획보다 우선)

- 한영 전환 직후 **첫 글자만 전환 전 언어로 입력되는 문제**를 조사한다. 앞선 글자 자체가 다시 붙는 현상은 아니라는 사용자 확인을 받았다. 재현 가능한 결함만 수정하고 실제 호스트 재현 여부를 구분한다.
- 추가 모음 결합과 분해 삭제를 **하나의 영구 설정**으로 묶고 기본값은 `false`로 한다. 꺼짐: `ㅕ + ㅣ`를 `ㅖ`로 합치지 않고 직접 입력한 `ㅖ`를 Backspace로 지우면 `ㅕ`를 남기지 않는다. 켜짐: `ㅕ + ㅣ → ㅖ`, `ㅖ → ㅕ`를 허용한다. `ㅐ`와 유사한 추가 결합 모음도 같은 정책을 적용한다.
- 일반적인 `ㅗ + ㅏ → ㅘ`와 자음 조합은 유지한다. 설정 초기값·저장·현재 조합·키보드 재생성에 대한 회귀 테스트를 포함한다. 이전의 엔진 기본값을 유지한다는 계획은 이 요구를 덮어쓸 수 없다.
- 이번 작업 시작 시 제품 코드 변경은 없었고 미추적 파일은 이 계획서뿐이었다. 이전 작업의 구현 완료를 전제하지 않는다.

## 실행 계약

목표: Delete·Maestro Home/End·설치 메뉴의 재현 가능한 결함을 단계별로 고치고, 수정 전후 증거와 배포 가능한 로컬 패키지를 남긴다.
완료 조건: 각 변경 전 실패/변경 후 통과, 관련 lane과 전체 테스트, Release 빌드, 버전/build 증가, 한국어 semantic commit, 동일 버전 Apple Development 서명 Local.pkg 검증. 실호스트 입력·설치 직후 메뉴 증거는 별도 수용 조건으로 남긴다.
범위 밖: push, 사용자 설치본 교체, 강제 프로세스 재시작, 재로그인, 새 의존성, 입력 원문 수집. 설치 기반 검증은 사용자 확인 후 수행한다.
진행 순서: 지연 Delete 작업 권한 → 물리/합성 modifier 경계 → 설치/메뉴의 관측된 결함 → 누적 검증과 패키징. 메뉴 원인이 재현되지 않으면 임의 복구 코드를 넣지 않고 남은 검증 조건을 명시한다.

## 사용자 요구

1. 한글 입력 중 Delete가 기대와 다르게 동작한다.
2. Home이 한 칸씩만 움직이거나 기대와 다르게 이동한다. Home/End는 Keyboard Maestro가 `Command+←/→`로 매핑한다.
3. 설치 후 tray 입력기 설정 메뉴가 사라지는 문제가 남아 있다.
4. 원인은 코드로 확정된 행동과 실호스트 미재현 가설을 분리하고, 승인된 수정을 Grok 4.6·high로 실행한다.
5. 한영 전환 직후 첫 글자부터 새 언어를 적용한다.
6. 추가 모음 결합·분해 삭제를 하나의 기본 꺼짐 옵션으로 제공한다.

비범위: 전면 rewrite, libhangul 교체, 새 의존성, Maestro 설정 변경, 원시 입력 문자·전체 keycode 로그, 임의 sleep 증가, 모든 후속 입력 일괄 취소.

## 확인된 기준선

- 계획 조사 시작 시 HEAD `ff44a84`, worktree clean, `main`이 origin보다 15커밋 앞선 상태. 구현 시작 시 미추적 파일은 이 문서뿐이었다.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-update`: `Test run with 510 tests in 53 suites passed after 1.458 seconds.`
- 계획의 3개 관련 lane을 합친 selector 검증: `Test run with 220 tests in 11 suites passed after 0.218 seconds.`
- 설치본 `--post-install-status`: `candidates=true enabled=true ready=true`.
- E2E `--preflight-only`: 설치/PKG CDHash `37c5091a7a60ff386b55362a7a4cdd506de6c01f` 일치, AX·CGEvent 권한 PASS.
- 실 TextEdit/Chrome 타이핑, 실행 중 code object, tray 메뉴, relogin TIS는 미검증.
- 2026-09-08 수정 전 재검증: 전체 510개 / 53 suites 통과 (1.497초), 설치본 3.0.18의 후보·enabled·ready 모두 true. 이는 설치 메뉴의 현재 표시 여부를 증명하지 않는다.

## 확인된 코드 행동 vs 실사용 가설

이 절의 코드 위치와 진단은 수정 전 기준이다. 실제 반례 재현과 수정 후 결과는 마지막 **구현·검증 기록**을 우선한다.

코드로 확인된 행동과 사용자 증상의 인과는 아직 같지 않다. 아래 가설은 재현 전에는 원인 확정이 아니다.

### Delete

확인: 현재 엔진의 Backspace(51)는 복합 자모를 분해한다 (`HangulComposerTests.swift:973`). 일반 조합 `와 → 오 → ㅇ`과 달리 직접 입력한 `ㅐ → ㅏ`, `ㅖ → ㅕ` 등의 추가 분해는 2026-09-08 요구에 따라 기본 꺼짐 옵션으로 분리한다. ForwardDelete(117)는 별 경로다.

확인: `InputSession.swift:410-414`의 `clientWritesAreConfirmedSafe`는 현재 generation의 동적 bool이다. `InputSession.swift:1013-1016`은 `[weak self] self?.clientWritesAreConfirmedSafe == true` closure를 adapter에 붙인다. `HostTextAdapters.swift:86-102`가 이 closure를 `HostKeyTransaction`에 넘기고, `HostKeyTransaction.swift:4-10`의 `DeferredClientWriteAuthorization`은 closure만 저장한다.

확인: `InputSession.swift:420-425`에 `ContextStateLease`가 있지만 이 host-key 지연 경로에는 캡처되지 않는다. `HostKeyTransaction.swift:185-194`, `452-497`은 권한이 false면 중단하고, 준비 상태가 확인되면 전달한다. 준비가 끝내 확인되지 않으면 최대 100회 polling 뒤 중단한다. 이때 원래 keyDown은 이미 소비됐고(`529-577`), 해당 종료 분기에서는 host에 재전달하지 않는다. 정상 전달 경로 전체가 중복이라는 뜻은 아니다.

확인: `ReturnDeliveryTests.swift:990-1033`은 `true`를 `false`로 바꾼 뒤 유지하는 케이스다. `true → false → true` ABA는 잡지 못한다.

가설(미재현): 같은 client에서 field handoff가 일어나 새 field가 비보안으로 다시 승인되면, 옛 ForwardDelete/Return 작업이 살아날 수 있다. 이는 안전 여부가 true → false → true로 돌아오면서 이전 작업까지 유효해 보이는 ABA 문제다. 텍스트·caret gate는 추가 보호지만 내용/위치가 같다는 사실만으로 같은 field임을 증명하지는 않는다. 사용자 Delete 증상의 확정 원인은 아니다.

가설(미재현): `DirectInsertionPlanner.swift:80-94`, `121-129`는 같은 delivery turn에서 timestamp가 달라도 비반복 동일 키를 중복으로 소비한다. `InputSession.swift:606-625`는 main-queue에서 generation이 같을 때만 turn을 끝낸다. 실제 빠른 입력이 이 순서로 오는지는 미재현.

### Home / Keyboard Maestro

확인: 물리 전환키 해제 후 잔류 Command 제거는 `RightCommandSuppressor.swift:489-547`의 의도된 경로다. 현재 코드는 `eventSourceUnixProcessID > 0`을 합성키 보존의 판단값으로 사용한다. 실제 Maestro 이벤트의 PID·side flags를 관측하지 않았으므로, 이 조건을 모든 물리/합성 이벤트에 대한 확정 분류로 취급하지 않는다.

확인: `hasSuppressedKeyCodes || hiddenKeyCode != nil` 분기는 `preservesSynthesizedModifiers`보다 먼저 `hostVisibleModifierFlags`로 재작성한다 (`RightCommandSuppressor.swift:519-527`). 이 경로에서는 합성 Command/Shift도 물리 `pressedKeyCodes` 기준으로 빠질 수 있다.

확인: `flagsChanged`는 PID와 무관하게 `modifierKeyIsDown`으로 물리 상태에 넣는다 (`RightCommandSuppressor.swift:279-316`). 합성 Command down이 물리 집합에 남으면 이후 정규화도 그 상태를 따른다.

확인: 단위 테스트 `synthesizedCommandNavigationRemainsHostVisible`는 `preservesSynthesizedModifiers: true`를 직접 넘긴다. 실제 CGEvent PID, suppression/hidden 교차, Maestro `Command+←/→` 호스트 결과는 미검증.

가설(미재현): Home이 한 칸 이동하는 현상은 합성 `Command+Left`의 Command가 제거된 결과일 수 있다. 3.0.18이 정규화 분기 회귀를 고친 뒤에도 suppression/hidden·물리 관측 교차는 남아 있다.

### 설치 후 메뉴 소실

확인: `InputSourceManager.swift:10-16`의 `isReady`는 후보+enabled만 본다. IMK 연결·tray 메뉴 표시는 보장하지 않는다.

확인: `HangyeolInputController.swift:1287-1294`의 `menu()`는 새 `NSMenu`를 만든다. `InputMethodMenuTests.swift:9-33`은 프로세스 안에서 만든 메뉴 구조만 본다.

확인: `Packaging/scripts/postinstall:197-202` ordinary update는 현재 IMK를 유지하고 다음 로그인 marker를 남긴 뒤 `exit 0`한다. 현재 세션 메뉴 검증은 없다.

미확정: `main.swift:114`의 `IMKServer` 반환값 미보관은 수명 조사 후보다. 메뉴 소실 원인으로 확정하지 않는다.

2026-09-08 반증 실험: 고유 bundle ID·connection name의 임시 `.app`에서 제품과 같은 `init(name:bundleIdentifier:)` 경로로 생성한 서버는 지역 참조와 autoreleasepool 종료 뒤에도 weak 참조가 살아 있었다 (`created=true`, `retained_after_scope=true`). 기존 설치본을 선택·등록·재시작하지 않은 격리 실험이다. 따라서 단순히 반환값을 버렸다는 이유만으로 메뉴 소실의 원인을 확정하거나 보관 코드를 해결책으로 제시하지 않는다. Apple 문서는 이 서버가 [입력 클라이언트 연결을 관리함](https://developer.apple.com/documentation/inputmethodkit/imkserver)을 명시하지만 설치 후 실제 메뉴 가시성까지 보장하지 않는다.

확인된 검증 공백: TIS ready와 IMK 연결·메뉴 표시는 서로 다른 조건인데 현재 성공 판정은 후자를 확인하지 않는다. 이 공백은 미해결 메뉴 문제를 놓치는 이유이지, 메뉴를 사라지게 하는 직접 원인이 확정됐다는 뜻은 아니다. 현재 메뉴 연결 단절·실행본 불일치·메뉴 요청 실패 중 어느 경로인지는 미검증이다.

## 설계 선택과 핵심 계약

작은 경계별 리팩토링을 선택한다. 기존 engine·adapter를 모두 대체하는 전면 재작성은 호스트별 조합 종료와 Secure Input 계약을 동시에 바꾸므로 범위에서 제외한다.

| 경계 | 현재 → 제안 | 유지할 계약 |
| --- | --- | --- |
| 지연 host-key 권한 | 현재 안전 여부 closure → 작업 시작 시점의 불변 lease + 실행 직전 검증 | 동기 adapter 쓰기 정책은 유지하고, 지연 작업에만 당시 field/adapter 소유권을 고정 |
| modifier 처리 | 보정 과정에서 출처 재해석 → 출처 관측·전환 소유·host-visible flags 결정 분리 | 단일 InputModeStore, 좌우 Command 전환, 정상 Command/Shift shortcut, 자체 replay 우회 |
| 설치 판정 | 등록 상태 `isReady` → 등록·실행본/IMK 응답·실제 메뉴 확인을 각각 보고 | 기존 CLI 필드와 종료값 소비자를 먼저 조사하고 호환성 유지; 메뉴 미확인을 성공으로 승격하지 않음 |

새 타입·필드 이름은 제안이며 아직 API 변경은 없다. 큰 입력 큐나 새 프레임워크를 도입하지 않고 기존 `ContextStateLease`, `HostKeyTransaction`, 설치 lifecycle 테스트를 확장한다.

## 재현 행렬

아래 문자열은 검증용 합성 fixture이며 `|`는 실제 문자가 아니라 caret 표기다. 최종 텍스트뿐 아니라 선택 범위, marked text 종료, host action 횟수도 검사한다.

| 상황 | 기대 결과와 증거 |
| --- | --- |
| 한영 전환 직후 첫 키 | 전환 처리 중 layout override 등이 재진입해도 첫 키부터 새 언어 사용; 두 방향·연속 전환·field/secure 경계 포함 |
| 추가 모음 옵션 꺼짐 (기본) | `ㅕ + ㅣ`는 `ㅖ`로 합쳐지지 않음; 직접 입력한 `ㅐ`/`ㅖ`를 삭제하면 `ㅏ`/`ㅕ`를 남기지 않음 |
| 추가 모음 옵션 켜짐 | `ㅏ/ㅑ/ㅓ/ㅕ + ㅣ → ㅐ/ㅒ/ㅔ/ㅖ`, 역방향 분해 삭제 허용; 설정 변경 및 키보드 재생성 후에도 같은 정책 |
| 조합 중 Backspace | `와 → 오 → ㅇ`, `맑 → 말`; 한 번 누름·독립 연타·길게 누름을 구분 |
| 조합 확정 뒤 Backspace | host가 커서 앞(왼쪽) 문자 한 개만 삭제; IME와 host가 중복 처리하지 않음 |
| Forward Delete | `가나|다라`에 `마` 조합 후 Delete → `가나마|라`; Backspace로 `맑 → 말` 후 Delete → `가나말|라` |
| 지연 삭제와 field 변경 | A에서 예약 후 동일 client의 B를 재승인해도 A 작업은 B에 쓰지 않음; 두 field의 텍스트·caret가 같은 경우도 포함 |
| 지연 삭제 직후 입력 | 다음 문자·다음 Delete·Home·Tab이 먼저 들어오는 순서를 결정론적으로 구동; 전달/취소가 한 번만 종결되고 늦은 삭제가 후속 입력에 적용되지 않음 |
| Maestro Home/End | 줄바꿈·자동 줄바꿈 없는 한 줄 중간에서 정확히 줄 시작/끝 이동; Shift 동반 시 해당 구간만 선택 |
| 전환키와 합성키 교차 | 좌/우 Command 설정 각각, 전환 전·누른 중·해제 직후와 suppression 유무; 실제 눌린 Shift 보존 및 `f/ㄹ`이 찾기를 열지 않음 |
| 중복 전달과 고유 연타 | 동일 이벤트 재진입은 한 번만 처리; 다른 timestamp/identity의 독립 입력은 main-queue clear 전이라도 손실 여부를 검증 |
| 설치 전후 메뉴 | 최초 설치·일반 업데이트·등록 변경을 분리; 직후와 재로그인 후 각각 source 표시, 설정 항목, 설정 창 열기 확인 |

## 단계 계획

공통 제약: 단일 `InputModeStore`와 IMK 세션 소유를 유지한다. lifecycle finalize/`InputSession`을 보존한다. DebugLogger는 debug-only로 비문자 intent·generation·결과만 남긴다. 원시 문자, 전체 keycode stream, 문서 본문 로그는 금지한다.

### 0. 재현 정의와 관측

대상: 기존 `DebugLogger` 진단 지점, `ReturnDeliveryTests`, `ToggleMonitoringTests`, `InputSessionFinalizeTests`, `InputMethodMenuTests`, `HangyeolE2ERunner`. 이 단계에서는 제품 동작을 바꾸지 않는다.

수용: 위 행렬을 바탕으로 최소 실패 시퀀스 또는 결정론적 반례 테스트를 만든다. 기존 테스트를 먼저 확장한다. DEBUG 진단은 비문자 intent, 출처 분류 결과, opaque 작업/세대 ID, delivered/cancelled 사유만 허용한다. 분류 불가능한 이벤트는 unknown으로 유지한다. 사용자 입력 원문·전체 keycode stream·document 내용·bundle ID는 기존 `DebugLogger` 계약대로 남기지 않는다. 실제 문자열·caret 비교는 합성 fixture에서만 수행한다.

검증: 아래 실행 명령의 suite selector를 사용한다. `ToggleMonitoringTests.swift`는 파일명이므로 `--filter ToggleMonitoringTests`를 사용하지 않는다. 재현 전후 실패 여부와 실행 테스트 수를 기록한다. 실호스트는 격리 fixture에서 관측하고 사용자 작업 창의 본문은 읽거나 바꾸지 않는다.

롤백: 제품 입력 경로는 유지한 채 새 진단만 비활성화할 수 있게 한다. 재현 테스트는 후속 수정의 증거로 보존한다. 입력 동작 변경이 섞이면 0단계 범위를 벗어난 것으로 본다.

위험: 민감한 로그가 생기면 진단을 중단하고 범위를 바로잡는다. 최소 반례 없이 추측으로 1·2·3단계를 동시에 변경하지 않는다. 코드 반례가 성립해도 사용자 실사례와의 인과는 실호스트 검증까지 미확정으로 남긴다.

### 1. Delete 소유권과 exactly-once

대상: `InputSession.swift`, `HostTextAdapters.swift`, `HostKeyTransaction.swift`, `ReturnDeliveryTests.swift`.

수용:

- Backspace(51)의 일반 조합 계약은 유지한다. 추가 모음의 결합·분해 삭제는 2026-09-08의 기본 꺼짐 옵션 요구를 따른다.
- ForwardDelete/Return 지연 작업마다 시작 시점의 context generation/revision과 adapter 소유권을 캡처한다. 기존 `ContextStateLease` 재사용 가능성을 우선 확인하고 실행 직전 현재 안전 여부와 함께 검증한다. adapter 생성 때 한 번 고정해 정상적인 이후 field 쓰기까지 막지 않는다.
- 결과를 예약됨/전달됨/안전상 취소됨으로 구분한다. 이후 키를 무조건 취소하지 않으며, 타임아웃 뒤 소유권 없는 field에 뒤늦게 재전달하지 않는다. 같은 field 내 후속 입력의 순서 문제는 위 행렬로 증명한 뒤 필요한 최소 중재만 추가한다. polling 횟수나 sleep 증가는 해결책으로 삼지 않는다.
- 실제 `InputSession` 승인 경로를 사용하는 `true → false → true` 회귀를 추가한다. 단순 bool mock만으로 대체하지 않는다. 기존 false 유지, caret 변경, commit 재진입 보호도 남긴다.

검증:

아래 공통 명령의 `ReturnDeliveryTests|HangulComposerTests|InputSessionFinalizeTests` lane.

롤백: 배포 전에 회귀가 발생하면 작업을 멈추고 이 단계의 변경만 재작업한다. 이전 구현으로 돌아갈 때는 새 반례가 다시 실패하는 미해결 상태로 표시한다. 다른 작업자의 변경을 포함한 일괄 Git 복원은 하지 않는다.

위험: 텍스트/caret 일치만으로 소유권을 재사용하면 ABA가 남는다.

### 2. 이벤트 출처별 modifier policy

대상: `RightCommandSuppressor.swift`, `ToggleMonitoringState.swift`, `ToggleMonitoringTests.swift`.

수용:

- 물리 키: 전환 패밀리 잔류 비트는 제거하고, 현재 눌린 물리 modifier는 복원한다.
- 외부 합성: Maestro로 확인된 Command/Shift를 잔류로 오인해 제거하지 않는다. PID만으로 물리/합성을 확정하지 말고 실제 fixture에서 관측한 신호와 자체 replay marker를 구분한다.
- 자체 replay: `DeferredHostKeyDelivery` marker 경로를 유지한다.
- unknown: 물리 집합을 오염시키거나 사용자의 정상 shortcut을 추측으로 제거하지 않도록 별도 정책을 정의한다. 어떤 신호로 분류했는지와 미분류 사례를 테스트에 남긴다.
- suppression/hidden 교차에서도 출처별 보존 정책을 적용한다. 단순히 합성 flag 검사를 맨 위로 올려 한자키·전환키 소유 계약을 우회하지 않도록 down/up 전체 시퀀스를 검증한다.
- 고유 연타는 중복 소비하지 않는다. 1단계 lease와 별개로 delivery-turn 가정을 재현 로그로 확인한 뒤에만 손본다.

검증:

아래 공통 명령의 `SuppressedKeyPairTests|ToggleMonitoringOwnershipTests|KeyEventDedupTests` lane과 실제 Maestro fixture. 단일 helper에 합성 boolean을 직접 넘기는 테스트만으로 끝내지 않는다.

실검증: Maestro Home/End가 줄 이동으로 동작하고, 우측 Command 전환 직후 첫 글자가 찾기 단축키가 되지 않으며, Shift+Home이 유지된다. 단위 테스트만으로 호스트 완료를 선언하지 않는다.

롤백: 기존 잔류 Command·Shift+Home 회귀가 다시 실패하면 2단계를 중단하고 해당 변경만 재작업한다. 수정 전 버전으로의 회귀를 정상 해결로 보고하지 않는다.

위험: 합성 `flagsChanged`를 물리 집합에 넣으면 Maestro와 잔류 Command 제거가 다시 충돌한다.

### 3. 설치 상태기계 분리

대상: `InputSourceManager.swift`, `PostInstallPreparation.swift`, `InputSourceLifecycle.swift`, `Packaging/scripts/preinstall`/`postinstall`, `main.swift`, `InputMethodMenuTests` 및 기존 설치 계약 테스트. `IMKServer` 소유 변경은 수명 증거가 나온 뒤에만.

수용:

- 등록 ready(후보+enabled), runtime ready(현재 패키지와 실행본 identity 일치 및 IMK 응답), menu ready(실제 설정/정보 항목과 명령 실행)를 분리한다. PID 존재만으로 runtime ready를 확정하지 않는다.
- ordinary update는 현재 세션 IMK 유지 + next-login marker 계약을 유지한다.
- post-install 게이트는 재로그인 전에 실제 메뉴를 확인하지 않으면 현재 세션 성공으로 보고하지 않는다.

검증: 아래 설치 lane과 shell 구문 검사. 메뉴 생성 함수는 원래부터 정상일 수 있으므로 `menu()` 요청 유무·응답·화면 표시·설정 창 열기를 구분한다. 최초 설치, ordinary update, registration change 각각 재로그인 전에 확인한다. 자동화할 공개 경계가 확인되지 않으면 그 항목은 수동 게이트로 남기고 성공을 추정하지 않는다.

롤백: 상태 보고 확장과 복구 동작 변경을 분리해, 실패 시 이번 단계의 동작 변경만 되돌릴 수 있게 한다. 기존 durable marker·세대 검증·snapshot은 보존한다. 실제 설치/재로그인/프로세스 재시작은 별도 승인된 검증 창에서만 수행한다.

위험: 현재 세션 IMK 재기동은 조합과 메뉴 연결을 끊을 수 있으므로, 사용자 입력 중 강제 재기동을 일반 복구책으로 넣지 않는다. 이 문서는 재기동이 과거 소실의 확정 원인이라고 주장하지 않는다.

### 4. 실호스트 게이트

대상: 설치본. 코드 변경 없음.

수용: TextEdit/Chrome/사용자 앱에서 Delete, Maestro Home/End, 전환 직후 첫 글자, 설치 후 tray 메뉴, 재로그인 TIS를 각각 관측한다. 패키지 서명과 510 테스트는 이 게이트를 대체하지 않는다.

검증: 아래 E2E 명령과 실제 Maestro/설치 검증. 기존 E2E의 `typePhysicalKeys`도 CGEvent 합성 입력이므로 물리 키보드 증거와 구분한다. 현재 runner에는 이번 전체 Home/End·설치 후 메뉴 행렬이 없으므로 fixture 확장 또는 명시적 수동 검증이 필요하다. 실패 시 해당 단계로 되돌린다.

## 검증 명령과 완료 게이트

작업 디렉터리는 `/Users/thlim/cube/PriType-Swift`다. 아래 suite 이름은 이번 조사에서 `swift test list`로 확인했다. `--skip-update`는 deprecated 경고가 있어 후속 명령에서는 생략하며 `Package.resolved`의 기존 revision을 유지한다.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test list
swift test --filter 'HangyeolCoreTests\.(ReturnDeliveryTests|HangulComposerTests|InputSessionFinalizeTests)'
swift test --filter 'HangyeolCoreTests\.(SuppressedKeyPairTests|ToggleMonitoringOwnershipTests|KeyEventDedupTests)'
swift test --filter 'HangyeolCoreTests\.(InstallerInputSourceLifecycleTests|InstallerSessionContractTests|PostInstallPreparationTests|InputMethodMenuTests|DebugLoggerTests)'
swift test
bash -n Packaging/scripts/preinstall Packaging/scripts/postinstall Packaging/scripts/postinstall_classification.sh
git diff --check
swift run -c debug HangyeolE2E --package /Users/thlim/cube/PriType-Swift/Hangyeol_3.0.18_Local.pkg --preflight-only
# 승인된 실호스트 검증 시 실행. 수정 버전을 설치한 뒤에는 해당 버전의 PKG 경로로 바꾼다.
swift run -c debug HangyeolE2E --package /Users/thlim/cube/PriType-Swift/Hangyeol_3.0.18_Local.pkg
```

실사용 수용 조건은 각 변경의 반례 테스트 + 관련 lane + 전체 테스트 + 실제 호스트/메뉴 증거다. 설치/서명 성공, TIS ready, 실행본 일치, 입력 정확성, 메뉴 표시를 서로 대체하지 않는다. 초기 계획 시점에는 3.0.18 기준 전체·관련 단위 테스트와 preflight를 실행했다. 수정본의 전체 UI E2E·설치·재로그인 검증은 별도 승인 후 수행한다.

## 다음 Grok 실행 지시

사용자가 구현을 지시하면 동일한 Grok 4.6·high 설정으로 실행한다. 먼저 `git status -sb`, 가까운 `AGENTS.md`, 이 문서의 코드 근거를 다시 읽는다. 0단계 반례를 고정한 뒤 한 경계씩 변경하고, 근거가 계획을 반박하면 계획부터 수정한다. 개인정보 보호와 Secure Input 계약을 약화하지 않는다.

사용자가 수정 구현을 승인했다. 프로젝트 `AGENTS.md`의 Delivery에 따라 검증 후 patch/build를 각각 1 올리고 한국어 semantic commit 및 같은 버전의 Apple Development 서명 앱을 담은 Local.pkg 생성·검증까지 수행한다. 사용자가 보류하면 그 지시를 따른다. push·배포·설치·재로그인은 별도 승인 범위다.

## 코드 근거 위치

- [지연 쓰기 권한과 세션 경계](../Sources/HangyeolCore/InputSession.swift): 206–230, 410–431, 606–625, 1013–1022.
- [adapter에서 host-key로 전달](../Sources/HangyeolCore/HostTextAdapters.swift): 75–103.
- [지연 삭제·재전달](../Sources/HangyeolCore/HostKeyTransaction.swift): 4–10, 131–215, 452–510, 529–577.
- [modifier 정규화](../Sources/HangyeolCore/RightCommandSuppressor.swift): 264–316, 426–438, 489–547.
- [modifier 전환 상태](../Sources/HangyeolCore/ToggleMonitoringState.swift): 510–559.
- [중복키 판정](../Sources/HangyeolCore/DirectInsertionPlanner.swift): 52–148.
- [IME 메뉴](../Sources/HangyeolCore/HangyeolInputController.swift): 1284–1345; [등록 상태](../Sources/HangyeolCore/InputSourceManager.swift): 10–16.
- [설치 단계](../Packaging/scripts/postinstall): 174–203; [IMKServer 생성](../Sources/Hangyeol/main.swift): 113–117.
- [삭제 테스트](../Tests/HangyeolCoreTests/ReturnDeliveryTests.swift): 990–1033; [자모 삭제 계약](../Tests/HangyeolCoreTests/HangulComposerTests.swift): 973–991.
- [합성키 테스트](../Tests/HangyeolCoreTests/ToggleMonitoringTests.swift): 513–543; [메뉴 단위 테스트](../Tests/HangyeolCoreTests/InputMethodMenuTests.swift): 9–33.
- [실호스트 검증 절차](E2ETesting.md), [유지할 통합 아키텍처](UnifiedInputArchitecture.md).

## 구현·검증 기록

2026-09-08 추가 모음 옵션, 첫 키의 언어, modifier 보존과 지연 쓰기 권한을 Grok 4.6 / high로 구현했다. 현재 사용자 설치본은 교체하지 않았다. 아래는 기준선부터 수정 후까지의 검증 이력이며, 최종 상태는 마지막 결과를 따른다.

- 전체 510 tests / 53 suites 통과.
- `HangyeolVerify` 통과 (모의 입력 검증이며 실제 호스트 증거가 아님).
- 설치본 3.0.18의 등록 상태 정상; 메뉴 표시 미확인.
- 격리 IMKServer 수명 실험은 지역 참조 종료 뒤 서버가 유지됨을 확인. 메뉴 소실 직접 원인 미확정.
- 부모 검증에서 `FirstInputModeRegressionTests` 실패: keyboard override 안에서 재진입한 첫 키가 전환 전 언어로 처리됨. 한글→영문·영문→한글 두 경우, 6개 assertion 실패. 제품 전환 함수와 pending coordinator를 사용한 결정론적 반례이며 실제 앱에서의 재진입 빈도는 미측정.
- 부모 검증에서 `ExtendedVowelDefaultRegressionTests` 실패: 2개 parameterized tests / 16개 사례에서 요청한 기본 꺼짐 계약과 현재 동작이 다름을 확인.
- 부모 검증에서 `SynthesizedNavigationRegressionTests` 실패: 합성키 보존을 명시해도 suppression/hidden 상태가 있으면 Command·Shift가 제거됨. 2개 parameterized tests / 6개 사례, 9개 assertion 실패. 실제 Maestro 설정은 Home/End에 Command 화살표, Shift 조합에 Command+Shift 화살표를 보내도록 되어 있었고 변경하지 않았다.
- modifier 수정 후 부모 재검증: `SynthesizedNavigationRegressionTests|SuppressedKeyPairTests|ToggleMonitoringOwnershipTests` 36 tests / 3 suites 통과. 보존 판단을 물리 상태 재구성보다 먼저 적용했고 source PID 휴리스틱 자체는 변경하지 않았다.
- 전환 수정 후 Grok 검증: `FirstInputModeRegressionTests|InputModeOwnershipTests|SecureToggleTests|LifecycleOperationSequenceTests` 35 tests / 5 suites 통과. 부모도 첫 입력·소유권·Secure Input lane을 재실행해 통과를 확인했다. 재진입한 새 조합 유지와 더 새로운 전환을 바깥 전환이 덮지 않는 사례를 포함한다.
- 모음 수정 후 부모 검증: `ExtendedVowelDefaultRegressionTests|HangulComposerTests` 54 tests / 3 suites 통과. 기본 꺼짐 16개 사례와 기존 `와 → 오 → ㅇ` 조합·삭제 계약을 확인했다.
- 설정은 `extendedVowelCombinationEnabled` 하나로 저장하며 getter는 메모리 캐시만 읽는다. 설정 기본값, 저장 후 재생성, true/false refresh, 1,000회 getter의 UserDefaults 읽기 방지를 포함한 `ConfigurationManagerTests` 25개 통과.
- 부모의 `DeferredHostKeySessionTests`에서 실제 InputSession 권한을 캡처해 모의 replay를 실행했다. 필드 변경 후 재승인은 옛 예약을 취소했지만, Secure Input 철회 후 같은 필드 재승인은 Return·Forward Delete 예약을 되살려 2개 사례가 실패했다. 승인 유지 시 정상 전달과 승인 철회 시 취소를 함께 검증하며 실제 앱에는 CGEvent를 보내지 않는다.

### 최종 소스 검증 (2026-09-08)

- 지연 쓰기는 스케줄 당시 승인된 context lease·adapter identity·쓰기 승인 revision을 모두 캡처한다. 승인 전 캡처는 영구 거부하고, Secure Input 철회 시 쓰기 revision을 증가시켜 동일 필드 재승인으로 옛 작업이 살아나지 않게 했다. 기존 context analysis revision과 동기 쓰기 판정은 그대로 둔다.
- `DeferredClientWriteLeaseTests`와 실제 session을 연결한 모의 Return·Forward Delete 재전달 회귀가 통과했다. 승인 유지 시 정상 전달, 필드 변경·보안 철회 후 옛 예약 취소, 새 예약 허용을 확인했다.
- 추가 모음 관련 최종 집중 검증은 66 tests / 4 suites 통과. 직접 입력한 ㅐ/ㅒ/ㅔ/ㅖ의 옵션 켜짐 삭제, 입력·삭제의 실시간 on/off, 세벌식 재생성, 실제 자판과 미적용 설정의 구분, 원자 삭제 뒤 일반 겹모음 삭제 복구, `맑 → 말` 양쪽 옵션을 포함한다.
- 전체 `swift test`: 536 tests / 59 suites 통과. `HangyeolVerify`의 모의 입력 검증, plist·문자열 lint, `git diff --check` 통과.
- 릴리스 대상: 3.0.19 / build 102. `build_local.sh`로 같은 버전의 Apple Development 서명 앱·helper를 포함한 `Hangyeol_3.0.19_Local.pkg`를 생성하고, 펼친 payload의 버전·서명·등록 메타데이터를 확인한다.
- 사용자 설치본·Maestro 설정은 변경하지 않았다. 새 버전의 실제 호스트 입력, 설정 창 표시, 설치·재로그인·tray 메뉴 검증은 미실행이며 메뉴 소실 원인은 미확정이다. 패키지 서명·생성 성공을 이 검증의 대체 증거로 사용하지 않는다.
