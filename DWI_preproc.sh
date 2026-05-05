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
checkoptvar degibbs nthreads tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT

### Remove nifti suffix
dwi=$( removeniisfx ${dwi} )

# Derived variables
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
dwiname=$( basename ${dwi} )

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

# Parse dwi filename
declare -A bids
extract_BIDS_entities "${dwi}" bids acq

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_dwipreproc.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/code/logs/${dwiname}_log
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
checkoptvar degibbs nthreads tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parsed BIDS info ${dwiname}"
echo "************************************"
echo ""
echo ""

checkoptvar bids

# Set various folders
ddir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/dwi
dderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/dwi
rderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/reg
dwiprefix=sub-${bids[sub]}_ses-${bids[ses]}

# First return of variables discovered so far
checkoptvar scriptdir dwiname ddir dderivdir rderivdir dwiprefix

# Now move to more interesting things
cd ${ddir} || exit 1

# Create folders
replace_and mkdir ${tmp}
if_missing_do mkdir ${dderivdir}
if_missing_do mkdir ${rderivdir}

for dwifile in ${dwiprefix}_*_${bids[filesuffix]}.nii.gz
do
	dwifile=$( basename $( removeniisfx ${dwifile} ) )
	# Not sure we need to skip the fake b0
	[[ ${dwifile} == *"acq-7db0"* ]] && continue

	echo ""
	echo ""
	echo "************************************"
	echo "***    Prepare ${dwifile} for (joint) denoising"
	echo "************************************"
	echo ""
	echo ""

	mrconvert -fslgrad ${dwifile}.bvec ${dwifile}.bval  -json_import ${dwifile}.json -strides 0,0,0,1 ${dwifile}.nii.gz ${tmp}/${dwifile}.mif -force

	if [[ ${degibbs} == "yes" ]]
	then
		# MRtrix3 suggests doing degibbs after dwidenoise though
		mrdegibbs ${tmp}/${dwifile}.mif ${tmp}/${dwifile}_degibbs.mif -force
		dwisuffix=${bids[filesuffix]}_degibbs
	fi
done

dwicat -scratch ${tmp} ${tmp}/${dwiprefix}_*_${bids[filesuffix]}.mif ${tmp}/${dwiprefix}_concat.mif

# Doing denoise on merged volumes and respitting out divided nifti files
# See https://community.mrtrix.org/t/dwidenoise-correct-use/586/4
# And https://community.mrtrix.org/t/combining-two-dwi-images-with-b800-and-b2000/7115
# However see https://qsiprep.readthedocs.io/en/stable/preprocessing.html#denoising-and-merging-images
mkdir -p ${dderivdir}/${dwiprefix}_dwidenoise
dwidenoise ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -noise ${dderivdir}/${dwiprefix}_dwidenoise/noise.nii.gz -force
mrcalc ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -subtract ${dderivdir}/${dwiprefix}_dwidenoise/residulas.nii.gz

mrconvert -export_grad_fsl ${dderivdir}/${dwiprefix}_concat.bvec ${dderivdir}/${dwiprefix}_concat.bval -strides -1,+2,+3,+4 \
		  ${tmp}/${dwiprefix}_denoised.mif ${tmp}/${dwiprefix}_denoised.nii.gz -force

echo ""
echo ""
echo "************************************"
echo "***    Use SBRefs of ${dwifile} to create masks and topup"
echo "************************************"
echo ""
echo ""

# Estimate first giving a name for folder purposes
${scriptdir}/blocks/pepolar.sh -nii ${dwiprefix}_dwi_concat -blipdown ${ddir}/${dwiprefix}_acq-7db0_sbref -blipup ${ddir}/${dwiprefix}_acq-40db1k_sbref \
							   -workdir ${bids[root]}/derivatives/vessels -estimateonly -modality dwi -tmp ${tmp}

pepolardir=${dderivdir}/${dwiprefix}_dwi_concat_topup
# Apply on blipup
${scriptdir}/blocks/pepolar.sh -nii ${ddir}/${dwiprefix}_acq-40db1k_sbref -pepolardir ${pepolardir} \
							   -workdir ${bids[root]}/derivatives/vessels -modality dwi -tmp ${tmp}

# Use corrected blipup to make a brain mask
# For some reason I don't want to think about, this mask can be awful. Instead I'll do a better one mixing a few options together.
${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${dwiprefix}_acq-40db1k_sbref_tpp -method "bet 3dss" -tmp ${tmp} -nobrain
# Also create a combined mask from distorted files to use for eddy
${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${dwiprefix}_denoised -method avgbet -tmp ${tmp} -nobrain

fslmaths ${tmp}/${dwiprefix}_acq-40db1k_sbref_tpp_brain_mask -add ${tmp}/${dwiprefix}_denoised_brain_mask -bin ${dderivdir}/${dwiprefix}_dwi_brain_mask
fslmaths ${tmp}/${dwiprefix}_acq-40db1k_sbref_tpp -mas ${dderivdir}/${dwiprefix}_dwi_brain_mask ${dderivdir}/${dwiprefix}_dwi_brain

# Prepare index file for eddy
eddyindex=""
for i in $( seq 1 $( fslval ${tmp}/${dwiprefix}_denoised dim4 ) ); do eddyindex="${eddyindex} 1"; done
echo ${eddyindex} > ${tmp}/eddyindex

# Run eddy
eddy --imain=${tmp}/${dwiprefix}_denoised.nii.gz --mask=${dderivdir}/${dwiprefix}_dwi_brain_mask \
	 --acqp=${pepolardir}/acqparam.txt --topup=${pepolardir}/outtp --index=${tmp}/eddyindex \
	 --bvecs=${dderivdir}/${dwiprefix}_concat.bvec --bvals=${dderivdir}/${dwiprefix}_concat.bval \
	 --json=${dwifile}.json --nthr=${nthreads} \
	 --out=${tmp}/${dwiprefix}_eddied

mv ${tmp}/${dwiprefix}_eddied.eddy.json ${dderivdir}/00.${dwiprefix}_dwi_preprocessed_eddy_parameters.json
mv ${tmp}/${dwiprefix}_eddied.eddy_shell_indicies.json ${dderivdir}/00.${dwiprefix}_dwi_preprocessed_shell_indexes.json
mv ${tmp}/${dwiprefix}_eddied.eddy_rotated_bvecs ${dderivdir}/00.${dwiprefix}_dwi_preprocessed.bvecs


# Bias field correction (why only now?) with ants N4
# 02.2. Bias Correction
# See dwibiascorrect

# echo "Performing BFC on ${anat}"
# ImageMath 4 ${tmp}/${dwiprefix}_trunc.nii.gz TruncateImageIntensity ${tmp}/${dwiprefix}_eddied.nii.gz 0.02 0.98 256

N4BiasFieldCorrection -d 4 -i ${tmp}/${dwiprefix}_eddied.nii.gz -o ${dderivdir}/00.${dwiprefix}_dwi_preprocessed.nii.gz


echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"

cd ${cwd}




# """
# Copyright 2022, Stefano Moia.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# """
