#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------
# Trim Galore batch driver
#  - Local mode: runs jobs sequentially, streaming output to screen (no backgrounding)
#  - Slurm mode: submits one sbatch job per sample (simple & reliable)
#
# CSV format required (header):
#   group,replicate,fastq_1,fastq_2,control
# -----------------------------------------------------------

VERSION="4.0"

# Defaults
MODE="local"          # "local" or "slurm"
CORES=4
OUTDIR="trim_galore_out"
INPUT=""              # samplesheet.csv; optional if using --pair
GROUP_PREFIX="manual"
DRYRUN=0
VERBOSE=0

PAIRS_R1=()
PAIRS_R2=()

print_help() {
cat <<'EOF'
Usage:
  run_trim_galore.sh [OPTIONS] [-- SLURM_OPTS...]

Modes (choose one; default: local):
  --local                      Run locally (stream live output to screen)
  --slurm                      Submit one sbatch job per sample (simple)

Inputs (choose one):
  -i, --input FILE             nf-core style samplesheet.csv
  --pair R1 R2                 Add a paired FASTQ (repeatable). Used if no CSV.

Common options:
  -o, --outdir DIR             Output dir [default: trim_galore_out]
  -c, --cores N                Threads per Trim Galore job [default: 4]
  --group-prefix STR           Group prefix for manual mode [default: manual]
  --dry-run                    Validate only; no trimming
  -v, --verbose                Verbose logging
  -h, --help                   Show this help

Notes:
  • Local mode runs jobs sequentially and prints the tool output live.
  • Slurm mode submits one sbatch per sample; tail slurm logs to watch progress.
  • Worker requirements: trim_galore, cutadapt, fastqc, gzip (or pigz).
EOF
}

log(){ echo "[$(date '+%F %T')] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

trim_ws(){
  local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"
}

# -------------------------
# Parse CLI
# -------------------------
SLURM_EXTRA=()
[[ $# -eq 0 ]] && { print_help; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift;;
    --slurm) MODE="slurm"; shift;;
    -i|--input) INPUT="${2:-}"; shift 2;;
    --pair) [[ $# -lt 3 ]] && die "--pair needs R1 R2"; PAIRS_R1+=("$2"); PAIRS_R2+=("$3"); shift 3;;
    -o|--outdir) OUTDIR="$2"; shift 2;;
    -c|--cores) CORES="$2"; shift 2;;
    --group-prefix) GROUP_PREFIX="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) print_help; exit 0;;
    --) shift; SLURM_EXTRA=("$@"); break;;
    *) die "Unknown argument: $1";;
  esac
done

# -------------------------
# Build job list (arrays)
# -------------------------
declare -a JOB_GROUP JOB_REP JOB_R1 JOB_R2
idx=0

if [[ -n "${INPUT}" ]]; then
  [[ -f "${INPUT}" ]] || die "Samplesheet not found: ${INPUT}"
  # Read CSV
  BOM=$'\xef\xbb\xbf'
  header_raw="$(head -n1 "${INPUT}")"; header="${header_raw#$BOM}"
  expected="group,replicate,fastq_1,fastq_2,control"
  if [[ "${header}" != "${expected}" ]]; then
    echo "WARNING: header mismatch
    Expected: ${expected}
    Found   : ${header}" | sed 's/^    //'
  fi

  while IFS=, read -r g r f1 f2 ctrl; do
    g="$(trim_ws "${g:-}")"; r="$(trim_ws "${r:-}")"
    f1="$(trim_ws "${f1:-}")"; f2="$(trim_ws "${f2:-}")"; ctrl="$(trim_ws "${ctrl:-}")"
    [[ -z "${g}${r}${f1}${f2}${ctrl}" ]] && continue
    idx=$((idx+1))
    JOB_GROUP[idx]="${g}"
    JOB_REP[idx]="${r}"
    JOB_R1[idx]="${f1}"
    JOB_R2[idx]="${f2}"
  done < <(tail -n +2 "${INPUT}")
else
  # Manual pairs
  [[ ${#PAIRS_R1[@]} -gt 0 ]] || die "Provide -i samplesheet.csv or one/more --pair"
  for ((i=0;i<${#PAIRS_R1[@]};i++)); do
    idx=$((idx+1))
    JOB_GROUP[idx]="${GROUP_PREFIX}"
    JOB_REP[idx]="$((i+1))"
    JOB_R1[idx]="${PAIRS_R1[$i]}"
    JOB_R2[idx]="${PAIRS_R2[$i]}"
  done
fi

TOTAL="${idx}"
[[ "${TOTAL}" -gt 0 ]] || die "No jobs parsed."

mkdir -p "${OUTDIR}"
SUMMARY_TSV="${OUTDIR}/summary.tsv"
SUMMARY_LOG="${OUTDIR}/summary.log"
echo -e "group\treplicate\tfastq_1\tfastq_2\tstatus\tmessage" > "${SUMMARY_TSV}"
: > "${SUMMARY_LOG}"

WORKER="$(dirname "$0")/run_trim_galore_worker.sh"
[[ -x "${WORKER}" ]] || die "Worker not executable: ${WORKER}"

log "Mode=${MODE}  Jobs=${TOTAL}  Outdir=${OUTDIR}  Cores=${CORES}  Dry-run=${DRYRUN}"

# -------------------------
# LOCAL MODE (stream to screen)
# -------------------------
if [[ "${MODE}" == "local" ]]; then
  for i in $(seq 1 "${TOTAL}"); do
    g="${JOB_GROUP[$i]}"; r="${JOB_REP[$i]}"; f1="${JOB_R1[$i]}"; f2="${JOB_R2[$i]}"
    # Call worker directly, streaming output via --stream
    GROUP="${g}" REPLICATE="${r}" FASTQ1="${f1}" FASTQ2="${f2}" \
    OUTDIR="${OUTDIR}" CORES="${CORES}" DRYRUN="${DRYRUN}" VERBOSE="${VERBOSE}" \
    SUMMARY_TSV="${SUMMARY_TSV}" SUMMARY_LOG="${SUMMARY_LOG}" \
    bash "${WORKER}" --direct --stream
  done
  log "All local jobs finished."
  log "Summary: ${SUMMARY_TSV}  /  ${SUMMARY_LOG}"
  exit 0
fi

# -------------------------
# SLURM MODE (one sbatch per sample)
# -------------------------
for i in $(seq 1 "${TOTAL}"); do
  g="${JOB_GROUP[$i]}"; r="${JOB_REP[$i]}"; f1="${JOB_R1[$i]}"; f2="${JOB_R2[$i]}"
  SAMPLE_TAG="${g}_rep${r}"
  slurm_out="${OUTDIR}/slurm_${SAMPLE_TAG}.%j.out"
  slurm_err="${OUTDIR}/slurm_${SAMPLE_TAG}.%j.err"
  mkdir -p "${OUTDIR}"

  # Export vars to the sbatch job
  export GROUP="${g}" REPLICATE="${r}" FASTQ1="${f1}" FASTQ2="${f2}"
  export OUTDIR CORES DRYRUN VERBOSE SUMMARY_TSV SUMMARY_LOG

  JOBID=$(sbatch \
    --job-name="tg_${SAMPLE_TAG}" \
    --output="${slurm_out}" \
    --error="${slurm_err}" \
    "${SLURM_EXTRA[@]}" \
    --export=ALL,GROUP,REPLICATE,FASTQ1,FASTQ2,OUTDIR,CORES,DRYRUN,VERBOSE,SUMMARY_TSV,SUMMARY_LOG \
    "${WORKER}" --direct \
    | awk '{print $NF}')

  log "Submitted ${SAMPLE_TAG} as JobID ${JOBID} (logs: ${slurm_out} / ${slurm_err})"
done

log "All Slurm jobs submitted."
log "Summary will accumulate in: ${SUMMARY_TSV}  /  ${SUMMARY_LOG}"

