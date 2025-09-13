#!/usr/bin/env bash
set -euo pipefail

# Fix/synchronize a paired-end FASTQ set by intersecting read IDs.
# Requires BBTools 'repair.sh' in PATH (module load bbmap OR conda install -c bioconda bbmap).
#
# Usage:
#   fix_fastq_pair.sh -1 R1.fq.gz -2 R2.fq.gz -o outdir [-p sample_name] [-t threads]
#
# Output:
#   outdir/<sample>_R1.fixed.fq.gz
#   outdir/<sample>_R2.fixed.fq.gz
#   outdir/<sample>.singletons.fq.gz (reads that were orphaned)
#   Prints the two fixed paths to stdout at the end.

R1=""
R2=""
OUTDIR="fixed_fastq"
SAMPLE=""
THREADS=8

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(date '+%F %T')] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -1) R1="${2:-}"; shift 2;;
    -2) R2="${2:-}"; shift 2;;
    -o|--outdir) OUTDIR="${2:-}"; shift 2;;
    -p|--prefix) SAMPLE="${2:-}"; shift 2;;
    -t|--threads) THREADS="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,60p' "$0"; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -f "${R1}" ]] || die "R1 not found: ${R1}"
[[ -f "${R2}" ]] || die "R2 not found: ${R2}"
mkdir -p "${OUTDIR}"

# Derive sample name if not provided
if [[ -z "${SAMPLE}" ]]; then
  baseR1="$(basename "${R1}")"
  baseR2="$(basename "${R2}")"
  # crude common prefix
  SAMPLE="$(printf "%s\n%s\n" "$baseR1" "$baseR2" | sed 'N;s/^\(.*\).*\\n\1.*/\1/;t;d' || true)"
  [[ -n "${SAMPLE}" ]] || SAMPLE="sample"
  SAMPLE="${SAMPLE%_R1*}"; SAMPLE="${SAMPLE%_1*}"
fi

OUT1="${OUTDIR}/${SAMPLE}_R1.fixed.fq.gz"
OUT2="${OUTDIR}/${SAMPLE}_R2.fixed.fq.gz"
SING="${OUTDIR}/${SAMPLE}.singletons.fq.gz"

# Quick integrity checks
log "gz integrity check..."
if ! gzip -t "${R1}" 2>/dev/null; then log "WARNING: gzip -t failed on R1: ${R1} (will salvage pairs)"; fi
if ! gzip -t "${R2}" 2>/dev/null; then log "WARNING: gzip -t failed on R2: ${R2} (will salvage pairs)"; fi

# Need BBTools repair.sh
command -v repair.sh >/dev/null 2>&1 || die "repair.sh not found in PATH (install or module load bbmap)."

log "Re-pairing with BBTools repair.sh…"
# Note: repair.sh uses read names to synchronize pairs; keeps only reads present in both.
repair.sh \
  in1="${R1}" in2="${R2}" \
  out1="${OUT1}" out2="${OUT2}" outs="${SING}" \
  overwrite=t threads="${THREADS}" 1>&2

# Sanity check: counts should now match
count_reads() { zcat "$1" 2>/dev/null | awk 'NR%4==2{c++} END{print c+0}'; }
C1=$(count_reads "${OUT1}") || C1=0
C2=$(count_reads "${OUT2}") || C2=0
log "Fixed pair counts: R1=${C1}, R2=${C2}"
if [[ "${C1}" -eq 0 || "${C2}" -eq 0 || "${C1}" -ne "${C2}" ]]; then
  die "Post-fix counts still invalid (R1=${C1}, R2=${C2})."
fi

echo "${OUT1}"
echo "${OUT2}"

