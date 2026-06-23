#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
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
		-sbref)		sbref=$2;shift;;	# The main sbref of the dataset. If present, the T2w will be also be processed and used.

		-no_bbr)	bbr=no;;			# Use normal coregistration rather than BBR.

		-tmp)		tmp=$2;shift;;		# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)		debug=yes;;			# Turn on debug mode.

		-h)			displayhelp $0;;	# Display this help.
		-v)			version $0;exit 0;;	# Display the version.
		*)			echo "Wrong flag: $1";displayhelp 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar sbref
checkoptvar bbr tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT

### Remove nifti suffix
sbref=$( removeniisfx ${sbref})

# Derived variables
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
sbrefname=$( basename ${sbref} )

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

# Parse sbref filename
declare -A bids
extract_BIDS_entities "${sbref}" bids task

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_sbrefpreproc.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/code/logs/${sbrefname}_log
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
checkreqvar sbref
checkoptvar bbr tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parsed BIDS info ${sbrefname}"
echo "************************************"
echo ""
echo ""

checkoptvar bids

# Set various folders
fdir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/func
fmapdir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/fmap
fderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/func
aderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-02/anat
rderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/reg
sbrefprefix=sub-${bids[sub]}_ses-${bids[ses]}

# Check if there is a processed T2w anatomical
t2wanat=$( ls ${aderivdir}/* | grep T2w | grep brain.nii.gz )

# First return of variables discovered so far
checkoptvar scriptdir sbrefname fdir fmapdir fderivdir aderivdir rderivdir sbrefprefix


# Find all sbrefs
sbreffiles=()

# Limit to echo 1 and magnitude volume (all in filesuffix)
for sfile in $( ls ${fdir}/${sbrefprefix}* | grep ${bids[filesuffix]}.nii.gz | sort -V )
do
	sbreffiles+=($( removeniisfx ${sfile}))
done

# Create folders
if_missing_do mkdir ${fderivdir}
if_missing_do mkdir ${rderivdir}


for sbreffile in ${sbreffiles[@]}
do
	sbrefname=$( basename ${sbreffile} )

	echo "************************************"
	echo "*** Crop and correct bias field ${sbrefname}"
	echo "************************************"
	echo "************************************"

	ImageMath 3 ${tmp}/${sbrefname}_trunc.nii.gz TruncateImageIntensity ${sbreffile}.nii.gz 0.02 0.98 256
	N4BiasFieldCorrection -d 3 -i ${tmp}/${sbrefname}_trunc.nii.gz -o ${tmp}/${sbrefname}_bfc.nii.gz

	echo "************************************"
	echo "*** Topup ${sbrefname}"
	echo "************************************"
	echo "************************************"

	# Check if there is a topup folder already and if there are multiple, select the first one.
	mapfile -t topupdirs < <(find "${fderivdir}/" -maxdepth 1 -type d -name "*topup*")
	if [[ ${#topupdirs[@]} -gt 0 ]]; then topupdir=${topupdirs[0]}; else topupdir=""; fi

	if [ -z "${topupdir}" ] || [ ! -d "${topupdir}" ]
	then
		echo "No previous topup run found, running it anew"
		blipup=$(find "${fmapdir}/" -maxdepth 1 -name "${sbrefprefix}*AP*.nii.gz" | head -n 1)
		blipdown=$(find "${fmapdir}/" -maxdepth 1 -name "${sbrefprefix}*PA*.nii.gz" | head -n 1)

		${scriptdir}/blocks/pepolar.sh -nii ${tmp}/${sbrefname}_bfc \
				-blipup ${blipup} \
				-blipdown ${blipdown} \
				-workdir ${bids[root]}/derivatives/vessels/ \
				-acqparams ${scriptdir}/acqparam_func.txt \
				-tmp ${tmp}
	else
		echo "Found ${topupdir}, using it as previous run source"
		${scriptdir}/blocks/pepolar.sh -nii ${tmp}/${sbrefname}_bfc \
				-pepolardir ${topupdir} \
				-workdir ${bids[root]}/derivatives/vessels/ \
				-tmp ${tmp}	
	fi

	echo "************************************"
	echo "*** Brain extract ${sbrefname}"
	echo "************************************"
	echo "************************************"

	${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${sbrefname}_bfc_tpp -method fsss -tmp ${tmp}
	mv ${tmp}/${sbrefname}_bfc_tpp_brain.nii.gz ${fderivdir}/${sbrefname}_brain.nii.gz
	mv ${tmp}/${sbrefname}_bfc_tpp_brain_mask.nii.gz ${fderivdir}/${sbrefname}_brain_mask.nii.gz

	# Parse again sbref filename - we want the task now.
	sbrefprefix=${sbrefname%_"${bids[filesuffix]}"*}
	[[ ${sbrefprefix} =~ task-([^_]+) ]] && task=${BASH_REMATCH[1]}

	if [[ -e ${t2wanat} ]]
	then

		echo "************************************"
		echo "*** Coregister ${sbrefname} to T2w anat"
		echo "************************************"
		echo "************************************"

		t2wanatname=$( basename ${t2wanat} )
		t2wanatname=${t2wanatname%*_brain*}

		if [[ "${bbr}" == "yes" ]]
		then
			echo "Coregistering ${sbrefname} to ${t2wanatname} using normalised BBR search cost, normalised MI cost, and 6 DoFs (Rigid body)"
			# Extract WM, then make sure it's in anat space
			fslmaths ${t2wanat%_brain*}_seg.nii.gz -thr 3 ${tmp}/wm.nii.gz

			flirt -in ${fderivdir}/${sbrefname}_brain -ref ${t2wanat} -out ${rderivdir}/${sbrefprefix}2T2w_fsl -omat ${rderivdir}/${sbrefprefix}2T2w_fsl.mat \
				  -searchcost bbr -cost normmi -wmseg ${tmp}/wm.nii.gz -dof 6 -searchry -90 90 -searchrx -90 90 -searchrz -90 90

			echo "Inverting matrix to coregister ${t2wanat%.nii*} to ${sbref}"
			
			convert_xfm -omat ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl.mat -inverse ${rderivdir}/${sbrefprefix}2T2w_fsl.mat
			flirt -init ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl.mat -applyxfm -in ${t2wanat} \
				  -ref ${fderivdir}/${sbrefname}_brain -o ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl
		else
			echo "Coregistering ${t2wanatname} to ${sbrefname} using normalised MI cost and 6 DoFs (Rigid body)"
			flirt -in ${t2wanat} -ref ${fderivdir}/${sbrefname}_brain -out ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl \
				  -omat ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl.mat \
				  -searchry -90 90 -searchrx -90 90 -searchrz -90 90 -cost normmi -searchcost normmi -dof 6
		fi
		
		echo "Trasforming matrix from FSL to ANTs"
		c3d_affine_tool -ref ${fderivdir}/${sbrefname}_brain -src ${t2wanat} ${rderivdir}/${t2wanatname}2task-${task}_sbref_fsl.mat \
						-fsl2ras -oitk ${rderivdir}/${t2wanatname}2task-${task}_sbref0GenericAffine.mat
		antsApplyTransforms -d 3 -i ${t2wanat} \
							-r ${fderivdir}/${sbrefname}_brain.nii.gz -o ${rderivdir}/${t2wanatname}2task-${task}_sbref.nii.gz \
							-n Linear -t ${rderivdir}/${t2wanatname}2task-${task}_sbref0GenericAffine.mat
	fi

	# If it's the first SBRef of the first session, then make it the universal SBRef, otherwise coregister all other SBRefs to that one.
	if [[ "${bids[ses]}" -eq 1 ]] && [[ ${sbreffile} == ${sbreffiles[0]} ]]
	then
		echo "************************************"
		echo "*** ${sbrefname} is the universal SBRef "
		echo "************************************"
		echo "************************************"

		echo "${sbreffile}_brain" > ${rderivdir}/universal_sbref_source
		cp ${fderivdir}/${sbrefname}_brain.nii.gz ${rderivdir}/sbref_brain.nii.gz
		cp ${fderivdir}/${sbrefname}_brain_mask.nii.gz ${rderivdir}/sbref_brain_mask.nii.gz
		cp ${tmp}/${sbrefname}_bfc_tpp.nii.gz ${rderivdir}/sbref.nii.gz
		cp ${rderivdir}/${t2wanatname}2task-${task}_sbref0GenericAffine.mat ${rderivdir}/${t2wanatname}2sbref0GenericAffine.mat
	else
		echo "************************************"
		echo "*** Coregister ${sbrefname} to universal SBRef"
		echo "************************************"
		echo "************************************"
		if_missing_do copy ${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-01/reg/sbref_brain.nii.gz ${rderivdir}/sbref_brain.nii.gz
		if_missing_do copy ${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-01/reg/sbref_brain_mask.nii.gz ${rderivdir}/sbref_brain_mask.nii.gz
		if_missing_do copy ${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-01/reg/sbref.nii.gz ${rderivdir}/sbref.nii.gz

		flirt -in ${fderivdir}/${sbrefname}_brain -ref ${rderivdir}/sbref_brain -out ${rderivdir}/${sbrefprefix}2sbref_fsl \
			  -omat ${rderivdir}/${sbrefprefix}2sbref_fsl.mat \
			  -searchry -90 90 -searchrx -90 90 -searchrz -90 90 -cost normmi -searchcost normmi -dof 6
		c3d_affine_tool -ref ${rderivdir}/sbref_brain -src ${fderivdir}/${sbrefname}_brain ${rderivdir}/${sbrefprefix}2sbref_fsl.mat \
						-fsl2ras -oitk ${rderivdir}/${sbrefprefix}2sbref0GenericAffine.mat
		antsApplyTransforms -d 3 -i ${fderivdir}/${sbrefname}_brain.nii.gz \
							-r ${rderivdir}/sbref_brain.nii.gz -o ${rderivdir}/${sbrefprefix}2sbref.nii.gz \
							-n Linear -t ${rderivdir}/${sbrefprefix}2sbref0GenericAffine.mat
	fi
done

cd ${cwd}

echo ""
echo ""
echo "************************************"
echo "***    SBREF Preproc completed!"
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
