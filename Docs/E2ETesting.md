# 실제 IME E2E 검증

`HangyeolE2E`는 설치된 한결 입력기를 실제 `CGEvent` 키 입력과
`AXUIElement` 결과 조회로 검증한다. 유닛 테스트와 달리 InputMethodKit,
TextEdit, Chrome renderer를 포함한 전체 입력 경로를 실행한다.

## 안전 경계

- 개발용 Mac에서 SIP를 끄거나 TCC 데이터베이스를 수정하지 않는다.
- 러너는 현재 프로세스에 이미 부여된 손쉬운 사용 및 키 이벤트 전송 권한만
  검사한다. 권한이 없으면 설정을 바꾸지 않고 preflight에서 실패한다.
- 자동 테스트용 Chrome은 임시 user-data directory로 별도 실행한다. 기존
  Chrome 프로필과 로그인 세션은 사용하지 않는다.
- TextEdit도 기존 사용자 프로세스를 재사용하지 않고 테스트 전용 인스턴스로
  실행한다. 종료를 확인한 뒤 임시 문서를 삭제하므로 열기·저장 시트나 테스트
  창을 사용자 세션에 남기지 않는다.
- 현재 입력 소스와 클립보드, 한결 내부 한·영 모드는 테스트가 끝나면 복원한다.
- 권한을 자동 준비해야 하는 CI는 폐기 가능한 Tart macOS VM에서만 구성한다.

## 실행

먼저 검증할 PKG를 설치한다. 러너는 설치 앱과 PKG payload의 bundle ID,
버전, build, signing identifier, code-directory hash(CDHash), team identifier,
leaf signing authority를 대조한다. 입력 소스를 선택한 뒤에는 실행 중인 한결
IMK 서버의 code object도 PID로 직접 검사한다. 디스크 앱만 새 버전이고 현재
세션이 이전 실행 파일을 계속 쓰는 경우를 통과시키지 않으며, 하나라도 다르면
실제 입력 테스트를 시작하지 않는다.

특정 Chrome 시나리오만 재현하려면 `--scenario '중간 삽입'`처럼 이름 일부를
지정한다. TextEdit 모드 준비와 종료 시 복원은 유지한다. 일치하는 시나리오가
없으면 실패한다. 합성 입력란의 최근 조합·입력 이벤트도 실패 진단에 포함한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run -c debug HangyeolE2E \
  --package /absolute/path/Hangyeol_<version>_Local.pkg
```

설치본·PKG·권한·Chrome·입력 소스만 검사하려면 다음 명령을 사용한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run -c debug HangyeolE2E \
  --package /absolute/path/Hangyeol_<version>_Local.pkg \
  --preflight-only
```

## 자동 시나리오

- TextEdit 기본 두벌식 조합과 Return
- Chrome 일반 input과 contenteditable
- 같은 Chrome client의 클릭 및 Tab field handoff
- Chrome 브라우저 탭 반복 전환 직후 대기 없는 첫 음절
- 한글·영문 전환 직후 첫 글자
- 붙여넣기 직후 한글 입력
- 조합 직후 Shift+Return
- 문장 중간 조합 직후 Forward Delete
- `맑`을 `말`로 Backspace한 직후 Forward Delete
- 일반 input/contenteditable 중간 삽입·Backspace·한영 전환: `가나다라 → 가나말x나다라`
- 일반 input/contenteditable의 `:완료:`: U+003A U+C644 U+B8CC U+003A 유지

결과는 최종 문자열을 정확히 비교한다. 정규화하면 같아 보이는 분리 자모도
실패로 판정한다. 고정 대기 시간으로 성공을 가정하지 않고 제한 시간 동안
실제 값과 focus 조건을 polling한다. 실패 시 설치 버전, 활성 앱, 활성 필드,
caret, 각 필드의 실제 Unicode 값을 출력한다.

## Confluence 검증

로컬 Chrome fixture 통과는 Confluence 통과를 대신하지 않는다. 로그인된
Confluence 페이지에서 수동 또는 별도 브라우저 세션으로 검증하지 않은 경우
결과를 `미검증`으로 기록한다. 자동 결과와 실제 Confluence 결과는 항상
분리해서 보고한다.

## 3.0.24 입력 안정성 요구와 회귀 근거

요구 출처: 2026-09-18 사용자 요청. Chrome 중간 삽입·삭제·한영 전환에서 새 입력과
주변 문자를 보존하고, Slack 이모티콘 이름 `:완료:`가 자소 분리되지 않아야 한다.

| 경계 | 기대 결과 | 검증 |
| --- | --- | --- |
| 같은 필드의 문서 접근 상태만 변경 | 읽어서 확인한 `오`를 이어 `완`으로 조합 | `InputSessionFinalizeTests.markedCompositionSurvivesDocumentAccessChange` |
| 전환·종료 후 다시 중간 삽입 | 옛 조합 위치 폐기, 새 삽입 위치 사용 | `InputSessionFinalizeTests.lifecycleCommitRetiresMarkedAdapterRange` |
| 조합 확정·콜론·마지막 자모 삭제 | 확정 뒤 빈 조합 없음, 실제 남은 자모는 한 번 취소 | `HostAdapterResolverTests.committedBlinkTextDoesNotStartEmptyComposition` |
| 범위 조회 중 입력란 변경 | 이전 권한으로 새 필드에 쓰지 않음 | `HostAdapterResolverTests.markedWriteRechecksOwnershipAfterSelectionRead` |
| `:완료:` 입력 | NFC 코드 포인트 일치, 불필요한 빈 조합 없음 | `HostAdapterResolverTests.koreanEmojiShortcodePreservesSyllables`, Chrome E2E |

수정 전 설치된 3.0.22/build 105를 서명·실행 PID까지 확인한 E2E는 9개 중 5개 통과했다.
Tab 직후 `계 → ㅖ`, Shift+Return 뒤 `나 → ㄴㅏ`, Forward Delete 누락,
브라우저 탭 전환 직후 첫 음절 실패를 관측했다. 이 결과만으로 각 증상을 특정 코드 결함과
일대일로 연결하지 않는다. 새 버전 설치 후 재실행 결과를 별도로 기록해야 한다.

Chromium의 [setMarkedText 구현](https://chromium.googlesource.com/chromium/src/+/main/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm)은
빈 문자열을 조합 취소로 처리한다. 3.0.24는 이미 확정한 조합에 이 취소를 중복 전송하지 않는다.
테스트 fixture는 Slack 편집기 자체가 아니므로 실제 Slack 이모티콘 자동완성은 별도 확인 대상이다.

## 3.0.25 전환 순서 수정과 남은 실호스트 검증

2026-09-18 재로그인 후 설치본 3.0.24/build 107과 실행 PID의 서명을 대조해
키 입력을 직접 전송했다. 빠른 입력에서는 11개 중 5개가 통과했다.
중간 편집 결과는 `가나말x나다라` 대신 `가나ㅌ나다라`였고, Tab 첫 자모,
Shift+Return 뒤 조합, Forward Delete도 실패했다. 붙여넣기 항목은 모드 준비,
브라우저 탭 항목은 주소창 초점 준비에서 실패했으므로 해당 동작의 판정은 미검증이다.
`:완료:`의 input/contenteditable NFC 검사는 통과했지만 실제 Slack은 미검증이다.

동일 설치본에서 비교 목적으로 키 간격을 7ms에서 52ms로 늘렸을 때
중간 편집·Tab·Shift+Return·Forward Delete가 통과해 전체 9/11이었다.
이 비교는 속도 의존성을 보여주며, 모든 실패가 같은 원인이라는 증거는 아니다.
러너 기본 간격은 다시 7ms로 복원했다.

전환 큐는 모니터링 스레드에 두 번의 전환이 먼저 도착하면 이전 키를 처리하기
전에 둘 다 실행할 수 있었다. 3.0.25는 modifier 전환의 원래 CGEvent 시각을
보존하고 IMK flagsChanged/keyDown 시각까지의 요청만 실행한다. 타임스탬프 없는
활성화·메인 큐 콜백은 이 요청을 앞당겨 실행하지 않는다. 일반 키로 설정한 전환,
IOKit 대체 경로와 설정 UI의 기존 요청 경로는 이번 변경의 대상이 아니다.

`FirstInputModeRegressionTests.delayedKeysRespectPhysicalToggleOrder`는 전환 10초,
영문 키 11초, 전환 12초가 대기 중이어도 9초의 한글 입력을 확정하지 않고,
11초에는 영문 모드를 유지하는지 검증한다. 시각 제한을 제거한 기존 처리로
6개 assertion 실패, 제한을 적용한 처리로 통과했다.

3.0.25의 설치본 E2E는 아직 수행하지 않았다. 현재 원격 세션에서 시스템 입력기
교체에 필요한 관리자 인증을 사용할 수 없어 3.0.24를 유지했다. 따라서 이번
수정으로 Tab·Shift+Return·Forward Delete 또는 실제 Slack까지 해결됐다고
판정하지 않는다. 새 패키지 설치 후 빠른 입력 전체 시나리오를 재실행해야 한다.

## 창 복귀 후 Forward Delete 검증

3.0.20은 내부 엔진 조합이 끝났는데 Blink 호스트에 조합 표시가 남은 경우를 처리한다.
`ReturnDeliveryTests.forwardDeleteAfterWindowRoundTrip`은 창을 떠날 때 호스트가 조합 확정을
반영하는 경우와 무시하는 경우를 각각 모델링한다. 이는 실제 Codex의 IMK 콜백을 관측한
결과가 아니므로 새 패키지 적용 후 다음 수동 검증을 별도로 수행한다.

1. Codex 입력란에 `가나다라`를 입력하고 `나|다` 사이로 커서를 이동한다.
2. `마`를 조합해 `가나마다라`가 보이는 상태에서 다른 창으로 전환한다.
3. Codex로 돌아온 뒤 **커서 뒤를 지우는 Forward Delete**를 한 번 누른다. Backspace와 구분한다.
4. 결과가 `가나마라`, 커서가 `가나마|라`인지 확인한다. 빠른 복귀와 잠시 머문 뒤 복귀를 각각 확인한다.

수정은 현재 비보안 필드의 조합 범위와 내용을 읽어 검증할 수 있을 때만 적용한다.
쓰기 승인이나 조합 확인이 실패하면 이전 필드의 캐시로 내용을 추정해 쓰지 않는다.
단위 테스트·패키지 검증 통과와 위 실호스트 결과를 구분해 기록한다.


## 3.0.26: IMK가 재작성한 이벤트 시각과 중간 편집

3.0.25 실제 Chrome 빠른 입력에서 `가나말x나다라`가 되어야 하는 중간 편집이
`가나ㅌ나다라`로 끝났다. 진단 앱에서 event tap의 CGEvent와 IMK 콜백을 비교하니
IMK bridge가 NSEvent 시각을 늦은 전달 시각으로 바꾸고 CGEvent user data도
보존하지 않았다. flagsChanged 역시 이전 keyDown보다 먼저 전달될 수 있었다.
그 결과 이전 Backspace보다 한영 전환이 먼저 적용되어 조합 글자가 사라졌다.

3.0.26은 event tap에서 텍스트를 저장하지 않고 키 코드·수정 키·반복 여부·대상 PID와
원래 시각·호스트 재전달 여부를 최대 128개, 2초 동안만 연결한다. IMK keyDown은
이 원래 시각까지의 전환만 적용하며 flagsChanged에서 전환을 앞당기지 않는다.
PhysicalKeyDeliveryTests는 전달 시각이 두 전환 뒤로 밀린 경우에도 이전 삭제 키,
영문 키, 다음 한글 키가 각각 올바른 모드로 처리되는지와 FIFO·만료·대상 PID·재전달
식별을 검증한다.

패키지를 만들기 전 서명 앱을 검사하려면 다음 실행 방식도 지원한다. 실행 중
입력기 PID의 코드 서명을 지정 앱과 대조한다. 이 방식은 패키지 내용의 검증을
대신하지 않으며, 패키지 비교는 기존 --package 옵션을 사용한다.

```sh
swift run HangyeolE2E --app /absolute/path/Hangyeol.app --scenario '중간 삽입'
```

2026-09-18, 별도 ID의 Apple Development 서명 진단 앱에서 실제 7ms 간격 입력으로
TextEdit 기본 입력과 Chrome 중간 삽입·Backspace·전환이 2/2 통과했다.
같은 수정의 전체 실행은 7/11 통과했다. 한글 이모티콘 이름 `:완료:`는 Chrome의
input/contenteditable에서 통과했지만 실제 Slack 편집기 검증은 아니다.
남은 실패는 Tab 다음 첫 음절, Shift+Return 줄바꿈, Forward Delete이며,
브라우저 탭 시나리오는 주소창 초점 확보 실패로 입력 결과를 판정하지 못했다.

사용자가 화면 조작 중단과 현재 수정 범위의 마무리를 요청하여 추가 실호스트
테스트를 중단했다. 진단 입력기를 해제·종료하고 기존 설치본을 다시 선택했다.
3.0.26 패키지를 이 호스트에 설치하거나 실행하지 않았다. 설치 직후 Chrome 한영
전환이 재로그인 전 작동하지 않았던 증상은 이번 변경에서 해결된 것으로 판정하지
않는다. 이후 진단 앱에만 시도했던 commitComposition 상위 호출 제거는 효과가
확인되지 않아 제품 소스에 반영하지 않았다.

## 후속 수정 검증 중 (2026-09-19)

3.0.26 설치본은 사용자가 설치하지 않았으며 시스템 설치본은 3.0.25다.
사용자의 원격 조작 재개 요청에 따라 진단 입력기 활성화 허용을 UI에서 처리했다.

Chrome의 Shift+Return/Forward Delete는 조합 확정 후 원래 키를 즉시 통과시키는
경로에서 실제 입력 테스트를 통과했다. 기존 비동기 재전송은 뒤따르는 첫 조합이
시작되면 `host_key_target_changed`로 취소되어 줄바꿈 또는 삭제가 누락됐다.
Chrome에만 원래 키 전달을 적용하며 다른 Blink 앱의 기존 호환 경로는 유지한다.
단위 테스트의 Chrome 기대값은 이 실호스트 관측에 맞춰 원래 키 한 번 전달과
조합 보존을 검증하도록 변경했다. Codex/Slack의 재전송 검증은 유지했다.

IMK 중복 콜백이 다음 물리 키의 FIFO 항목을 먼저 소비할 수 있던 순서도 수정했다.
키 정보는 먼저 조회만 하고, 중복 판정을 통과한 콜백에서만 소비한다.

설치 로그에서는 3.0.25 활성화 완료(2026-09-18 22:02:31) 뒤 PackageKit이 receipt를
기록하고 앱을 touch/register했다. postinstall이 초기 활성화 완료를 기다리는
순환을 제거하고, 실행 중인 입력기가 새 receipt 버전 및 변경된 기록 시각을
관측한 뒤 기존 안정화 검증을 수행하도록 수정 중이다. 같은 버전 재설치와
receipt 누락/구버전 대기를 단위 테스트로 검증한다. 실제 관리자 설치 경로는
아직 실행하지 않았으므로 재로그인 문제 해결 완료를 뜻하지 않는다.

실호스트 전체 실행은 9/11 통과했다. Tab 직후 첫 음절과 브라우저 탭 시나리오가
남았다. 별도 진단에서 Tab 다음 첫 자음 후 늦은 commitComposition 콜백과
클라이언트 교체가 관측됐다. 새 클라이언트는 markedRange를 아직 제공하지 않고
attributedSubstring도 nil을 반환해, 기존 조합을 무조건 옮기면 다른 필드에
쓰기 위험이 있다. 입력 대상 확인 없는 조합 이동 실험은 제품 코드에 넣지 않았다.

러너는 수정 키를 실제 flagsChanged 누름/해제 순서로 전달하도록 보완했다.
브라우저 탭 준비에는 빠져 있던 Cmd+T를 추가했으며, 지연된 AX 주소창 초점 대신
새 탭의 고유 pageID로 실제 로드를 검증한다. 이 보완 후 브라우저 탭 시나리오는
준비 단계는 통과했으나 새 입력란의 `나`가 `ㅏ`로 끝나는 실제 실패를 확인했다.
논리적인 기대 문자열과 즉시 입력 조건은 유지했다.

진단 앱의 AXIsProcessTrusted()는 true였다. 추가 권한 요청은 불필요한 것으로
정정했으며 권한을 변경하지 않았다. 입력 콜백 중 AX 초점 조회는 cannotComplete로
실패하여 제품 경로에 채택하지 않았다. Tab 검증이 끝나기 전에는 버전 증가·완료
커밋·새 패키지를 만들지 않는다.

### 원격 직접 검증 후 추가 관측 (2026-09-19)

사용자의 “네가 해줘. 나 원격이야” 요청에 따라 진단 입력기 허용을 처리하고
추가 물리 키 테스트를 실행했다. 시스템 설치본을 교체하지 않았다.

- 기본 Apple 두벌식을 임시 선택한 비교에서도 Tab 직후 `계`의 첫 자음과
  새 브라우저 탭의 `나`의 첫 자음이 누락됐다. 두 비교의 실패 직후 선택 소스는
  `com.apple.inputmethod.Korean.2SetKorean`임을 다시 확인했다.
  로그: `/tmp/hangyeol-327-apple-tab.log`,
  `/tmp/hangyeol-327-apple-browser.log`.
- 이는 이 호스트의 Chrome 153.0.8010.48 및 CGEvent 테스트 경로에서
  한결 외 입력기도 재현된다는 증거다. Chrome만의 원인으로 확정하거나,
  일반 하드웨어 입력 및 실제 Slack에서도 동일하다고 단정하지 않는다.
- 창 제목 변경의 영향을 분리하려고 진단용 fixture의 상태를 localhost 관측기로
  전달했다. 이 실행에서도 Tab/새 탭 누락이 재현됐다. 전체 8/11 통과였고
  나머지 한 건은 Forward Delete 동작 이전 `clear editable` 준비 실패였다.
  로그: `/tmp/hangyeol-327-http.log`. localhost 관측기는 제품에 추가하지 않았다.
- 35ms/100ms 입력 지연, 이벤트 탭의 별도 스레드, 키보드 배열 override 생략,
  IMK 상위 lifecycle 호출 생략, keyDown-only 이벤트 마스크, 조기 클라이언트
  조회, NSNotFound replacement range 길이 변경은 전체 성공을 입증하지 못했다.
  모두 진단 복제본에서만 시험했고 제품 코드에 반영하지 않았다.
- 제품 후보의 기존 검증은 단위 559개/60 suites 및 HangyeolVerify 통과다.
  실호스트 전체 통과, 실제 Slack, 관리자 설치 후 재로그인 없는 활성화는
  미검증/미완료다. 기존 9/11 결과를 전체 성공으로 해석하지 않는다.

사용자의 “문제가 없을 때 설치본” 조건이 충족되지 않아 3.0.27 버전 증가,
완료 커밋 및 새 패키지 생성은 보류한다. 검증된 범위의 수정도 작업 트리에
유지하며 완료로 보고하지 않는다. 임시 Apple 입력기 parent 활성화는 비교 후
원래 비활성 상태로 복구했다.


## 3.0.27: Chrome 첫 키 전달 순서 보완 (2026-09-20)

현재 요구사항은 기본 Apple 입력기에서도 재현되더라도 한결에서 해결하는 것이다.
앞 절의 패키지 보류는 당시 실패 결과이며 아래 검증이 이를 갱신한다. 이번 완료 기준은
중간 삽입·Backspace·한영 전환·NFC 이모티콘 이름·Tab/브라우저 탭 첫 음절과
원래 호스트 Return/Delete 동작을 보존하는 제품 수정 및 실제 입력 검증이다.

Chrome의 Tab 뒤 첫 키가 이전 IMK 컨텍스트로 전달되고 늦은 활성화/확정 콜백이
첫 자음을 없애는 현상을 보완했다. `ChromeInputHandoffGate`는 한결 선택 상태의
Chrome에서만 Tab/Ctrl+Tab/Cmd+T/Cmd+W를 관찰한다. 첫 물리 키와 일치하는 IMK
콜백만 활성화 준비용으로 소비하고, 원래 키와 뒤따르는 누름·해제·수정 키·마우스
이벤트를 순서대로 macOS에 재전달한다. 이전 필드의 조합 문자열을 새 필드로 옮기지 않는다.

일반 Tab은 25ms, 브라우저 탭은 60ms 후 재전달하며 이벤트 간격은 2ms다.
이는 관측한 호스트 전환을 위한 제한된 대기이며 모든 환경의 지연 상한 보장은 아니다.
IMK 콜백이 없으면 100ms 뒤 후속 이벤트만 풀어 이미 전달된 첫 키를 중복하지 않는다.
256개 상한 또는 모니터 종료 시 대기를 해제한다. 다른 입력기·다른 앱·보안 입력 및
사용자 지정 단축키는 시작 대상에서 제외하고, 오래된 이동 경계는 만료시킨다.
Chrome 단축키의 왼쪽 Command/Control 경계에서는 현재 소유한 조합을 먼저 확정해
탭 복귀 후 새 음절이 기존 글자를 덮어쓰지 않게 한다. 한영/한자 지정 modifier는 제외한다.

기존 `clear editable` 준비 실패는 전체 선택이 완료되기 전에 삭제 키가 이어질 수
있었고, 관측용 DOM Range 길이가 innerText의 줄바꿈 길이와 달랐던 경우를 분리했다.
fixture는 실제 전체 선택 범위를 관찰한 뒤 준비용 Backspace를 보낸다. 검증 대상의
빠른 입력 간격이나 기대 문자열은 완화하지 않았다. 새 시나리오는 Tab 직후 두 번 삭제,
한영 두 번 전환, 영문 반복 입력과 Backspace/Return을 중간 상태 대기 없이 수행한다.

최종 제품 코어와 동일한 진단 앱으로 전체 12/12를 두 번 연속 관측했다.
Chrome 첫 Tab 10회, 브라우저 탭 전환 10회, 추가 삭제·전환/영문 호스트 키 각 5회를
각 실행에 포함한다. 진단 앱 서명과 Chrome 검사 시 실행 PID를 대조했고 기존 제품의
이벤트 탭이 함께 실행되지 않게 진단 러너에서 기존 제품 프로세스를 종료했다.
진단 전용 변경은 앱 식별자와 검사용 실행 제어이며 제품 배포 코드에는 포함하지 않는다.
TextEdit 항목은 텍스트 결과의 증거이며 Chrome의 프로세스 대조와 별도로 해석한다.

- `/tmp/hangyeol-327-final-e2e1.log`: 12/12, 실패 0
- `/tmp/hangyeol-327-final-e2e2.log`: 12/12, 실패 0
- `/tmp/hangyeol-327-release-tests.log`: 566 tests / 61 suites 통과
- `/tmp/hangyeol-327-final-verify.log`: HangyeolVerify 통과
- `bash -n`, `git diff --check` 통과
- `ChromeInputHandoffGateTests`: 정확한 원래 키 식별, 순서/중복, 콜백 누락,
  종료, 범위 제외, 클릭 경계, 큐 상한, 수정 키/타임스탬프 보존
- `PhysicalKeyDeliveryTests`: 중복 IMK 콜백이 다음 물리 키를 소비하지 않음
- 설치 receipt 대기와 후속 활성화는 단위/패키지 계약 검증이며 실제 관리자 설치는 미실행

사용자가 로컬로 복귀했고 잦은 설치 테스트를 원하지 않으므로 시스템 설치본은
3.0.25/build 108로 유지했다. 검증 종료 후 진단 입력기를 비활성화·종료·등록 해제하고
기존 한결 선택을 `verify-selected ready=true`로 확인했다. 새 패키지 설치 후에는
현재 로그인에서 새 프로세스 활성화, 실제 Slack 자동완성과 일반 하드웨어 입력을
한 번에 확인해야 한다. fixture 통과를 실제 Slack 검증 완료로 표현하지 않는다.


## 3.0.28 후보: Codex 조합 선택 해제 전 호스트 키 전달

사용자는 Codex 입력창에서 아래 세 가지를 보고했다. 잠시 정상화되기도 하며,
특히 문장 끝 Forward Delete는 빠르게 누르면 실패하고 기다렸다 누르면 정상이다.

- `한글` + Shift+Return: `한글`과 줄바꿈을 보존해야 하나 `글`이 사라짐
- `한중|글` + Forward Delete: `한중`이어야 하나 `중`이 사라져 `한글`이 됨
- `하나|` + 빠른 Forward Delete: 뒤 문자가 없으므로 `하나`를 유지해야 하나 `하`가 됨

이는 수정 요구사항의 권위이며 기존 Chrome fixture 통과로 반박하지 않는다.
기존 설치본 3.0.27에 정확한 첫 두 문자열의 Chrome 검사를 추가한 결과는 각각
통과했다(`/tmp/hangyeol-328-before-return.log`, `/tmp/hangyeol-328-before-delete.log`).
Codex 직접 재현을 시도했으나 Computer Use가 `com.openai.codex` 접근을 안전상
차단했다. 다른 UI 도구로 우회하지 않았으며 실제 Codex 수정 후 확인은 남아 있다.

코드에서 확인한 경로는 두 가지다. Return 재전달은 선택 범위를 조회하지 않아,
글자는 읽히지만 아직 선택된 상태에서 줄바꿈이 선택된 조합을 대체할 수 있었다.
또 markedRange가 없고 조합이 선택 범위로만 노출되면 재전달 준비를 거절하고
원래 Delete를 호스트에 넘길 수 있었다. 선택 문자열을 실제로 읽어 현재 조합과
일치하고 입력란 쓰기 권한이 유지되는 경우에만 이 범위를 재전달 대기의 기준으로
사용한다. Return도 실제 선택 범위를 조회해 조합 선택이 해제될 때까지 기다린다.

`selectedCompositionRemainsVisibleBeforeRetirement`는 실제 앱을 조작하지 않고,
본문에 조합 글자가 보이지만 선택 해제가 늦는 호스트 상태를 모델링한다. 세 문장과
확인된 markedRange 유무의 6개 조합을 검사한다. 수정 전에는 15개 assertion이
실패했고 `한\n`, `한글`, `하`의 손실 결과를 재현했다. 수정 후 모두 통과했다.
텍스트 조회 불가·내용 불일치·길이 불일치·조회 중 쓰기 권한 철회는 허용하지 않는다.

- 수정 전: `/tmp/hangyeol-328-all-cases-before.log`
- 수정 후 관련 검사: `/tmp/hangyeol-328-return-after.log`
- 전체 자동 검사: `/tmp/hangyeol-328-all-tests.log` (568 tests / 61 suites)

이 증거는 코드의 실패 가능한 경로와 수정 효과를 입증한다. 해당 경로가 사용자의
Codex 세션에서 발생했다는 런타임 증거는 아직 없다. 3.0.28은 설치 확인용 후보이며,
설치된 3.0.27을 자동 교체하지 않는다. 새 설치 후 위 세 문장의 빠른 입력/잠시 대기
입력을 실제 Codex에서 확인해야 실사용 회귀 해결을 판정할 수 있다.

## 3.0.29: 빠른 Forward Delete의 Electron 조합 손실

2026-09-20 사용자는 3.0.28 설치 후 Shift+Return은 정상이나, 빠른
`한중|글` + Forward Delete가 여전히 `한글`이 된다고 보고했다.
사용자가 허용한 Claude Desktop 빈 초안에서 실제 키 입력으로 동일한 손실과
Delete가 누락되어 `한중글`이 남는 현상을 모두 관측했다. 메시지는 전송하지 않았다.

내용을 기록하지 않는 진단에서 Claude는 읽을 수 있는 문서에도 length=0을
반환하고, 조합 범위가 늦게 갱신되며, 조합 완료·커서 이동을 IMK로 보고한 후에도
재전달된 Delete가 조합 글자를 지우는 경우가 있었다. 명시적 범위에 빈 문자열을
삽입하는 방식도 반영되지 않았다. 확인된 해결 경로는 현재 커서 앞의 확정 글자와
뒤의 한 글자를 함께 지정해, 확정 글자만 남기는 비어 있지 않은 범위 교체다.

제품 변경:
- 미확인 조합 범위라도 내용과 정확한 선택 영역이 일치하면 문서에 보이는 조합으로
  취급한다. 기존 누락 경로의 잘못된 문서 길이 증가 대기를 제거한다.
- 내용이 확인된 현재 선택 영역을 지연된 markedRange보다 우선한다.
- 조합 완료를 확인했는데 문서 길이가 0인 호스트에는 Delete를 재전달하지 않는다.
  최대 64 UTF-16 단위의 읽을 수 있는 접두부를 제한된 이진 탐색으로 찾고 한 grapheme을
  선택한다. 확정 글자와 뒤 글자의 실제 내용·커서·조합 해제·쓰기 권한을 다시 확인한
  다음 확정 글자를 보존하는 범위 교체를 한다.
- 조회할 수 없거나 grapheme이 탐색 한계에 닿으면 쓰지 않는다. 포커스나 권한이
  바뀐 입력란에도 쓰지 않는다. 기존 정상 길이 호스트와 Chrome 예외는 유지한다.

기존 회귀 테스트를 확장했다. 미확인 범위 조건은 수정 전 `한중글`이 남으며 실패했고,
length=0 / IMK 조합 완료 후에도 Delete가 조합을 취소하는 호스트 모델은 수정 전
8 assertions가 실패했다. 기대 문자열과 기존 assertions는 완화하지 않았다.
현재 조합·늦은 조합 범위, 문장 끝, 가족 이모지, 결합 문자, 권한 철회, 커서 이동,
탐색 한계를 넘는 grapheme을 검사한다.

- `/tmp/hangyeol-329-before.log`: provisional 조건 수정 전 실패
- `/tmp/hangyeol-329-lengthless-before.log`: Electron 손실 모델 수정 전 실패
- `/tmp/hangyeol-329-final-return.log`: 관련 47 tests / 2 suites 통과
- `/tmp/hangyeol-329-final-tests.log`: 최종 전체 검사
- `/tmp/hangyeol-329-final-verify.log`: HangyeolVerify
- `/tmp/hangyeol-329-package.log`: Apple Development 서명·패키지 검증

제품과 동일한 최종 HostKeyTransaction 코드의 진단 앱을 Claude에 연결해 확인했다.
최종 후보에서 중간에 별도 대기 없이 `gksrmf`, Left, `wnd`, Forward Delete를 입력한
결과가 4회 모두 `한중`이었다. `gksk` 직후 Delete는 `하나`를 유지했고, `한글` 직후
Shift+Return은 글자와 줄바꿈을 보존했다. 준비용 `한👨‍👩‍👧‍👦`를 붙여 넣고 이모지 앞에서
`wnd`, Delete를 입력한 결과도 `한중`이었다. 각 결과는 실제 Claude AX 문서로 확인했다.
이는 유한한 자동 키 입력 검증이며 모든 물리 키 타이밍이나 Codex 앱 자체의 증거는 아니다.

진단 입력기의 비활성화·종료·등록 해제, 테스트 초안 삭제, 사이드바 복원을 마쳤다.
원래 설치된 3.0.28을 다시 실행하고 `verify-selected ready=true`를 확인했다.
3.0.29는 자동 설치하지 않는다. Codex는 Computer Use 접근이 차단돼 직접 검증하지
않았으며, 다른 UI 도구로 우회하지 않았다.

2026-09-20 사용자는 설치 후 다시 로그인했으며 “이제 해결된 것 같네”라고 보고했다.
이는 설치 후 사용자 실사용 확인이며, 위 Claude 자동 검증과 구분한다.
Codex 직접 자동 검증은 수행하지 않았고, 모든 입력 타이밍의 해결을 단정하지 않는다.

## 재설치 직후 입력 메뉴 소실 조사 (2026-09-21, 진행 중)

사용자 요구는 재설치 후 재로그인 없이 `한결 설정…`과 `한결 정보`가 표시되고
실행되는 것이다. 완료 판정은 같은 로그인 세션의 실제 재설치 후 두 항목의 표시와
실행, 입력 소스 정상 동작을 확인하는 것으로 한다. TIS ready나 단위 검사만으로
메뉴 복구를 판정하지 않는다.

3.0.29/build 112를 08:00:41–08:00:50 재설치한 뒤 사용자가 제공한 스크린샷에서
한결 선택 상태지만 두 항목 대신 비활성 점 표시가 나타나는 현상이 재현되었다.
`/var/log/install.log`는 설치 성공을 기록했다. 한결 PID 96253은 08:00:50에
시작되었으며, TextInputMenuAgent PID 57434는 전날 로그인부터 유지되고 있었다.
활성화 대기 마커는 없었다. 로그에는 새 한결 프로세스의 InputMethodKit Menu 및
Activate Server 요청이 있으므로 프로세스 생존·요청 수신만으로 정상 표시를
보장할 수 없다. MenuAgent의 메뉴 항목 불일치 오류도 있지만 원인으로 확정하지 않는다.
원본 진단 로그는 `/tmp/hangyeol-menu-reinstall-20260921.log`에 보존했다.

복구 조건을 분리하기 위해 한결 PID 96253만 종료하고 같은 설치본을 PID 98170으로
다시 시작했다. 준비 helper 실행 시 selected-before=false였으므로 선택 상태를
강제로 변경하지 않았다. TextInputMenuAgent와 로그인 세션은 유지했다.
이 조치 뒤 실제 메뉴 표시 여부는 사용자 확인 대기 중이다. 아직 수정·해결 또는
새 패키지 검증 완료로 판단하지 않는다.

사용자는 한결만 재시작한 뒤에도 점 표시가 유지된다고 확인했다. 다음 단계로
입력 메뉴 프로세스만 재시작했다. `launchctl kickstart -k`는 SIP에 의해 거절되었고,
보호 설정을 변경하지 않았다. 현재 사용자 소유 PID 57434에 정상 종료(SIGTERM)를
보낸 뒤 macOS가 TextInputMenuAgent를 PID 98470으로 다시 시작한 것을 확인했다.
한결 PID 98170은 유지되었다. 이 두 번째 조치 뒤 메뉴 표시는 사용자 확인 대기 중이다.

메뉴 프로세스 재시작 뒤 사용자 스크린샷에서는 한결/ABC 목록 자체가 사라졌다.
새 프로세스의 제품 상태 조회 역시 candidates=false, enabled=false, ready=false와
verify-selected=false였다. 따라서 메뉴 프로세스 재시작만을 해결책으로 채택하지 않는다.
기존 설치본에 register → enable-parent → enable-mode → select-mode를 각각 별도
프로세스로 실행했고 모두 status=0이었다. 후속 별도 프로세스에서 candidates=true,
enabled=true, ready=true 및 verify-selected=true를 확인했다. 이 복구 뒤 메뉴 항목
표시·실행은 아직 사용자 확인 전이며, TIS 상태와 구분한다.

사용자는 재등록 뒤에도 입력 소스 없는 메뉴가 유지되는 스크린샷을 제공했다.
셸의 launchctl managername=Aqua, manageruid=501, 콘솔 사용자=thlim이며,
launchctl asuser 501의 별도 상태 조회도 ready=true였다. System Settings의
키보드 > 입력 소스 편집 화면을 Computer Use로 직접 열었을 때 목록에는
한결 하나가 표시되었다. 따라서 현재 현상을 단순히 다른 로그인 세션에서
등록한 결과라고 판단하지 않는다. 등록 UI와 상단 메뉴가 불일치하는 상태다.
`메뉴 막대에서 입력 메뉴 보기`를 on→off→on으로 변경하고 원래 on 상태로
복원한 뒤 완료를 눌렀다. 표시 갱신 결과는 사용자 확인 대기 중이다.


사용자는 표시 토글 뒤에도 한결이 없다고 확인했다. 이후 System Settings에서 ABC를
추가하고 한결 제거·재추가를 진행했다. 사용자의 상세 관찰로는 **ABC만 추가한
시점에 이미 한결이 돌아왔고, ABC→한결 전환 후 설정·정보가 표시되었다**.
따라서 제거·재추가 자체가 필요하다는 초기 해석은 철회한다. 최종 스크린샷에서
ABC, 선택된 한결, 한결 설정, 한결 정보를 확인했다. 재로그인은 하지 않았다.

추가 진단에서 `TISDisableInputSource(ABC)`는 status=0을 반환했지만 다음 별도
프로세스의 TIS 목록에는 ABC가 여전히 enabled였다. 오류 반환을 무시한 것이
직접 원인이라는 가설은 철회한다. 기존 설치 경로가 그 뒤 HIToolbox 목록을 직접
편집해 ABC를 제거하는 것은 관측된 시스템 유지 상태와 충돌하는 경로다.
이 현상만으로 최초 메뉴 소실의 모든 원인을 확정하지는 않는다.

3.0.30/build 113 후보 변경:
- 새 패키지 receipt를 확인한 뒤 fallback→한결 전환을 수행한다. 기존 TIS ready
  preflight가 ordinary update의 실제 전환을 생략하지 않도록 한다.
- 원래부터 활성 상태인 ABC도 전환 대상으로 전달한다. 원래 다른 입력기를
  선택했던 사용자는 변경하지 않는다.
- 활성화 완료 시 fallback을 자동 제거하거나 HIToolbox에서 강제 삭제하지 않는다.
  설치 후 ABC가 남을 수 있으며 입력 소스 관리는 시스템 설정에서 할 수 있다.
- 실패한 fallback 전환/별도 검증은 활성화 완료로 처리하지 않고 대기 요청을 남긴다.

573 tests / 61 suites 통과. 수정된 debug executable의 select-fallback,
verify-fallback-selected, select-mode, verify-selected를 순서대로 실행해 모두
성공한 것을 확인했다. 이는 기존 설치본이 실행 중인 환경의 전환 명령 검증이며,
새 패키지 재설치 후 메뉴 표시·설정/정보 실행 검증을 대신하지 않는다.
최종 패키지 설치 후 재로그인 전 표시와 메뉴 명령 실행 검증은 미완료다.

최종 3.0.30/build 113 상태에서 전체 573 tests / 61 suites가 통과했다
(`/tmp/hangyeol-330-final-tests.log`). HangyeolVerify와 셸 구문 검사도 통과했다.
`build_local.sh`로 4.2MB Local.pkg를 생성하고 압축을 푼 앱·설치 도우미의
Apple Development 서명, 제품 ID, 버전/build, 등록 메타데이터를 검증했다
(`/tmp/hangyeol-330-package.log`). 새 패키지는 아직 설치하지 않았다.
