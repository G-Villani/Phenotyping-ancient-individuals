#!/bin/bash
#
#SBATCH --job-name=aHISplex_multisample
#SBATCH --partition=cpuqueue
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=0-04:00:00
#SBATCH --output=aHISplex_multisample_%j.log

# ─── USAGE ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Tool to start directly from already imputed genomes in bcf format, GLIMPSE2 output

Usage: $0 [OPTIONS]

Options:
  --in-dir   DIR   Directory with BCF/VCF files          [default: /XXX/Imputation/GLIMPSE2/GLIMPSE2_ligate]
  --prefix   STR   File prefix                           [default: XXX_imputed_]
  --suffix   STR   File suffix                           [default: _ligated.bcf]
  --a-dir    DIR   aHISplex installation directory       [default: /XXX/Phenotype/aHISplex]
  --out-dir  DIR   Output directory                      [default: aHISplex_results]
  --ref      STR   Reference genome (GRCh37 or GRCh38)   [default: GRCh37]
  --help           Show this help message

Example:
  $0 --in-dir /path/to/bcf --prefix my_prefix_ --suffix _ligated.vcf.gz --out-dir results --ref GRCh38
EOF
    exit 1
}

# ─── DEFAULTS ─────────────────────────────────────────────────────────────────
IN_DIR="/XXX/Imputation/GLIMPSE2/GLIMPSE2_ligate"
PREFIX=""
SUFFIX="_ligated.bcf"
A_DIR="/XXX/Phenotype/aHISplex"
OUT_DIR="aHISplex_results"
REF="GRCh37"

# ─── PARSE ARGUMENTS ──────────────────────────────────────────────────────────
OPTS=$(getopt \
    --options '' \
    --long in-dir:,prefix:,suffix:,a-dir:,out-dir:,ref:,help \
    --name "$0" \
    -- "$@") || usage

eval set -- "$OPTS"

while true; do
    case "$1" in
        --in-dir)  IN_DIR="$2";  shift 2 ;;
        --prefix)  PREFIX="$2";  shift 2 ;;
        --suffix)  SUFFIX="$2";  shift 2 ;;
        --a-dir)   A_DIR="$2";   shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --ref)     REF="$2";     shift 2 ;;
        --help)    usage ;;
        --)        shift; break ;;
        *)         usage ;;
    esac
done

# ─── VALIDATE ─────────────────────────────────────────────────────────────────
if [[ "$REF" != "GRCh37" && "$REF" != "GRCh38" ]]; then
    echo "ERROR: --ref must be GRCh37 or GRCh38 (got: $REF)"
    exit 1
fi

if [ ! -d "$IN_DIR" ]; then
    echo "ERROR: --in-dir '$IN_DIR' does not exist"
    exit 1
fi

if [ ! -d "$A_DIR" ]; then
    echo "ERROR: --a-dir '$A_DIR' does not exist"
    exit 1
fi

# ─── DERIVED PATHS ────────────────────────────────────────────────────────────
AHISPLEX_DATA="$A_DIR/aHISplex_data"
TRANS_TOOL="$A_DIR/bin/transToHISplex"
SITES="$AHISPLEX_DATA/sites_${REF}.txt"
TRANS="$AHISPLEX_DATA/trans_${REF}.tsv"

# ─── TOOL CHECK ───────────────────────────────────────────────────────────────
for tool in bcftools "$TRANS_TOOL"; do
    if ! command -v "$tool" &>/dev/null && [ ! -x "$tool" ]; then
        echo "ERROR: $tool not found or not executable"
        exit 1
    fi
done

# ─── SETUP ────────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"

echo "========================================"
echo "aHISplex multi-sample run"
echo "IN_DIR:   $IN_DIR"
echo "OUT_DIR:  $OUT_DIR"
echo "REF:      $REF"
echo "Date:     $(date)"
echo "========================================"

# ─── COLLECT INPUT FILES (sorted by chromosome number) ───────────────────────
mapfile -t INPUT_FILES < <(ls "$IN_DIR"/${PREFIX}*${SUFFIX} 2>/dev/null \
    | sort -V)

NFILES=${#INPUT_FILES[@]}
if [ "$NFILES" -eq 0 ]; then
    echo "ERROR: No files matching ${PREFIX}*${SUFFIX} found in $IN_DIR"
    exit 1
fi

echo "* Pattern:  ${IN_DIR}/${PREFIX}<CHR>${SUFFIX}"
echo "* Found $NFILES files:"
printf '  %s\n' "${INPUT_FILES[@]}"

# ─── INDEX FILES (if not already indexed) ────────────────────────────────────
echo "* Checking/creating indexes..."
for f in "${INPUT_FILES[@]}"; do
    if [ ! -f "${f}.csi" ]; then
        echo "  Indexing $(basename $f)..."
        bcftools index "$f"
        if [ $? -ne 0 ]; then
            echo "ERROR: indexing failed for $f"
            exit 1
        fi
    fi
done

# ─── STEP 1: concat all chromosomes ──────────────────────────────────────────
echo "* Concatenating $NFILES files..."

bcftools concat \
    --threads "$SLURM_CPUS_PER_TASK" \
    -O b \
    -o "$OUT_DIR/all_chromosomes.bcf" \
    "${INPUT_FILES[@]}"

if [ $? -ne 0 ]; then
    echo "ERROR: bcftools concat failed"
    exit 1
fi

bcftools index "$OUT_DIR/all_chromosomes.bcf"

# ─── STEP 2: bcftools query for HIrisPlex-S markers ──────────────────────────
echo "* Filtering HIrisPlex-S variants..."

bcftools query \
    -f '%CHROM\t%POS\t%REF\t%ALT[\t%SAMPLE=%GT]\n' \
    -R "$SITES" \
    "$OUT_DIR/all_chromosomes.bcf" \
    > "$OUT_DIR/HISplex_variants.tsv"

if [ $? -ne 0 ]; then
    echo "ERROR: bcftools query failed"
    exit 1
fi

NVARIANTS=$(wc -l < "$OUT_DIR/HISplex_variants.tsv")
echo "  Found $NVARIANTS variant lines"

# ─── STEP 3: convert to HIrisPlex-S CSV ──────────────────────────────────────
echo "* Converting to HIrisPlex-S allele counts..."

"$TRANS_TOOL" "$TRANS" "$OUT_DIR/HISplex_variants.tsv" \
    > "$OUT_DIR/HISplex41_upload.csv"

if [ $? -ne 0 ]; then
    echo "ERROR: transToHISplex failed"
    exit 1
fi

NSAMPLES=$(tail -n +2 "$OUT_DIR/HISplex41_upload.csv" | wc -l)
echo "* Output: $OUT_DIR/HISplex41_upload.csv ($NSAMPLES samples)"
echo ""
echo "NEXT STEPS:"
echo "  1. Upload $OUT_DIR/HISplex41_upload.csv to https://hirisplex.erasmusmc.nl/"
echo "  2. Download the result CSV from the web interface"
echo "  3. Run: classifHISplex -short HIrisPlex-S_result.csv > classifications_short.csv"
echo ""
echo "Done: $(date)"
