#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  ⏱️  Detection Delay Benchmark v2
#  Measures wall-clock time from attack → alert in Wazuh
#  Run from: Kali VM (192.168.100.30)
# ══════════════════════════════════════════════════════════════

TARGET="http://192.168.100.20:8080"
INDEXER="https://192.168.100.10:9200"
INDEXER_AUTH="admin:SecretPassword"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ⏱️  End-to-End Detection Delay Benchmark v2            ║"
echo "║  Kali (attack) → Wazuh SIEM (alert)                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Count alerts for a given rule ──────────────────────────
count_alerts() {
    local rule_id="$1"
    local result=$(curl -sk -u ${INDEXER_AUTH} -X POST "${INDEXER}/wazuh-alerts-4.x-*/_count" \
        -H "Content-Type: application/json" \
        -d "{\"query\":{\"match\":{\"rule.id\":\"${rule_id}\"}}}" 2>/dev/null)
    echo "$result" | jq -r '.count // 0' 2>/dev/null
}

# ── Run a single benchmark test ────────────────────────────
run_test() {
    local test_name="$1"
    local rule_id="$2"
    local level="$3"
    local attack_cmd="$4"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${test_name} → Rule ${rule_id} (Level ${level})${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Count alerts BEFORE attack
    local before=$(count_alerts "$rule_id")
    echo -e "${YELLOW}[$(date +%H:%M:%S)] Alerts before: ${before}${NC}"

    # Execute the attack
    echo -e "${YELLOW}[$(date +%H:%M:%S)] Executing attack...${NC}"
    local start_time=$(date +%s)
    eval "$attack_cmd"

    # Poll until alert count increases (max 3 minutes)
    echo -e "${YELLOW}[$(date +%H:%M:%S)] Waiting for alert in Wazuh...${NC}"
    local elapsed=0
    local max_wait=180

    while [ $elapsed -lt $max_wait ]; do
        local current=$(count_alerts "$rule_id")
        if [ "$current" -gt "$before" ]; then
            local end_time=$(date +%s)
            local delay=$((end_time - start_time))
            echo -e "${GREEN}[$(date +%H:%M:%S)] ✓ Alert detected! Count: ${before} → ${current}${NC}"
            echo -e "${GREEN}${BOLD}[$(date +%H:%M:%S)] ⏱️  Delay: ${delay} seconds${NC}"
            echo "${test_name}|${rule_id}|${level}|${delay}" >> /tmp/benchmark_results.txt
            echo ""
            return
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "\r${YELLOW}  ⏳ Polling... ${elapsed}s elapsed (checking every 5s)${NC}    "
    done

    echo ""
    echo -e "${RED}[✗] TIMEOUT — alert not detected in ${max_wait}s${NC}"
    echo "${test_name}|${rule_id}|${level}|TIMEOUT" >> /tmp/benchmark_results.txt
    echo ""
}

# ── Get auth token ─────────────────────────────────────────
echo -e "${YELLOW}[*] Authenticating...${NC}"
TOKEN=$(curl -s -X POST ${TARGET}/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin123"}' | jq -r '.token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    echo -e "${RED}[✗] Login failed! Is the target running?${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Token obtained${NC}"
echo ""

# Clear previous results
> /tmp/benchmark_results.txt

# ══════════════════════════════════════════════════════════
#  RUN TESTS
# ══════════════════════════════════════════════════════════

run_test "TEST 1: Failed Login" "100121" "6" \
    "curl -s -X POST ${TARGET}/api/auth/login -H 'Content-Type: application/json' -d '{\"username\":\"hacker\",\"password\":\"wrong\"}' > /dev/null"

run_test "TEST 2: SSRF (Low)" "100111" "8" \
    "curl -s '${TARGET}/api/payments/verify-gateway?endpoint=http://localhost:8080/health' -H 'Authorization: Bearer ${TOKEN}' > /dev/null"

run_test "TEST 3: SSRF → IMDS (Critical)" "100110" "15" \
    "curl -s '${TARGET}/api/payments/verify-gateway?endpoint=http://imds/latest/meta-data/iam/security-credentials/banking-api-role' -H 'Authorization: Bearer ${TOKEN}' > /dev/null"

# ══════════════════════════════════════════════════════════
#  RESULTS SUMMARY
# ══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  📊 Detection Delay Results                             ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo -e "${NC}"

printf "  ${BOLD}%-28s │ %-6s │ %-5s │ %-10s${NC}\n" "Attack" "Rule" "Level" "Delay"
echo "  ────────────────────────────┼────────┼───────┼───────────"

total=0
count=0

while IFS='|' read -r name rule level delay; do
    if [ "$delay" = "TIMEOUT" ]; then
        color="${RED}"
        display="TIMEOUT"
    else
        count=$((count + 1))
        total=$((total + delay))
        if [ "$delay" -lt 30 ]; then color="${GREEN}"
        elif [ "$delay" -lt 60 ]; then color="${YELLOW}"
        else color="${RED}"; fi
        display="${delay}s"
    fi
    printf "  %-28s │ %-6s │ %-5s │ ${color}%-10s${NC}\n" "$name" "$rule" "$level" "$display"
done < /tmp/benchmark_results.txt

echo ""
if [ $count -gt 0 ]; then
    avg=$((total / count))
    echo -e "  ${BOLD}Average Delay:${NC}  ${GREEN}${avg}s${NC}"
    echo -e "  ${BOLD}Total Tests:${NC}    ${count}"
fi

echo ""
echo -e "  ${BOLD}Pipeline:${NC} Attack → API Log → Forwarder (30s) → Agent → Indexer"
echo ""
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Results saved to: /tmp/benchmark_results.txt${NC}"
