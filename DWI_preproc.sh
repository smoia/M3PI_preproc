#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

displayhelp() {
echo "Required:"
echo "dwi"
echo "Optional:"
echo "aref tmp"
exit ${1:-0}
}

# Check if there is input

if [[ ( $# -eq 0 ) ]]
then
	displayhelp
fi

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
		-dwi)		dwi=$2;shift;;

		-TEs)		TEs="$2";shift;;
		-tmp)		tmp=$2;shift;;

		-h)			displayhelp;;
		-v)			version;exit 0;;
		*)			echo "Wrong flag: $1";displayhelp 1;;
	esac
	shift
done

# Check input
checkreqvar dwi
checkoptvar tmp debug

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
[[ "$dwiname" =~ ^sub-([0-9]+)_ses-([0-9]+)_(acq-([^_]+))_([^\.]+)\.nii\.gz$ ]] && \
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


# What to do, the rest is old stuff
# See https://community.mrtrix.org/t/dwidenoise-correct-use/586/4
# And https://community.mrtrix.org/t/combining-two-dwi-images-with-b800-and-b2000/7115


# mrconvert each file

# dwicat all files together

# dwidenoise all

# mrconvert back to nifti bvals and bvecs

# Brain mask, maybe one bad one first for topup on average
# See dwi2mask

# Then see dwipreproc
# Topup ? With b=0? Or with SBRef? Or with fieldmaps?
# Applytopup? But maybe in eddy already?
# Eddy

# Maybe brain mask again?

# Bias field correction (why only now?) with ants N4
# See dwibiascorrect

# ...?

# post proc

# dwi2response to estiamte response function with msmt_5tt method
# See https://mrtrix.readthedocs.io/en/0.3.16/concepts/response_function_estimation.html

# dwi2fod for multi-shell multi-tissue constrained spherical deconvolution

# tckgen for initial tractogram

# tcksift for SIFT OR SIFT2? MAYBE OPTION

# tck2connectome for connectome.







# Crop and bias field correct dwis
for dwifile in ${dwiprefix}_*_${dwisuffix}.nii.gz
do
	dwifile=$( basename $( removeniisfx ${dwifile} ) )

	[[ "$dwifile" =~ (.*)_echo-([^_]+) ]] && boxfile=${BASH_REMATCH[1]} && echo=${BASH_REMATCH[2]}

	echo ""
	echo ""
	echo "************************************"
	echo "***    Crop and correct bias field ${dwifile}"
	echo "************************************"
	echo ""
	echo ""

	## 01.Crop based on the first echo
	if [[ "${echo}" -eq 1 ]]
	then
		3dAutobox -extent_ijkord_to_file ${tmp}/${boxfile}_box ${dwifile}.nii.gz
	fi

	coords=$( awk '{ printf "%s %s ", $2, $3 - $2 + 1 }' ${tmp}/${boxfile}_box )
	fslroi ${dwifile}.nii.gz ${tmp}/${dwifile}_ab.nii.gz ${coords}
	## 02. Bias Field Correction with ANTs
	# 02.1. Truncate (0.01) for Bias Correction
	echo "Performing BFC on ${dwifile}"
	ImageMath 3 ${tmp}/${dwifile}_trunc.nii.gz TruncateImageIntensity ${tmp}/${dwifile}_ab.nii.gz 0.02 0.98 256
	# 02.2. Bias Correction
	N4BiasFieldCorrection -d 3 -i ${tmp}/${dwifile}_trunc.nii.gz -o ${tmp}/${dwifile}_bfc.nii.gz
done

# Prepare echoes averaging and T2* mapping
dwifiles=()

# Check all possible acqs and runs when needed 
mapfile -t acqs < <(find "${ddir}" -type f -printf "%f\n" | grep "${dwisuffix}" | grep -oP '_acq-\K[^_]+' | sort -u)

for a in "${acqs[@]}"
do
	workdwi=${dwiprefix}_acq-${a}

	mapfile -t runs < <(find "${ddir}" -type f -printf "%f\n" | grep "${workdwi}" | grep "${dwisuffix}" | grep -oP '_run-\K[^_]+' | sort -u)

	if [ ${#runs[@]} -eq 0 ] || [[ -z "${runs[0]}" && ${#runs[@]} -eq 1 ]]
	then
		dwifiles+=("${workdwi}")
	else
		for r in "${runs[@]}"
		do
			dwifiles+=("${workdwi}_run-${r}")
		done
	fi
done

echo "************************************"
echo "***    Check variables"
echo "************************************"

echo "acqs are " "${acqs[@]}"
echo "runs are " "${runs[@]}"
echo "dwifiles are " "${dwifiles[@]}"

for i in "${!dwifiles[@]}"
do
	dwifile=${dwifiles[i]}

	echo ""
	echo ""
	echo "************************************"
	echo "***    Dealing with echoes of ${dwifile}"
	echo "************************************"
	echo ""
	echo ""

	echo ""
	echo "---------------------------"
	echo "MAKE SURE PYTHON IS CORRECT"
	echo "---------------------------"
	alias python=/usr/bin/python
	alias python3=/usr/bin/python3
	echo "Python: $( which python ) $( which python3 )"
	echo ""

	echo ""
	echo "--------------"
	echo "Running t2smap"
	echo "--------------"
	echo "Python: $( which python ) $( which python3 )"


	# T2* mapping and optimal combination
	t2smap -d ${tmp}/${dwifile}_echo-?_${dwisuffix}_bfc.nii.gz --masktype none -e ${TEs} --out-dir ${tmp}/${dwifile}_TED
	fslmaths ${tmp}/${dwifile}_TED/desc-optcom_bold.nii.gz ${tmp}/${dwifile}_optcom_${dwisuffix}.nii.gz -odt float
	fslmaths ${tmp}/${dwifile}_TED/T2starmap.nii.gz ${tmp}/${dwifile}_t2star_${dwisuffix}.nii.gz -odt float

	# echo average
	# [ you can substitute this average step with your code if you prefer ]
	3dMean -prefix ${tmp}/${dwifile}_echoavg_${dwisuffix}.nii.gz ${tmp}/${dwifile}_echo-?_${dwisuffix}_bfc.nii.gz

	# sampling
	alias python=/usr/bin/python
	alias python3=/usr/bin/python3
	echo "--------------"
	echo "Running resampling"
	echo "--------------"
	echo "Python: $( which python ) $( which python3 )"

	${scriptdir}/resample.py ${tmp} ${dwifile} ${dwisuffix} 

	# realign to vesselref (first file in input)
	echo ""
	echo ""
	echo "************************************"
	echo "***    Spatially coregister ${dwifile}"
	echo "************************************"
	echo ""
	echo ""
	if (( i == 0 ))
	then
		if_missing_do copy ${tmp}/${dwifile}_echoavg_${dwisuffix}.nii.gz ${rderivdir}/sub-${sub}_vesselref_downsampled.nii.gz
		if_missing_do copy ${tmp}/${dwifile}_echoavg_upsampled_${dwisuffix}.nii.gz ${regref}
		if_missing_do copy ${tmp}/${dwifile}_echoavg_upsampled_${dwisuffix}.nii.gz ${dderivdir}/${dwifile}_echoavg_${dwisuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${dwifile}_optcom_upsampled_${dwisuffix}.nii.gz ${dderivdir}/${dwifile}_optcom_${dwisuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${dwifile}_t2star_upsampled_${dwisuffix}.nii.gz ${dderivdir}/${dwifile}_t2star_${dwisuffix}2vesselref.nii.gz
	else
		flirt -in ${tmp}/${dwifile}_echoavg_upsampled_${dwisuffix} -ref ${regref} -cost normcorr -searchcost normcorr -dof 6 \
		-omat ${rderivdir}/${dwifile}2vesselref_fsl.mat -o ${dderivdir}/${dwifile}_echoavg_${dwisuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${dwifile}_optcom_upsampled_${dwisuffix} -ref ${regref} \
		-init ${rderivdir}/${dwifile}2vesselref_fsl.mat -applyxfm -o ${dderivdir}/${dwifile}_optcom_${dwisuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${dwifile}_t2star_upsampled_${dwisuffix} -ref ${regref} \
		-init ${rderivdir}/${dwifile}2vesselref_fsl.mat -applyxfm -o ${dderivdir}/${dwifile}_t2star_${dwisuffix}2vesselref.nii.gz
	fi
done

echo ""
echo ""
echo "************************************"
echo "***    Average ${dwiname}"
echo "************************************"
echo ""
echo ""

# Average all echo averages, optcoms, and t2* maps
3dMean -prefix ${dderivdir}/00.${dwiprefix}_${dwisuffix}_esavgd_preprocessed.nii.gz ${dderivdir}/${dwiprefix}_*_echoavg_${dwisuffix}2vesselref.nii.gz
3dMean -prefix ${dderivdir}/00.${dwiprefix}_${dwisuffix}_optcom_preprocessed.nii.gz ${dderivdir}/${dwiprefix}_*_optcom_${dwisuffix}2vesselref.nii.gz
3dMean -prefix ${dderivdir}/00.${dwiprefix}_${dwisuffix}_t2star_preprocessed.nii.gz ${dderivdir}/${dwiprefix}_*_t2star_${dwisuffix}2vesselref.nii.gz

echo ""
echo ""
echo "************************************"
echo "***    Brain extract 00.${dwiprefix}_${dwisuffix}_esavgd_preprocessed"
echo "************************************"
echo ""
echo ""

# Brain extraction
bet ${dderivdir}/00.${dwiprefix}_${dwisuffix}_esavgd_preprocessed.nii.gz ${tmp}/dwi_brain.nii.gz -R -f 0.5 -g 0 -n -m
mv ${tmp}/dwi_brain_mask.nii.gz ${dderivdir}/00.${dwiprefix}_${dwisuffix}_mask

cd ${cwd}


# Final output of the preprocessing:
# ${dderivdir}/00.${dwiprefix}_${dwisuffix}_esavgd_preprocessed.nii.gz
# ${dderivdir}/00.${dwiprefix}_${dwisuffix}_optcom_preprocessed.nii.gz
# ${dderivdir}/00.${dwiprefix}_${dwisuffix}_t2star_preprocessed.nii.gz
# ${dderivdir}/00.${dwiprefix}_${dwisuffix}_mask.nii.gz

echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"


if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
