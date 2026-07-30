#!/usr/bin/env bash
#
# 광명교회 홈페이지 배포 스크립트 (서버에서 실행)
#
# 하는 일:
#   1) git 저장소에서 main 최신 상태를 받아옵니다
#   2) 웹에 공개할 파일만 골라 문서 루트로 복사합니다
#   3) 바뀐 게 있을 때만 로그를 남깁니다
#
# .git 디렉터리나 내부 문서(docs/, tests/, scripts/)는 문서 루트로
# 복사하지 않습니다. 저장소를 그대로 서빙하면 .git 이 통째로 노출되어
# 위험하기 때문에, 저장소와 문서 루트를 분리합니다.
#
# 수동 실행:  sudo /srv/gmchurch/deploy/publish.sh
# 자동 실행:  systemd 타이머가 2시간마다 호출합니다

set -euo pipefail

REPO_DIR="${REPO_DIR:-/srv/gmchurch}"
WEB_ROOT="${WEB_ROOT:-/var/www/gmchurch}"
BRANCH="${BRANCH:-main}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

cd "$REPO_DIR"

# 원격 최신 상태 확인
git fetch --quiet origin "$BRANCH"

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/${BRANCH}")"

if [ "$LOCAL" = "$REMOTE" ] && [ -f "${WEB_ROOT}/index.html" ]; then
  # 변경 없음 — 조용히 종료 (타이머가 자주 도니 로그를 남기지 않습니다)
  exit 0
fi

log "배포 시작: ${LOCAL:0:7} → ${REMOTE:0:7}"

# 로컬에서 손댄 내용이 있어도 원격 기준으로 강제 정렬합니다.
# 서버에서 직접 파일을 고치지 마세요. git 에 커밋한 것만 반영됩니다.
git reset --quiet --hard "origin/${BRANCH}"
git clean --quiet -fd

mkdir -p "$WEB_ROOT"

# 웹에 올릴 것만 동기화합니다.
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude '.vscode/' \
  --exclude '.claude/' \
  --exclude 'node_modules/' \
  --exclude 'deploy/' \
  --exclude 'scripts/' \
  --exclude 'tests/' \
  --exclude 'docs/' \
  --exclude '*.md' \
  --exclude 'package.json' \
  --exclude 'package-lock.json' \
  --exclude '.gitignore' \
  "${REPO_DIR}/" "${WEB_ROOT}/"

chown -R www-data:www-data "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +

log "배포 완료: $(git log -1 --pretty='%h %s')"
