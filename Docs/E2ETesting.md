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


## 3.0.30 설치 실패와 실제 대기 결함 (2026-09-21)

사용자는 09:43에 3.0.30 설치 후 입력 소스가 없는 메뉴와 영문으로만 입력되는
현상을 보고했다. 설치본 버전은 3.0.30, 한결 PID 3735였지만 새 프로세스의
상태는 candidates=false/enabled=false/ready=false였고 대기 마커는 이미 없었다.
따라서 3.0.30의 설치 후 복구는 실패로 판정하며 이전 로컬 검사와 구분한다.
진단 로그는 `/tmp/hangyeol-330-install-failure.log`에 보존했다.

안정화 검사 프로세스들이 09:43:22.7–23.6에 집중되어 있었다. 의도한 5개 안정
관측 사이의 총 5.5초 대기는 실행되지 않았다. GCD worker의 RunLoop에 소스가
없으면 RunLoop.run(until:)는 지정 시각까지 대기하지 않고 즉시 반환한다.
실제 운영 호출이 사용하는 함수를 그대로 worker에서 검사하는 회귀 테스트에서
80ms 요청이 약 0.305ms에 반환되어 실패했다(`/tmp/hangyeol-retry-before.log`).
수정은 worker 대기를 Thread.sleep으로 바꾸며 IMK 메인 스레드는 차단하지 않는다.
같은 방식의 활성화 완료 polling도 함께 수정했다.

기존 설치본에 register/enable-parent/enable-mode 후 ABC→한결 선택을 수행하여
TIS ready=true를 확인했지만 이는 사용자 화면 복구 증거와 구분한다.
3.0.31/build 114 후보는 위 대기 결함을 수정한다. 전체 574 tests / 61 suites와
실제 worker 대기 회귀 검사를 통과했다. 새 설치본의 재설치 검증은 아직 수행하지
않았으므로 전체 메뉴 문제 해결을 확정하지 않는다.

## Chrome 반복 실행 중 영문 혼입 진단 (2026-09-21)

사용자 요구: 다른 앱에서 한글을 입력할 때 백그라운드 Chrome 자동화/실행 때문에
일시적으로 영문이 입력되지 않아야 한다. ABC 전환과 동일한 문제로 가정하지 않는다.

설치본 3.0.30/build 113에서 별도 TextEdit 인스턴스에 물리 CGEvent로 `한글\n`을
반복 입력하고, 별도 프로필 Chrome을 Playwright로 재실행했다. 전송 전 대상 PID를
검사하고, 테스트 Chrome이 포커스를 가져간 경우 TextEdit로 돌아온 뒤 입력을 재개했다.
사용자 문서/클립보드/원격 연결/입력 소스 등록은 변경하지 않았다.

| 조건 | 결과 |
| --- | --- |
| 기존 Chrome에서 백그라운드 자동 입력, TextEdit 60줄 | 불일치 없음 (이전 검사) |
| 창 있는 Chrome 재실행 12회, TextEdit 200줄 | 9줄 불일치. `한글` 대신 `g나글` 1회, 자모 분리/누락도 관찰 |
| 같은 재실행 + TextEdit 복귀 후 75ms 대기 | 2줄 불일치. 영문은 관찰 안 됐지만 자모 분리/줄바꿈 누락이 남음 |
| 화면 없는 Chrome 재실행 12회, TextEdit 200줄 | 불일치 0, 영문 혼입 0 |

NSWorkspace 활성 앱 알림에는 Chrome→TextEdit의 짧은 왕복이 기록됐으며,
2ms 간격 TIS 표본은 전부 한결이었다. 이는 표본 사이의 전환까지 배제하는 증명은 아니다.
창 있는 재실행 실험의 첫 영문 혼입은 TextEdit 복귀 직후 관찰됐다. 고정 지연의
한 번의 영문 미검출을 수정 성공으로 보지 않는다. 재현기는 원격 클라이언트 키 전달을
거치지 않았으며 실제 앱의 모든 입력 경로를 검증한 것은 아니다.

현재 배포 빌드는 DebugLogger가 컴파일에서 제거되어 내부 한영 상태 변경과
context/ownership 경계에서의 raw pass-through를 구분할 수 없다. 입력기 결함의
정확한 분기와 수정은 아직 미확정이다. 진단 코드만 활성화/비활성화, 키 경계,
pass-through 사유, 처리 결과와 내부 모드를 기록하도록 확장했다. 문자, 키 코드,
앱 이름, 문서 내용은 기록하지 않는다. 입력 처리/보안 판정의 반환값은 변경하지 않았다.

관찰 자료: `/Users/thlim/Documents/Codex/hangyeol-focus-diagnostics-2026-09-21/`.
`headed/native.log`의 `PASS/RESULT PASS`는 초기 탐침이 불일치를 계속 관찰하려고
중단을 해제하면서 남긴 잘못된 요약이다. 해당 실험은 **9줄 불일치로 실패**다.
후속 탐침은 불일치가 있으면 FAIL로 표시하며 보관한 소스도 실패 종료 코드를 반환한다.
자동 테스트의 즉시 완화책은 가능한 시나리오를 headless로 실행하는 것이다.
이는 한결 입력기 자체의 수정 완료를 의미하지 않는다.


진단 준비 검증: 574개/61 suites 통과, HangyeolVerify 통과, release DebugLogger 2개
검사 통과, git diff --check 통과. Apple Development 서명 앱/설치 helper를 담은
`Hangyeol_3.0.31_FocusDiagnostic_Local.pkg`의 서명, payload 버전/build와 등록 metadata를
검증했다 (SHA-256 `89599627ff8b9731c5a4f15902b605bb359a145c6447132bc220d898aff7ec63`).
진단본은 DEBUG 빌드이며 최종 수정/배포본이 아니다. 설치된 3.0.30/PID 3735는
교체하지 않았다. `sudo -n true`는 `a password is required`로 거절되어 관리자 인증이
필요하다. 다음 단계는 진단본 설치 후 실행 중 바이너리 식별을 확인하고 동일 재현을
실행해 `input.key_boundary`, `input.key_passthrough`, `input.key_result`,
`input.activation/deactivation`, `toggle.transition_started`를 함께 대조하는 것이다.
현재 수정은 진단 목적이며 근본 수정과 버전 증가/최종 커밋은 보류한다.


## 3.0.31 진단본 설치 후 결과와 시스템 편집기 분류 수정 (2026-09-22)

사용자 확인: 설치 후 입력 메뉴에서 기존 입력기들이 사라졌고, 키보드 하나를
삭제·추가하자 한결이 다시 표시됐다. **3.0.31의 재설치 메뉴 문제는 미해결**이다.
현재 정상으로 복구한 등록 상태는 변경하지 않았다. 설치 앱은 진단 PKG와 동일한
3.0.31/build 114, CDHash `f7500bde12138230a5884cbdd16b40facea2f8c7`이다.

진단본에서 창 있는 Chrome 재실행 12회/200줄 검사: 8줄 불일치, 영문 혼입은
이번 실행에서 미검출. 1470개 키 경계/처리 결과가 기록됐고 내부 모드는 모두
korean이었다. context guard의 key_passthrough와 toggle.transition은 없었다.
이는 앞서 영문이 섞였던 순간의 내부 원인까지 증명하지 않는다. 후속 24회 검사는
기준 입력 첫 줄부터 예상치 못한 문자가 관찰돼 깨끗한 대조 실험으로 채택하지 않았다.
자료는 `/Users/thlim/Documents/Codex/hangyeol-focus-diagnostics-2026-09-22/`에 보관했다.

별도 TextEdit 입력이 `host.capabilities surface=blink_web`으로 분류되어 Chrome용
Return 재전송을 적용하는 결함을 확인했다. `NSTextInputReplacementRangeAttributeName`은
Blink만의 속성이 아니며 WebKit의 AppKit SPI 선언에도 있다:
https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/mac/NSTextInputContextSPI.h

실제 관찰된 TextEdit과 알려진 시스템 렌더러 Finder/Safari에 대해서는 이 속성만으로
Blink로 분류하지 않도록 수정했다. 식별하지 못한 호스트의 기존 capability fallback과
Chrome/Electron/Hermes 호환 계약은 유지했다. 시스템 호스트 네 가지의 회귀 테스트가
수정 전에 실패하는 것을 확인했고, 수정 후 전체 575개/61 suites가 통과했다.
진단 로그는 DEBUG에서만 활성화된다. 이것은 확인된 분류 결함의 수정이며, 짧은
포커스 왕복의 영문 혼입과 재설치 메뉴 문제 전체의 해결을 뜻하지 않는다.
3.0.32/build 115 후보는 설치하지 않았으므로 변경 후 실제 호스트 검증은 아직 남아 있다.

3.0.32 후보 최종 확인: 575개 테스트 통과, HangyeolVerify 통과, Apple Development
서명 앱/설치 helper, 패키지 payload 버전 3.0.32/build 115와 등록 metadata 검증 통과.
생성 파일은 `Hangyeol_3.0.32_Local.pkg`. 설치하지 않았다. 현재 실행 중 3.0.31
진단본(PID 75284)의 CDHash도 진단 PKG와 일치하며 TextEdit 기본 입력 1/1 통과했다.


## 3.0.32 설치 후 실제 호스트 검증 (2026-09-22)

설치 앱/실행 PID 80875와 Local PKG의 서명·버전 3.0.32/build 115·CDHash
`9934ecbe9e70f4929744412ad1e67d499e14cbaa` 일치를 확인했다. 기본 TextEdit
두벌식 입력은 1/1 통과했다. 그러나 Chrome 재실행 12회/한글 200줄에서 **7줄
불일치, 그중 영문 혼입 2줄**이 재현됐다 (`한ㄱmㄹ`, `ㅎkㄴ글`). 기준 입력
10줄은 불일치가 없었다. TIS 표본은 계속 한결이며 짧은 Chrome→TextEdit
포커스 왕복을 기록했다. **3.0.32는 원래 영문 혼입 문제의 해결본이 아니다.**
분류 결함 수정만으로 해결되지 않았으며 오류 개수 차이를 개선 효과로 해석하지 않는다.
원격 클라이언트가 아닌 로컬 CGEvent 검사라는 제한은 유지한다.

현재 TextInputMenuAgent의 접근성 트리에는 ABC, 한결, 한결 설정..., 한결 정보가
정상 표시된다. 사용자는 이번 설치에서도 삭제·재추가로 복구했다고 확인했다.
따라서 **3.0.32에서도 재설치 메뉴 소실은 미해결**이며 현재 정상 메뉴는 자동 복구의
증거가 아니다. 메뉴 CUA 호출은 두 차례
timeoutReached여서 허용된 네이티브 AX 읽기로 전환했으며 등록 상태를 변경하지 않았다.
검증 자료: `/Users/thlim/Documents/Codex/hangyeol-focus-diagnostics-2026-09-22/installed-3.0.32/`.


## Jira 설명 편집기의 조합 중 Shift+Return (2026-09-22)

사용자가 지정한 실제 Chrome Jira QTF-145 설명 편집기에서 검사했다. 대상은
`#ak-editor-textarea`이며 제목/인용/목록/빈 문단을 가진 Atlassian 편집기였다.
현재 설치본은 3.0.32이며 3.1.0은 입력 코드 변경 없는 버전 갱신이었다.

물리 CGEvent로 마지막 빈 문단에 `한글`을 입력하고 Shift+Return을 누르자
`한`과 hardBreak만 남고 `글`이 사라졌다. Shift flagsChanged 누름/뗌을 포함한
재검사에서도 같은 손실을 확인했다. 반면 오른쪽 화살표로 조합을 먼저 확정한 뒤
Shift+Return, `한글`을 입력하면 `한글\n한글`이 유지됐다. 앱 전환 없이 지정된
편집기에서 발생했으므로 앞서 수용한 앱 간 포커스 탈취 현상과 구분한다.

검사 후 실행 취소로 원래 텍스트와 H3/blockquote/2개 li/빈 p 구조를 복구했다.
저장 버튼을 누르지 않았고 이슈 내용은 게시하지 않았다.

원인 후보는 Chrome web에 대해 일반 Enter와 Shift+Enter를 함께 즉시 pass-through하던
예외다. 조합 확정 IPC가 반환됐다고 웹 편집기의 조합 종료까지 완료된 것은 아니다.
Chrome web의 조합 중 Shift+Return만 기존 HostKeyTransaction 경로에 포함했다.
이 경로는 소유한 조합 범위/선택의 해제와 읽을 수 있는 확정 텍스트를 검사하고,
준비 조건이 충족되면 원래 Shift 플래그를 유지한 Return을 한 번 전달한다. 일반 Chrome Return, 비조합 줄바꿈,
Command/Control/Option 단축키, 다른 호스트의 기존 처리는 유지한다. 앱 간 포커스
문제용 지연을 추가한 것이 아니며 새 고정 대기 시간도 도입하지 않았다.

새 회귀 검사는 변경 전 4개 assertion 실패를 확인했다. 변경 후 전체 576개/61 suites
통과. 기존 Chrome Shift+Return의 즉시 통과를 기대하던 검사는 이번 실제 사용자 요구에
맞춰 조합 확정 후 soft break 한 번 전달을 검증하도록 바꿨다. 일반 Return 즉시 전달
검사와 지연 replay/빠른 Delete/보안 및 세션 교체 검사도 유지했다.
3.1.1/build 117 후보의 실제 Jira 재검증은 설치 후 수행해야 하며 아직 완료가 아니다.
설치 메뉴 소실 문제도 이 변경의 해결 범위에 포함하지 않는다.


### 3.1.1 설치 후 일반 Return 추가 재현 (2026-09-22)

사용자는 `한글` 뒤 Shift+Enter 또는 일반 Enter에서 `한`만 남고, Shift를
별도로 눌렀다가 Shift+Enter를 누르면 유지된다고 보고했다. 설치 앱의 버전은
3.1.1이었다. 같은 Jira 편집기에서 직접 검사한 Shift+Enter 1회는 성공했지만,
일반 Enter에서는 마지막 `글` 소실을 재현했다. Shift 선행 입력에 따른 차이는
아직 직접 검증하지 않았으며 Shift+Enter의 간헐적 실패를 해결로 판정하지 않는다.

편집기 범위에만 임시 이벤트 리스너를 설치해 관찰했다. 실패한 일반 Enter는
compositionend(`글`) 시각 820698.7ms 직후 820699.3ms에 비조합 Enter keydown을
받았고, 최종 문단에는 `한`만 남았다. 성공한 Shift+Enter의 비조합 Enter는
compositionend 뒤 약 16.6ms에 관찰됐다. 이는 두 실행의 관찰값이며 필요한
대기 시간이나 편집기 내부 모델 동기화의 확정 원인으로 해석하지 않는다.
검사 후 실행 취소로 이번 검사 직전 사용자 초안(목록의 `한글` 포함)과 텍스트가
정확히 같음을 확인했다. 저장/취소 버튼은 누르지 않았고 임시 리스너를 제거했다.

3.1.2에서는 Chrome 일반 Return만 조합 완료 확인을 우회하던 예외를 제거했다.
이미 Shift+Return과 다른 Blink 웹 호스트에서 사용하는 HostKeyTransaction을
일반 Return/숫자패드 Enter에도 적용한다. 고정 대기 시간은 추가하지 않았다.
기존 테스트의 즉시 pass-through 기대는 이번 사용자 요구와 실측 실패에 따라
조합 확정 후 호스트 줄바꿈 1회로 변경했다. Return/숫자패드 Enter와 Shift
조합의 4개 사례로 기존 회귀 검사를 통합했으며 변경 전 비-Shift 두 사례에서
8개 assertion 실패를 확인했다. 이 모델 검사는 실제 Jira 렌더러 성공의 증거가 아니다.

변경 후 전체 575개/61 suites와 HangyeolVerify가 통과했다.

3.1.2 설치 후 일반 Enter, Shift+Enter, Shift 선행 후 Shift+Enter, 줄바꿈 직후
연속 한글 입력의 실제 Jira 재검증이 남아 있다. 재설치 메뉴 소실도 별도 미해결이다.

### 3.1.2 실제 사용자 재현과 renderer 안정화 후보 (2026-09-22)

사용자가 실제 Jira 설명 편집기에서 Enter/Backspace/재입력 후 Enter와
Shift+Enter를 반복했다. 처음의 요소별 임시 기록은 비어 있어 재현 증거로 쓰지
않았다. 이후 document capture listener에서 `#ak-editor-textarea` 대상으로만
기록하도록 바꾸고 자동 키 입력으로 수집 동작을 확인했다. 사용자 재현 전 자동
시험 입력은 전부 실행 취소했고 직전 초안과 텍스트가 같음을 확인했다.

사용자 재현의 마지막 1,000개 이벤트 중 조합 종료부터 호스트 Enter까지 모두
남아 있는 20회에서 일반 Enter 소실 2회를 확인했다. 아래 숫자는 compositionend
(`글`)부터 비조합 Enter keydown까지의 관찰 간격(ms)이며, 최소 안전 시간의
증명이 아니다. 성공/실패 모두 Enter 전에는 caret=2,2이고 텍스트가 `한글`이었다.

- 일반 Enter 보존: 15.6, 9.1, 20.5, 20.8, 26.9, 8.7, 10.4, 7.9, 9.6,
  12.7, 23.7, 21.9, 16.5, 7.7, 17.0
- 일반 Enter 소실: 4.6 (`2480500.8 → 2480505.4`),
  6.4 (`2491069.4 → 2491075.8`); Enter keyup에서 `한`만 남음
- Shift+Enter 보존: 10.7, 6.6, 9.5

따라서 표시상 조합 종료/선택 해제만으로 편집기의 줄바꿈 준비를 보장하지 못한다.
Backspace가 직접 원인이라는 증거는 아니며, 이번 수집 구간의 Shift+Enter는
성공했다. 사용자에게 보고받은 빠른 Shift+Enter 실패 역시 미해결 범위로 유지한다.
수집 후 임시 리스너를 제거했으며 사용자 재현 텍스트는 건드리거나 저장하지 않았다.

3.1.3/build 119 후보는 Chrome의 조합 중 Return/숫자패드 Enter(Shift 포함)에만
기존 readiness 통과 후 20ms 안정화 대기를 추가한다. 그 뒤 세션 권한, 커서 위치,
조합 범위, 확정 텍스트를 다시 검사한다. 대기 중 새 조합/커서 이동/필드 교체가
생기면 잘못된 곳으로 줄바꿈을 보내지 않는다. 같은 조합이 다시 나타나면 안정화를
다시 시작한다. 일반 타이핑, 비조합 Enter, Delete, 다른 호스트에는 이 대기를
추가하지 않는다. 이는 OS 포커스 탈취 대응 지연과 별개의 조합 직후 처리다.

20ms는 관찰된 실패 간격보다 여유를 둔 후보 값이며 모든 편집기의 완료를
확인하는 API가 아니다. 테스트 모델에서는 IMK caret/mark가 먼저 완료되고
편집기 갱신이 뒤따르는 경우를 재현했다. 새 4개 Return/Shift 사례는 변경 전
12개 assertion 실패를 확인했다. 권한 해제, 새 조합, 텍스트 변경, 커서 이동,
동일 mark 재등장 검사도 추가했다. 설치 후 실제 Jira에서 반복 입력/빠른
후속 입력을 검증하기 전에는 사용자 증상이 해결됐다고 판정하지 않는다.

최종 코드에서 전체 577개/61 suites, HangyeolVerify, git diff --check 통과.


## 3.1.4 Google 조합 커서 위치

요구 출처: 2026-09-22 사용자 수정 요청. Google AI Overview의 Ask anything
입력창에서 조합 중에도 커서가 현재 글자 뒤에 있어야 하며, 받침·Backspace·중간
삽입과 삭제를 보존해야 한다. 전체 타이핑 지연이나 글자마다 강제 확정은 추가하지 않는다.

macOS 26.6.2 / Chrome 153.0.8010.48, 기존 사용자 Google textarea에서
CUA 키 입력과 DOM의 value/selectionStart/selectionEnd를 함께 관찰했다.
원문 `여기서`를 기준으로 테스트 글자만 추가하고 매번 원문으로 복원했다.
Google 질문 전송과 Jira 문서 저장은 하지 않았다.

- 기존 3.1.3: `g,k` → `여기서하`, selection=(3,4). 한결은 (1,0)을 요청하지만
  Chrome DOM에는 활성 음절을 선택한 범위가 나타났다.
- Chrome CDP `Input.imeSetComposition`에 상대 caret=(1,1)을 직접 전달한 대조:
  `여기서하`, selection=(4,4). 따라서 해당 Google textarea 자체가 끝 커서를
  항상 앞쪽 선택으로 바꾸는 것은 아니다. 이 대조는 실제 한결 입력 검증과 구분한다.
- 수정 후보: Blink에 스타일 없는 NSAttributedString을 전송 → (4,4).
- 재시작 효과 대조: 동일 소스에서 payload만 기존 NSString으로 되돌린 debug
  실행 파일로 프로세스를 교체한 뒤 같은 필드에서 다시 (3,4)를 관찰했다.
- 수정 후보로 다시 교체: `여기서한글` → (5,5), `여기서한중글` → (5,5).
  뒤 문자 Delete 결과는 `여기서한중`으로 현재 조합을 보존했다.
- `하 → 한 → Backspace → 하`에서도 caret=(4,4)를 유지했다.
- Shift+Return 시 `여기서한글`은 보존했으나 이 Google 입력창에서는 줄바꿈이
  생기지 않았다. 이 실행을 줄바꿈 성공이나 물리 키의 빠른 연속 입력 검증으로
  보고하지 않는다. Jira의 실제 빠른 Enter/Shift+Enter 재검증은 이번 범위 밖이다.

비교 실행은 같은 bundle ID의 Apple Development 서명 debug 앱으로 수행했다.
설치 디스크 앱은 변경하지 않았으며, 종료 후 `/Library/Input Methods/Hangyeol.app`
3.1.3 프로세스로 복구했다. 배포할 release 패키지의 설치 후 실측과는 구분한다.

변경은 Blink marked payload 형식뿐이다. 과거 `_forceAttributedString` 충돌이
기록된 색상·밑줄 속성은 보내지 않는다. 위 실측에서 충돌은 관찰되지 않았으나 모든
Electron 호스트·macOS 버전의 무충돌을 입증한 것은 아니다. Native/WebKit 스타일,
조합 커서의 UTF-16 끝 범위, 기존 3.1.3의 Chrome Return 안정화는 유지한다.

기존 payload 테스트를 확장해 빈 조합·자모·음절·복수 음절·보조 평면 문자의
문자열 보존 및 Blink의 빈 속성 집합을 검증한다. 기존 NSString 구현에서는 6개
입력이 실패했고 수정 후 통과했다. 호스트 변경 테스트는 단순 attributed 여부뿐
아니라 AppKit 스타일 → Blink 빈 속성 전환을 검사하도록 유지했다.
전체 577 tests / 61 suites 통과. 실제 IMK/Chrome 커서 개선의 근거는 위 대조 실측이며,
mock 테스트가 macOS 전송 계층을 재현한다고 주장하지 않는다.

## 3.1.5 문자 정보가 없는 탐색키

요구 출처: 2026-09-22 사용자 요청. Chrome ChatGPT에서 `안녕` 조합 직후
Keyboard Maestro의 Home → Command+Left가 이동하지 않고 오류처럼 반응한다는
보고다. 특수키는 조합을 보존한 채 앱의 이동/Shift 선택 동작으로 이어져야 한다.

코드에서 별도로 확인한 결함은 Home/End/Page Up/Page Down이 문자 코드 fallback에만
의존해 `characters`가 nil/빈 문자열이면 조합 확정 전에 반환된다는 점이다.
기존 화살표와 같은 하드웨어 keyCode 경로로 처리하고 이동 전 로컬 문자 문맥을
무효화한다. 이벤트 modifier를 바꾸거나 재전송 대기 시간을 추가하지 않는다.

기존 composer 테스트에 네 키 × nil/빈 문자열 × Fn/Shift 조합을 추가했다.
최초 Fn 및 Shift+Fn 16개 조합은 수정 전 48개 assertion 실패를 확인했다.
최종 검사에는 modifier 없음과 Shift 단독도 포함하여 32개 조합에서 확정 문자열,
조합 해제, host pass-through, Shift 보존과 확정 호출 순서를 확인한다.
전체 578 tests / 61 suites가 통과했다.

설치된 3.1.4에서 CUA의 개별 키 입력으로 실제 ChatGPT에 `안녕`을 조합한 뒤
Command+Left를 직접 보내면 글자를 보존하며 DOM caret이 (2,2)에서 (0,0)으로
이동했다. 첫 DOM keydown은 composing=true였고, compositionend 뒤의 후속
keydown은 composing=false였다. 직접 보낸 Home/Command+Left에 해당하는
Keyboard Maestro Engine 실행 로그가 없었으므로 실제 매크로 재현으로 보지 않는다.
메시지는 전송하지 않았고 테스트 문구와 임시 이벤트 리스너는 제거했다.

따라서 본 변경은 문자 정보가 없는 탐색키의 composer 계약을 수정한 것이다.
사용자가 보고한 물리 Home → Keyboard Maestro → Chrome 전체 경로의 실패 원인과
설치 후 해결 여부는 미확인이다. 기존 합성키 modifier 보존 정책과 Return 안정화는
유지한다. Keyboard Maestro 설정은 변경하지 않았다.

## 조합 중 Keyboard Maestro 탐색키 손상 재현 (2026-09-22)

사용자가 기존 ChatGPT 입력창에서 직접 입력했고, DOM 이벤트와 별도의 읽기 전용
navigation-only event tap을 함께 관찰했다. 설치본은 3.1.4였다. 요청된 동작은
`안녕`을 보존한 채 Home/Command/Option/Shift 탐색을 앱에 정확히 한 번 전달하는 것이다.

- Home → Keyboard Maestro Command+Left: `안녕` 뒤 ArrowLeft keydown/up은
  composing=true였고 compositionend가 없었다. 약 1.39초 뒤 Space에서
  compositionupdate가 ` `로 바뀌며 문서는 `안 `이 되었다.
- 실제 Command+Left → Keyboard Maestro Option+Left: 최종 `녕` input 뒤
  약 725ms 후 ArrowLeft(alt=true, meta=false, composing=true)가 도착했고,
  약 0.3ms 뒤 compositionupdate 데이터가 U+001C, 다음 input은 `안\u{001C}`였다.
  따라서 단순히 마지막 받침과 이동키가 빠르게 겹치는 경우에만 국한되지 않는다.
- Keyboard Maestro Engine 로그에 두 매크로 실행이 각각 기록되었다.
  읽기 전용 event tap에서도 물리 Home(PID 0)과 KM 화살표(PID 57509)를 구분했다.
  CGEvent Unicode는 U+001C지만 NSEvent.characters는 정상 U+F702였다.
  CGEvent의 U+001C만 보고 잘못된 문자 payload로 판단하거나 일괄 치환하지 않는다.
- CUA에서 직접 보낸 Option+Left는 기존 설치본에서도 `안녕`을 유지하며
  caret을 (2,2)에서 (0,0)으로 옮겼다. 이 자동 입력은 KM 경로를 검증하지 않는다.

위 손상은 관찰된 호스트 결과다. Chromium 내부 어느 분기가 실행됐는지까지
계측한 것은 아니다. 회귀 모델은 mark가 남은 채 raw navigation을 넘기면 마지막
음절을 제어문자로 대체하는 이 결과를 고정하고, 조합 종료 확인 전에는 키가
호스트에 전달되지 않도록 검사한다. 새 고정 대기 시간은 사용하지 않는다.

3.1.6/build 122는 이 모델에 맞춰 Blink 조합 중 탐색키를 기존 host key
transaction으로만 전달한다. 한자 후보가 떠 있으면 후보 창이 먼저 소비한다.
단위·모델 검증은 실제 Keyboard Maestro 설치본 재현과 구분한다.

## 3.1.7 Chrome 탐색 단축키 검증 (2026-09-23)

3.1.6 설치본에서 사용자가 `안뇽` 뒤 Home을 누르면 ChatGPT 메시지가 제출되고,
Command+Left를 누르면 `Try again` 화면이 열렸다. Chrome DOM 기록에서
탐색키 직후 조합 데이터가 줄바꿈으로 바뀌는 손상이 확인됐다. Chrome의
`flagsChanged`에서 왼쪽 Command·Control만으로 조합을 미리 확정하던 경로를
제거하고, 실제 keyDown의 기존 host key transaction에 처리를 맡겼다.

Apple Development 서명한 3.1.7 debug 후보를 실행 중인 IMK로 대조한 뒤,
사용자가 같은 Chrome ChatGPT 입력창에서 Keyboard Maestro Home과
Command+Left를 직접 시험했다. Keyboard Maestro Engine에 두 매크로 실행이
기록됐고, Chrome DOM에는 첫 탐색키 keydown에서 `안녕`의 마지막 음절이
정상 compositionend로 끝나고 후속 keydown에서 caret이 이동한 기록이 남았다.
사용자도 동작을 확인했다.
전체 585개 단위 테스트와 55개 ReturnDelivery 테스트가 통과했고, Chrome
브라우저 탭 직후 첫 음절 E2E 시나리오가 통과했다. 같은 E2E 실행의 TextEdit
기본 Return 검사는 `한글\n` 대신 `한글`이 관찰돼 전체 E2E 통과로 판정하지
않는다. 이번 변경은 Chrome 전용 modifier 조기 확정만 제거한다. 3.1.7
설치본의 재로그인 후 검증은 별도다.
