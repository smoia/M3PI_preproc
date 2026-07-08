#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
MNI=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/templates/MNI152_T1_1mm_brain.nii.gz
MNIres=2.5
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
		-anat)		anat=$2;shift;;		# The main T1w/MP2RAGE of the dataset. If present, the T2w will be also be processed and used.

		-MNI)			MNI=$2;shift;;			# Full path to (MNI) template (use to change default template). Set to "none" to skip normalisation.
		-MNIres)		MNIres=$2;shift;;		# Desired resolution of MNI template - if not at the right resolution, the template will be resampled. 

		-tmp)			tmp=$2;shift;;			# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)			debug=yes;;				# Turn on debug mode.

		-h)			displayhelp $0;;	# Display this help.
		-v)			version $0;exit 0;;	# Display the version.
		*)			echo "Wrong flag: $1";displayhelp 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar anat
checkoptvar MNI MNIres tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ -n "${tmp}" ] && [ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT
### Remove nifti suffix
for var in anat MNI
do
	eval "${var}=$( removeniisfx ${!var})"
done

# Derived variables
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
anatname=$( basename ${anat} )

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

# Parse anat filename
declare -A bids
extract_BIDS_entities "${anat}" bids ses

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_anatpreproc.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/code/logs/${anatname}_log
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
checkreqvar anat
checkoptvar tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parsed BIDS info ${anatname}"
echo "************************************"
echo ""
echo ""

checkoptvar bids

# Set various folders
adir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/anat
aderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/anat
rderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/reg
anatprefix=${anatname%_"${bids[filesuffix]}"*}

# First return of variables discovered so far
checkoptvar scriptdir anatname adir aderivdir rderivdir anatprefix

# Find potential T2w file
anatfiles=(${anat})

t2wanat=$( ls ${adir}/${anatprefix}* | grep T2w.nii.gz )
[[ -e ${t2wanat} ]] && anatfiles+=($( removeniisfx ${t2wanat})) && t2wanatname=$( basename $( removeniisfx ${t2wanat}) )

# Now move to more interesting things
cd ${adir} || exit 1

# Create folders
if_missing_do mkdir ${aderivdir}
if_missing_do mkdir ${rderivdir}


for anatfile in ${anatfiles[@]}
do
	suffix=${anatfile##*_}

	echo "************************************"
	echo "*** Crop and correct bias field $( basename ${anatfile} )"
	echo "************************************"
	echo "************************************"

	ImageMath 3 ${tmp}/${suffix}_trunc.nii.gz TruncateImageIntensity ${anatfile}.nii.gz 0.02 0.98 256
	N4BiasFieldCorrection -d 3 -i ${tmp}/${suffix}_trunc.nii.gz -o ${tmp}/${suffix}_bfc.nii.gz
done

if [[ -e ${t2wanat} ]]
then
	echo "************************************"
	echo "*** Skullstrip ${t2wanatname}"
	echo "************************************"
	echo "************************************"

	${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${suffix}_bfc.nii.gz -method 3dss -tmp ${tmp}
	mv ${tmp}/${suffix}_bfc_brain.nii.gz ${aderivdir}/${t2wanatname}_brain.nii.gz
	mv ${tmp}/${suffix}_bfc_brain_mask.nii.gz ${aderivdir}/${t2wanatname}_brain_mask.nii.gz

	echo "************************************"
	echo "*** Coregister ${t2wanatname} to ${anatname}"
	echo "************************************"
	echo "************************************"

	echo "Flirt ${tmp}/${suffix}_bfc on ${t2wanat}"
	flirt -in ${tmp}/${suffix}_bfc -ref ${tmp}/${bids[filesuffix]}_bfc -cost normmi -searchcost normmi \
		  -omat ${rderivdir}/${t2wanatname}2${bids[suffix]}_fsl.mat -o ${rderivdir}/${t2wanatname}2${bids[suffix]}_fsl.nii.gz
	c3d_affine_tool -ref ${tmp}/${bids[filesuffix]}_bfc -src ${tmp}/${suffix}_bfc ${rderivdir}/${t2wanatname}2${bids[suffix]}_fsl.mat \
				    -fsl2ras -oitk ${rderivdir}/${t2wanatname}2${bids[suffix]}0GenericAffine.mat
	antsApplyTransforms -d 3 -i ${tmp}/${suffix}_bfc.nii.gz \
						-r ${tmp}/${bids[suffix]}_bfc.nii.gz -o ${rderivdir}/${t2wanatname}2${bids[suffix]}.nii.gz \
						-n Linear -v -t ${rderivdir}/${t2wanatname}2${bids[suffix]}0GenericAffine.mat
fi

echo "************************************"
echo "*** Skullstrip ${anatname}"
echo "************************************"
echo "************************************"

if [[ -e ${t2wanat} ]]
then
	antsApplyTransforms -d 3 -i ${aderivdir}/${t2wanatname}_brain_mask.nii.gz \
						-r ${tmp}/${bids[filesuffix]}_bfc.nii.gz -o ${aderivdir}/${anatname}_brain_mask.nii.gz \
						-n NearestNeighbor -t ${rderivdir}/${t2wanatname}2${bids[suffix]}0GenericAffine.mat
	fslmaths ${tmp}/${bids[filesuffix]}_bfc -mas ${aderivdir}/${anatname}_brain_mask ${aderivdir}/${anatname}_brain
else
	${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${bids[filesuffix]}_bfc.nii.gz -method fsss -tmp ${tmp}
	mv ${tmp}/${bids[filesuffix]}_bfc_brain.nii.gz ${aderivdir}/${anatname}_brain.nii.gz
	mv ${tmp}/${bids[filesuffix]}_bfc_brain_mask.nii.gz ${aderivdir}/${anatname}_brain_mask.nii.gz
fi

echo "************************************"
echo "*** Anat segment ${anatfile}"
echo "************************************"
echo "************************************"

echo "Segmenting ${anat}"
Atropos -d 3 -a ${aderivdir}/${anatname}_brain.nii.gz \
-o ${aderivdir}/${anatname}_seg.nii.gz \
-x ${aderivdir}/${anatname}_brain_mask.nii.gz -i kmeans[3] \
--use-partial-volume-likelihoods 1x2x3 \
-s 1x2 -s 2x3 \
-v 1

if [[ -e ${t2wanat} ]]
then
	echo "Coregister segmentation to ${t2wanatname}"
	antsApplyTransforms -d 3 -i ${aderivdir}/${anatname}_seg.nii.gz \
						-r ${aderivdir}/${t2wanatname}_brain.nii.gz -o ${aderivdir}/${t2wanatname}_seg.nii.gz \
						-n MultiLabel -v -t [${rderivdir}/${t2wanatname}2${bids[suffix]}0GenericAffine.mat, 1]
fi

## 02. Split, erode & dilate
echo "Splitting the segmented files, eroding and dilating"
3dcalc -a ${aderivdir}/${anatname}_seg.nii.gz -expr 'equals(a,1)' -prefix ${tmp}/CSF.nii.gz -overwrite
3dcalc -a ${aderivdir}/${anatname}_seg.nii.gz -expr 'equals(a,3)' -prefix ${aderivdir}/${anatname}_WM.nii.gz -overwrite
3dcalc -a ${aderivdir}/${anatname}_seg.nii.gz -expr 'equals(a,2)' -prefix ${aderivdir}/${anatname}_GM.nii.gz -overwrite

dicsf=-2
diwm=-3

3dmask_tool -input ${tmp}/CSF.nii.gz -prefix ${tmp}/CSF_eroded.nii.gz -dilate_input ${dicsf} -overwrite
3dmask_tool -input ${aderivdir}/${anatname}_WM.nii.gz -prefix ${tmp}/WM_eroded.nii.gz -fill_holes -dilate_input ${diwm} -overwrite
3dmask_tool -input ${aderivdir}/${anatname}_GM.nii.gz -prefix ${aderivdir}/${anatname}_GM_dilated.nii.gz -dilate_input 2 -overwrite
fslmaths ${aderivdir}/${anatname}_GM_dilated -mas ${aderivdir}/${anatname}_brain_mask ${aderivdir}/${anatname}_GM_dilated

#!# Further release: Check number voxels > compcorr components
until [ "$(fslstats ${tmp}/CSF_eroded -p 100)" != "0" -o "${dicsf}" == "0" ]
do
	let dicsf+=1
	echo "Too much erosion, setting new erosion to ${dicsf}"
	3dmask_tool -input ${tmp}/CSF.nii.gz -prefix ${tmp}/CSF_eroded.nii.gz -dilate_input ${dicsf} -overwrite
done 
until [ "$(fslstats ${tmp}/WM_eroded -p 100)" != "0" -o "${diwm}" == "0" ]
do
	let diwm+=1
	echo "Too much erosion, setting new erosion to ${diwm}"
	3dmask_tool -input ${aderivdir}/${anatname}_WM.nii.gz -prefix ${tmp}/WM_eroded.nii.gz -fill_holes -dilate_input ${diwm} -overwrite
done

# Checking that the CSF mask doesn't cointain GM
echo "Checking that the CSF doesn't contain GM"
fslmaths ${tmp}/CSF_eroded -sub ${aderivdir}/${anatname}_GM_dilated.nii.gz -thr 0 ${tmp}/CSF_eroded

# Recomposing masks
echo "Recomposing the eroded maps into one volume"
fslmaths ${aderivdir}/${anatname}_GM -mul 2 ${aderivdir}/${anatname}_GM
fslmaths ${tmp}/WM_eroded -sub ${tmp}/CSF -thr 0 -mul 3 -add ${tmp}/CSF_eroded -add ${aderivdir}/${anatname}_GM ${aderivdir}/${anatname}_seg_eroded

# Check uppercase and lowercase
if [[ ${MNI} != "none" ]]
then
	echo "************************************"
	echo "*** Anat normalise ${anatname}"
	echo "************************************"
	echo "************************************"

	std=${rderivdir}/standard
	if_missing_do copy ${MNI}.nii.gz ${std}.nii.gz
	if_missing_do mask ${std}.nii.gz ${std}_mask.nii.gz

	anatsource=${aderivdir}/${anatname}_brain

	cd ${rderivdir} || exit

	antsRegistration -d 3 -r [${std}.nii.gz,${anatsource}.nii.gz,1] \
					 -o [${anatname}2std,${anatname}2std.nii.gz,${anatprefix}_std2${bids[suffix]}.nii.gz] \
					 -x [${std}_mask.nii.gz, ${anatsource}_mask.nii.gz] \
					 -n Linear -u 0 -w [0.005,0.995] \
					 -t Rigid[0.1] \
					 -m MI[${std}.nii.gz,${anatsource}.nii.gz,1,48,Regular,0.1] \
					 -c [1000x500x250x100,1e-6,10] \
					 -f 8x4x2x1 \
					 -s 3x2x1x0vox \
					 -t Affine[0.1] \
					 -m MI[${std}.nii.gz,${anatsource}.nii.gz,1,48,Regular,0.1] \
					 -c [1000x500x250x100,1e-6,10] \
					 -f 8x4x2x1 \
					 -s 3x2x1x0vox \
					 -t SyN[0.1,3,0] \
					 -m CC[${std}.nii.gz,${anatsource}.nii.gz,1,5] \
					 -c [100x70x50x20,1e-6,10] \
					 -f 8x4x2x1 \
					 -s 3x2x1x0vox \
					 -z 1 -v 1

	if [[ ${MNIres} != "none" && ! -e ${std}_resamp_${MNIres}mm.nii.gz ]]
	then
		echo "Resampling ${std} at ${MNIres}mm"
		ResampleImageBySpacing 3 ${std}.nii.gz ${std}_resamp_${MNIres}mm.nii.gz ${MNIres} ${MNIres} ${MNIres} 0
		echo "Creating mask for ${std} at ${MNIres}mm"
		fslmaths ${std}_resamp_${MNIres}mm -bin ${std}_resamp_${MNIres}mm_mask
		echo "Registering ${anatname} to resampled standard"
		antsApplyTransforms -d 3 -i ${anatsource}.nii.gz \
							-r ${std}_resamp_${MNIres}mm.nii.gz -o ${anatname}2std_resamp_${MNIres}mm.nii.gz \
							-n Linear -t ${anatname}2std1Warp.nii.gz -t ${anatname}2std0GenericAffine.mat
	fi
fi


cd ${cwd}

echo ""
echo ""
echo "************************************"
echo "***    Anat preproc completed!"
echo "************************************"

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
