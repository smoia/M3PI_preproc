#!/usr/bin/env bash

for sub in $(seq -f %02g 1 6); do
  screen_name="preproc_${sub}"

  screen -dmS "$screen_name" \
    -L -Logfile /Neurodata/Logs/${screen_name}.log \
    bash -c "
      apptainer exec -e --no-home \
        -B /Neurodata/M3PI:/data \
        -B /Neurodata/gitlab/M3PI_preproc:/scripts \
        -B /scratch:/tmp /Neurodata/gitlab/M3PI_preproc/M3PI_vessels.sif \
        /scripts/anat_preproc.sh \
        -anat /data/sub-${sub}/ses-02/anat/sub-${sub}_ses-02_UNIT1.nii.gz;

      apptainer exec -e --no-home \
        -B /Neurodata/M3PI:/data \
        -B /Neurodata/gitlab/M3PI_preproc:/scripts \
        -B /scratch:/tmp /Neurodata/gitlab/M3PI_preproc/M3PI_vessels.sif \
        /scripts/sbref_preproc.sh \
        -sbref /data/sub-${sub}/ses-01/func/sub-${sub}_ses-01_task-simon_echo-1_part-mag_sbref.nii.gz;

      for ses in \$(seq -f %02g 1 9); do
      	ses_dir=\"/Neurodata/M3PI/sub-${sub}/ses-\${ses}\"
      	if [ -d \"\$ses_dir\" ] && [ \$(find \"\$ses_dir\" -type f -name \"*simon*\" | wc -l) -gt 0 ]; then
          apptainer exec -e --no-home \
            -B /Neurodata/M3PI:/data \
            -B /Neurodata/gitlab/M3PI_preproc:/scripts \
            -B /scratch:/tmp /Neurodata/gitlab/M3PI_preproc/M3PI_vessels.sif \
            /scripts/func_preproc.sh \
            -func /data/sub-${sub}/ses-\${ses}/func/sub-${sub}_ses-\${ses}_task-simon_echo-1_part-mag_bold.nii.gz \
            -den_tissues -only_optcom -exclude_tasks \"motor breathhold rest\" -fwhm 5 -applynuisance;
        fi
      done
  "
done
