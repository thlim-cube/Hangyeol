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
