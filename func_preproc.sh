#!/usr/bin/env bash

# shellcheck source=./utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

# Check if there is input
[[ ( $# -eq 0 ) ]] && displayhelp $0 1

# Preparing the default values for variables
TEs="10.6 28.69 46.78 64.87 82.96"
mrefvol=default
preproc_echoes=yes
preproc_optcom=yes
voldiscard=10
despike=no
slicetimeinterp=none
fdthr=.3
outthr=.05
polort=4        # AFNI suggests 1 degree every 150 seconds.
den_motreg=yes
den_meica=no
den_tissues=no
applynuisance=no
fwhm=none
greyplot=no
excluded_tasks=none
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
		-func)		func=$2;shift;;		# The main func of the dataset. If present, the T2w will be also be processed and used.

		-TEs)				TEs="$2";shift;;			# TEs of multi-echo files.
		-mrefvol)			mrefvol=$2;shift;;			# Use a specific file for motion realignment reference (e.g. a specific SBRef file) (provide full path). If set to "task", use the specific task SBRef, if set to "none", take the volume average. Otherwise, use the universal SBRef.
		-only_optcom)		preproc_echoes=no;;			# Process optimally combined signal volume only, do not process echo volumes further than optimal combination.
		-only_echoes)		preproc_optcom=no;;			# Process echoes volumes only, do not optimally combine the signal.
		-voldiscard)		voldiscard=$2;shift;;		# Set the initial volumes to discard due to magnetization stability (or just cause they're empty).
		-despike)			despike=yes;;				# Despike functional data in input.
		-slicetimeinterp)	slicetimeinterp=$2;shift;;	# Apply slice time interpolation (provide file with timings).
		-fdthr)				fdthr=$2;shift;;			# FD threshold above which volume is tagged for censoring. This DOES NOT apply censoring automatically.
		-outthr)			outthr=$2;shift;;			# Outcount threshold above which volume is tagged for censoring. This DOES NOT apply censoring automatically.
		-polort)			polort=$2;shift;;			# Legendre Polynomial degrees to consider. Set to -1 to not include them.
		-den_motreg)		den_motreg=yes;;			# Add motion parameters (6+6 first derivatives) to the denoising matrix.
		-den_meica)			den_meica=yes;;				# Add MEICA rejected components to the denoising matrix. 
		-den_tissues)		den_tissues=yes;;			# Add tissue averages to the denoising matrix. 
		-applynuisance)		applynuisance=yes;;			# Actually apply denoising, otherwise the program just computes it.
		-fwhm)				fwhm=$2;shift;;				# FWHM of the Gaussian distribution to use as spatial smoothing kernel.
		-make_greyplots)	greyplot=yes;;				# Make greyplots (time consuming)!
		-exclude_tasks)		excluded_tasks=$2;shift;;	# Skip preproc of one or more tasks.

		-tmp)		tmp=$2;shift;;		# Folder for temporary files. If not in debug mode, it'll be deleted at the end.
		-debug)		debug=yes;;			# Turn on debug mode.

		-h)			displayhelp $0;;	# Display this help.
		-v)			version $0;exit 0;;	# Display the version.
		*)			echo "Wrong flag: $1";displayhelp 1;; # Anything else is wrong!
	esac
	shift
done

# Check input
checkreqvar func
checkoptvar mrefvol preproc_echoes preproc_optcom voldiscard despike slicetimeinterp \
			fdthr outthr polort den_motreg den_meica den_tissues applynuisance \
			fwhm greyplot excluded_tasks tmp debug

# Debug
[[ ${debug} == "yes" ]] && set -x && trap 'set +x' EXIT
[[ ${debug} == "no" ]] && trap '[ "${tmp}" != "/" ] && rm -rf ${tmp}' EXIT

### Remove nifti suffix
func=$( removeniisfx ${func})

# Derived variables
scriptdir=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )
funcname=$( basename ${func} )

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

# Parse func filename
declare -A bids
extract_BIDS_entities "${func}" bids echo

if_missing_do stop ${bids[root]}
if_missing_do mkdir ${bids[root]}/code/logs

# Create tmp folder
tmp="$(mktemp --tmpdir=${tmp} -d sub-${bids[sub]}_ses-${bids[ses]}_task-${bids[task]}_funcpreproc.XXXXXX)"

# Preparing log folder and log file, removing the previous one
logfile=${bids[root]}/code/logs/${funcname}_log
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
checkreqvar func
checkoptvar mrefvol preproc_echoes preproc_optcom voldiscard despike slicetimeinterp \
			fdthr outthr polort den_motreg den_meica den_tissues applynuisance \
			fwhm greyplot excluded_tasks tmp debug

echo "************************************"
echo "************************************"

echo ""
echo ""
echo "************************************"
echo "***    Parsed BIDS info ${funcname}"
echo "************************************"
echo ""
echo ""

checkoptvar bids

# Set various folders
fdir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/func
fmapdir=${bids[root]}/sub-${bids[sub]}/ses-${bids[ses]}/fmap
fderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/func
rderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-${bids[ses]}/reg

# First return of variables discovered so far
checkoptvar scriptdir funcname fdir fmapdir fderivdir rderivdir

# Find all right funcs in echoes order
funcfiles=()

mapfile -t echoes < <(find "${fdir}" -type f -printf "%f\n" | grep "${bids[filesuffix]}" | grep -oP '_echo-\K[^_]+' | sort -u)
echo "Found ${#echoes[*]} echoes: ${echoes[*]}"

mapfile -t tasks < <(find "${fdir}" -type f -printf "%f\n" | grep "${bids[filesuffix]}" | grep -oP '_task-\K[^_]+' | sort -u)
echo "Found ${#tasks[*]} tasks: ${tasks[*]}"

for task in ${tasks[@]}
do
	if [[ "${excluded_tasks}" != *"${task}"* ]]
	then
		funcprefix=${func%_task-*}_task-
		funcmid=${func#"${funcprefix}"} && funcmid=${funcmid%_echo-*}_echo-
		for e in ${echoes[@]}
		do
			#!# check that bids filesuffix has the extension inside.
			ffile=${funcprefix}${funcmid}${e}_${bids[filesuffix]}
			[[ -e ${ffile}.nii.gz ]] && funcfiles+=($( removeniisfx ${ffile}))
		done
	fi
done


# Create folders
if_missing_do mkdir ${fderivdir}

# Check if there is a topup folder already and if there are multiple, select the first one.
mapfile -t topupdirs < <(find "${fderivdir}/" -maxdepth 1 -type d -name "*topup*")
if [[ ${#topupdirs[@]} -gt 0 ]]; then topupdir=${topupdirs[0]}; else topupdir=""; fi

# Spat reference part 1: if it's default or a file
if [[ ${mrefvol} == "default" ]];
then
	echo "Checking for universal SBRef"

	unisbrefdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-01/reg

	if_missing_do stop ${unisbrefdir}

	echo "Copying universal SBRef in session reg folder"
	[[ ${bids[ses]} -gt 1 ]] && if_missing_do mkdir ${rderivdir} \
		&& cp ${unisbrefdir}/sbref* ${rderivdir}/. \
		&& cp ${unisbrefdir}/*T2w2sbref0*.mat ${rderivdir}/.

	mref=${rderivdir}/sbref_brain
fi

if [[ ${mrefvol} == *".nii.gz" ]]
then
	if [[ -e ${mrefvol} ]]
	then  
		mref=${mrefvol}
		if_missing_do mask ${mref}.nii.gz ${mref}_mask.nii.gz
	else
		echo "!!!  WARNING: ${mrefvol} not found, setting it to 'none'"
		mrefvol=none
	fi
fi

firstechoes=()
# Func preproc part 1: all echo volumes.
for funcfile in ${funcfiles[@]}
do
	funcname=$( basename ${funcfile} )
	funcprefix=${funcname%"_${bids[filesuffix]}"}

	echo "************************************"
	echo "*** Func correct ${funcname}"
	echo "************************************"
	echo "************************************"

	nTR=$(fslval ${funcfile} dim4)

	funcsource=${funcfile}
	
	# Spat reference part 2: if it's none or task-based
	if [[ ${funcprefix} == *"echo-1"* ]]
	then
		if [[ ${mrefvol} == "none" ]]
		then
			# create mask & mref - this should trigger only on first run
			fslmaths ${funcsource} -Tmean ${tmp}/${funcprefix}_avg

			if [ -z "${topupdir}" ] || [ ! -d "${topupdir}" ]
			then
				echo "No previous topup run found, running it anew"
				blipup=$(find "${fmapdir}/" -maxdepth 1 -name "sub-${bids[sub]}_ses-${bids[ses]}*AP*.nii.gz" | head -n 1)
				blipdown=$(find "${fmapdir}/" -maxdepth 1 -name "sub-${bids[sub]}_ses-${bids[ses]}*PA*.nii.gz" | head -n 1)

				${scriptdir}/blocks/pepolar.sh -nii ${tmp}/${funcprefix}_avg \
						-blipup ${blipup} \
						-blipdown ${blipdown} \
						-workdir ${bids[root]}/derivatives/vessels/ \
						-acqparams ${scriptdir}/acqparam_func.txt \
						-tmp ${tmp}
				topupdir=${fderivdir}/${funcprefix}_topup
			else
				echo "Found ${topupdir}, using it as previous run source"
				${scriptdir}/blocks/pepolar.sh -nii ${tmp}/${funcprefix}_avg \
						-pepolardir ${topupdir} \
						-workdir ${bids[root]}/derivatives/vessels/ \
						-tmp ${tmp}	
			fi

			ImageMath 3 ${tmp}/${funcprefix}_avg_trunc.nii.gz TruncateImageIntensity ${tmp}/${funcprefix}_avg_tpp.nii.gz 0.02 0.98 256

			brain_extract -nii ${tmp}/${funcprefix}_avg_trunc -method fsss -tmp ${tmp}
			
			mref=${fderivdir}/${funcprefix}_brain
			
			mv ${tmp}/${funcprefix}_avg_trunc_brain.nii.gz ${mref}.nii.gz
			mv ${tmp}/${funcprefix}_avg_trunc_brain_mask.nii.gz ${mref}_mask.nii.gz

		elif [[ ${mrefvol} == "task" ]]
		then
			mref=${fderivdir}/${funcname%_bold*}_sbref_brain
		fi
	else
		[[ ${mrefvol} == "none" ]] && mref=${fderivdir}/${funcprefix%_echo-*}_echo-1_brain
		[[ ${mrefvol} == "task" ]] && fsfx=${funcname%_bold*}_sbref_brain \
			&& mref=${fderivdir}/${funcprefix%_echo-*}_echo-1_${fsfx#_echo-?_}
	fi
	mask=${mref}_mask

	# Now to the main file
	if [[ "${nTR}" -gt "1" ]]
	then
		# discard volumes
		[[ "${voldiscard}" -gt "0" ]] && fslroi ${funcsource} ${tmp}/${funcprefix}_dsd ${voldiscard} -1 \
			&& funcsource=${tmp}/${funcprefix}_dsd

		[[ ${greyplot} == "yes" ]] && echo "Create Greyplot ${funcname} pre-preproc" \
			&& 3dGrayplot -input ${funcsource}.nii.gz -mask ${mask}.nii.gz \
						  -prefix ${fderivdir}/${funcprefix}_gp_pre.png -dimen 1800 1200 \
						  -polort ${polort} -peelorder -percent -range 3

		3dToutcount -mask ${mask}.nii.gz -fraction -polort 5 \
					-legendre ${funcsource}.nii.gz > ${fderivdir}/${funcprefix}_outcount.1D

		[[ "${despike}" == "yes" ]] && echo "Despike ${funcname}" \
			&& 3dDespike -prefix ${tmp}/${funcprefix}_dsk.nii.gz ${funcsource}.nii.gz \
			&& funcsource=${tmp}/${funcprefix}_dsk

		if [[ "${slicetimeinterp}" != "none" ]]
		then
			echo "Slice Interpolate ${funcname}"
			3dTshift -Fourier -prefix ${tmp}/${funcprefix}_si.nii.gz \
					-tpattern ${slicetimeinterp} -overwrite \
					${funcsource}.nii.gz
			funcsource=${tmp}/${funcprefix}_si

			[[ ${greyplot} == "yes" ]] && echo "Create Greyplot ${funcname} post slice interpolation" \
				&& 3dGrayplot -input ${funcsource}.nii.gz -mask ${mask}.nii.gz \
							  -prefix ${fderivdir}/${funcprefix}_gp_sliceinterp.png -dimen 1800 1200 \
							  -polort ${polort} -peelorder -percent -range 3

		fi
	fi
	[[ "${funcname}" == *"echo-1"* ]] && firstechoes+=(${funcsource})
done

if [[ "${den_tissues}" == "yes" ]]
then
	echo "************************************"
	echo "*** Coregister anatomical segmentation to ${funcprefix}"
	echo "************************************"
	echo "************************************"

	aderivdir=${bids[root]}/derivatives/vessels/sub-${bids[sub]}/ses-02/anat
	seg=${aderivdir}/sub-${bids[sub]}_ses-02_UNIT1_seg_eroded.nii.gz
	seg2t2w=${aderivdir}/../reg/sub-${bids[sub]}_ses-02_T2w2UNIT10GenericAffine.mat
	[[ ${mrefvol} == "default" ]] && t2w2sbref=${rderivdir}/sub-${bids[sub]}_ses-02_T2w2sbref0GenericAffine.mat \
		&& seg2sbref=${fderivdir}/seg2sbref.nii.gz \
		&& antsApplyTransforms -d 3 -i ${seg} -r ${mref}.nii.gz -o ${seg2sbref} \
							  -n Linear -t ${t2w2sbref} -t ${seg2t2w}
fi

# Quick check if there was a topup run in the session, if not estimate it.
echo "************************************"
echo "*** Check topup for ${funcname}"
echo "************************************"
echo "************************************"

if [ -z "${topupdir}" ] || [ ! -d "${topupdir}" ]
then
	echo "No previous topup run found, estimating it anew"
	blipup=$(find "${fmapdir}/" -maxdepth 1 -name "sub-${bids[sub]}_ses-${bids[ses]}*AP*.nii.gz" | head -n 1)
	blipdown=$(find "${fmapdir}/" -maxdepth 1 -name "sub-${bids[sub]}_ses-${bids[ses]}*PA*.nii.gz" | head -n 1)

	${scriptdir}/blocks/pepolar.sh -nii ${firstechoes[0]}_fakeextrabit \
			-blipup ${blipup} \
			-blipdown ${blipdown} \
			-nref ${mref}.nii.gz \
			-workdir ${bids[root]}/derivatives/vessels/ \
			-acqparams ${scriptdir}/acqparam_func.txt \
			-estimateonly \
			-tmp ${tmp}
	topupdir=${fderivdir}/$( basename ${firstechoes[0]} )_topup
else
	echo "Found ${topupdir}, using it as previous run source"
fi

for funcsource in "${firstechoes[@]}"
do
	nTR=$(fslval ${funcsource} dim4)
	TR=$(fslval ${funcsource} pixdim4)
	funcprefix=$( basename ${funcsource%_echo-*}_echo-1 )

	# Func preproc part 2: Spacecomp

	echo "************************************"
	echo "*** Func spacecomp ${funcprefix}"
	echo "************************************"
	echo "************************************"

	[[ ${mrefvol} == "none" ]] && mref=${fderivdir}/${funcprefix}_brain && mask=${mref}_mask
	[[ ${mrefvol} == "task" ]] && fsfx=${funcname%_bold*}_sbref_brain \
		&& mref=${fderivdir}/${funcprefix%_echo-*}_echo-1_${fsfx#_echo-?_} && mask=${mref}_mask

	# Start with echo 1
	[[ "${nTR}" -gt "1" ]] && ${scriptdir}/blocks/compute_fddvars.py -in ${funcsource}.nii.gz -m ${mask}.nii.gz \
		&& mv ${funcsource}_dvars.par ${fderivdir}/${funcprefix}_dvars_pre.par

	echo "McFlirting ${funcprefix} & masking"
	if [[ -d ${tmp}/${funcprefix}_mcf.mat ]]; then rm -r ${tmp}/${funcprefix}_mcf.mat; fi
	if [[ -d ${rderivdir}/${funcprefix}_mcf.mat ]]; then rm -r ${rderivdir}/${funcprefix}_mcf.mat; fi
	mcflirt -in ${funcsource} -r ${mref} -out ${tmp}/${funcprefix}_mcf -stats -mats -plots
	mv -f ${tmp}/${funcprefix}_mcf.mat ${rderivdir}/.
	mv -f ${tmp}/${funcprefix}_mcf_*.nii.gz ${fderivdir}/.

	fslmaths ${tmp}/${funcprefix}_mcf -mas ${mask} ${tmp}/${funcprefix}_bet

	if [[ "${nTR}" -gt "1" ]]
	then
		1d_tool.py -infile ${tmp}/${funcprefix}_mcf.par -demean -write ${fderivdir}/${funcprefix}_mcf_demean.par -overwrite
		1d_tool.py -infile ${fderivdir}/${funcprefix}_mcf_demean.par -derivative -demean -write ${fderivdir}/${funcprefix}_mcf_deriv1.par -overwrite

		${scriptdir}/blocks/compute_fddvars.py -in ${tmp}/${funcprefix}_mcf.nii.gz -m ${mask}.nii.gz
		mv ${tmp}/${funcprefix}_mcf_dvars.par ${fderivdir}/${funcprefix}_dvars_post.par
		mv ${tmp}/${funcprefix}_fd.par ${fderivdir}/${funcprefix}_fd.par

		[[ ${greyplot} == "yes" ]] && echo "Create Greyplot ${funcname} post motion" \
								   && 3dGrayplot -input ${tmp}/${funcprefix}_mcf.nii.gz -mask ${mask}.nii.gz \
												 -prefix ${fderivdir}/${funcprefix}_gp_motrealign.png -dimen 1800 1200 \
												 -polort ${polort} -peelorder -percent -range 3

		echo "Preparing censoring"
		1deval -a ${fderivdir}/${funcprefix}_fd.par -b=${fdthr} -c ${fderivdir}/${funcprefix}_outcount.1D -d=${outthr} -expr 'isnegative(a-b)*isnegative(c-d)' > ${fderivdir}/${funcprefix}_censor.1D
	fi

	(( nTR-- ))
	firstechoprefix=${funcprefix}
	firstechosource=${funcsource}

	# Now continue with all other echoes, as well as repeat on first echo cause apparently it's not registered correctly.
	for e in $( seq 1 ${#echoes[@]} )
	do
		funcprefix=${funcprefix%_echo-*}_echo-${e}
		funcsource=${funcsource%_echo-*}_echo-${e}_${funcsource#*_echo-?_}
		[[ ! -e ${funcsource}.nii.gz ]] && echo "!!! WARNING: ${funcsource}.nii.gz not found, skipping" \
			&& continue

		echo "************************************"
		echo "*** Func realign ${funcprefix}"
		echo "************************************"
		echo "************************************"

		echo "Applying McFlirt transformations in ${funcsource}"

		mkdir ${tmp}/${funcprefix}_split
		mkdir ${tmp}/${funcprefix}_merge
		fslsplit ${funcsource} ${tmp}/${funcprefix}_split/vol_ -t

		for i in $( seq -f %04g 0 ${nTR} )
		do
			echo "Flirting volume ${i} of ${nTR} in ${funcprefix}"
			flirt -in ${tmp}/${funcprefix}_split/vol_${i} -ref ${mref} -applyxfm \
			-init ${rderivdir}/${firstechoprefix}_mcf.mat/MAT_${i} -out ${tmp}/${funcprefix}_merge/vol_${i}
		done

		echo "Merging ${funcprefix}"
		fslmerge -tr ${tmp}/${funcprefix}_mcf ${tmp}/${funcprefix}_merge/vol_* ${TR}

		# 01.2. Apply mask
		echo "BETting ${funcprefix}"
		fslmaths ${tmp}/${funcprefix}_mcf -mas ${mask} ${tmp}/${funcprefix}_bet

		[[ ${greyplot} == "yes" ]] && echo "Create Greyplot ${funcprefix} post motion" \
								   && 3dGrayplot -input ${tmp}/${funcprefix}_mcf.nii.gz -mask ${mask}.nii.gz \
												 -prefix ${fderivdir}/${funcprefix}_gp_motrealign.png -dimen 1800 1200 \
												 -polort ${polort} -peelorder -percent -range 3
	done

	# Func preproc part 3: MEICA

	funcprefix=${firstechoprefix}

	echo "************************************"
	echo "*** Func MEICA ${firstechosource}"
	echo "************************************"
	echo "************************************"

	echo ""
	echo "Make sure system python is used by prepending /usr/bin to PATH"
	[[ "${PATH%%:*}" != "/usr/bin" ]] && export PATH=/usr/bin:$PATH
	echo "PATH is set to $PATH"
	echo ""
	echo "--------------"
	echo "Running tedana"
	echo "--------------"
	echo "Python: $( which python ) $( which python3 )"

	tedana -d ${tmp}/${funcprefix%-?}-?_bet.nii.gz -e ${TEs} --tedpca mdl \
		   --out-dir ${fderivdir}/${funcprefix}_meica --seed 42 --overwrite

	preproc_vols=()

	# Housekeeping 
	[[ ${preproc_optcom} == "yes" ]] && preproc_vols+=( optcom ) \
		&& fslmaths ${fderivdir}/${funcprefix}_meica/desc-optcom_bold.nii.gz ${tmp}/${funcprefix%_echo-*}_optcom_bet -odt float

	[[ ${preproc_echoes} == "yes" ]] && preproc_vols+=( $( seq 1 ${#echoes[@]} ) )

	#!# Add ortho steps 

	# Func preproc part 4: Final steps
	noechofuncprefix=${firstechoprefix%_echo-*}

	for e in ${preproc_vols[@]}
	do
		if [[ ${e} == "optcom" ]]; then funcsource=${tmp}/${noechofuncprefix}_optcom_bet; else funcsource=${tmp}/${noechofuncprefix}_echo-${e}_bet; fi
		funcname=$( basename ${funcsource} )
		funcprefix=${funcname%_bet*}
		echo "************************************"
		echo "*** Apply Pepolar ${funcname}"
		echo "************************************"
		echo "************************************"
		[[ -z "${topupdir}" || ! -d "${topupdir}" ]] && echo "Something went wrong, there is no topup directory ready." && exit 1
		${scriptdir}/blocks/pepolar.sh -nii ${funcsource} \
				-pepolardir ${topupdir} \
				-workdir ${bids[root]}/derivatives/vessels/ \
				-tmp ${tmp}

		funcsource=${funcsource}_tpp

		echo "************************************"
		echo "*** Func Nuiscomp ${funcname}"
		echo "************************************"
		echo "************************************"

		echo "Preparing nuisance matrix"

		run3dDeconvolve="3dDeconvolve -input ${funcsource}.nii.gz -float \
		-x1D ${fderivdir}/${funcprefix}_nuisreg_mat.1D \
		-xjpeg ${fderivdir}/${funcprefix}_nuisreg_mat.jpg \
		-x1D_stop"

		[[ "${polort}" -gt -1 ]] && run3dDeconvolve="${run3dDeconvolve} -polort ${polort}" && den_detrend="yes ${polort} degree(s)"
		[[ "${den_motreg}" == "yes" ]] && run3dDeconvolve="${run3dDeconvolve} -ortvec ${fderivdir}/${firstechoprefix}_mcf_demean.par motdemean \
														   -ortvec ${fderivdir}/${firstechoprefix}_mcf_deriv1.par motderiv1"
		[[ "${den_meica}" == "yes" ]] && run3dDeconvolve="${run3dDeconvolve} -ortvec ${fderivdir}/${firstechoprefix}_rejected.1D meica"
		

		if [[ "${den_tissues}" == "yes" ]]
		then
			[[ ${funcprefix} =~ task-([^_]+) ]] && task=${BASH_REMATCH[1]}

			[[ ${mrefvol} == "task" ]] && t2w2sbref=${rderivdir}/sub-${bids[sub]}_ses-02_T2w2task-${task}sbref0GenericAffine.mat \
				&& seg2sbref=${fderivdir}/seg2task-${task}.nii.gz \
				&& antsApplyTransforms -d 3 -i ${seg} -r ${mref}.nii.gz -o ${seg2sbref} \
							 		  -n Linear -t ${t2w2sbref} -t ${seg2t2w}

			echo "Extracting average WM and CSF in ${func}"

			3dDetrend -polort ${polort} -prefix ${funcsource}_tissuedtd.nii.gz ${funcsource}.nii.gz -overwrite
			fslmeants -i ${funcsource}_tissuedtd.nii.gz -o ${fderivdir}/${funcprefix}_avg_tissue.1D --label=${seg2sbref}

			run3dDeconvolve="${run3dDeconvolve} -num_stimts  2 \
						 -stim_file 1 ${fderivdir}/${funcprefix}_avg_tissue.1D'[0]' -stim_base 1 -stim_label 1 CSF \
						 -stim_file 2 ${fderivdir}/${funcprefix}_avg_tissue.1D'[2]' -stim_base 2 -stim_label 2 WM"
		fi

		echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo "# Running 3dDeconvolve with the following parameters:"
		echo "   + Denoise motion regressors:         ${den_motreg}"
		echo "   + Denoise legendre polynomials:      ${den_detrend}"
		echo "   + Denoise meica rejected components: ${den_meica}"
		echo "   + Denoise average tissues signal:    ${den_tissues}"
		echo ""
		echo "# Generating the command:"
		echo ""
		echo "${run3dDeconvolve}"
		echo ""
		echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++"

		eval ${run3dDeconvolve}

		if [[ "${applynuisance}" == "yes" ]]
		then
			echo "Actually applying nuisance"
			fslmaths ${funcsource} -Tmean ${tmp}/${funcprefix}_avgfornuisance
			3dTproject -polort 0 -input ${funcsource}.nii.gz  -mask ${mask}.nii.gz \
			-ort ${fderivdir}/${funcprefix}_nuisreg_mat.1D -prefix ${tmp}/${funcprefix}_prj.nii.gz \
			-overwrite
			fslmaths ${tmp}/${funcprefix}_prj -add ${tmp}/${funcprefix}_avgfornuisance ${tmp}/${funcprefix}_den
			funcsource=${tmp}/${funcprefix}_den
		fi

		if [[ ${fwhm} != "none" ]]
		then

			echo "************************************"
			echo "*** Func smoothing ${funcname}"
			echo "************************************"
			echo "************************************"

			3dBlurInMask -input ${funcsource}.nii.gz -mask ${mask}.nii.gz -prefix ${tmp}/${funcprefix}_sm.nii.gz -preserve -FWHM ${fwhm} -overwrite
			funcsource=${tmp}/${funcprefix}_sm
		fi

		3dcalc -a ${funcsource}.nii.gz -b ${mask}.nii.gz -expr 'a*b' \
			   -prefix ${fderivdir}/00.${funcprefix}_native_preprocessed.nii.gz \
			   -short -gscale -overwrite

		[[ ${greyplot} == "yes" && ${nTR} -gt 1 ]] && echo "Create Greyplot ${funcname} final" \
		   && 3dGrayplot -input ${fderivdir}/00.${funcprefix}_native_preprocessed.nii.gz -mask ${mask}.nii.gz \
						 -prefix ${fderivdir}/${funcprefix}_gp_final.png -dimen 1800 1200 \
						 -polort ${polort} -peelorder -percent -range 3

	done
done

cd ${cwd}

echo ""
echo ""
echo "************************************"
echo "***    Func Preproc completed!"
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
