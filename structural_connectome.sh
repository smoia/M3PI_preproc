#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
mask=default
tt5=no
maxlength=250
n_fibers=10M
sift_version=sift2
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
		-dwi)		dwi=$2;shift;;		# Preprocessed, concatenated DWI series.
		-parc)		parc=$2;shift;;		# User-selected parcellation image (nodes) mapped to DWI space
		
		-mask)		mask=$2;shift;;				# Brain mask in DWI space. Default to DWI reference brain mask from preprocessing.
		-5tt)		tt5=yes;;					# Use 5TT segmentation and msmt_5tt response algorithm (requires T1w and T2w images in DWI space)
		-maxlength)	maxlength=$2;shift;;		# Max len of fibers.
		-n_fibers)	n_fibers=$2;shift;;			# Max number of fibers to seed.
		-sift)		sift_version=sift;;			# Toggle between 'sift' or 'sift2' (Default)
		-nthreads)	nthreads=$2;shift;;			# Number of threads to use for MRtrix3 commands.
		-tmp)		tmp=$2;shift;;				# Folder for temporary files. If not in debug mode, it'll be deleted as the script ends (succesfully or not).
		-debug)		debug=yes;;					# Turn on debug mode.

		-h)			displayhelp $0;;	# Display help.
		-v)			version;exit 0;;	# Display version.
		*)			echo "Wrong flag: $1";displayhelp $0 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar dwi parc
checkoptvar mask tt5 maxlength n_fibers sift_version nthreads tmp debug
# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT

### Remove nifti suffix
dwi=$( removeniisfx ${dwi} )

# Derived variables
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
extract_BIDS_entities "${dwi}" bids ses

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_structural_connectome.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/code/logs/${dwiname}_connectome_log
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
checkreqvar dwi parc
checkoptvar mask tt5 maxlength n_fibers sift_version nthreads tmp debug

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
dderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/dwi
rderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/reg
dwiprefix=sub-${bids[sub]}_ses-${bids[ses]}

# First return of variables discovered so far
checkoptvar scriptdir dwiname ddir dderivdir rderivdir dwiprefix

# Now move to more interesting things

# Create folders
replace_and mkdir ${tmp}
if_missing_do stop ${dderivdir}

dwi_mif="${tmp}/dwi.mif"
mrconvert ${dwi}.nii.gz ${dwi_mif} -nthreads ${nthreads} -quiet

echo ""
echo ""
echo "************************************"
echo "***    Compute MSMT response and run Constrained Spherical Deconvolution for ${dwiname}"
echo "************************************"
echo ""
echo ""

if_missing_do mkdir ${dderivdir}/response_check

if [[ ${tt5} == "yes" ]]
then
	if [[ -e ${rderivdir}/${dwiprefix}_T2w2dwi.nii.gz && -e ${rderivdir}/${dwiprefix}_UNIT12dwi.nii.gz ]]
	then
		5ttgen fsl -t2 ${rderivdir}/${dwiprefix}_T2w2dwi.nii.gz -premasked ${rderivdir}/${dwiprefix}_UNIT12dwi.nii.gz ${dderivdir}/5tt_seg.nii.gz
		tt5_img=${dderivdir}/5tt_seg.nii.gz
		run_dwi2response="dwi2response msmt_5tt ${dwi_mif} ${tt5_img} "
	else
		echo "!!! WARNING: 5TT MSMT algorithm requested but T2 and T1 images are missing. Using standard dhollander algorithm"
		run_dwi2response="dwi2response dhollander ${dwi_mif}"
	fi
else
	run_dwi2response="dwi2response dhollander ${dwi_mif}"
fi

run_dwi2response="${run_dwi2response} ${tmp}/wm.txt ${tmp}/gm.txt ${tmp}/csf.txt -voxels ${dderivdir}/response_check/voxels.nii.gz -nthreads ${nthreads}"

echo "${run_dwi2response}"
eval "${run_dwi2response}"

dwi2fod msmt_csd ${dwi_mif} \
		${tmp}/wm.txt ${tmp}/wm_fod.mif \
		${tmp}/gm.txt ${tmp}/gm_fod.mif \
		${tmp}/csf.txt ${tmp}/csf_fod.mif \
		-mask ${mask} -nthreads ${nthreads}

echo ""
echo ""
echo "************************************"
echo "***    Generate tractogram for ${dwiname}"
echo "************************************"
echo ""
echo ""

run_tckgen="tckgen -seed_dynamic ${tmp}/wm_fod.mif -maxlength ${maxlength} -select ${n_fibers} -nthreads ${nthreads}"

[[ ${tt5} == "yes" ]] && run_tckgen="${run_tckgen} -act ${tt5_img} -crop_at_gmwmi"

run_tckgen="${run_tckgen} ${tmp}/wm_fod.mif ${tmp}/tracks_initial.tck"

echo "${run_tckgen}"
eval "${run_tckgen}"


echo ""
echo ""
echo "************************************"
echo "***    Quantitative Re-weighting of ${dwiname}-based connectome"
echo "************************************"
echo ""
echo ""

act5tt=""
[[ ${tt5} == "yes" ]] && act5tt="-act ${tt5_img}"

[[ "${sift_version}" = "sift2" ]] && echo "Running SIFT2 (calculating track weights)..." \
	&& tcksift2 ${tmp}/tracks_initial.tck ${tmp}/wm_fod.mif ${tmp}/sift_weights.txt \
		${act5tt} -nthreads ${nthreads}

[[ "${sift_version}" = "sift" ]] && echo "Running SIFT (filtering tracks to 1M)..." \
	&& tcksift ${tmp}/tracks_initial.tck ${tmp}/wm_fod.mif ${tmp}/tracks_sift.tck \
		${act5tt} -term_number 1M -nthreads ${nthreads}

parcname=$( basename ${parc} )

echo ""
echo ""
echo "************************************"
echo "***    Compute ${dwiname}-based connectome using ${parcname}"
echo "************************************"
echo ""
echo ""

[[ "${sift_version}" = "sift2" ]] && echo "Using SIFT2 weights" \
	&& tck2connectome ${tmp}/tracks_initial.tck ${parc} ${dderivdir}/${dwiprefix}_${parcname}_connectome.csv \
		-tck_weights_in ${tmp}/sift_weights.txt \
		-out_assignment ${dderivdir}/${dwiprefix}_${parcname}_assignments.csv \
		-nthreads ${nthreads} -force

[[ "${sift_version}" = "sift" ]] && echo "Using SIFT filtered tracklist" \
	&& tck2connectome ${tmp}/tracks_sift.tck ${parc} ${dderivdir}/${dwiprefix}_${parcname}_connectome.csv \
		-out_assignment ${dderivdir}/${dwiprefix}_${parcname}_assignments.csv \
		-nthreads ${nthreads} -force

echo ""
echo "************************************"
echo "*** Connectome Generation Completed!"
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
