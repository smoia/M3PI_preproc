#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
degibbs=no
nthreads=2
bbr=yes
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

		-no_bbr)	bbr=no;;			# Use normal coregistration rather than BBR.

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
checkoptvar degibbs nthreads bbr tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ -n "${tmp}" ] && [ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT
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
checkoptvar degibbs nthreads bbr tmp debug

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

# Create folders
replace_and mkdir ${tmp}
if_missing_do mkdir ${dderivdir}
if_missing_do mkdir ${rderivdir}

# Now move to more interesting things
for dwifile in ${ddir}/${dwiprefix}_*_${bids[filesuffix]}.nii.gz
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

	mrconvert -fslgrad ${ddir}/${dwifile}.bvec ${ddir}/${dwifile}.bval  -json_import ${ddir}/${dwifile}.json -strides 0,0,0,1 ${ddir}/${dwifile}.nii.gz ${tmp}/${dwifile}.mif -force

	if [[ ${degibbs} == "yes" ]]
	then
		# MRtrix3 suggests doing degibbs after dwidenoise though
		mrdegibbs ${tmp}/${dwifile}.mif ${tmp}/${dwifile}_degibbs.mif -force
		dwisuffix=${bids[filesuffix]}_degibbs
	else
		dwisuffix=${bids[filesuffix]}
	fi
done

dwicat -scratch ${tmp} ${tmp}/${dwiprefix}_*_${dwisuffix}.mif ${tmp}/${dwiprefix}_concat.mif

# Doing denoise on merged volumes and respitting out divided nifti files
# See https://community.mrtrix.org/t/dwidenoise-correct-use/586/4
# And https://community.mrtrix.org/t/combining-two-dwi-images-with-b800-and-b2000/7115
# However see https://qsiprep.readthedocs.io/en/stable/preprocessing.html#denoising-and-merging-images
mkdir -p ${dderivdir}/${dwiprefix}_dwidenoise
dwidenoise ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -noise ${dderivdir}/${dwiprefix}_dwidenoise/noise.nii.gz -force
mrcalc ${tmp}/${dwiprefix}_concat.mif ${tmp}/${dwiprefix}_denoised.mif -subtract ${dderivdir}/${dwiprefix}_dwidenoise/residuals.nii.gz -force

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
${scriptdir}/blocks/pepolar.sh -nii ${dderivdir}/${dwiprefix}_dwi_concat -blipdown ${ddir}/${dwiprefix}_acq-7db0_sbref -blipup ${ddir}/${dwiprefix}_acq-40db1k_sbref \
							   -workdir ${bids[root]}/derivatives/vessels -estimateonly -datatype dwi -tmp ${tmp}

pepolardir=${dderivdir}/${dwiprefix}_dwi_topup
# Apply on blipup
${scriptdir}/blocks/pepolar.sh -nii ${ddir}/${dwiprefix}_acq-40db1k_sbref -pepolardir ${pepolardir} \
							   -workdir ${bids[root]}/derivatives/vessels -datatype dwi -tmp ${tmp}

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

echo ${eddyindex} > ${pepolardir}/eddyindex

# Run eddy
eddy --imain=${tmp}/${dwiprefix}_denoised.nii.gz --mask=${dderivdir}/${dwiprefix}_dwi_brain_mask \
	 --acqp=${pepolardir}/acqparam.txt --topup=${pepolardir}/outtp --index=${pepolardir}/eddyindex \
	 --bvecs=${dderivdir}/${dwiprefix}_concat.bvec --bvals=${dderivdir}/${dwiprefix}_concat.bval \
	 --json=${ddir}/${dwifile}.json --out=${tmp}/${dwiprefix}_eddied --verbose

cp ${tmp}/${dwiprefix}_eddied.eddy_rotated_bvecs ${dderivdir}/00.${dwiprefix}_dwi_preprocessed.bvecs
replace_and mkdir ${dderivdir}/${dwiprefix}_eddy

for f in ${tmp}/${dwiprefix}_eddied.e*; do mv ${f} ${dderivdir}/${dwiprefix}_eddy/${f#*.eddy_}; done

# Bias field correction (why only now?) with ants N4
# 02.2. Bias Correction
# See dwibiascorrect

N4BiasFieldCorrection -d 4 -i ${tmp}/${dwiprefix}_eddied.nii.gz -o ${dderivdir}/00.${dwiprefix}_dwi_preprocessed.nii.gz

# Realignment
aderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-02/anat
if [[ -d ${aderivdir} ]]
then
	t2wanat=$( ls ${aderivdir}/* | grep T2w | grep brain.nii.gz )

	if [[ -e ${t2wanat} ]]
	then

		t2wanatname=$( basename ${t2wanat} )
		t2wanatname=${t2wanatname%*_brain*}
		seg=${t2wanat%_brain*}_seg

		dwiref=${dderivdir}/${dwiprefix}_dwi_brain
		dwirefname=${dwiprefix}_dwi_brain

		echo "************************************"
		echo "*** Coregister ${dwirefname} to T2w anat"
		echo "************************************"
		echo "************************************"


		if [[ "${bbr}" == "yes" ]]
		then
			echo "Coregistering ${dwirefname} to ${t2wanatname} using normalised BBR search cost, normalised MI cost, and 6 DoFs (Rigid body)"
			# Extract WM, then make sure it's in anat space
			fslmaths ${seg}.nii.gz -thr 3 ${tmp}/wm.nii.gz

			flirt -in ${dwiref} -ref ${t2wanat} -out ${rderivdir}/${dwiprefix}_dwi2T2w_fsl -omat ${rderivdir}/${dwiprefix}_dwi2T2w_fsl.mat \
				  -searchcost bbr -cost normmi -wmseg ${tmp}/wm.nii.gz -dof 6 -searchry -90 90 -searchrx -90 90 -searchrz -90 90

			echo "Inverting matrix to coregister ${t2wanat%.nii*} to ${dwirefname}"
			
			convert_xfm -omat ${rderivdir}/${t2wanatname}2dwi_fsl.mat -inverse ${rderivdir}/${dwiprefix}_dwi2T2w_fsl.mat
			flirt -init ${rderivdir}/${t2wanatname}2dwi_fsl.mat -applyxfm -in ${t2wanat} \
				  -ref ${dwiref}_brain -o ${rderivdir}/${t2wanatname}2dwi_fsl
		else
			echo "Coregistering ${t2wanatname} to ${dwirefname} using normalised MI cost and 6 DoFs (Rigid body)"
			flirt -in ${t2wanat} -ref ${dwiref} -out ${rderivdir}/${t2wanatname}2dwi_fsl \
				  -omat ${rderivdir}/${t2wanatname}2dwi_fsl.mat \
				  -searchry -90 90 -searchrx -90 90 -searchrz -90 90 -cost normmi -searchcost normmi -dof 6
		fi
		
		echo "Trasforming matrix from FSL to ANTs"
		c3d_affine_tool -ref ${dwiref} -src ${t2wanat} ${rderivdir}/${t2wanatname}2dwi_fsl.mat \
						-fsl2ras -oitk ${rderivdir}/${t2wanatname}2dwi0GenericAffine.mat
		antsApplyTransforms -d 3 -i ${t2wanat} \
							-r ${dwiref}.nii.gz -o ${rderivdir}/${t2wanatname}2dwi.nii.gz \
							-n Linear -t ${rderivdir}/${t2wanatname}2dwi0GenericAffine.mat


		t1wanat=$( ls ${aderivdir}/* | grep UNIT1 | grep brain.nii.gz )
		t2w2t1w=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-02/reg/${t2wanatname}2UNIT10GenericAffine.mat

		if [[ -e ${t1wanat} && -e ${t2w2t1w} ]]
		then
			t1wanatname=$( basename ${t1wanat} )
			t1wanatname=${t1wanatname%*_brain*}

			echo "************************************"
			echo "*** Coregister T1w anat to ${dwirefname}"
			echo "************************************"
			echo "************************************"

			antsApplyTransforms -d 3 -i ${t1wanat} \
								-r ${dwiref}.nii.gz -o ${rderivdir}/${t1wanatname}2dwi.nii.gz \
								-n Linear -t ${rderivdir}/${t2wanatname}2dwi0GenericAffine.mat \
								-t [${t2w2t1w},1]
		fi
	else
		echo "No T2w data found, skipping coregistration"
	fi
else
	echo "No anatomical derivatives found, skipping coregistration"
fi

echo ""
echo ""
echo "************************************"
echo "***    DWI Preproc completed!"
echo "************************************"

cd ${cwd}


# """
# Copyright 2024, Stefano Moia.

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
