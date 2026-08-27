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

결과는 최종 문자열을 정확히 비교한다. 정규화하면 같아 보이는 분리 자모도
실패로 판정한다. 고정 대기 시간으로 성공을 가정하지 않고 제한 시간 동안
실제 값과 focus 조건을 polling한다. 실패 시 설치 버전, 활성 앱, 활성 필드,
caret, 각 필드의 실제 Unicode 값을 출력한다.

## Confluence 검증

로컬 Chrome fixture 통과는 Confluence 통과를 대신하지 않는다. 로그인된
Confluence 페이지에서 수동 또는 별도 브라우저 세션으로 검증하지 않은 경우
결과를 `미검증`으로 기록한다. 자동 결과와 실제 Confluence 결과는 항상
분리해서 보고한다.
