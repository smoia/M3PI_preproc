#!/usr/bin/env bash

# shellcheck source=../utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/../utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
pepolardir=none
blipup=none
blipdown=none
applytopup=yes
workdir=/data/derivatives/vessels
modality=func
acqparams=none
tmp=.
debug=no

### print input
printline=$( basename -- $0 )
echo "${printline}" "$@"
# Parsing required and optional variables with flags
# Also checking if a flag is the help request or the version
while [ ! -z "$1" ]
do
	case "$1" in
		-nii)	nii=$2;shift;;		# Nifti file to apply topup to

		-pepolardir)	pepolardir=$2;shift;;	# Directory containing PEPolar files from a previous run
		-blipup)		blipup=$2;shift;;		# File with same PE as nii for PEPolar estimation
		-blipdown)		blipdown=$2;shift;;		# File with opposite PE as nii for PEPolar estimation
		-estimateonly)	applytopup=no;;			# Estimate topup only, don't apply it to the input
		-workdir)		workdir=$2;shift;;		# Directory of nifti derivatives (derivatives root).
		-modality)		modality=$2;shift;;		# Directory of nifti derivatives (derivatives root).
		-acqparams)		acqparams=$2;shift;;	# File with acquisition parameters for topup. If none, program creates it.

		-tmp)		tmp=$2;shift;;				# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)		debug=yes;;					# Turn on debug mode.

		-h)			displayhelp $0;;			# Display help.
		-v)			version;exit 0;;			# Display version.
		*)			echo "Wrong flag: $1";displayhelp $0 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar nii
checkoptvar pepolardir blipup blipdown estimateonly workdir modality tmp debug

[[ ${debug} == "yes" ]] && set -x

### Remove nifti suffix
for var in nii blipup blipdown
do
	eval "${var}=$( removeniisfx ${var} )"
done

### Cath errors and exit on them
set -e
######################################
######### Script starts here #########
######################################

cwd=$(pwd)

niiname=$( basename ${nii} )

[[ "$niiname" =~ ^(sub-[^_]+)_(ses-[^_]+) ]] && \
	nderivdir=${workdir}/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${modality}

if_missing_do stop ${nderivdir}

## 01. PEpolar
# If there isn't an estimated field, make it.
if [[ ${pepolardir} == "none" && ${blipup} != "none" && ${blipdown} != "none" ]]
then
	echo "Preparing PEpolar map computation"
	if_missing_do stop ${blipup}.nii.gz
	if_missing_do stop ${blipdown}.nii.gz
	if_missing_do stop ${blipup}.json
	if_missing_do stop ${blipdown}.json

	pepolardir=${nderivdir}/${niiname}_topup

	replace_and mkdir ${pepolardir}
	fslmerge -t ${pepolardir}/mgdmap ${blipup} ${blipdown}

	if [[ ${acqparams} == "none" ]]
	then
		echo "Extracting acquisition parameters via MRtrix3"
		mrconvert ${blipup}.nii.gz ${tmp}/delete.nii.gz -export_pe_topup ${tmp}/blipup_topup -json_import ${blipup}.json
		mrconvert ${blipdown}.nii.gz ${tmp}/delete.nii.gz -export_pe_topup ${tmp}/blipdown_topup -json_import ${blipdown}.json -force
		cat ${tmp}/blipup_topup ${tmp}/blipdown_topup > ${pepolardir}/acqparam.txt
	fi

	echo "Computing PEpolar map for ${niiname}"
	topup --imain=${nderivdir}/mgdmap --datain=${pepolardir}/acqparam.txt --out=${nderivdir}/outtp --verbose

# If there isn't an estimated file and no image was given, break it.
elif [[ ${pepolardir} == "none" && ! -d ${nderivdir}/${niiname}_topup && ( ${blipup} == "none" || ${blipdown} == "none" ) ]]
then
	checkoptvar blipup blipdown
	echo "PEpolar image computation requires both to be declared."
	checkoptvar pepolardir
	echo "If you have a previously computed topup give the path to the right pepolar folder"
	exit 1

# If no image was given, and there _is_ an estimated file, fake it.
elif [[ ${pepolardir} == "none" && -d ${nderivdir}/${niiname}_topup && -e ${nderivdir}/${niiname}_topup/outtp.nii.gz ]]
then
	echo ""
	echo "WARNING: PEPolar folder was not specified, blip images were not specified, but there is a valid folder in ${nderivdir}/${niiname}_topup."
	echo "Using found folder as PEPolar folder."
	echo ""
	pepolardir=${nderivdir}/${niiname}_topup
fi

# 03.2. Applying the warping to the nifti volume
if [[ ${applytopup} == "yes" ]]
then
	if [[ ${pepolardir} != "none" ]]
	then
		[[ ! -d ${pepolardir} && -d ${nderivdir}/${pepolardir} ]] && pepolardir=${nderivdir}/${pepolardir} && \
			echo "Found folder ${pepolardir} in ${nderivdir}"

		if_missing_do stop ${pepolardir}

		# If a folder was given but it's not a valid folder, stop it.
		if [[ ! -e ${pepolardir}/outtp.nii.gz || ! -e ${pepolardir}/acqparam.txt ]]
		then
			checkoptvar pepolardir
			echo "Provided folder ${pepolardir} does not contain valid topup files"
			exit 1
		fi
	fi

	echo "Applying PEPOLAR map on ${nii}"
	applytopup --imain=${nii} --datain= ${pepolardir}/acqparam.txt --inindex=1 \
	--topup=${pepolardir}/outtp --out=${tmp}/${niiname}_tpp --verbose --method=jac

fi

cd ${cwd}

if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi