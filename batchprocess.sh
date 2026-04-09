#!/usr/bin/env bash

# apptainer shell --no-home -e -B /Neurodata/M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp M3PI_vessels.sif
# for sub in $(seq -f %02g 1 6)
# do
# /scripts/3dMEEPI_preproc.sh -anat /data/sub-${sub}/ses-7T/anat/sub-${sub}_ses-7T_acq-normRO_run-1_echo-1_part-mag_T2starw.nii.gz
# done

# apptainer shell --no-home -e -B /Neurodata/M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp VesselBoost.sif
# for sub in $(seq -f %02g 1 6)
# do
# /scripts/vessels_segmentation.sh -anat /data/derivatives/vessels/sub-${sub}/ses-7T/anat/00.sub-${sub}_ses-7T_part-mag_T2starw_imgavg_preprocessed
# done

for sub in $(seq -f %02g 1 6)
do
screen_name="vesselprep_${sub}"

screen -dmS "$screen_name" \
-L -Logfile $DATA/Logs/${screen_name}.log \
bash -c "
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/M3PI_vessels.sif \
/scripts/3dMEEPI_preproc.sh -anat /data/sub-${sub}/ses-7T/anat/sub-${sub}_ses-7T_acq-normRO_run-1_echo-1_part-mag_T2starw.nii.gz;
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
/scripts/vessels_segmentation.sh -anat /data/derivatives/vessels/sub-${sub}/ses-7T/anat/00.sub-${sub}_ses-7T_part-mag_T2starw_imgavg_preprocessed;
"
done



for sub in $(seq -f %02g 1 6)
do
screen_name="vesselseg_${sub}"

screen -dmS "$screen_name" \
-L -Logfile $DATA/Logs/${screen_name}.log \
bash -c "
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
/scripts/vessels_segmentation.sh -anat /data/derivatives/vessels/sub-${sub}/ses-7T/anat/00.sub-${sub}_ses-7T_part-mag_T2starw_imgavg_preprocessed;
"
done

screen_name="vesselprep_${sub}"
screen -dmS "vesselprep_02" \
-L -Logfile $DATA/Logs/vesselprep_02.log \
bash -c "
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
mv /data/derivatives/vessels/sub-02/ses-7T /data/derivatives/vessels/sub-02/ses-7T_v1;
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/M3PI_vessels.sif \
/scripts/3dMEEPI_preproc.sh -anat /data/sub-02/ses-7T/anat/sub-02_ses-7T_acq-normRO_run-1_echo-1_part-mag_T2starw.nii.gz -degibbs;
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
/scripts/vessels_segmentation.sh -anat /data/derivatives/vessels/sub-02/ses-7T/anat/00.sub-02_ses-7T_part-mag_T2starw_imgavg_preprocessed;
"


screen_name="vesselprep_${sub}"
screen -dmS "vesselprep_04" \
-L -Logfile $DATA/Logs/vesselprep_04.log \
bash -c "
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
mv /data/derivatives/vessels/sub-04/ses-7T /data/derivatives/vessels/sub-04/ses-7T_v1;
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/M3PI_vessels.sif \
/scripts/3dMEEPI_preproc.sh -anat /data/sub-04/ses-7T/anat/sub-04_ses-7T_acq-normRO_run-1_echo-1_part-mag_T2starw.nii.gz -skip_bfc;
apptainer exec -e --no-home -B $M3PI:/data -B $GITLAB/M3PI_preproc:/scripts -B /scratch:/tmp $GITLAB/M3PI_preproc/VesselBoost.sif \
/scripts/vessels_segmentation.sh -anat /data/derivatives/vessels/sub-04/ses-7T/anat/00.sub-04_ses-7T_part-mag_T2starw_imgavg_preprocessed;
"
