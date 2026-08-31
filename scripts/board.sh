#!/usr/bin/env bash
# board.sh — 멀티세션 관제 칠판(_INFLIGHT.md) 헬퍼
#
# 모드:
#   hook              SessionStart 훅용. clean → 진행중 표시 → 드리프트 점검 → 리마인드.
#                     (칠판 파일이 있는 프로젝트에서만 출력, 그 외엔 조용히 종료)
#   show              진행 중 섹션만 출력
#   clean             7일 지난 [완료] 줄 자동 제거
#   sync              칠판 ↔ tickets/ 드리프트 점검(읽기전용 경고)
#   add "레인" "요약"  진행중 줄 추가 (오늘 날짜)
#   done "키워드"      매칭되는 진행중/대기 줄을 [완료]로 전환 (오늘 날짜)
#
# 칠판 파일이 없으면 조용히 종료(= 이 프레임워크를 쓰지 않는 프로젝트).

set -uo pipefail

# 컨텍스트 경로: AGENT_CTX 환경변수 > 스크립트 위치(.agent-context/scripts/) 기준 자동 해석
if [ -n "${AGENT_CTX:-}" ]; then
  CTX="$AGENT_CTX"
else
  _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CTX="$(dirname "$_self")"
fi
BOARD="$CTX/_INFLIGHT.md"
TICKETS="$CTX/tickets"
MODE="${1:-show}"

[ -f "$BOARD" ] || exit 0

today() { date +%F; }

# ── 진행 중 섹션 출력 (## 진행 중 ~ 다음 ## 헤더 직전) ──────────────
show_progress() {
  awk '
    /^## / { if (seen) exit; if ($0 ~ /진행 중/) { seen=1; print; next } }
    seen { print }
  ' "$BOARD"
}

# ── 7일 지난 [완료] 줄 제거 (줄의 마지막 YYYY-MM-DD 기준, 날짜 없으면 보존) ──
clean_done() {
  local cutoff tmp
  cutoff="$(date -v-7d +%F 2>/dev/null || date -d '7 days ago' +%F 2>/dev/null)"
  [ -z "$cutoff" ] && return 0
  tmp="$(mktemp)"
  awk -v cutoff="$cutoff" '
    function lastdate(s,   d) {
      d=""
      while (match(s, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        d=substr(s, RSTART, RLENGTH); s=substr(s, RSTART+RLENGTH)
      }
      return d
    }
    /^- \[완료\]/ {
      d=lastdate($0)
      if (d != "" && d < cutoff) next   # 오래된 완료줄 drop
    }
    { print }
  ' "$BOARD" > "$tmp" && mv "$tmp" "$BOARD"
}

# ── 드리프트 점검: 활성 티켓인데 칠판 진행중에 없는 것 / 칠판에 종결건 잔존 ──
sync_check() {
  local progress f key kpfx fm status_line closed any=0
  # 활성 줄만 집계 — [완료]로 바뀌었지만 아직 섹션에 남아있는 줄은 제외
  progress="$(show_progress | grep -E '^- \[(진행중|대기)\]')"
  for f in "$TICKETS"/*.md; do
    [ -f "$f" ] || continue
    # key = 'key:' 다음 첫 토큰만 (뒤 주석/설명 무시)
    key="$(awk '/^key:/{print $2; exit}' "$f" | tr -d '"\r')"
    [ -z "$key" ] && continue
    # 칠판 매칭은 키 앞 2세그먼트 프리픽스로 — 칠판 요약에 축약키(SEC-HMAC 등)만 적혀도 매칭 (풀키 grep 오탐 방지)
    kpfx="$(printf '%s' "$key" | cut -d- -f1-2)"
    fm="$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f{print}' "$f")"
    # status/상태/state 값만 모아 인라인 주석(#…) 제거 후 종결 여부 판정
    # 판정은 상태 값의 선두 세그먼트(첫 공백/괄호/대시 전)만 사용 —
    # "진행중 — prd 코드준비완료·대기" 같은 진행 메모 속 '완료'에 오탐하지 않게.
    # (상태/status 줄이 여러 개면 각 줄의 선두 세그먼트를 모두 모아 하나라도 종결이면 종결)
    status_head="$(printf '%s\n' "$fm" | grep -iE '^(status|상태|state):' | sed 's/#.*//' | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]（(—–·].*$//')"
    closed=0
    case "$status_head" in
      *종결*|*종료*|*완료*|*done*|*범위외*|*졸업*|*반증*) closed=1 ;;
    esac
    if [ "$closed" = 0 ]; then
      if ! printf '%s' "$progress" | grep -q -- "$kpfx"; then
        echo "  ⚠️ [$key] 활성 티켓인데 칠판 '진행 중'에 없음"
        any=1
      fi
    else
      if printf '%s' "$progress" | grep -q -- "$kpfx"; then
        echo "  ⚠️ [$key] 칠판 '진행 중'에 있는데 티켓은 종결됨 → 완료 처리 필요"
        any=1
      fi
    fi
  done
  [ "$any" = 0 ] && echo "  ✓ 칠판 ↔ 티켓 일치"
}

# ── 진행중 줄 추가 ──────────────────────────────────────────────
add_line() {
  local lane="${1:-개선}" summary="${2:-}" line tmp
  [ -z "$summary" ] && { echo "사용법: board.sh add \"레인\" \"요약\""; exit 1; }
  line="- [진행중] ($lane) $summary — $(today) / "
  tmp="$(mktemp)"
  awk -v line="$line" '
    { print }
    /^## 진행 중/ && !ins { print line; ins=1 }
  ' "$BOARD" > "$tmp" && mv "$tmp" "$BOARD"
  echo "추가됨: $line"
}

# ── 진행중/대기 줄 → 완료 전환 ──────────────────────────────────
done_line() {
  local kw="${1:-}" tmp t
  [ -z "$kw" ] && { echo "사용법: board.sh done \"키워드\""; exit 1; }
  t="$(today)"
  tmp="$(mktemp)"
  awk -v kw="$kw" -v t="$t" '
    {
      if (!d && $0 ~ /^- \[(진행중|대기)\]/ && index($0, kw) > 0) {
        sub(/^- \[(진행중|대기)\]/, "- [완료]")
        $0 = $0 " ✅" t
        d=1
      }
      print
    }
    END { if (!d) print "  (매칭 줄 없음: " kw ") " > "/dev/stderr" }
  ' "$BOARD" > "$tmp" && mv "$tmp" "$BOARD"
  echo "완료 처리: '$kw' 매칭 줄 → [완료]"
}

# ── SessionStart 훅: 칠판이 있는 프로젝트에서만 출력 ──────────────
hook_mode() {
  # 훅 stdin JSON에서 cwd 추출 (없으면 PWD)
  local input cwd
  input="$(cat 2>/dev/null || true)"
  cwd="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -z "$cwd" ] && cwd="$PWD"
  # 칠판 파일이 없으면 이미 위에서 종료됨. 별도 경로 화이트리스트를 두지 않는다.
  : "${cwd:-}"

  clean_done
  echo "════════════════════════════════════════"
  echo "📋 멀티세션 관제 칠판 (_INFLIGHT.md)"
  echo "════════════════════════════════════════"
  show_progress
  echo ""
  echo "🔄 드리프트 점검 (칠판 ↔ tickets/):"
  sync_check
  echo ""
  echo "📌 이 세션 규칙: 새 작업 받으면 칠판에 자기 줄 추가"
  echo "   → scripts/board.sh add \"VOC|개선|분석\" \"요약\""
  echo "   끝나면 → scripts/board.sh done \"키워드\""
}

case "$MODE" in
  hook)  hook_mode ;;
  show)  show_progress ;;
  clean) clean_done && echo "✓ 7일 지난 완료줄 청소 완료" ;;
  sync)  sync_check ;;
  add)   add_line "${2:-}" "${3:-}" ;;
  done)  done_line "${2:-}" ;;
  *)     echo "모드: hook | show | clean | sync | add | done"; exit 1 ;;
esac
