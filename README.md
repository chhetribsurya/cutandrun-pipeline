# FASTQ Pair Validation & CUT\&RUN Trimming Pipeline

This repository provides helper scripts and wrappers for validating and fixing paired-end FASTQ files before running the **CUT\&RUN Trim Galore pipeline**.
It addresses common issues such as truncated FASTQ mates, mismatched pairs, and gzip integrity errors that can cause Trim Galore or nf-core/cutandrun to fail.

---

##  Overview

When running CUT\&RUN or similar pipelines, a common source of failure is **FASTQ pairing errors**:

* Files labeled as R1 and R2 may not actually be mates (e.g., mismatched samples or barcodes).
* One mate may be truncated or corrupted (gzip EOF error).
* Lane-split files may be mis-associated.

This repo includes:

* **`fix_fastq_pair.sh`** — repairs a single R1/R2 pair using [BBTools `repair.sh`](https://jgi.doe.gov/data-and-tools/bbtools/), ensuring synchronized mates.
* **`fix_samplesheet_fastq.sh`** — batch-fixes an entire nf-core-style `samplesheet.csv`, producing a corrected version with valid paths.
* **`run_trim_galore.sh` + `run_trim_galore_worker.sh`** — orchestrate **Trim Galore + FastQC** either locally (streaming output live) or on Slurm clusters (one job per sample).

---

## Requirements

Use **either** Modules **or** Conda. Pick one and stick with it for both fixing and trimming.

### Option A — HPC **Modules**

Load these **before running** any script:

```bash
# Core tools for trimming
module load trim_galore
module load cutadapt
module load fastqc
module load pigz            # optional, if available for faster gzip

# For repairing pairs (used by fix_* scripts)
module load bbmap           # provides repair.sh
```

> **Slurm jobs**: non-interactive shells sometimes don’t preload the `module` command.
> To be safe, the worker script includes a commented block:
>
> ```bash
> # in run_trim_galore_worker.sh (uncomment this block)
> # source /etc/profile.d/modules.sh >/dev/null 2>&1 || true
> # module purge >/dev/null 2>&1 || true
> # module load trim_galore
> # module load cutadapt
> # module load fastqc
> # module load pigz || true
> ```
>
> Uncomment it so each Slurm job loads the tools itself.

### Option B — **Conda/Mamba**

```bash
mamba create -n cutnrun-tools -c bioconda -c conda-forge \
  trim-galore cutadapt fastqc bbmap pigz
mamba activate cutnrun-tools
```

Verify:

```bash
which trim_galore && trim_galore --version
which cutadapt && cutadapt --version
which fastqc && fastqc --version
which repair.sh
```

---

##  In details: Scripts in this repo

* **`run_trim_galore.sh`** — driver for Trim Galore + FastQC

  * `--local`: runs sequentially, streaming logs to your screen.
  * `--slurm`: submits one **sbatch** job per sample (std Slurm logs).
* **`run_trim_galore_worker.sh`** — worker for a single sample (called by driver).
* **`fix_fastq_pair.sh`** — re-synchronize one R1/R2 pair using BBTools `repair.sh`.
* **`fix_samplesheet_fastq.sh`** — batch-fix all pairs in an nf-core `samplesheet.csv` and write `samplesheet.fixed.csv`.

---

## 🚀 Quick Start

### 1) Environment

Load **modules** (Option A) or **activate Conda** (Option B) as above.

> For **Slurm**, also **uncomment the module block** inside `run_trim_galore_worker.sh` so every job loads the right tools.

---

##  Usage

### A) Fix a manual pair

If you suspect a problematic R1/R2 pair, you can fix it manually:

```bash
chmod +x fix_fastq_pair.sh
module load bbmap   # or: conda install -c bioconda bbmap

./fix_fastq_pair.sh \
  -1 HUH7_XIST_KO_Input_R1_1.fastq.gz \
  -2 HUH7_XIST_KO_Input_R1_2.fastq.gz \
  -o fixed_fastq/HUH7_XIST_KO_Input \
  -p HUH7_XIST_KO_Input \
  -t 8

# → prints the two fixed paths, e.g.:
# fixed_fastq/HUH7_XIST_KO_Input/HUH7_XIST_KO_Input_R1.fixed.fq.gz
# fixed_fastq/HUH7_XIST_KO_Input/HUH7_XIST_KO_Input_R2.fixed.fq.gz
```

Use those two new paths with your manual run:

```bash
./run_trim_galore.sh --local -o tg_out -c 8 \
  --pair fixed_fastq/HUH7_XIST_KO_Input/HUH7_XIST_KO_Input_R1.fixed.fq.gz \
        fixed_fastq/HUH7_XIST_KO_Input/HUH7_XIST_KO_Input_R2.fixed.fq.gz \
  --group-prefix HUH7_manual
```

---

### B) Fix an entire samplesheet

If you want to fix all pairs in your `samplesheet.csv`:

```bash
chmod +x fix_fastq_pair.sh fix_samplesheet_fastq.sh
module load bbmap   # or: conda install -c bioconda bbmap

./fix_samplesheet_fastq.sh -i samplesheet.csv -o fixed_batch -t 8
# -> outputs fixed_batch/samplesheet.fixed.csv
```

Then run Trim Galore with the corrected CSV:

```bash
# Local execution (streaming output)
./run_trim_galore.sh --local -i fixed_batch/samplesheet.fixed.csv -o tg_out -c 8

# Slurm execution (one job per sample)
./run_trim_galore.sh --slurm -i fixed_batch/samplesheet.fixed.csv -o tg_out -c 8 -- \
  --partition=normal --time=12:00:00 --cpus-per-task=8 --mem=16G
```

---

##  Outputs

* **Fixed FASTQs**:

  * `*_R1.fixed.fq.gz` and `*_R2.fixed.fq.gz` (valid paired mates)
  * `*.singletons.fq.gz` (reads that lacked a mate)

* **Trim Galore pipeline outputs**:

  * QC reports (`*.html`, `*.zip`)
  * Trimmed FASTQs (`*_val_1.fq.gz`, `*_val_2.fq.gz`)
  * Logs: `summary.tsv`, `summary.log`

---

##  Troubleshooting

* **Error: “Read 2 output is truncated at sequence count …”**
  → Indicates one mate ended early. Use `fix_fastq_pair.sh` or `fix_samplesheet_fastq.sh` to repair.

* **Pairs: 0 / Singletons: 100% (from repair.sh)**
  → The provided R1 and R2 are not true mates (different barcodes or mismatched samples). Double-check sample provenance.

* **Gzip EOF warnings**
  → Suggest file truncation or corruption. Re-download or re-copy the file, then re-run the fix scripts.

---

##  References

* [BBTools repair.sh documentation](https://jgi.doe.gov/data-and-tools/bbtools/)
* [Trim Galore! documentation](https://www.bioinformatics.babraham.ac.uk/projects/trim_galore/)
* [nf-core/cutandrun pipeline](https://nf-co.re/cutandrun)

---

