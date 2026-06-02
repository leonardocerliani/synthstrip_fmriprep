#!/bin/bash

# run_fmriprep.sh
#
# fMRIprep launcher — processes all subjects in bids_root in a single call.
#
# Supports two skull-stripping strategies selected by SKULL_STRIP_PROCEDURE:
#
#   "synthstrip"  — use the synthstrip-generated brain (ORIG_T1w_brain)
#                   → copies ORIGINAL_T1W/*_ORIG_T1w_brain.NIFTIGZ → anat/*_T1w.nii.gz
#                   → runs fmriprep with --skull-strip-t1w skip
#
#   "fmriprep"    — let fmriprep do its own skull stripping with ANTs
#                   → restores the full-head T1w from ORIGINAL_T1W/*_ORIG_T1w.NIFTIGZ
#                   → runs fmriprep with --skull-strip-t1w force
#
# NB: the script is idempotent: the user can run the script with the `fmriprep` option even
# **after** having run it with the `synthstrip` option, since the original T1w image
# is restored from the ORIGINAL_T1W folder, even if in the previous run (with the `synthstrip` option)
# it had been overwritten by the ORIG_T1w_brain file.
#
# ⚠️ Do NOT run this script directly — launch in the background: ⚠️
# nohup ./run_fmriprep.sh >> fmriprep.log 2>&1 &
# Then monitor with:  tail -f fmriprep.log


# ════════════════════════════════════════════════════════════════════════════
# ── User parameters — edit everything in this section ──────────────────────
# ════════════════════════════════════════════════════════════════════════════

SKULL_STRIP_PROCEDURE="synthstrip"   # "synthstrip"  or  "fmriprep"

bids_root="/data00/MRI_hackaton/SKULL_STRIP_TESTS/bids"
deriv_root="/data00/MRI_hackaton/SKULL_STRIP_TESTS/derivatives_fmriprep_synthstrip"
work_dir="./fmriprep_work_MASSIVE_DELETE_ASAP"

# FreeSurfer
FREESURFER_HOME="/usr/local/freesurfer"
freesurfer_license="${FREESURFER_HOME}/license.txt"

# Parallelism
# --nprocs:       workflow-level parallelism (independent nodes run at once)
# --omp-nthreads: thread-level parallelism per process (ANTs, ITK)
# Total threads ≈ nprocs × omp-nthreads
nprocs=10
omp_nthreads=4

# MNI Template
MNI_template="MNI152NLin2009cAsym:res-2"

# ════════════════════════════════════════════════════════════════════════════
# ── Do not touch anything below! ───────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
    echo ""
    echo "  ⚠️  Make sure you have adjusted all parameters to your needs."
    echo ""
    echo "  ⚠️  Running in terminal/tmux — output will be visible here."
    echo "  For background execution:"
    echo ""
    echo "      nohup ./run_fmriprep.sh >> fmriprep.log 2>&1 &"
    echo ""
fi



# ── Validate SKULL_STRIP_PROCEDURE ──────────────────────────────────────────
if [ "${SKULL_STRIP_PROCEDURE}" != "synthstrip" ] && [ "${SKULL_STRIP_PROCEDURE}" != "fmriprep" ]; then
    echo "⚠️  SKULL_STRIP_PROCEDURE must be 'synthstrip' or 'fmriprep'."
    echo "    Got: '${SKULL_STRIP_PROCEDURE}'"
    exit 1
fi

# ── Pre-flight: prepare T1w files for all subjects ──────────────────────────
n_t1w=$(find "${bids_root}" -type f -name '*T1w.nii.gz' ! -name '*ORIG*' | wc -l)

if [ "${SKULL_STRIP_PROCEDURE}" = "synthstrip" ]; then

    echo "=== Pre-flight [synthstrip]: brain → T1w ==="
    n_orig=$(find "${bids_root}" -type f -name '*ORIG_T1w_brain.NIFTIGZ' | wc -l)
    echo "  T1w files         : ${n_t1w}"
    echo "  ORIG_T1w_brain    : ${n_orig}"

    if [ "${n_t1w}" -ne "${n_orig}" ]; then
        echo "  ⚠️  Not all subjects have a synthstrip skull-stripped T1w."
        echo "  Run synthstrip first, then re-launch this script."
        exit 1
    fi

    echo "  ✓ Copying synthstrip brains → T1w"
    find "${bids_root}" -type f -name '*ORIG_T1w_brain.NIFTIGZ' | while read src; do
        anat_dir=$(dirname $(dirname "${src}"))    # .../anat/ORIGINAL_T1W → .../anat
        src_name=$(basename "${src}")              # sub-XX_ORIG_T1w_brain.NIFTIGZ
        t1w_name="${src_name/ORIG_T1w_brain.NIFTIGZ/T1w.nii.gz}"
        cp "${src}" "${anat_dir}/${t1w_name}"
        echo "  ${t1w_name}"
    done

    skull_strip_opt="skip"

elif [ "${SKULL_STRIP_PROCEDURE}" = "fmriprep" ]; then

    echo "=== Pre-flight [fmriprep]: full-head T1w → T1w ==="
    n_orig=$(find "${bids_root}" -type f -name '*ORIG_T1w.NIFTIGZ' ! -name '*brain*' | wc -l)
    echo "  T1w files         : ${n_t1w}"
    echo "  ORIG_T1w (backup) : ${n_orig}"

    if [ "${n_t1w}" -ne "${n_orig}" ]; then
        echo "  ⚠️  Not all subjects have a full-head T1w backup in ORIGINAL_T1W/."
        echo "  Run synthstrip first (it creates the backup), then re-launch."
        exit 1
    fi

    echo "  ✓ Restoring full-head T1w from backup"
    find "${bids_root}" -type f -name '*ORIG_T1w.NIFTIGZ' ! -name '*brain*' | while read src; do
        anat_dir=$(dirname $(dirname "${src}"))  # .../anat/ORIGINAL_T1W → .../anat
        src_name=$(basename "${src}")            # sub-XX_ORIG_T1w.NIFTIGZ
        t1w_name="${src_name/ORIG_T1w.NIFTIGZ/T1w.nii.gz}"
        cp "${src}" "${anat_dir}/${t1w_name}"
        echo "  ${t1w_name}"
    done

    skull_strip_opt="force"

fi

echo "=== Pre-flight done — skull_strip_opt: ${skull_strip_opt} ==="
echo ""
echo "=== Starting fMRIprep · $(date) ==="

mkdir -p "${work_dir}"

fmriprep-docker \
    ${bids_root} \
    ${deriv_root} \
    participant \
    -u $(id -u):$(id -g) \
    --no-tty \
    --fs-no-reconall \
    --fs-license-file ${freesurfer_license} \
    --output-spaces ${MNI_template} \
    --fd-spike-threshold 0.5 \
    --dvars-spike-threshold 1.5 \
    --skull-strip-t1w ${skull_strip_opt} \
    --nprocs ${nprocs} \
    --omp-nthreads ${omp_nthreads} \
    --write-graph \
    --notrack \
    -w ${work_dir}

echo "=== Finished · $(date) ==="
echo "=== Cleaning : ${work_dir} ==="
rm -rf "${work_dir}"
