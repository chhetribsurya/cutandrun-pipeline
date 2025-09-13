#!/usr/bin/bash

# Run the trim galore to check for each files using the samplesheet:
bash ./run_trim_galore.sh --slurm -i ./samplesheet_HUH7_corrected_batch2_fixed.csv -o tg_out_samplesheet -c 6 -- --partition=normal --time=4:00:00 --cpus-per-task=8 --mem=16G


# Run the trim galore in manual mode please
#./run_trim_galore.sh --local -o tg_out -c 8   --pair HUH7_XIST_KO_Input_R1_1.fastq.gz HUH7_XIST_KO_Input_R1_2.fastq.gz   --group-prefix HUH7_manual

# Fix the fastq using bbtools
#./fix_fastq_pair.sh -1 HUH7_XIST_KO_Input_R1_1.fastq.gz -2 HUH7_XIST_KO_Input_R1_2.fastq.gz   -o fixed_fastq/HUH7_XIST_KO_Input -p HUH7_XIST_KO_Input -t 8


#How to use
#Local (streams live to your screen):
#./run_trim_galore.sh --local -o tg_out -c 8 \
#  --pair HUH7_XIST_KO_Input_R1_1.fastq.gz HUH7_XIST_KO_Input_R1_2.fastq.gz \
#  --group-prefix HUH7_manual
#Local with CSV (streams live):
#./run_trim_galore.sh --local -i /path/to/samplesheet.csv -o tg_out -c 8
#Slurm (one job per sample; tail the logs):
#./run_trim_galore.sh --slurm -i /path/to/samplesheet.csv -o tg_out -c 8 -- \
#  --partition=normal --time=12:00:00 --cpus-per-task=8 --mem=16G
## then:
#tail -f tg_out/slurm_<group>_rep<rep>.<jobid>.out
#
#Notes
#* Local mode shows Trim Galore progress live (via tee to trim_galore.combined.log) and does not background anything.
#* Slurm mode does the standard thing: submits jobs and lets Slurm manage output; you can tail each job’s Slurm logs.
#* Uncomment modules or conda in the worker to match your cluster environment.



