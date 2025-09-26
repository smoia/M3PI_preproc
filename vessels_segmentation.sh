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
checkoptvar TEs tmp debug

[[ ${debug} == "yes" ]] && set -x

### Remove nifti suffix
anat=$( removeniisfx ${anat} )

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

# Parse anat filename and force right folder's absolute path pt. 1
workdir=$( dirname $( realpath ${anat} ) | sed -E 's|/sub-[^_]+/ses-[^_]+/anat||')
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
anatname=$( basename ${anat} )

if_missing_do stop ${workdir}
if_missing_do mkdir ${workdir}/logs

# Preparing log folder and log file, removing the previous one
logfile=${workdir}/logs/${anatname}_log
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
checkoptvar TEs tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parse BIDS info ${anatname}"
echo "************************************"
echo ""
echo ""

# Parse anat filename and force right folder's absolute path pt. 2
[[ "$anatname" =~ 00.sub-([^_]+)_ses-([^_]+)_([^\.]+)$ ]] && \
	sub=${BASH_REMATCH[1]} && \
	ses=${BASH_REMATCH[2]} && \
	anatsuffix=${BASH_REMATCH[3]}

anatprefix=sub-${sub}_ses-${ses}
tmp=${tmp}/sub-${sub}_ses-${ses}_vesselssegment

# First return of variables discovered so far
checkoptvar workdir scriptdir anatname sub ses anatprefix anatsuffix tmp

# Create folders
replace_and mkdir ${tmp}
if_missing_do mkdir ${tmp}/deskulled
if_missing_do mkdir ${workdir}/segmentations/masks
if_missing_do mkdir ${workdir}/segmentations/prediction

echo ""
echo ""
echo "************************************"
echo "***    Final processing for VesselBoost 00.${anatprefix}_${anatsuffix}"
echo "************************************"
echo ""
echo ""

# Normalise
ImageMath 3 ${tmp}/${anatprefix}_${anatsuffix}_nrmd.nii.gz Normalize ${anat}.nii.gz

# Secondary, more robust Bias Field Correction
N4BiasFieldCorrection -d 3 -i ${tmp}/${anatprefix}_${anatsuffix}_nrmd.nii.gz \
                        -o ${tmp}/${anatprefix}_${anatsuffix}_bfcvb.nii.gz \
                        -b [10,3] -c [100x100x100x100,0.0] -v 1

# Brain extraction with freesurfer
${scriptdir}/blocks/brainmask.sh -nii ${tmp}/${anatprefix}_${anatsuffix}_bfcvb.nii.gz -method fsss -tmp ${tmp}
mv ${tmp}/${anatprefix}_${anatsuffix}_bfcvb_brain_mask.nii.gz ${workdir}/segmentations/masks/${anatprefix}_brain_mask_fsss.nii.gz
mv ${tmp}/${anatprefix}_${anatsuffix}_bfcvb_brain.nii.gz mv ${tmp}/deskulled/${anatprefix}_${anatsuffix}_bfcvb_brain

echo ""
echo ""
echo "************************************"
echo "***    Segment (VesselBoost) 00.${anatprefix}_${anatsuffix}"
echo "************************************"
echo ""
echo ""

conda activate vessel_boost

/opt/VesselBoost/prediction.py --ds_path ${tmp}/deskulled --out_path ${workdir}/segmentations/prediction \
							   --pretrained /opt/VesselBoost/saved_models/t2s_mod_ep1k2_0728 --prep_mode 4

cd ${cwd}

echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"


if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
