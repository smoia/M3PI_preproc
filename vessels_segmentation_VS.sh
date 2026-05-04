#!/usr/bin/env bash

#####
# Heavily Influenced by Marshall Xu's preprocessing on VesselBoost.
#####

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
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
		-anat)		anat=$2;shift;;		# A 3dMEEPI derivative file, specifically the grandaverage of the acquisitions (00.*_imgavg_preprocessed).

		-tmp)		tmp=$2;shift;;		# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)		debug=yes;;			# Turn on debug mode.

		-h)			displayhelp $0;;	# Display this help.
		-v)			version $0;exit 0;;	# Display the version.
		*)			echo "Wrong flag: $1";displayhelp 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar anat
checkoptvar tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT

### Remove nifti suffix
anat=$( removeniisfx ${anat} )

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

# #!# The file should be in a derivative folder, so bids[root] is the derivative folder already, not the real root 

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/../../code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_vesselssegmentVS.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/../../code/logs/${anatname}_log
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
anatprefix=sub-${bids[sub]}_ses-${bids[ses]}

# First return of variables discovered so far
checkoptvar adir

# Create folders
if_missing_do mkdir ${bids[root]}/VesSynthSegmentations

echo ""
echo ""
echo "************************************"
echo "***    Downsampling data twice"
echo "************************************"
echo ""
echo ""

for imgfile in ${bids[root]}/sub-*/ses-*/*${bids[suffix]}
do
	x=$( fslval ${imgfile} dim1 )
	y=$( fslval ${imgfile} dim2 )
	z=$( fslval ${imgfile} dim3 )
	for suffix in resampledorig downsampled
	do
		(( x/=2 ))
		(( y/=2 ))
		(( z/=2 ))
		echo "Preparing ${imgfile%.nii.gz}_${suffix}.nii.gz"
		ResampleImage 3 ${imgfile} ${imgfile%.nii.gz}_${suffix}.nii.gz ${x}x${y}x${z} 1 0
	done
done

source /opt/miniconda3/bin/activate
conda activate vessynth-env

python3 /opt/VesSynth/vessynth_test.py -i ${bids[root]}/sub-*/ses-*/*${bids[suffix]}.nii.gz -o ${bids[root]}/VesSynthSegmentations -mod T2star -t 0.05 0.1
python3 /opt/VesSynth/vessynth_test.py -i ${bids[root]}/sub-*/ses-*/*${bids[suffix]}_resampledorig.nii.gz -o ${bids[root]}/VesSynthSegmentations -mod T2star -t 0.05 0.1
python3 /opt/VesSynth/vessynth_test.py -i ${bids[root]}/sub-*/ses-*/*${bids[suffix]}_downsampled.nii.gz -o ${bids[root]}/VesSynthSegmentations -mod T2star -t 0.05 0.1

subs=()
sess=()
mapfile -t subs < <(find "${bids[root]}" -maxdepth 1 -type d -printf "%f\n" | grep -oP 'sub-\K[^_]+' | sort -u)
mapfile -t sess < <(find "${bids[root]}" -mindepth 2 -maxdepth 2 -type d -printf "%f\n" | grep -oP 'ses-\K[^_]+' | sort -u)

if_missing_do mkdir ${bids[root]}/manualsegready 

for sub in ${subs[@]}
do
	for ses in ${sess[@]}
	do
		# Set various stuff
		adir=${bids[root]}/sub-${sub}/ses-${ses}/anat
		anatprefix=00.sub-${sub}_ses-${ses}_${bids[suffix]}
		fileprefix=${bids[root]}/VesSynthSegmentations/${anatprefix}_imgavg_preprocessed

		# Oversample
		x=$( fslval ${fileprefix}_vessels_prob dim1 )
		y=$( fslval ${fileprefix}_vessels_prob dim2 )
		z=$( fslval ${fileprefix}_vessels_prob dim3 )

		for suffix in resampledorig downsampled
		do
			echo "Oversampling ${anatprefix} ${suffix} vessels probability maps"
			ResampleImage 3 ${fileprefix}_${suffix}_vessels_prob.nii.gz \
						  ${tmp}/${anatprefix}_${suffix}_oversampled_vessels_prob.nii.gz ${x}x${y}x${z} 1 0
		done

		# Dilate mask by ~7-8 mm
		3dmask_tool -input ${adir}/${anatprefix}_brain_mask.nii.gz \
					-prefix ${tmp}/${anatprefix}_mask_dilated.nii.gz \
					-dilate_input 40 -overwrite

		${bids[root]}/sub-${sub}/ses-${ses}/anat/
		3dcalc -a ${fileprefix}_vessels_prob.nii.gz \
			   -b ${tmp}/${anatprefix}_resampledorig_oversampled_vessels_prob.nii.gz \
			   -c ${tmp}/${anatprefix}_downsamples_oversampled_vessels_prob.nii.gz \
			   -m ${tmp}/${anatprefix}_mask_dilated.nii.gz \
			   -prefix ${bids[root]}/manualsegready/${anatprefix}_imgavg_preprocessed_vessels.nii.gz \
			   -expr "(step(a-0.05)+step(b-0.1)+step(c-0.1))*m" -overwrite

		fslmaths ${adir}/${anatprefix}_imgavg_preprocessed -mas ${tmp}/${anatprefix}_mask_dilated \
				 ${bids[root]}/manualsegready/${anatprefix}_imgavg_preprocessed_brain
	done
done

cd ${cwd}

echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"


if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
