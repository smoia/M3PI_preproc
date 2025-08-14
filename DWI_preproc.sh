#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
degibbs=no
nthreads=2
tmp=/tmp
debug=no

### print input
printline=$( basename -- $0 )
echo "${printline}" "$@"
printcall="${printline} $*"
# Parsing required and optional variables with flags
# Also checking if a flag is the help request or the version
while [ ! -z "$1" ]
do
	case "$1" in
		-dwi)		dwi=$2;shift;;		# Any DWI file from an acq series to process; the others will be found.

		-degibbs)	degibbs=yes;;		# Turn on deGibbs artifacts denoising.
		-nthreads)	nthreads=$2;shift;;	# Number of threads to use for eddy.

		-tmp)		tmp=$2;shift;;		# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)		debug=yes;;			# Turn on debug mode.

		-h)			displayhelp $0;;	# Display help.
		-v)			version;exit 0;;	# Display version.
		*)			echo "Wrong flag: $1";displayhelp $0 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar dwi
checkoptvar degibbs tmp debug

[[ ${debug} == "yes" ]] && set -x

### Remove nifti suffix
dwi=$( removeniisfx ${dwi} )

### Cath errors and exit on them
set -e
######################################
######### Script starts here #########
######################################
echo ""
echo "Make sure system python is used by prepending /usr/bin to PATH"
[[ "${PATH%%:*}" != "/usr/bin" ]] && export PATH=/usr/bin:$PATH
echo "PATH is set to $PATH"
echo ""

cwd=$(pwd)

# Parse dwi filename and force right folder's absolute path pt. 1
workdir=$( dirname $( realpath ${dwi} ) | sed -E 's|/sub-[^_]+/ses-[^_]+/dwi||')
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
dwiname=$( basename ${dwi} )

if_missing_do stop ${workdir}
if_missing_do mkdir ${workdir}/derivatives/vessels/logs

# Preparing log folder and log file, removing the previous one
logfile=${workdir}/derivatives/vessels/logs/${dwiname}_log
replace_and touch ${logfile}

echo "************************************" >> ${logfile}

exec 3>&1 4>&2

exec 1>${logfile} 2>&1

version
date
echo ""
echo ${printcall}
echo ""
echo "PATH is set to $PATH"
checkreqvar dwi
checkoptvar TEs tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parse BIDS info ${dwiname}"
echo "************************************"
echo ""
echo ""

# Parse dwi filename and force right folder's absolute path pt. 2
[[ "$dwiname" =~ ^sub-([^_]+)_ses-([^_]+)_(acq-([^_]+))_([^\.]+)$ ]] && \
	sub=${BASH_REMATCH[1]} && \
	ses=${BASH_REMATCH[2]} && \
	acq=${BASH_REMATCH[4]:-} && \
	dwisuffix=${BASH_REMATCH[5]}

ddir=${workdir}/sub-${sub}/ses-${ses}/dwi
dderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/dwi
rderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/reg

dwiprefix=sub-${sub}_ses-${ses}
tmp=${tmp}/sub-${sub}_ses-${ses}_dwipreproc

# First return of variables discovered so far
checkoptvar workdir scriptdir dwiname sub ses acq dwisuffix ddir dderivdir rderivdir dwiprefix tmp

# Now move to more interesting things
cd ${ddir} || exit 1

# Create folders
replace_and mkdir ${tmp}
if_missing_do mkdir ${dderivdir}
if_missing_do mkdir ${rderivdir}

[[ ! -d ${dderivdir} ]] && exit 2
[[ ! -d ${rderivdir} ]] && exit 2

declare -A dwifilevols

for dwifile in ${dwiprefix}_*_${dwisuffix}.nii.gz
do
	# Not sure we need to skip the fake b0
	[[ ${dwifile} == *"acq-7db0"* ]] && dwifilevols["7db0"]=$( fslval ${dwifile} dim4 )
	dwifile=$( basename $( removeniisfx ${dwifile} ) )

	echo ""
	echo ""
	echo "************************************"
	echo "***    Prepare ${dwifile} for (joint) denoising"
	echo "************************************"
	echo ""
	echo ""

	mrconvert -fslgrad ${dwifile}.bvec ${dwifile}.bval  -json_import ${dwifile}.json -strides 0,0,0,1 ${dwifile}.nii.gz ${tmp}/${dwifile}.mif

	if [[ ${degibbs} == "yes" ]]
	then
		# MRtrix3 suggests doing degibbs after dwidenoise though
		mrdegibbs ${tmp}/${dwifile}.mif ${tmp}/${dwifile}_degibbs.mif
		dwisuffix=${dwisuffix}_degibbs
	fi

	# Populate array of file dimensions for use with eddy
	[[ "$dwifile" =~ _acq-([^_]+) ]] && dwifilevols["${BASH_REMATCH[1]}"]=$( fslval ${dwifile} dim4 )
done

dwicat ${tmp}/${dwiprefix}_*_${dwisuffix}.mif ${tmp}/${dwiprefix}_concat.mif

# Doing denoise on merged volumes and respitting out divided nifti files
# See https://community.mrtrix.org/t/dwidenoise-correct-use/586/4
# And https://community.mrtrix.org/t/combining-two-dwi-images-with-b800-and-b2000/7115
# However see https://qsiprep.readthedocs.io/en/stable/preprocessing.html#denoising-and-merging-images
mkdir -p ${dderivdir}/${dwiprefix}_dwidenoise
dwidenoise ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -noise ${dderivdir}/${dwiprefix}_dwidenoise/noise.nii.gz
mrcalc ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -subtract ${dderivdir}/${dwiprefix}_dwidenoise/residulas.nii.gz

mrconvert -export_grad_fsl ${dderivdir}/${dwiprefix}_concat.bvec ${dderivdir}/${dwiprefix}_concat.bval -strides -1,+2,+3,+4 \
		  ${tmp}/${dwiprefix}_denoised.mif ${tmp}/${dwiprefix}_denoised.nii.gz

echo ""
echo ""
echo "************************************"
echo "***    Use SBRefs of ${dwifile} to create masks and topup"
echo "************************************"
echo ""
echo ""

# Estimate first giving a name for folder purposes
${scriptdir}/blocks/pepolar.sh -nii ${dwiprefix}_dwi_concat -blipup ${ddir}/${dwiprefix}_acq-7db0_sbref -blipdown ${ddir}/${dwiprefix}_acq-40db1k_sbref \
							   -workdir ${workdir}/derivatives/vessels -estimateonly -modality dwi -debug ${debug} -tmp ${tmp}

pepolardir=${dderivdir}/${dwiprefix}_dwi_concat_topup
# Apply on blipup
${scriptdir}/blocks/pepolar.sh -nii ${ddir}/${dwiprefix}_acq-7db0_sbref -pepolardir ${pepolardir} \
							   -workdir ${workdir}/derivatives/vessels -modality dwi -debug ${debug} -tmp ${tmp}

# Use corrected blipup to make a brain mask
bet ${tmp}/${dwiprefix}_acq-7db0_sbref_tpp ${tmp}/${dwiprefix}_dwi_brain -R -f 0.5 -g 0 -n -m
mv ${tmp}/${dwiprefix}_dwi_brain_mask.nii.gz ${dderivdir}/.

# Also create a combined mask from distorted files to use for eddy
fslmaths ${tmp}/${dwiprefix}_denoised -Tmean ${tmp}/avg_dwi
bet ${tmp}/avg_dwi ${tmp}/avg_dwi_brain -R -f 0.5 -g 0 -n -m

# Run eddy (although very uncertain about HOW)
eddy --imain=${tmp}/${dwiprefix}_denoised.nii.gz --mask=${dderivdir}/${dwiprefix}_dwi_brain_mask \
	 --acqp=${pepolardir}/acqparam.txt --topup=${pepolardir}/outtp \
	 --bvecs=${dderivdir}/${dwiprefix}_concat.bvec --bvals=${dderivdir}/${dwiprefix}_concat.bval \
	 --json=${dwifile}.json \
	 --out=${tmp}/${dwiprefix}_eddied
	 # --index is still missing!

# Bias field correction (why only now?) with ants N4
# 02.2. Bias Correction
# See dwibiascorrect
N4BiasFieldCorrection -d 3 -i ${tmp}/${dwiprefix}_eddied.nii.gz -o ${dderivdir}/00.${dwiprefix}_dwi_preprocessed.nii.gz

# post proc

# dwi2response to estiamte response function with msmt_5tt method
# See https://mrtrix.readthedocs.io/en/0.3.16/concepts/response_function_estimation.html

# dwi2fod for multi-shell multi-tissue constrained spherical deconvolution

# tckgen for initial tractogram

# tcksift for SIFT OR SIFT2? MAYBE OPTION

# tck2connectome for connectome.

echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"

cd ${cwd}

if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
