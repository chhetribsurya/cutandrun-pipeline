#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------
# Worker: runs ONE Trim Galore paired job
# Inputs via ENV when called with --direct:
#   GROUP, REPLICATE, FASTQ1, FASTQ2, OUTDIR, CORES, DRYRUN, VERBOSE
#   SUMMARY_TSV, SUMMARY_LOG
#
# Flags:
#   --direct    read inputs from env (recommended by driver)
#   --stream    print tool output live to screen (use in local mode)
# -----------------------------------------------------------

STREAM=0
DIRECT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stream) STREAM=1; shift;;
    --direct) DIRECT=1; shift;;
    *) echo "Unknown arg to worker: $1" >&2; exit 2;;
  esac
done

log(){ echo "[$(date '+%F %T')] [${SLURM_JOB_ID:-local}] $*"; }

append_safe() {
  local f="$1"; shift; local txt="$*"
  # Single-writer append is fine; if you expect heavy concurrency, add flock here.
  echo -e "${txt}" >> "${f}"
}

die(){ echo "ERROR: $*" >&2; exit 1; }
vbool(){ [[ "${1:-0}" -eq 1 ]] && echo "true" || echo "false"; }

# -------------------------
# Read inputs
# -------------------------
if [[ "${DIRECT}" -ne 1 ]]; then
  die "Worker expects --direct (env-based invocation) from the driver."
fi

GROUP="${GROUP:?GROUP env missing}"
REPLICATE="${REPLICATE:?REPLICATE env missing}"
FASTQ1="${FASTQ1:?FASTQ1 env missing}"
FASTQ2="${FASTQ2:?FASTQ2 env missing}"
OUTDIR="${OUTDIR:?OUTDIR env missing}"
CORES="${CORES:?CORES env missing}"
DRYRUN="${DRYRUN:-0}"
VERBOSE="${VERBOSE:-0}"
SUMMARY_TSV="${SUMMARY_TSV:?SUMMARY_TSV env missing}"
SUMMARY_LOG="${SUMMARY_LOG:?SUMMARY_LOG env missing}"

SAMPLE_TAG="${GROUP}_rep${REPLICATE}"
SAMPLE_DIR="${OUTDIR}/${GROUP}/rep${REPLICATE}"
LOG_DIR="${SAMPLE_DIR}/logs"
mkdir -p "${LOG_DIR}"

log "Starting ${SAMPLE_TAG}"
log "fastq1=${FASTQ1}"
log "fastq2=${FASTQ2}"
log "cores=${CORES}  dry_run=$(vbool "${DRYRUN}")  stream=$(vbool "${STREAM}")"

# -------------------------
# Environment (uncomment ONE block)
# -------------------------
# module purge >/dev/null 2>&1 || true
# module load trim_galore
# module load cutadapt
# module load fastqc
# module load pigz || true

# source ~/.bashrc
# eval "$(conda shell.bash hook)"
# conda activate cutnrun-nf-env
# -------------------------

# -------------------------
# Validation
# -------------------------
STATUS="OK"; MSG=""
[[ -z "${GROUP}" || -z "${REPLICATE}" || -z "${FASTQ1}" || -z "${FASTQ2}" ]] && { STATUS="FAIL"; MSG="missing fields"; }
[[ "${STATUS}" == "OK" && ! -f "${FASTQ1}" ]] && { STATUS="FAIL"; MSG="fastq_1 not found: ${FASTQ1}"; }
[[ "${STATUS}" == "OK" && ! -f "${FASTQ2}" ]] && { STATUS="FAIL"; MSG="fastq_2 not found: ${FASTQ2}"; }
[[ "${STATUS}" == "OK" && ! -s "${FASTQ1}" ]] && { STATUS="FAIL"; MSG="fastq_1 empty: ${FASTQ1}"; }
[[ "${STATUS}" == "OK" && ! -s "${FASTQ2}" ]] && { STATUS="FAIL"; MSG="fastq_2 empty: ${FASTQ2}"; }

if [[ "${STATUS}" == "OK" ]]; then
  if ! gzip -t "${FASTQ1}" 2>> "${SUMMARY_LOG}"; then STATUS="FAIL"; MSG="gzip integrity failed: ${FASTQ1}"; fi
fi
if [[ "${STATUS}" == "OK" ]]; then
  if ! gzip -t "${FASTQ2}" 2>> "${SUMMARY_LOG}"; then STATUS="FAIL"; MSG="gzip integrity failed: ${FASTQ2}"; fi
fi

if [[ "${STATUS}" != "OK" ]]; then
  append_safe "${SUMMARY_TSV}" "${GROUP}\t${REPLICATE}\t${FASTQ1}\t${FASTQ2}\tFAIL\t${MSG}"
  append_safe "${SUMMARY_LOG}" "[VALIDATION-FAIL] ${SAMPLE_TAG} :: ${MSG}"
  log "Validation failed: ${MSG}"
  exit 0
fi

# -------------------------
# Run Trim Galore
# -------------------------
mkdir -p "${SAMPLE_DIR}"

if [[ "${DRYRUN}" -eq 1 ]]; then
  append_safe "${SUMMARY_TSV}" "${GROUP}\t${REPLICATE}\t${FASTQ1}\t${FASTQ2}\tOK\tvalidated_only_dryrun"
  append_safe "${SUMMARY_LOG}" "[OK-DRYRUN] ${SAMPLE_TAG} :: Validation passed"
  log "Dry-run: validation OK"
  exit 0
fi

# Compose command
TG_CMD=( trim_galore
  --fastqc
  --cores "${CORES}"
  --paired
  --gzip
  --output_dir "${SAMPLE_DIR}"
  "${FASTQ1}" "${FASTQ2}"
)

log "Running: ${TG_CMD[*]}"

set +e
if [[ "${STREAM}" -eq 1 ]]; then
  # line-buffer to stream nicely; tee to both screen and file
  { stdbuf -oL -eL "${TG_CMD[@]}" 2>&1 | tee "${LOG_DIR}/trim_galore.combined.log"; } 
  rc=${PIPESTATUS[0]}
else
  # non-streaming (Slurm): keep separate stdout/stderr files + Slurm log
  "${TG_CMD[@]}" > "${LOG_DIR}/trim_galore.stdout.log" 2> "${LOG_DIR}/trim_galore.stderr.log"
  rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
  append_safe "${SUMMARY_TSV}" "${GROUP}\t${REPLICATE}\t${FASTQ1}\t${FASTQ2}\tFAIL\ttrim_galore_exit_${rc}"
  append_safe "${SUMMARY_LOG}" "[RUN-FAIL] ${SAMPLE_TAG} :: Trim Galore exit ${rc}"
  log "Trim Galore failed with code ${rc}"
  exit 0
fi

# Post-run check: expect *_val_1*.fq.gz and *_val_2*.fq.gz
shopt -s nullglob
tg1=( "${SAMPLE_DIR}"/*_val_1*.fq.gz )
tg2=( "${SAMPLE_DIR}"/*_val_2*.fq.gz )
shopt -u nullglob

if [[ ${#tg1[@]} -eq 0 || ${#tg2[@]} -eq 0 ]]; then
  append_safe "${SUMMARY_TSV}" "${GROUP}\t${REPLICATE}\t${FASTQ1}\t${FASTQ2}\tFAIL\tmissing_trimmed_pairs"
  append_safe "${SUMMARY_LOG}" "[POST-CHECK-FAIL] ${SAMPLE_TAG} :: Missing trimmed pairs in ${SAMPLE_DIR}"
  log "Post-run check failed"
  exit 0
fi

append_safe "${SUMMARY_TSV}" "${GROUP}\t${REPLICATE}\t${FASTQ1}\t${FASTQ2}\tOK\ttrim_complete"
append_safe "${SUMMARY_LOG}" "[OK] ${SAMPLE_TAG} :: Completed"
log "Completed OK"

