#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
tmp=/tmp
debug=no
TEs="9.46 24.66 39.86"

### print input
printline=$( basename -- $0 )
echo "${printline}" "$@"
printcall="${printline} $*"
# Parsing required and optional variables with flags
# Also checking if a flag is the help request or the version
while [ ! -z "$1" ]
do
	case "$1" in
		-anat)		anat=$2;shift;;		# Any 3dMEEPI of an echo/acq/run series, the others will be found automatically.

		-TEs)		TEs="$2";shift;;	# Echo Times of the expected input. Must be specified within " "
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
if_missing_do mkdir ${workdir}/derivatives/vessels/logs

# Preparing log folder and log file, removing the previous one
logfile=${workdir}/derivatives/vessels/logs/${anatname}_log
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
[[ "$anatname" =~ sub-([^_]+)_ses-([^_]+)(_acq-([^_]+))?(_run-([^_]+))?(_echo-([^_]+))_([^\.]+)$ ]] && \
	sub=${BASH_REMATCH[1]} && \
	ses=${BASH_REMATCH[2]} && \
	acq=${BASH_REMATCH[4]:-} && \
	run=${BASH_REMATCH[6]:-} && \
	echo=${BASH_REMATCH[8]:-} && \
	anatsuffix=${BASH_REMATCH[9]}

adir=${workdir}/sub-${sub}/ses-${ses}/anat
aderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/anat
rderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/reg
regref=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/reg/sub-${sub}_vesselref.nii.gz
anatprefix=sub-${sub}_ses-${ses}
tmp=${tmp}/sub-${sub}_ses-${ses}_vesselsbfc

# First return of variables discovered so far
checkoptvar workdir scriptdir anatname sub ses acq run echo adir aderivdir rderivdir regref anatprefix anatsuffix tmp


# Now move to more interesting things
cd ${adir} || exit 1

# Create folders
replace_and mkdir ${tmp}
if_missing_do mkdir ${aderivdir}
if_missing_do mkdir ${rderivdir}

[[ ! -d ${aderivdir} ]] && exit 2
[[ ! -d ${rderivdir} ]] && exit 2

# Crop and bias field correct anats
for anatfile in ${anatprefix}_*_${anatsuffix}.nii.gz
do
	anatfile=$( basename $( removeniisfx ${anatfile} ) )

	[[ "$anatfile" =~ (.*)_echo-([^_]+) ]] && boxfile=${BASH_REMATCH[1]} && echo=${BASH_REMATCH[2]}

	echo ""
	echo ""
	echo "************************************"
	echo "***    Crop and correct bias field ${anatfile}"
	echo "************************************"
	echo ""
	echo ""

	## 01.Crop based on the first echo
	if [[ "${echo}" -eq 1 ]]
	then
		3dAutobox -extent_ijkord_to_file ${tmp}/${boxfile}_box ${anatfile}.nii.gz
	fi

	coords=$( awk '{ printf "%s %s ", $2, $3 - $2 + 1 }' ${tmp}/${boxfile}_box )
	fslroi ${anatfile}.nii.gz ${tmp}/${anatfile}_ab.nii.gz ${coords}
	## 02. Bias Field Correction with ANTs
	# 02.1. Truncate (0.01) for Bias Correction
	echo "Performing BFC on ${anatfile}"
	ImageMath 3 ${tmp}/${anatfile}_trunc.nii.gz TruncateImageIntensity ${tmp}/${anatfile}_ab.nii.gz 0.02 0.98 256
	# 02.2. Bias Correction
	N4BiasFieldCorrection -d 3 -i ${tmp}/${anatfile}_trunc.nii.gz -o ${tmp}/${anatfile}_bfc.nii.gz
done

# Prepare echoes averaging and T2* mapping
anatfiles=()

# Check all possible acqs and runs when needed 
mapfile -t acqs < <(find "${adir}" -type f -printf "%f\n" | grep "${anatsuffix}" | grep -oP '_acq-\K[^_]+' | sort -u)

for a in "${acqs[@]}"
do
	workanat=${anatprefix}_acq-${a}

	mapfile -t runs < <(find "${adir}" -type f -printf "%f\n" | grep "${workanat}" | grep "${anatsuffix}" | grep -oP '_run-\K[^_]+' | sort -u)

	if [ ${#runs[@]} -eq 0 ] || [[ -z "${runs[0]}" && ${#runs[@]} -eq 1 ]]
	then
		anatfiles+=("${workanat}")
	else
		for r in "${runs[@]}"
		do
			anatfiles+=("${workanat}_run-${r}")
		done
	fi
done

echo "************************************"
echo "***    Check variables"
echo "************************************"

echo "acqs are " "${acqs[@]}"
echo "runs are " "${runs[@]}"
echo "anatfiles are " "${anatfiles[@]}"

for i in "${!anatfiles[@]}"
do
	anatfile=${anatfiles[i]}

	echo ""
	echo ""
	echo "************************************"
	echo "***    Dealing with echoes of ${anatfile}"
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
	t2smap -d ${tmp}/${anatfile}_echo-?_${anatsuffix}_bfc.nii.gz --masktype none -e ${TEs} --out-dir ${tmp}/${anatfile}_TED
	fslmaths ${tmp}/${anatfile}_TED/desc-optcom_bold.nii.gz ${tmp}/${anatfile}_optcom_${anatsuffix}.nii.gz -odt float
	fslmaths ${tmp}/${anatfile}_TED/T2starmap.nii.gz ${tmp}/${anatfile}_t2star_${anatsuffix}.nii.gz -odt float

	# echo average
	# [ you can substitute this average step with your code if you prefer ]
	3dMean -prefix ${tmp}/${anatfile}_echoavg_${anatsuffix}.nii.gz ${tmp}/${anatfile}_echo-?_${anatsuffix}_bfc.nii.gz

	for imgtype in echoavg optcom t2star
	do
		imgfile=${tmp}/${anatfile}_${imgtype}_${anatsuffix}.nii.gz
		x=$( fslval ${imgfile} dim1 ) 
		y=$( fslval ${imgfile} dim2 ) 
		z=$( fslval ${imgfile} dim3 )
		(( x*=2 ))
		(( y*=2 ))
		(( z*=2 ))
		ResampleImage 3 ${imgfile} ${tmp}/${anatfile}_${imgtype}_upsampled_${anatsuffix}.nii.gz ${x}x${y}x${z} 1 0
	done

	# realign to vesselref (first file in input)
	echo ""
	echo ""
	echo "************************************"
	echo "***    Spatially coregister ${anatfile}"
	echo "************************************"
	echo ""
	echo ""
	if (( i == 0 ))
	then
		if_missing_do copy ${tmp}/${anatfile}_echoavg_${anatsuffix}.nii.gz ${rderivdir}/sub-${sub}_vesselref_downsampled.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix}.nii.gz ${regref}
		if_missing_do copy ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix}.nii.gz ${aderivdir}/${anatfile}_echoavg_${anatsuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_optcom_upsampled_${anatsuffix}.nii.gz ${aderivdir}/${anatfile}_optcom_${anatsuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_t2star_upsampled_${anatsuffix}.nii.gz ${aderivdir}/${anatfile}_t2star_${anatsuffix}2vesselref.nii.gz
	else
		flirt -in ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix} -ref ${regref} -cost normcorr -searchcost normcorr -dof 6 \
		-omat ${rderivdir}/${anatfile}2vesselref_fsl.mat -o ${aderivdir}/${anatfile}_echoavg_${anatsuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${anatfile}_optcom_upsampled_${anatsuffix} -ref ${regref} \
		-init ${rderivdir}/${anatfile}2vesselref_fsl.mat -applyxfm -o ${aderivdir}/${anatfile}_optcom_${anatsuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${anatfile}_t2star_upsampled_${anatsuffix} -ref ${regref} \
		-init ${rderivdir}/${anatfile}2vesselref_fsl.mat -applyxfm -o ${aderivdir}/${anatfile}_t2star_${anatsuffix}2vesselref.nii.gz
	fi
done

echo ""
echo ""
echo "************************************"
echo "***    Average ${anatname}"
echo "************************************"
echo ""
echo ""

# Average all echo averages, optcoms, and t2* maps
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_imgavg_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_echoavg_${anatsuffix}2vesselref.nii.gz
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_optcom_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_optcom_${anatsuffix}2vesselref.nii.gz
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_t2star_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_t2star_${anatsuffix}2vesselref.nii.gz

echo ""
echo ""
echo "************************************"
echo "***    Brain extract 00.${anatprefix}_${anatsuffix}_imgavg_preprocessed"
echo "************************************"
echo ""
echo ""

${scriptdir}/blocks/brainmask.sh -nii ${aderivdir}/00.${anatprefix}_${anatsuffix}_imgavg_preprocessed.nii.gz -method bet -tmp ${tmp} -nobrain
mv ${aderivdir}/00.${anatprefix}_${anatsuffix}_imgavg_preprocessed_brain_mask.nii.gz ${aderivdir}/00.${anatprefix}_${anatsuffix}_brain_mask.nii.gz

cd ${cwd}

# Final output of the preprocessing:
# ${aderivdir}/00.${anatprefix}_${anatsuffix}_imgavg_preprocessed.nii.gz
# ${aderivdir}/00.${anatprefix}_${anatsuffix}_optcom_preprocessed.nii.gz
# ${aderivdir}/00.${anatprefix}_${anatsuffix}_t2star_preprocessed.nii.gz
# ${aderivdir}/00.${anatprefix}_${anatsuffix}_mask.nii.gz

echo ""
echo ""
echo "************************************"
echo "***    Preproc completed!"
echo "************************************"


if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
