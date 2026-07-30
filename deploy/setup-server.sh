#!/usr/bin/env bash
#
# 광명교회 홈페이지 — 네이버 클라우드 서버 최초 세팅 스크립트 (Ubuntu)
#
# 새로 만든 NCP 서버에 root 로 접속해서 한 번만 실행하면
# nginx 설치 · 저장소 clone · 자동 배포 타이머 등록까지 끝납니다.
#
# 사용법:
#   wget https://raw.githubusercontent.com/lmkhkm/GMSKH_Homepage/main/deploy/setup-server.sh
#   chmod +x setup-server.sh
#   ./setup-server.sh gmskh.or.kr you@example.com
#
#   1번째 인자: 도메인 (www 없이)
#   2번째 인자: Let's Encrypt 알림 받을 이메일 (선택, 있으면 HTTPS 자동 설정 시도)
#
# 여러 번 실행해도 안전합니다.

set -euo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"
REPO_URL="${REPO_URL:-https://github.com/lmkhkm/GMSKH_Homepage.git}"
REPO_DIR="/srv/gmchurch"
WEB_ROOT="/var/www/gmchurch"
BRANCH="${BRANCH:-main}"

die() { printf '\n오류: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m▶ %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "root 로 실행해 주세요. (sudo ./setup-server.sh ...)"
[ -n "$DOMAIN" ] || die "도메인을 인자로 넣어 주세요.  예) ./setup-server.sh gmskh.or.kr admin@gmskh.or.kr"

# 도메인 형식 최소 검증 (http:// 를 붙여 넣는 실수를 잡습니다)
case "$DOMAIN" in
  http://*|https://*|*/*) die "도메인만 넣어 주세요. https:// 나 / 는 빼야 합니다." ;;
esac

step "1/7  패키지 설치"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# 네이버 클라우드 서버에는 IPv6 가 없는 경우가 많습니다.
# 그런데 우분투 nginx 패키지의 기본 사이트 설정에 listen [::]:80 이 들어 있어서
# 설치 도중 nginx 기동이 실패하고 패키지가 '설정 안 됨' 상태로 남습니다.
#   nginx: [emerg] socket() [::]:80 failed (97: Address family not supported by protocol)
# 그래서 설치 실패를 일단 넘긴 뒤, 기본 사이트를 걷어내고 설정을 마무리합니다.
apt-get install -y -qq nginx git rsync curl dnsutils certbot python3-certbot-nginx \
  || echo "  패키지 설정이 중단됐습니다. 아래에서 이어서 처리합니다."

# 우분투 기본 사이트는 쓰지 않습니다. IPv6 리스닝 줄도 주석 처리해 둡니다.
rm -f /etc/nginx/sites-enabled/default
if [ -f /etc/nginx/sites-available/default ]; then
  sed -i 's/^\([[:space:]]*\)listen \[::\]:80/\1# listen [::]:80/' \
    /etc/nginx/sites-available/default
fi

# 중단된 패키지 설정을 마무리합니다
dpkg --configure -a >/dev/null 2>&1 || true
apt-get install -y -qq -f >/dev/null 2>&1 || true

# 필요한 것들이 실제로 갖춰졌는지 확인
for cmd in nginx git rsync certbot; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "${cmd} 설치에 실패했습니다. 'apt-get install -f' 실행 후 다시 시도해 주세요."
done

step "2/7  저장소 준비 ($REPO_DIR)"
if [ -d "$REPO_DIR/.git" ]; then
  echo "이미 있습니다. 최신 상태로 갱신합니다."
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
  git -C "$REPO_DIR" reset --quiet --hard "origin/${BRANCH}"
else
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi
git config --global --add safe.directory "$REPO_DIR"
chmod +x "$REPO_DIR"/deploy/*.sh

step "3/7  nginx 설정"
mkdir -p "$WEB_ROOT"
sed "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" \
  "$REPO_DIR/deploy/nginx-gmchurch.conf" > /etc/nginx/sites-available/gmchurch
ln -sfn /etc/nginx/sites-available/gmchurch /etc/nginx/sites-enabled/gmchurch
rm -f /etc/nginx/sites-enabled/default

step "4/7  첫 배포"
bash "$REPO_DIR/deploy/publish.sh"

step "5/7  nginx 재시작"
nginx -t
# 설치 중 기동에 실패해 멈춰 있을 수 있으므로 reload 가 아니라 restart 로 올립니다
systemctl reload-or-restart nginx
systemctl enable --quiet nginx

step "6/7  자동 배포 타이머 등록 (2시간마다 git 확인)"
cp "$REPO_DIR/deploy/gmchurch-publish.service" /etc/systemd/system/
cp "$REPO_DIR/deploy/gmchurch-publish.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now gmchurch-publish.timer

step "7/7  HTTPS 인증서"
SERVER_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null || echo '')"
DOMAIN_IP="$(dig +short "$DOMAIN" A | tail -n1)"

if [ -z "$EMAIL" ]; then
  echo "이메일을 안 넣으셔서 건너뜁니다. 도메인 연결 후 아래 명령을 실행하세요:"
  echo "  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}"
elif [ -n "$SERVER_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
  echo "도메인이 아직 이 서버를 가리키지 않습니다."
  echo "  ${DOMAIN} → ${DOMAIN_IP:-응답없음}   이 서버 → ${SERVER_IP}"
  echo "DNS A 레코드를 ${SERVER_IP} 로 설정하고 전파된 뒤 아래를 실행하세요:"
  echo "  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} -m ${EMAIL} --agree-tos"
else
  certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" \
    -m "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive \
    || echo "인증서 발급에 실패했습니다. DNS 전파를 기다린 뒤 위 명령을 다시 실행해 보세요."
fi

cat <<EOF

────────────────────────────────────────
세팅 완료

  저장소     ${REPO_DIR}
  문서 루트  ${WEB_ROOT}
  서버 IP    ${SERVER_IP:-확인 실패}
  자동 배포  2시간마다 (systemctl status gmchurch-publish.timer)

앞으로는 GitHub main 에 push 하면 최대 2시간 안에 반영됩니다.
바로 반영하고 싶으면:  ${REPO_DIR}/deploy/publish.sh

배포 로그 보기:  journalctl -u gmchurch-publish.service -n 50
────────────────────────────────────────
EOF
