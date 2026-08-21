# PriType 통합 입력 아키텍처 (Unified Input Architecture)

최초 작성 2026-06-01 · 최종 갱신 2026-08-11
상태: **canonical** — 이 문서가 한/영 입력 구조의 정식 명세다.

이 문서는 `v2.6.5`(내부 모드 통합)와 `v2.7.2`(macOS 입력 소스 통합)의 장점을 결합한
현재 아키텍처는 **단일 소스 하이브리드**다. 검토 단계의 "영어 가짜 모드 2개 등록" 안은
채택하지 않았으며, 그 차이와 근거는 아래 §2.1에 정리한다.

---

## 1. 결합 원리

두 버전이 각각 다른 것을 잘했고, 동시에 못 가지는 근본 충돌이 있었다.

| | 2.6.5 (내부 모드) | 2.7.2 (실 ABC 소스) |
| --- | --- | --- |
| 한/영 상태 진리 | `HangulComposer.inputMode` 단일 | TIS source + IMK mode + composer (분산) |
| 전환 경로 | 프로세스 내부, 동기 | `TISSelectInputSource(ABC)` 비동기 |
| 첫 글자 안정성 | 안정 (race 거의 없음) | "전환 직후 첫 키 씹힘" |
| 모드/입력 일치 | 일관 | "한글인데 영어 쳐짐" |
| 영어 = 진짜 macOS ABC | 아님 (내부 처리) | 맞음 |
| 메뉴바/입력소스 UI 통합 | 덜 자연스러움 | 자연스러움 |
| Caps Lock = macOS 소유 | 아님 (PriType가 가로챔) | 맞음 |

**근본 충돌:** 실제 ABC source가 선택되는 순간 PriType는 현재 IMK 입력 세션 소유권을 잃는다.
그래서 "진짜 ABC + 무지연 내부 전환"은 양립 불가능하다. 전환 race(2.7.2의 씹힘/불일치)는
*실제 입력 소스 선택*과 *PriType 내부 composer mode*가 서로 다른 비동기 시스템이라는 데서 온다.

**결합안:** custom 전환키 경로에서는 PriType 단일 입력 소스가 활성 IMK 세션을 유지하고, process-global
`InputModeStore` 하나로 한/영 상태를 관리한다. 각 session의 `HangulComposer`는 이 store를 읽되 조합 상태는 공유하지 않는다. 영어는 기본 설정에서 조합하지 않고 raw key를 pass-through하며,
`overrideKeyboardWithKeyboardNamed`로 로마자 레이아웃을 입혀 ABC를 *체감*으로 재현한다(2.7대의 통합 일부).
기본값은 ABC/US를 강제하며, 사용자가 설정에서 명시적으로 켜면 Carbon이 제공하는 최근 사용
ASCII-capable keyboard layout(Dvorak·AZERTY 등)을 대신 적용한다.
Caps Lock 기반 전환은 예외로 macOS가 실제 TIS source를 소유하고, 이때 PriType custom toggle은 비활성화한다.
macOS 소유권 활성화 또는 ABC→PriType 재선택 경계는 pending으로 기록하고, 다음 비보안 PriType
keyDown에서 내부 mode를 한국어로 정합화한다. 정합화 전에는 `InputModeOwnershipTracker`가 pending
상태만 유지하고 실제 mode와 client를 변경하지 않는다.

---

## 2. 권장 구조

```
CGEventTap / IOKit  ──(키 감지만)──►  InputModeCoordinator   (정책: Caps Lock·controller 유무)
                                            │ requestToggle
                                            ▼
                              PriTypeInputController          (IMK 세션 imperative edge)
                                  │ performPriTypeModeTransition
        ┌─────────────────────────┼──────────────────────────┐
        ▼                         ▼                          ▼
  write-safe commit 1회  overrideKeyboard(Roman)       InputModeStore 갱신
  또는 write-free discard (영어 레이아웃 보정)          (★ 프로세스 단일 진리)
                                            │
                          ┌─────────────────┴─────────────────┐
                     .korean                                .english
              libhangul 조합 + marked text          기본 pure pass-through (return false)
                                                    macOS가 영문 처리
```

### 2.1 단일 소스 등록 (영어 가짜 모드 미등록)

`Info.plist`는 `ComponentInputModeDict` 아래 **단일 모드** `com.pritype.inputmethod.v2`만 등록한다
(`tsInputModeScriptKey = smKorean`). 별도의 `...english` 가짜 모드는 등록하지 않는다.

과거 RollbackPlan은 Korean/English 두 가짜 모드 등록을 제안했지만 채택하지 않는다. 이유:

- [StatusBarManager](../Sources/PriTypeCore/StatusBarManager.swift)는 과거 공개 API의 source compatibility를 위한 no-op shell이며 별도 메뉴 막대 아이콘을 표시하지 않는다.
- 영어 표시를 위해 가짜 IMK mode를 추가하면 아래의 비동기 전환과 stale 입력 소스 문제를 다시 만든다.
- 두 모드는 전환마다 `selectInputMode:`라는 **또 다른 비동기 IMK 호출을 hot path에 추가**한다.
  이는 `composer.inputMode`와 desync 가능 → 우리가 제거하려던 race를 재도입한다.
- 2.7대에서 고생한 입력 소스 중복, `tsVisibleInputModeOrderedArrayKey` 튜닝, stale ID 정리가 다시 필요해진다.

**트레이드오프(수용):** 영어 모드일 때도 macOS 메뉴바의 입력 소스 아이콘은 PriType(한글)로 남는다.
PriType은 별도 `한`/`A` 상태 아이콘을 추가하지 않는다. 실제 mode는 `InputModeStore`, pending 소유권 정합화는 `InputModeOwnershipTracker`, 감시 backend 수명은 `ToggleMonitorStatusStore`가 각각 보관한다.

### 2.2 상태 소유권

| 상태 | 소유자 | 비고 |
| --- | --- | --- |
| 한/영 진리 | process-global `InputModeStore` | 모든 세션 composer가 읽는 단일 source of truth |
| 한글 조합 | session-owned `HangulComposer` | client 간 preedit/commit 상태를 공유하지 않음 |
| process active controller | `ActiveOwnerHandoffRegistry` | 새 controller publish 전 이전 session retire |
| 전환 정책(Caps Lock·fallback) | `InputModeCoordinator` | 실제 TIS 소유권/선택 소스 경계만 pending으로 기록하고 mode는 직접 쓰지 않음 |
| 감시 backend 단일 소유권·제한 | `ToggleMonitorStatusStore` | CGEventTap/IOKit 동시 실행 방지, IOKit 미지원 바인딩 노출 |
| IMK 세션 edge(commit·override·layout) | `PriTypeInputController` | imperative 경계 |
| 실제 TIS source 선택 | **macOS만** | Caps Lock 경로 한정 |
| TIS 조회·stale 정리 | `InputSourceManager` | hot path 제외 |

---

## 3. 불변식 (회귀 가드)

1. custom toggle hot path에서 `TISSelectInputSource`를 호출하지 않는다.
2. 프로덕션에서 `composer.inputMode`를 바꾸는 writer는 `PriTypeInputController`뿐이다.
   사용자 토글은 `performPriTypeModeTransition`, macOS 소유권 변경/ABC→PriType 재선택은
   Secure Input 검사를 통과한 `reconcileMacOSOwnedInputSourceBoundary`를 거친다.
   `activateServer` 같은 일반 포커스 변경은 모드를 건드리지 않는다.
3. 현재 field generation이 비보안으로 확인된 모드 전환만 active composition을 정확히 1회 commit한다. Secure·stale·미확인 generation은 client write 없이 폐기한다.
4. 전환 직후 keyDown을 막거나 replay하지 않는다. 전환이 즉시 완료되므로 불필요하다.
5. 영어 편의 fallback이 꺼진 기본 상태에서 PriType는 printable key를 consume하지 않는다(`return false`).
6. Release의 일반 typing hot path에는 TIS/AX 조회, UserDefaults JSON decode, 로그 문자열 생성이나 latency trace 비용이 없다.
7. Caps Lock on이면 custom toggle을 비활성화한다. 둘이 같은 키 이벤트에서 동시 동작하지 않는다.
8. TIS 소유권/선택 소스 알림은 mode를 직접 쓰거나 조합을 commit하지 않고 pending만 기록한다.
9. 새 controller는 이전 controller/session을 retire한 뒤에만 process active owner가 된다. 이전 controller의 늦은 `deactivateServer`는 새 owner를 해제하지 못한다.
10. 입력 파이프라인 진단은 content-free structured metadata만 사용한다. Release hot path에는 로그 문자열 생성, clock read, trace 할당이 없다.

---

## 4. 현재 적용된 정제

이 결합안을 정식화하면서 구현에 반영한 4가지.

### ① 단일 소스 유지
`Info.plist`의 단일 모드 등록을 정식 구조로 고정. RollbackPlan의 2-가짜-모드 안은 폐기(§2.1).

### ② 영어 모드 기본값 = 순수 pass-through
[HangulComposer.handle()](../Sources/PriTypeCore/HangulComposer.swift)의 영어 분기는 조합 정리 후
기본적으로 `return false`를 수행한다. 영어의 더블스페이스 마침표 등 텍스트 편의는 macOS와 host 앱이
소유한다(2.7 결정과 일치). 이로써 기본 경로에서 "PriType 영어 버퍼 ↔ 실제 커서" desync와 host 치환
중복 가능성을 제거한다.

- 한글 모드의 더블스페이스 마침표는 기존대로 `NSAutomaticPeriodSubstitutionEnabled` 연동 정책을 유지한다.
- pass-through 키에 host가 치환을 적용하지 않는 경우 사용자가 설정에서 영어 편의 fallback을 켤 수 있다.
  ON일 때만 `TextConvenienceHandler`가 자동 대문자, 스마트 따옴표·대시, 더블스페이스 마침표의 실제
  치환 이벤트를 소비한다. 시스템 각 기능 설정을 따르며 기본값은 OFF다.

### ③ custom toggle 경로 단일화 (전환 정책을 coordinator로)
2.6.5는 `onToggle`이 `sharedComposer.toggleInputMode()`를 **직접** 호출했다. 현재 구조는
`RightCommandSuppressor/IOKit → InputModeCoordinator → PriTypeInputController → composer`로 일원화해,
Caps Lock 정책·active controller 가드·전환 전 1회 commit을 한 곳(coordinator/controller)에서 보장한다.

토글 콜백은 [RightCommandSuppressor.triggerToggle](../Sources/PriTypeCore/RightCommandSuppressor.swift)에서
`DispatchQueue.main.async`로 메인 런루프에 올린다. 이는 **검증된 2.6.5 기준선과 동일**하다.

> 설계 노트: "전환 직후 첫 글자 씹힘"의 구조적 원인은 async hop이 아니라 2.7.2의 *비동기 TIS source 선택*이었다.
> 현재 구조는 실제 ABC source를 선택하지 않고 process-global `InputModeStore`만 controller 경계에서 갱신하므로
> race가 사라진다. 한때 토글을 탭 콜백 안에서 동기 실행하는 안을 검토했으나, 2.6.5/2.7.2 어디에도 없던 신규
> 동작(탭 콜백 내 IMK IPC)이라 `kCGEventTapDisabledByTimeout` 위험만 추가하고 이득이 불확실해 채택하지 않았다.

### ④ controller-only inputMode write path
`InputModeStore`를 쓰는 production 경계는 `PriTypeInputController`로 제한한다. 일반 탭·앱·필드
activation은 마지막 mode를 유지한다. 단, macOS가 Caps Lock 전환을 소유하는 동안의 소유권 활성화
또는 ABC→PriType 재선택은 실제 입력 소스 경계이므로 예외다. 이 경계는 coordinator가 pending으로만
기록하고, Secure Input을 통과한 controller가 `.inputSourceOwnership` finalize 후 한국어 mode로 정합화한다.

---

## 5. 전환 트랜잭션 (원자 순서)

```
Tap/IOKit  ──requestToggle(source)──►  InputModeCoordinator
   InputModeCoordinator: Caps Lock 소유면 거부, active controller 없으면 거부
   InputModeCoordinator ──performModeTransition──►  PriTypeInputController
      Controller: stale session context를 현재 field 기준으로 갱신
      비보안: 현재 field generation의 client write를 승인
             → 이전 generation 조합은 write-free discard
             → 같은 generation의 active composition만 commit (1회)
             → overrideKeyboardWithKeyboardNamed(ABC/US 또는 opt-in 현재 Roman layout)
             → composer.setInputMode(next)
      Secure Input: client write 없이 composition discard
                    → composer.setInputMode(next)
                    → Roman layout sync는 다음 비보안 입력 직전까지 보류

TIS/소유권 알림 ──► InputModeOwnershipTracker
   경계가 아니거나 TIS 조회 실패: no-op, 상태 추정 금지
   실제 경계: pending Korean reconciliation만 기록

다음 PriType keyDown
   1. session/context 확인 및 중복 keyDown 판정
   2. Secure Input 검사
   3. pending 소유권 정합화가 있으면 controller가:
      - session.finalize(.inputSourceOwnership)
      - Hanja/local context 정리
      - Roman keyboard override를 Korean 기준으로 동기화
      - InputModeStore를 .korean으로 갱신
   4. 비보안이면 secure custom toggle에서 보류한 Roman layout을 현재 mode 기준으로 동기화
   5. 현재 keyDown 정상 조합
```

실패 처리:

- active controller가 없으면 composer mode만 단독으로 바꾸지 않는다(다음 activate에서 stale state로 첫 글자 엉킴 방지).
- active session이 없으면 custom toggle은 no-op이다.
- Secure Input에서는 pending macOS 소유권 정합화만 보류하므로 실제 `InputModeStore`와 client는 바뀌지 않는다. 이는 client write 없이 실제 내부 mode를 바꾸고 Roman layout만 보류하는 Secure custom toggle과 별도 계약이다.
- TIS source를 조회할 수 없으면 선택 source를 추정하지 않는다.
- Caps Lock 소유 상태면 custom toggle은 진입 자체가 거부된다.
- regular/combo 한자 바인딩은 `nonsecure`에서만 전체 press pair를 소비하고, `secure`/`unknown`에서는 전체 쌍을 host로 통과시킨다. modifier-only 한자키는 기존 전역 단축키 계약을 유지한다.
- 후보 callback은 generation·client·session snapshot이 일치할 때만 client write를 허용하며, mode/session/focus/mouse/Secure discard가 이를 무효화한다.

---

## 6. 회귀 검증

빌드/유닛:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c debug --product PriType
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c debug PriTypeVerify
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product PriType
```

실기기 미검증 수용 체크리스트(대상 앱: TextEdit · Safari/Chrome · Electron(ChatGPT) · KakaoTalk · Finder · Terminal/iTerm · GoodNotes):

아래 항목은 자동 테스트 결과가 아니라 release 전 설치된 IME에서 확인해야 할 수용 기준이다.

- 한↔영 빠른 연타 중 입력 — 한글 모드에 영어가 섞여 나오는 사례 0
- 전환키와 다음 문자 거의 동시 입력 — 첫 keydown 씹힘 0 (정제 ③)
- 한글 조합 중 전환 — 같은 field generation이 비보안으로 확인됐으면 전환 전 1회 commit, 아니면 client write 없이 discard
- 한글 조합 중 앱 포커스 이동 — 앱 비활성 시 조합을 강제 commit(host-무관 멱등 안전망). 정상 호스트는 IMK `deactivateServer`로, 그렇지 않은 호스트(과거 KakaoTalk 사례)는 `NSWorkspace` 비활성 알림으로 처리
- Backspace 길게 — release build 체감 딜레이 없음
- Return/Enter 1회 — GoodNotes 중복 줄바꿈 없음
- Hanja 후보창 호출 및 좌표 — Chromium fallback 포함
- 한자 후보창을 연 뒤 mode/session/click/Secure 경계 진입 — retained callback의 client write 0
- regular/combo 한자키 — nonsecure에서는 down/repeat/up 소비, secure/unknown에서는 전체 쌍 통과
- 영어 모드 더블스페이스 — host(macOS)가 처리하는지 확인 (정제 ② 검증 의존)
- Caps Lock 전환 on — custom toggle 비활성, macOS만 ABC↔PriType 전환
- Caps Lock 전환 on, ABC→PriType 복귀 — 첫 비보안 keyDown 전에 내부 mode가 한국어로 정합화됨
- 동일 PriType source에서 탭·앱·필드 이동 — 마지막 한/영 mode 유지
- Secure Input 필드의 pending 소유권 경계 — commit/mode write 없음(custom toggle은 별도 계약)
- 새 controller가 이전 deactivate보다 먼저 활성화 — write-safe인 이전 조합만 1회 확정하고, stale·미확인 generation은 write-free discard; 늦은 deactivate가 새 owner에 영향 없음
- CGEventTap 반복 실패 — tap 완전 해제 후 IOKit 단독 실행, 미지원 regular/combo 바인딩을 중앙 감시 상태에 기록

---

## 7. 보존 확정 (이미 검증된 개선)

- 최신 설정창 UI/UX (Liquid Glass)
- Caps Lock은 macOS 입력 소스 설정이 소유한다는 정책
- GoodNotes Return 중복/누락 보정
- 앱 비활성 시 조합 강제 commit — host-무관 멱등 안전망(과거 KakaoTalk 하드코딩을 일반화: `InputSession.handleAppDeactivation()` → `finalize(.appDeactivate)`)
- 설치/시작 시 PriType 자신을 `TISEnableInputSource` 하지 않는 보수화
