# 한결 (Hangyeol)

<p align="center">
  <strong>macOS 기본 입력 흐름에 맞춘 빠른 한글 입력기</strong><br>
  한글은 한결 조합, 영어는 ABC 레이아웃 pass-through. 전환은 빠르게, 조합은 가볍게.
</p>

<p align="center">
  <a href="https://github.com/Meapri/Hangyeol/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Meapri/Hangyeol?label=release"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14.0%2B-111111">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

한결은 Swift와 InputMethodKit으로 만든 macOS용 한글 입력기입니다. 시스템 파일과 코드에서는 `Hangyeol`로 표기합니다. 한글 조합 엔진은 [libhangul-swift](https://github.com/Meapri/libhangul-swift)를 사용합니다.

## 특징

- **빠르고 안정적인 한/영 전환**
  한결은 한 입력기 안에서 한글 모드와 영어 모드를 함께 관리합니다. 사용자 지정 전환키는 실제 `ABC` 입력 소스를 선택하지 않고 한결 내부 모드만 전환해, 전환 직후 첫 글자 씹힘과 한/영 상태 불일치를 줄입니다.

- **영문 레이아웃 pass-through**
  영어 모드에서는 한결이 문자를 직접 삽입하지 않고, 기본적으로 macOS `ABC`/`US` 키보드 레이아웃을 요청한 뒤 host 앱의 기본 입력 흐름으로 통과시킵니다. 설정에서 현재 영문 자판 배열 존중을 켜면 Dvorak·AZERTY 등 최근 사용한 ASCII-capable 레이아웃을 유지합니다.

- **빠른 한글 조합**
  두벌식 표준, 세벌식 390, 두벌식 옛한글, 세벌식 옛한글을 지원합니다.

- **한자와 자모 특수문자**
  한글 입력 중 한자키를 눌러 한자 후보를 고를 수 있습니다. 자음 입력 후 한자키를 누르면 `♥`, `★` 같은 자모 특수문자도 입력할 수 있습니다.
  일반키나 조합키를 한자키로 지정한 경우에는 현재 필드가 비보안으로 확인된 때만 해당 키를 소비합니다. Secure Input 또는 아직 판정되지 않은 필드에서는 원래 key down/repeat/up을 모두 통과시키며, 문자 입력이 없는 modifier-only 한자키는 기존 전역 단축키 동작을 유지합니다.

- **선택 가능한 전환키**
  macOS Caps Lock 입력 소스 전환을 쓰지 않는 경우, 우측 Command 등 원하는 키를 한결 한/영 전환키로 지정할 수 있습니다. Caps Lock 전환이 켜져 있으면 한결 전환키는 자동으로 비활성화됩니다.

- **macOS 입력 소스 표시 사용**
  한결은 macOS 입력 소스 표시 외에 별도의 메뉴 막대 아이콘을 추가하지 않습니다. 입력 문자열이나 문서 내용은 수집하지 않습니다.

- **macOS 설정 연동**
  스페이스 두 번으로 마침표 입력 등은 macOS 텍스트 입력 설정을 따릅니다. 영어 모드는 기본적으로 앱에 그대로 맡기며, 치환이 동작하지 않는 앱에서는 설정의 영어 편의 기능 대체 처리를 명시적으로 켤 수 있습니다.

- **공증된 설치 패키지**
  릴리즈 PKG는 Developer ID 서명, Apple 공증, Gatekeeper 검증을 거쳐 배포합니다.

## 설치

1. [최신 릴리즈](https://github.com/Meapri/Hangyeol/releases/latest)에서 `Hangyeol_Release.pkg`를 다운로드합니다.
2. PKG를 실행해 설치합니다.
3. 설치기가 한결 입력 소스를 현재 사용자에게 추가하고 설정 창을 한 번 엽니다. 처음 설치할 때는 한결을 바로 선택하고, 업데이트할 때는 현재 선택한 입력 소스를 유지합니다.
4. 설치가 끝나면 재시동 없이 한결 내부의 한/영 모드를 사용자 지정 전환키로 전환할 수 있습니다.

한결 앱 번들은 기본적으로 `/Library/Input Methods/Hangyeol.app`에 설치됩니다. 3.0 설치기는 2.x 설정을 한 번 이전하고 기존 앱·입력 소스 등록·설치 영수증을 정리한 뒤, 현재 로그인한 사용자 세션에서 macOS 표준 TIS API로 새 번들을 등록합니다. 이후 3.x 업데이트는 PackageKit의 원자적 교체를 사용합니다. 입력기 관련 시스템 프로세스를 강제 재시작하지 않으며, 다른 입력 소스와 ABC도 자동으로 삭제하지 않습니다.

macOS 보안 정책상 손쉬운 사용 권한은 설치기가 대신 허용할 수 없습니다. 3.0은 새 앱 ID를 사용하므로 2.x에서 올릴 때 한 번 다시 승인해야 합니다. 설치 직후 한결 설정과 macOS 승인 화면을 열어 필요한 단계만 안내하며, 이후 같은 ID와 코드 서명을 사용하는 3.x 업데이트에서는 권한이 유지됩니다.

## 한/영 전환 설정

### Caps Lock으로 전환

macOS 설정에서 `Caps Lock 키로 ABC 입력 소스 전환`을 켜면, Caps Lock 전환은 macOS가 직접 관리합니다.

이 모드에서는 한결 설정의 별도 한/영 전환키가 비활성화됩니다. 전환 경로가 둘로 갈라지지 않도록 macOS 입력 소스 전환을 단일 기준으로 사용합니다.
ABC에서 한결로 돌아오면 다음 비보안 입력에서 한결 내부 모드를 한국어로 맞춥니다. Secure Input 필드에서는 이 정합화를 실행하지 않아 실제 내부 모드와 client 문서를 유지하고, 내부 상태에만 다음 비보안 입력의 예상 모드를 보관합니다.

### 우측 Command 등으로 전환

Caps Lock 입력 소스 전환을 쓰지 않는다면 한결 설정에서 한/영 전환키를 지정할 수 있습니다. 기본값은 우측 Command입니다.

우측 Command 전환이 동작하지 않으면 `시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용`에서 한결 권한을 확인해 주세요. 설치 직후에도 권한이 갱신되지 않았다면 한결 항목을 껐다가 다시 켠 뒤 한결을 다시 여세요.

## 지원 기능

| 영역 | 내용 |
| --- | --- |
| 자판 배열 | 두벌식 표준, 세벌식 390, 두벌식 옛한글, 세벌식 옛한글 |
| 입력 소스 | 한결 단일 입력 소스, 영어는 내부 모드 + ABC/US 또는 현재 영문 레이아웃 pass-through |
| 전환 | macOS Caps Lock 입력 소스 전환 또는 한결 내부 사용자 지정 전환키 |
| 한자 | 한자 후보창, 자모 특수문자 입력 |
| 텍스트 편의 기능 | macOS 설정 연동, 영어 자동 대문자·스마트 문장부호·더블스페이스 대체 처리 선택 가능(기본 꺼짐) |
| 업데이트 | GitHub Releases 기반 자동 업데이트 확인 |

## 요구사항

- macOS 14.0 Sonoma 이상
- Swift 6.2 이상

## 빌드

```bash
# 개발 빌드
swift build

# 릴리즈 PKG 생성, 서명, 공증, Gatekeeper 검증
./build_release.sh
```

## 문제 해결

- **입력 소스가 중복으로 보일 때**
  최신 설치기는 현재 사용자의 한결 stale 항목을 정리하고 TIS API로 현재 번들을 다시 등록합니다. 설치 후에도 중복이 남으면 macOS 입력 소스 설정에서 표시된 항목과 한결 버전을 확인해 이슈에 첨부해 주세요.

- **Caps Lock 전환이 안 될 때**
  macOS 입력 소스 설정에서 Caps Lock 전환 옵션이 켜져 있는지 확인해 주세요. 한결 설정에서 Caps Lock을 직접 전환키로 지정하는 방식은 사용하지 않습니다.

- **우측 Command 전환이 안 될 때**
  손쉬운 사용 권한이 필요합니다. macOS 입력 소스 메뉴에서 `한결 설정...`을 열어 권한 상태를 확인해 주세요. IOKit fallback은 modifier-only 키만 지원하므로 regular key나 조합키가 동작하지 않으면 modifier-only 전환키로 바꾸거나 손쉬운 사용 권한을 복구해야 합니다.

## 문서

- [ARCHITECTURE.md](ARCHITECTURE.md): 내부 구조, 입력 처리 흐름, 주요 모듈
- [Docs/UnifiedInputArchitecture.md](Docs/UnifiedInputArchitecture.md): 현재 한/영 상태·소유권·전환 계약
- [BENCHMARK.md](BENCHMARK.md): 성능 측정 결과
- [CHANGELOG.md](CHANGELOG.md): 버전별 변경 사항

## 라이선스

MIT License
