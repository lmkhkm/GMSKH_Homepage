#!/usr/bin/env bash
#
# 광명교회 홈페이지 배포 스크립트 (서버에서 실행)
#
# 하는 일:
#   1) git 저장소에서 main 최신 상태를 받아옵니다
#   2) 웹에 공개할 파일만 골라 문서 루트로 복사합니다
#   3) 바뀐 게 있을 때만 로그를 남깁니다
#   4) 저장소의 타이머·서비스 설정이 서버와 다르면 서버에 새로 설치합니다
#
# .git 디렉터리나 내부 문서(docs/, tests/, scripts/)는 문서 루트로
# 복사하지 않습니다. 저장소를 그대로 서빙하면 .git 이 통째로 노출되어
# 위험하기 때문에, 저장소와 문서 루트를 분리합니다.
#
# 수동 실행:  sudo /srv/gmchurch/deploy/publish.sh
# 자동 실행:  systemd 타이머가 2시간마다, 주일 10:00~11:10에는 10분마다 호출합니다

set -euo pipefail

REPO_DIR="${REPO_DIR:-/srv/gmchurch}"
WEB_ROOT="${WEB_ROOT:-/var/www/gmchurch}"
BRANCH="${BRANCH:-main}"

# 마지막으로 '실제 복사까지 성공한' 커밋을 적어둡니다.
# git HEAD 만 보고 판단하면, 복사가 중간에 실패했거나 문서 루트가 망가져도
# "이미 배포됨"으로 넘겨버립니다. 복사가 끝난 뒤에만 이 파일을 갱신해서
# 실패한 배포는 다음 차례에 반드시 다시 시도되게 합니다.
STATE_FILE="${STATE_FILE:-/var/lib/gmchurch/deployed-commit}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# 타이머 주기를 바꿔도 서버에 접속하지 않고 git 만으로 반영되게 합니다.
# 잘못된 설정이 깔려 타이머가 멈추면 다시는 원격으로 고칠 수 없으므로
# 설치 전에 검사하고, 설치 뒤 타이머가 살아 있지 않으면 이전 설정으로 되돌립니다.
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
UNITS=(gmchurch-publish.service gmchurch-publish.timer)

sync_units() {
  # 최초 설치는 setup-server.sh 가 맡습니다. 여기서는 이미 깔린 것만 갱신합니다.
  [ "$(id -u)" -eq 0 ] || return 0
  [ -f "${UNIT_DIR}/gmchurch-publish.timer" ] || return 0

  local u changed=0
  for u in "${UNITS[@]}"; do
    cmp -s "${REPO_DIR}/deploy/${u}" "${UNIT_DIR}/${u}" || changed=1
  done
  [ "$changed" -eq 1 ] || return 0

  local check backup out
  check="$(mktemp -d)"
  backup="$(mktemp -d)"
  for u in "${UNITS[@]}"; do
    cp "${REPO_DIR}/deploy/${u}" "${check}/"
    cp "${UNIT_DIR}/${u}" "${backup}/" 2>/dev/null || true
  done

  # 우리 설정에 대한 경고가 한 줄이라도 나오면 설치하지 않습니다
  # (systemd 는 잘못된 줄을 경고만 하고 건너뛰기 때문)
  if ! out="$(systemd-analyze verify "${check}/gmchurch-publish.timer" 2>&1)" \
     || grep -q 'gmchurch-publish' <<<"$out"; then
    log "타이머 설정 검사 실패 — 서버 설정은 그대로 둡니다: ${out}"
    rm -rf "$check" "$backup"
    return 0
  fi

  cp "${check}/"* "${UNIT_DIR}/"
  systemctl daemon-reload
  systemctl restart gmchurch-publish.timer || true

  if systemctl is-active --quiet gmchurch-publish.timer; then
    log "타이머·서비스 설정 갱신: $(systemctl show -p NextElapseUSecRealtime --value gmchurch-publish.timer)"
  else
    cp "${backup}/"* "${UNIT_DIR}/"
    systemctl daemon-reload
    systemctl restart gmchurch-publish.timer || true
    log "새 타이머가 동작하지 않아 이전 설정으로 되돌렸습니다"
  fi
  rm -rf "$check" "$backup"
}

cd "$REPO_DIR"

# 원격 최신 상태 확인
git fetch --quiet origin "$BRANCH"

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/${BRANCH}")"
DEPLOYED="$(cat "$STATE_FILE" 2>/dev/null || true)"

if [ "$REMOTE" = "$DEPLOYED" ] && [ -s "${WEB_ROOT}/index.html" ]; then
  # 변경 없음 — 조용히 종료 (로그를 남기지 않습니다)
  # 직전 배포에서 받은 타이머 설정은 이 차례에 설치됩니다
  # (그때 돌던 publish.sh 는 갱신 전 판이라 설치 단계가 없을 수 있음)
  sync_units
  exit 0
fi

log "배포 시작: ${LOCAL:0:7} → ${REMOTE:0:7}"

# 로컬에서 손댄 내용이 있어도 원격 기준으로 강제 정렬합니다.
# 서버에서 직접 파일을 고치지 마세요. git 에 커밋한 것만 반영됩니다.
git reset --quiet --hard "origin/${BRANCH}"
git clean --quiet -fd

mkdir -p "$WEB_ROOT"

# 성가집 스캔은 순서지가 쓰는 쪽만 웹에 올립니다. 비공개 목록은 개발 저장소의
# scripts/hymnal-web-exclude.js 가 만들고, 목록 파일이 없으면 평소처럼 동작합니다.
HYMNAL_EXCLUDE="${REPO_DIR}/scripts/hymnal-web-exclude.txt"
RSYNC_EXTRA=()
if [ -f "$HYMNAL_EXCLUDE" ]; then
  RSYNC_EXTRA+=(--exclude-from="$HYMNAL_EXCLUDE")
fi

# 웹에 올릴 것만 동기화합니다.
rsync -a --delete \
  ${RSYNC_EXTRA[@]+"${RSYNC_EXTRA[@]}"} \
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

# 제외 목록은 이미 올라간 파일을 지워 주지 않으므로(rsync 규칙) 따로 지웁니다.
if [ -f "$HYMNAL_EXCLUDE" ] && [ -n "$WEB_ROOT" ]; then
  while IFS= read -r p; do
    case "$p" in
      /data/hymnal-2015/*) rm -rf -- "${WEB_ROOT}${p%/}" ;;
    esac
  done < "$HYMNAL_EXCLUDE"
fi

chown -R www-data:www-data "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +

# 여기까지 왔으면 복사가 끝난 것이므로 기록을 갱신합니다.
mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' "$REMOTE" > "$STATE_FILE"

log "배포 완료: $(git log -1 --pretty='%h %s')  파일 $(find "$WEB_ROOT" -type f | wc -l)개"

sync_units
