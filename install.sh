#!/usr/bin/env bash
# 프로젝트에 에이전트 컨텍스트를 세팅한다.
#   사용법: ./install.sh /path/to/project [규칙파일명]
set -euo pipefail

TARGET="${1:-}"
RULES_NAME="${2:-CLAUDE.md}"
SRC="$(cd "$(dirname "$0")" && pwd)"

[ -n "$TARGET" ] || { echo "사용법: $0 /path/to/project [규칙파일명]"; exit 1; }
[ -d "$TARGET" ] || { echo "대상 디렉토리가 없습니다: $TARGET"; exit 1; }

CTX="$TARGET/.agent-context"
mkdir -p "$CTX"
cp -R "$SRC/context-template/." "$CTX/"
mkdir -p "$CTX/scripts"
cp "$SRC/scripts/board.sh" "$CTX/scripts/board.sh"
chmod +x "$CTX/scripts/board.sh"

if [ -e "$TARGET/$RULES_NAME" ]; then
  echo "⚠️  $RULES_NAME 이 이미 있어 덮어쓰지 않았습니다. AGENT.md 를 참고해 직접 병합하세요."
else
  cp "$SRC/AGENT.md" "$TARGET/$RULES_NAME"
  echo "✅ $RULES_NAME 배치 완료 — {{...}} 플레이스홀더를 채우세요."
fi

echo "✅ .agent-context 스캐폴딩 완료: $CTX"
echo
echo "다음 단계"
echo "  1. $RULES_NAME 의 플레이스홀더 채우기"
echo "  2. 커맨드 설치: cp $SRC/commands/*.md ~/.claude/commands/"
echo "  3. 세션 시작 훅에 등록: $CTX/scripts/board.sh hook"
