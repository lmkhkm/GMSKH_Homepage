# 네이버 클라우드 배포 가이드

광명교회 홈페이지를 네이버 클라우드 서버(VM) + nginx 로 운영하는 방법입니다.
GitHub `main` 에 push 하면 서버가 알아서 받아가는 구조입니다.

```
GitHub (lmkhkm/GMSKH_Homepage)
        │  push
        ▼
  [ main 브랜치 ]
        │  서버가 2분마다 git fetch
        ▼
NCP 서버 /srv/gmchurch  ──rsync──▶  /var/www/gmchurch  ──▶  nginx  ──▶  방문자
```

> **왜 GitHub Actions 로 서버에 접속하지 않고 서버가 직접 받아가나요?**
> GitHub Actions 에서 SSH 로 배포하려면 서버의 22번 포트를 인터넷 전체에 열어야
> 합니다. GitHub 이 쓰는 IP 대역은 수천 개인 데다 수시로 바뀌고, 네이버 클라우드
> 방화벽(ACG)은 규칙을 50개까지만 넣을 수 있어서 특정 IP만 허용하는 게 불가능합니다.
> 서버가 스스로 받아가면 22번 포트를 관리자 IP에만 열어두면 되고, GitHub에
> 서버 비밀번호를 보관할 필요도 없습니다.

---

## 0. 준비물

- 네이버 클라우드 계정 (결제 정보 등록 완료)
- 도메인 `gmskh.or.kr` 의 DNS 관리 권한 (도메인 산 곳의 관리 페이지)
- SSH 접속 프로그램 — Windows 라면 기본 `터미널` 이나 PuTTY

사이트의 대표 주소는 **`https://gmskh.or.kr`** (www 없는 쪽) 입니다.
`canonical` · `og:url` · `sitemap.xml` 이 모두 이 주소로 맞춰져 있고,
`www.gmskh.or.kr` 로 들어오면 nginx 가 이쪽으로 넘겨줍니다.

---

## 1. 네트워크 만들기 (VPC · Subnet)

서버를 만들려면 VPC 와 Subnet 이 먼저 있어야 합니다.

1. 콘솔 → **Services → Networking → VPC** → `VPC 생성`
   - 이름: `gmchurch-vpc`
   - IP 주소 범위: `10.0.0.0/16`
2. **Subnet Management** → `Subnet 생성`
   - 이름: `gmchurch-subnet`
   - IP 범위: `10.0.1.0/24`
   - **Internet Gateway 전용 여부: `Y (Public)`** ← 반드시 Public
   - 용도: `일반`

> ⚠️ Private Subnet 에 서버를 만들면 공인 IP를 붙일 수 없습니다. 이걸 놓치면
> 서버를 지우고 다시 만들어야 합니다.

---

## 2. 서버 만들기

**Services → Compute → Server** → `서버 생성`

| 단계 | 선택 |
|---|---|
| 서버 이미지 | `Ubuntu 24.04` (최신 서버이미지 탭) |
| 서버 타입 | **Micro** — 신규 가입 후 1년 무료 |
| VPC / Subnet | 위에서 만든 `gmchurch-vpc` / `gmchurch-subnet` |
| 요금제 | **시간 요금제** (월 요금제는 서버를 정지해도 과금됩니다) |
| 호스트명 | `gmchurch-web` |
| 스토리지 | 기본값 |
| 인증키 | `새로운 인증키 생성` → 이름 입력 → **.pem 파일 다운로드** |
| ACG | 기본 ACG 그대로 (다음 단계에서 포트를 엽니다) |

> **`.pem` 파일은 반드시 안전한 곳에 보관하세요.** 네이버 클라우드는 이 파일로
> 서버 관리자 비밀번호를 복호화합니다. 잃어버리면 서버에 못 들어갑니다.

정적 사이트라 Micro(1 vCPU / 1GB) 로 충분합니다. 생성에 몇 분에서 십여 분 걸립니다.

---

## 3. 공인 IP 붙이기

**Server → Public IP** → `공인 IP 신청` → 방금 만든 서버 선택 → `생성`

발급된 IP를 적어두세요. 이게 도메인이 가리킬 주소입니다.

> 💸 공인 IP는 **서버에 붙어 있지 않아도 보유하는 동안 계속 과금**됩니다.
> 나중에 서버를 정리할 때 공인 IP도 같이 반납해야 요금이 멈춥니다.

---

## 4. 방화벽 열기 (ACG)

네이버 클라우드 기본 ACG는 **들어오는 연결을 전부 막습니다.** nginx를 설치해도
포트를 안 열면 사이트가 안 뜹니다.

**Server → ACG** → 서버에 붙은 ACG 선택 → `ACG 설정` → 아래 세 줄 추가 → `적용`

| 프로토콜 | 접근 소스 | 허용 포트 | 용도 |
|---|---|---|---|
| TCP | `0.0.0.0/0` | `80` | HTTP |
| TCP | `0.0.0.0/0` | `443` | HTTPS |
| TCP | `내 사무실/집 IP/32` | `22` | SSH 관리 |

> 22번은 가능하면 본인 IP만 여세요. 집 IP가 자주 바뀌어서 곤란하면 `0.0.0.0/0`
> 으로 열되, 서버 세팅 후 **비밀번호 로그인을 끄고 공개키만 쓰도록** 바꾸는 걸
> 권합니다. (아래 9번 참고)

---

## 5. 서버 접속

1. **Server → 서버 선택 → `서버 관리 및 설정 변경` → `관리자 비밀번호 확인`**
2. 아까 받은 `.pem` 파일을 끌어다 놓으면 비밀번호가 나옵니다. 복사해 두세요.
3. 터미널에서 접속:

```bash
ssh root@<공인IP>
# 비밀번호를 물어보면 위에서 복사한 값을 붙여넣기
```

> `root` 로 안 되면 `ubuntu@<공인IP>` 로 시도해 보세요. 이미지에 따라 다를 수 있습니다.

---

## 6. 세팅 스크립트 실행 (여기가 핵심)

서버에 접속한 상태에서 아래를 그대로 붙여넣으세요.
도메인과 이메일만 본인 것으로 바꾸면 됩니다.

```bash
curl -fsSL https://raw.githubusercontent.com/lmkhkm/GMSKH_Homepage/main/deploy/setup-server.sh -o setup-server.sh
chmod +x setup-server.sh
./setup-server.sh gmskh.or.kr admin@gmskh.or.kr
```

스크립트가 알아서 하는 일:

1. nginx · git · rsync · certbot 설치
2. 저장소를 `/srv/gmchurch` 에 clone
3. nginx 설정 배치 (도메인 자동 치환)
4. 웹에 공개할 파일만 골라 `/var/www/gmchurch` 로 복사
5. **2분마다 git 을 확인해서 자동 배포하는 systemd 타이머 등록**
6. 도메인이 이미 서버를 가리키고 있으면 HTTPS 인증서까지 자동 발급

여러 번 실행해도 안전합니다.

---

## 7. 도메인 연결

도메인을 산 곳(가비아·후이즈 등)의 DNS 관리에서 레코드를 추가합니다.
**네이버 클라우드 Global DNS를 꼭 쓸 필요는 없습니다.**

| 타입 | 호스트 | 값 |
|---|---|---|
| A | `@` | `<공인 IP>` |
| A | `www` | `<공인 IP>` |

`www` 도 같이 걸어두세요. 인증서가 두 주소 모두에 발급되고,
`www.gmskh.or.kr` 로 들어온 방문자는 nginx 가 `gmskh.or.kr` 로 301 넘겨줍니다.

전파에 보통 10분~1시간, 길면 하루가 걸립니다. 확인:

```bash
dig +short gmskh.or.kr
```

공인 IP가 나오면 완료입니다.

---

## 8. HTTPS 켜기

6번에서 도메인이 아직 연결 전이라 인증서가 건너뛰어졌다면, DNS 전파 후 서버에서:

```bash
certbot --nginx -d gmskh.or.kr -d www.gmskh.or.kr
```

이메일 입력하고 약관에 동의하면 끝입니다. **갱신은 certbot 이 자동으로** 합니다
(90일마다, 시스템 타이머로 자동 실행). 확인:

```bash
systemctl status certbot.timer
certbot renew --dry-run
```

---

## 9. 마무리 보안 (권장)

22번 포트를 전체 공개했다면 공개키 로그인으로 바꾸세요.

```bash
# 내 PC에서 (한 번만)
ssh-copy-id root@<공인IP>

# 서버에서
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

> ⚠️ 공개키 접속이 되는 걸 **먼저 확인한 뒤에** 비밀번호 로그인을 끄세요.
> 순서를 바꾸면 서버에 못 들어갑니다.

---

## 10. 평소 운영

### 사이트 고치기

지금까지 하던 것과 똑같습니다. `data.js` 를 고쳐서 `main` 에 push 하면
2분 안에 사이트에 반영됩니다.

### 바로 반영하고 싶을 때

```bash
/srv/gmchurch/deploy/publish.sh
```

### 배포가 잘 됐는지 보기

```bash
journalctl -u gmchurch-publish.service -n 30    # 배포 기록
systemctl status gmchurch-publish.timer          # 타이머 동작 여부
tail -f /var/log/nginx/gmchurch.error.log        # nginx 오류
```

### 주보 올리기

기존과 동일합니다. `bulletins/` 에 `YYYYMMDD_1.jpg` 형식으로 push 하면
GitHub Actions 가 `data.js` 를 갱신하고, 서버가 그걸 받아갑니다.

> ⚠️ **서버에서 직접 파일을 고치지 마세요.** `publish.sh` 가 `git reset --hard` 로
> 원격 기준으로 되돌리기 때문에 서버에서 한 수정은 다음 배포 때 사라집니다.
> 모든 수정은 git 을 통해서 하세요.

---

## 11. 문제 해결

| 증상 | 확인할 것 |
|---|---|
| 사이트가 안 열림 | ACG 에 80·443 이 열려 있는지 |
| SSH 접속이 안 됨 | ACG 22번 규칙의 접근 소스가 현재 내 IP 인지 |
| 도메인은 안 되는데 IP로는 열림 | DNS A 레코드 · `dig +short 도메인` |
| certbot 실패 | 80번 포트가 열려 있고 도메인이 이미 서버를 가리키는지 |
| push 했는데 반영이 안 됨 | `journalctl -u gmchurch-publish.service -n 30` |
| nginx 가 안 켜짐 | `nginx -t` 로 설정 문법 확인 |
| 수정한 CSS가 그대로 | 브라우저 강력 새로고침 (Ctrl+Shift+R) |

---

## 12. 비용

| 항목 | 비용 |
|---|---|
| Micro 서버 | **신규 가입 후 1년 무료** (계정당 1대) |
| VPC · Subnet · ACG | 무료 |
| 공인 IP | 시간당 과금 — 월 4천원 안팎으로 알려져 있음 |
| 블록 스토리지 SSD | 0.16원 / GB / 시간 |

정확한 금액은 [네이버 클라우드 요금 계산기](https://www.ncloud.com/charge/calc)에서
확인하세요. 홈페이지 트래픽 자체는 미미해서 사실상 공인 IP 비용이 전부입니다.

> ⏰ **Micro 무료 기간은 1년입니다.** 1년 뒤 자동으로 유료 전환되니 달력에
> 표시해 두세요. Micro는 "체험용으로 가용성·성능 보장 불가" 등급이라, 방문이
> 늘면 한 단계 위로 올리는 걸 고려하세요.

---

## 13. GitHub Pages 정리

새 도메인이 잘 뜨는 걸 확인한 뒤에 정리하세요.

1. 검색 반영을 위해 **Google Search Console** 에 새 도메인 속성을 등록하고
   `sitemap.xml` 을 제출
2. 기존 `frpsy.github.io/gmchurch_web` 주소는 당분간 그대로 두는 편이 안전합니다
   (기존 링크·검색결과가 죽지 않도록)
3. 완전히 옮기려면 저장소 Settings → Pages 에서 배포를 끄면 됩니다

---

## 부록: 파일 구조

```
deploy/
├── setup-server.sh            서버 최초 세팅 (한 번만 실행)
├── publish.sh                 git → 문서 루트 반영 (타이머가 호출)
├── nginx-gmchurch.conf        nginx 사이트 설정
├── gmchurch-publish.service   systemd 서비스
└── gmchurch-publish.timer     systemd 타이머 (2분 간격)

scripts/
└── set-site-url.js            사이트 절대주소 일괄 변경
```

### 도메인이 또 바뀌면

```bash
node scripts/set-site-url.js https://새도메인 --from https://옛도메인
```

`canonical` · `og:url` · `sitemap.xml` · `robots.txt` 를 한 번에 바꿔줍니다.
