#!/usr/bin/env bash
set -euo pipefail

# Fix all FASTQ pairs in an nf-core samplesheet and write a new samplesheet with updated paths.
# Requires: fix_fastq_pair.sh + BBTools repair.sh
#
# Usage:
#   fix_samplesheet_fastq.sh -i samplesheet.csv -o outdir [-t threads]
#
# Output:
#   outdir/samplesheet.fixed.csv
#   fixed FASTQs in outdir/fixed_fastq/<group>/rep<rep>/
#
IN=""
OUTDIR="fixed_fastq_batch"
THREADS=8

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date '+%F %T')] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) IN="${2:-}"; shift 2;;
    -o|--outdir) OUTDIR="${2:-}"; shift 2;;
    -t|--threads) THREADS="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,200p' "$0"; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -f "${IN}" ]] || die "Samplesheet not found: ${IN}"
mkdir -p "${OUTDIR}"
FIXED_CSV="${OUTDIR}/samplesheet.fixed.csv"

# Header passthrough
header="$(head -n1 "${IN}")"
echo "${header}" > "${FIXED_CSV}"

FIXER="$(dirname "$0")/fix_fastq_pair.sh"
[[ -x "${FIXER}" ]] || die "fix_fastq_pair.sh not executable beside this script."

# Process each line
tail -n +2 "${IN}" | while IFS=, read -r group replicate fastq1 fastq2 control; do
  # trim whitespace
  group="$(echo -n "${group}" | sed 's/^ *//;s/ *$//')"
  replicate="$(echo -n "${replicate}" | sed 's/^ *//;s/ *$//')"
  fastq1="$(echo -n "${fastq1}" | sed 's/^ *//;s/ *$//')"
  fastq2="$(echo -n "${fastq2}" | sed 's/^ *//;s/ *$//')"
  control="$(echo -n "${control}" | sed 's/^ *//;s/ *$//')"

  [[ -z "${group}${replicate}${fastq1}${fastq2}" ]] && continue

  # per-sample output dir
  sample_out="${OUTDIR}/fixed_fastq/${group}/rep${replicate}"
  mkdir -p "${sample_out}"

  log "Fixing ${group} rep${replicate}…"
  mapfile -t fixed_paths < <("${FIXER}" -1 "${fastq1}" -2 "${fastq2}" -o "${sample_out}" -p "${group}_rep${replicate}" -t "${THREADS}")

  new_r1="${fixed_paths[0]}"
  new_r2="${fixed_paths[1]}"
  # Write updated row (same columns, replaced fastq paths)
  echo "${group},${replicate},${new_r1},${new_r2},${control}" >> "${FIXED_CSV}"
done

log "Wrote fixed samplesheet: ${FIXED_CSV}"
echo "${FIXED_CSV}"

