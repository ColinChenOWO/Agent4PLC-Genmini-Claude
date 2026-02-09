#!/usr/bin/env bash
set -euo pipefail

# =========================
# verify_wsl.sh (WSL)
# - Syntax check via MATIEC first
# - Only if MATIEC succeeds -> run nuXmv
# - Logs saved to artifacts/verify/logs/
# =========================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (match your repo structure)
WORK_DIR="${ROOT_DIR}/led_control"
ST_FILE="${ST_FILE:-}"          # you can override with env or --st
SMV_FILE="${SMV_FILE:-}"        # you can override with env or --smv

# Tools (can override with env)
MATIEC_BIN="${MATIEC_BIN:-matiec}"
NUXMV_BIN="${NUXMV_BIN:-nuXmv}"

# Output
OUT_DIR="${ROOT_DIR}/artifacts/verify"
LOG_DIR="${OUT_DIR}/logs"
mkdir -p "${LOG_DIR}"

SYNTAX_ONLY=0

usage() {
  cat <<EOF
用法:
  ./verify_wsl.sh [--workdir <dir>] [--st <file.st>] [--smv <file.smv>] [--syntax-only]

預設:
  --workdir = ${WORK_DIR}
  自動挑 workdir 中第一個 .st / .smv
  Logs: ${LOG_DIR}

環境變數可覆蓋:
  MATIEC_BIN=...   NUXMV_BIN=...   ST_FILE=...   SMV_FILE=...

例:
  ./verify_wsl.sh
  ./verify_wsl.sh --syntax-only
  ./verify_wsl.sh --workdir ./led_control --st led_controller.st --smv led_control_model.smv
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORK_DIR="$2"; shift 2;;
    --st)      ST_FILE="$2"; shift 2;;
    --smv)     SMV_FILE="$2"; shift 2;;
    --syntax-only) SYNTAX_ONLY=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo -e "${RED}[ERR] Unknown arg: $1${NC}"; usage; exit 2;;
  esac
done

if [[ ! -d "${WORK_DIR}" ]]; then
  echo -e "${RED}[ERR] WORK_DIR 不存在: ${WORK_DIR}${NC}"
  exit 1
fi

cd "${WORK_DIR}"

# Auto-pick files if not specified
if [[ -z "${ST_FILE}" ]]; then
  ST_FILE="$(ls -1 *.st 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${SMV_FILE}" ]]; then
  SMV_FILE="$(ls -1 *.smv 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${ST_FILE}" || ! -f "${ST_FILE}" ]]; then
  echo -e "${RED}[ERR] 找不到 .st 檔（在 ${WORK_DIR}）${NC}"
  echo "提示：先跑 ls 看看"
  exit 1
fi
if [[ ${SYNTAX_ONLY} -eq 0 && ( -z "${SMV_FILE}" || ! -f "${SMV_FILE}" ) ]]; then
  echo -e "${RED}[ERR] 找不到 .smv 檔（在 ${WORK_DIR}）${NC}"
  echo "提示：先跑 ls 看看，或用 --smv 指定"
  exit 1
fi

# Resolve MATIEC
if ! command -v "${MATIEC_BIN}" >/dev/null 2>&1; then
  if [[ -x "$HOME/matiec/iec2c" ]]; then
    MATIEC_BIN="$HOME/matiec/iec2c"
  else
    echo -e "${RED}[ERR] 找不到 matiec。請安裝或設定 MATIEC_BIN${NC}"
    exit 1
  fi
fi

# Resolve nuXmv (only needed if not syntax-only)
if [[ ${SYNTAX_ONLY} -eq 0 ]]; then
  if ! command -v "${NUXMV_BIN}" >/dev/null 2>&1; then
    if [[ -x "${NUXMV_BIN}" ]]; then
      : # ok, direct path
    else
      echo -e "${RED}[ERR] 找不到 nuXmv。請把它加進 PATH 或設定 NUXMV_BIN=/path/to/nuXmv${NC}"
      exit 1
    fi
  fi
fi

# Optional: fix CRLF if dos2unix exists
if command -v dos2unix >/dev/null 2>&1; then
  dos2unix "${ST_FILE}" >/dev/null 2>&1 || true
  [[ ${SYNTAX_ONLY} -eq 1 ]] || dos2unix "${SMV_FILE}" >/dev/null 2>&1 || true
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Verify (WSL): MATIEC -> (pass) -> nuXmv${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "WORK_DIR:   ${GREEN}$(pwd)${NC}"
echo -e "MATIEC_BIN: ${GREEN}${MATIEC_BIN}${NC}"
echo -e "NUXMV_BIN:  ${GREEN}${NUXMV_BIN}${NC}"
echo -e "ST:         ${GREEN}${ST_FILE}${NC}"
if [[ ${SYNTAX_ONLY} -eq 0 ]]; then
  echo -e "SMV:        ${GREEN}${SMV_FILE}${NC}"
else
  echo -e "SMV:        ${YELLOW}(skip: --syntax-only)${NC}"
fi
echo -e "LOG_DIR:    ${GREEN}${LOG_DIR}${NC}"
echo ""

# --------
# Step 1: MATIEC (syntax)
# --------
echo -e "${YELLOW}[1/2] Running MATIEC (syntax check)...${NC}"
# Use tee but keep correct exit code
set +e
("${MATIEC_BIN}" "${ST_FILE}" 2> >(tee "${LOG_DIR}/matiec.err.log" >&2) \
  | tee "${LOG_DIR}/matiec.out.log") 
MATIEC_RC=${PIPESTATUS[0]}
set -e

if [[ ${MATIEC_RC} -ne 0 ]]; then
  echo ""
  echo -e "${RED}✗ MATIEC FAILED (rc=${MATIEC_RC})${NC}"
  echo -e "${YELLOW}請看：${LOG_DIR}/matiec.err.log${NC}"
  exit ${MATIEC_RC}
fi

echo -e "${GREEN}✓ MATIEC OK (syntax passed)${NC}"

if [[ ${SYNTAX_ONLY} -eq 1 ]]; then
  echo ""
  echo -e "${GREEN}DONE (syntax-only).${NC}"
  exit 0
fi

# --------
# Step 2: nuXmv (model check)
# --------
echo ""
echo -e "${YELLOW}[2/2] Running nuXmv...${NC}"
set +e
("${NUXMV_BIN}" "${SMV_FILE}" 2> >(tee "${LOG_DIR}/nuxmv.err.log" >&2) \
  | tee "${LOG_DIR}/nuxmv.out.log")
NUXMV_RC=${PIPESTATUS[0]}
set -e

if [[ ${NUXMV_RC} -ne 0 ]]; then
  echo ""
  echo -e "${RED}✗ nuXmv FAILED (rc=${NUXMV_RC})${NC}"
  echo -e "${YELLOW}請看：${LOG_DIR}/nuxmv.err.log${NC}"
  exit ${NUXMV_RC}
fi

echo ""
echo -e "${GREEN}✓ nuXmv OK${NC}"
echo -e "${GREEN}ALL DONE. Logs: ${LOG_DIR}${NC}"
