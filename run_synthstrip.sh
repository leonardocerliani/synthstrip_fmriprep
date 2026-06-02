#!/bin/bash

# LC 2026-06-02

usage() {
    echo ""
    echo "Usage: $0 <bids_root> [n_parallel_processes] [synthstrip_script]"
    echo ""
    echo "Arguments:"
    echo "  bids_root             Path to the BIDS root directory (mandatory)"
    echo "  n_parallel_processes  Number of parallel jobs (optional, default: 5)"
    echo "  synthstrip_script     Path to synthstrip-docker.sh (optional,"
    echo "                        default: \$PWD/synthstrip-docker.sh)"
    echo ""
    echo "Examples:"
    echo "  $0 /data/bids"
    echo "  $0 /data/bids 10"
    echo "  $0 /data/bids 10 /tools/synthstrip-docker.sh"
    echo ""
}

# ── Arguments ────────────────────────────────────────────────────────────────

if [ -z "$1" ]; then
    usage
    exit 1
fi

bids_root="$1"
n_parallel_processes="${2:-5}"
synthstrip_script="${3:-${PWD}/synthstrip-docker.sh}"

if [ ! -f "${synthstrip_script}" ]; then
    echo "ERROR: synthstrip-docker.sh not found at: ${synthstrip_script}"
    exit 1
fi

if [ ! -d "${bids_root}" ]; then
    echo "ERROR: bids_root directory not found: ${bids_root}"
    exit 1
fi

echo "=== run_synthstrip.sh ==="
echo "  bids_root          : ${bids_root}"
echo "  parallel processes : ${n_parallel_processes}"
echo "  synthstrip script  : ${synthstrip_script}"
echo ""

# ── Find T1w files, excluding anything already in ORIGINAL_T1W ──────────────

tmp_list=$(mktemp /tmp/T1s_list.XXXXXX.txt)

find "${bids_root}" -type f -name "*T1w.nii.gz" ! -name "*ORIG*" ! -path "*/ORIGINAL_T1W/*" \
    > "${tmp_list}"

n_found=$(wc -l < "${tmp_list}")
echo "Found ${n_found} T1w file(s) to process."
echo ""

# ── Process in parallel ──────────────────────────────────────────────────────

xargs -a "${tmp_list}" -P "${n_parallel_processes}" -I {} bash -c '
    synthstrip_script="$1"
    f="$2"

    anat_dir=$(dirname "${f}")
    orig_dir="${anat_dir}/ORIGINAL_T1W"

    # Safety check: if ORIGINAL_T1W already exists, skip this subject
    if [ -d "${orig_dir}" ]; then
        echo "[SKIP] ORIGINAL_T1W already exists for: ${f}"
        echo "       Remove ${orig_dir} manually if you want to reprocess."
        exit 0
    fi

    echo "[START] Processing: ${f}"

    mkdir -p "${orig_dir}"

    # Build output filenames
    base=$(basename "${f}")
    orig_t1w="${orig_dir}/${base/T1w.nii.gz/ORIG_T1w.nii.gz}"
    orig_brain="${orig_dir}/${base/T1w.nii.gz/ORIG_T1w_brain.nii.gz}"
    orig_mask="${orig_dir}/${base/T1w.nii.gz/ORIG_T1w_brain_mask.nii.gz}"

    # Copy original T1w into ORIGINAL_T1W/
    cp "${f}" "${orig_t1w}"

    # Run SynthStrip
    "${synthstrip_script}" \
        -i "${orig_t1w}" \
        -o "${orig_brain}" \
        -m "${orig_mask}" \
        -t 10 \
        --no-csf

    # Rename all .nii.gz files in ORIGINAL_T1W to .NIFTIGZ
    # so fmriprep cannot identify them as images
    for nii in "${orig_t1w}" "${orig_brain}" "${orig_mask}"; do
        if [ -f "${nii}" ]; then
            mv "${nii}" "${nii%.nii.gz}.NIFTIGZ"
        fi
    done

    echo "[DONE] Finished: ${f}"
' _ "${synthstrip_script}" {}

# ── Housekeeping ──────────────────────────────────────────────────────────────────

rm -f "${tmp_list}"

echo ""
echo "=== All done ==="
