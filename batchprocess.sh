#!/usr/bin/env bash

# apptainer shell --no-home -e -B /Neurodata/M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp M3PI_vessels.sif

for sub in $( seq 1 6 );
do
	/scripts/3dMEEPI_preproc.sh -anat /data/sub-01/ses-7T/anat/sub-01_ses-7T_acq-normRO_run-1_echo-1_part-mag_T2starw.nii.gz
done

