# test-inner.sh : datadog-agent7 설치 → 실행 → 업데이트 → 삭제 검사 (6~9단계)
#   test-rpm.sh 가 공통 부분(검사 함수, 저장소 설정 2~5단계) 뒤에 붙여 컨테이너에서 실행한다.
#   사용 가능: run, check, log / OLD_VER, NEW_VER, REPO_ID, REL, PKG
#
# - 벤더 installer 는 systemd 가 있을 때만 서비스 유닛을 만든다. 컨테이너에는 systemd 가
#   돌고 있지 않으므로 systemd 패키지와 /run/systemd/system 으로 운영 서버처럼 보이게 한다.
# - 출력이 긴 명령은 파일로 받은 뒤 검사 (pipefail 에서 grep -q 가 먼저 끝나면 SIGPIPE 로 실패 처리됨)
# - 에이전트는 가짜 api_key 로 직접 실행하고, 전송 주소는 로컬의 닫힌 포트로 돌려
#   Datadog 으로 아무것도 보내지 않는다.

CONF=/etc/datadog-agent/datadog.yaml
AGENT=/opt/datadog-agent/bin/agent/agent
AGENT_PID=""

start_agent() {
  rm -f /etc/datadog-agent/auth_token
  runuser -u dd-agent -- $AGENT run >/tmp/agent.log 2>&1 &
  AGENT_PID=$!
  for _ in $(seq 1 90); do
    runuser -u dd-agent -- $AGENT status >/dev/null 2>&1 && return 0
    kill -0 "$AGENT_PID" 2>/dev/null || break
    sleep 1
  done
  echo "    에이전트 기동 실패:"; tail -20 /tmp/agent.log | sed 's/^/      /'
  return 1
}
stop_agent() {
  run "runuser -u dd-agent -- $AGENT stop >/dev/null"
  [ -n "$AGENT_PID" ] && wait "$AGENT_PID" 2>/dev/null; AGENT_PID=""
}

log "검사 준비: systemd 가 있는 서버처럼 구성"
run "dnf -y -q install systemd >/dev/null"
mkdir -p /run/systemd/system

# ---------- 6) 이전 버전 설치 ----------
log "6) 특정 버전 설치: datadog-agent-$OLD_VER"
run "yum install -y --best datadog-agent-$OLD_VER 2>&1 | grep -vE 'Failed to connect to bus' | tail -12"
run "yum list installed datadog-agent 2>/dev/null | grep -E '^datadog-agent\.' | sed 's/^/    /'"
check "설치 버전 $OLD_VER"                 "rpm -q --qf '%{VERSION}' datadog-agent | grep -qx '$OLD_VER'"
check "설치 Release $REL"                  "rpm -q --qf '%{RELEASE}' datadog-agent | grep -q '^$REL\.'"
check "설치 저장소 @$REPO_ID"              "yum list installed datadog-agent 2>/dev/null | grep -q '@$REPO_ID'"
check "Epoch 2 (공식 패키지 Epoch 1 보다 우선)" "rpm -q --qf '%{EPOCH}' datadog-agent | grep -qx 2"
check "agent 바이너리"                     "[ -x $AGENT ]"
check "agent version = $OLD_VER"           "$AGENT version | grep -q 'Agent $OLD_VER '"
check "datadog-agent 명령이 PATH 에 있음"  "command -v datadog-agent"
check "파일 권한이 공식 RPM 과 동일 (rpm -V)" "! rpm -V --nomtime --nouser --nogroup datadog-agent | grep -E '^.M'"
check "dd-agent 계정 생성됨 (벤더 installer)" "id dd-agent"
check "systemd 유닛 설치됨 (벤더 installer)" \
  "[ -f /etc/systemd/system/datadog-agent.service ] || [ -f /usr/lib/systemd/system/datadog-agent.service ]"
check "설정 예제만 있고 datadog.yaml 은 없음 (API 키 미포함)" \
  "[ -f /etc/datadog-agent/datadog.yaml.example ] && [ ! -e $CONF ]"
check "agent 라이브러리 누락 없음 (ldd)"   "! ldd $AGENT | grep -q 'not found'"

# ---------- 7) 실행 확인 (가짜 api_key, 외부 전송 없음) ----------
log "7) 실행 확인 ($OLD_VER)"
cat > $CONF <<'EOF'
api_key: 00000000000000000000000000000000
hostname: pkgtest
# 검사용: 전송 주소를 로컬의 닫힌 포트로 (Datadog 으로 보내지 않음)
dd_url: http://127.0.0.1:9
remote_configuration:
  enabled: false
logs_enabled: false
apm_config:
  enabled: false
process_config:
  process_collection:
    enabled: false
# test-marker: 운영자가 작성한 설정
EOF
chown dd-agent:dd-agent $CONF; chmod 640 $CONF
if start_agent; then
  check "에이전트 실행 (agent status)"     "runuser -u dd-agent -- $AGENT status >/tmp/status.out 2>&1; grep -q 'Agent (v$OLD_VER)' /tmp/status.out"
  check "기본 점검 실행 (agent check uptime)" \
    "runuser -u dd-agent -- $AGENT check uptime >/tmp/check.out 2>&1; grep -q 'system.uptime' /tmp/check.out"
  stop_agent
else
  FAIL=$((FAIL+1)); FAILED+=("에이전트 실행 ($OLD_VER)")
fi

# ---------- 8) 업데이트 ----------
log "8) 업데이트: yum update datadog-agent"
run "yum check-update datadog-agent; [ \$? -eq 100 ]"
run "yum update -y --best datadog-agent 2>&1 | grep -vE 'Failed to connect to bus' | tail -12"   # --best: 의존성 문제로 건너뛰지 않고 실패로 처리
run "yum list installed datadog-agent 2>/dev/null | grep -E '^datadog-agent\.' | sed 's/^/    /'"
check "설치 버전 $NEW_VER"                 "rpm -q --qf '%{VERSION}' datadog-agent | grep -qx '$NEW_VER'"
check "패키지가 하나만 설치됨"             "[ \$(rpm -q datadog-agent | wc -l) -eq 1 ]"
check "agent version = $NEW_VER"           "$AGENT version | grep -q 'Agent $NEW_VER '"
check "datadog.yaml 보존됨"                "grep -q 'test-marker' $CONF"
check "systemd 유닛 유지"                  "[ -f /etc/systemd/system/datadog-agent.service ] || [ -f /usr/lib/systemd/system/datadog-agent.service ]"
if start_agent; then
  check "에이전트 실행 (agent status)"     "runuser -u dd-agent -- $AGENT status >/tmp/status.out 2>&1; grep -q 'Agent (v$NEW_VER)' /tmp/status.out"
  check "기본 점검 실행 (agent check uptime)" \
    "runuser -u dd-agent -- $AGENT check uptime >/tmp/check.out 2>&1; grep -q 'system.uptime' /tmp/check.out"
  stop_agent
else
  FAIL=$((FAIL+1)); FAILED+=("에이전트 실행 ($NEW_VER)")
fi

# ---------- 9) 삭제 ----------
log "9) 삭제: yum remove datadog-agent"
run "yum remove -y datadog-agent 2>&1 | grep -vE 'Failed to connect to bus' | tail -5"
check "패키지 삭제됨"                      "! rpm -q datadog-agent"
check "/opt/datadog-agent 삭제됨"          "[ ! -e $AGENT ]"
check "systemd 유닛 삭제됨 (벤더 installer)" \
  "[ ! -f /etc/systemd/system/datadog-agent.service ] && [ ! -f /usr/lib/systemd/system/datadog-agent.service ]"
check "datadog.yaml 보존됨 (패키지 파일 아님)" "grep -q 'test-marker' $CONF"
