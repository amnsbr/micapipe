#!/bin/bash
#
# Microstructural imaging processing:
#
# Preprocessing workflow for qT1.
# Generates microstructural profiles and mpc matrices on specified parcellations
#
# This workflow makes use of freesurfer and custom python scripts
#
# Atlas an templates are avaliable from:
#
# https://github.com/MICA-MNI/micapipe/tree/master/parcellations
#
#   ARGUMENTS order:
#   $1 : BIDS directory
#   $2 : participant
#   $3 : Out Directory
#
BIDS=$1
id=$2
out=$3
SES=$4
nocleanup=$5
threads=$6
tmpDir=$7
input_im=$8
mpc_reg=$9
mpc_str=${10}
synth_reg=${11}
PROC=${12}
export OMP_NUM_THREADS=$threads
here=$(pwd)

#------------------------------------------------------------------------------#
# qsub configuration
if [ "$PROC" = "qsub-MICA" ] || [ "$PROC" = "qsub-all.q" ] || [ "$PROC" = "LOCAL-MICA" ]; then
    MICAPIPE=/data_/mica1/01_programs/micapipe-v0.2.0
    source "${MICAPIPE}/functions/init.sh" "$threads"
fi

# source utilities
source "$MICAPIPE"/functions/utilities.sh

# Assigns variables names
bids_variables "$BIDS" "$id" "$out" "$SES"

# Check dependencies Status: POST_STRUCTURAL
micapipe_check_dependency "post_structural" "${dir_QC}/${idBIDS}_module-post_structural.json"

# Setting Surface Directory from post_structural
post_struct_json="${proc_struct}/${idBIDS}_post_structural.json"
recon=$(grep SurfRecon "${post_struct_json}" | awk -F '"' '{print $4}')
set_surface_directory "${recon}"

# Variables naming for multiple acquisitions
if [[ "${mpc_str}" == DEFAULT ]]; then
  mpc_str="qMRI"
  mpc_p="acq-qMRI"
else
  mpc_p="acq-${mpc_str}"
fi

# End if module has been processed
module_json="${dir_QC}/${idBIDS}_module-MPC-${mpc_str}.json"
micapipe_check_json_status "${module_json}" "MPC"

# Check microstructural image input flag and set parameters accordingly
if [[ "$input_im" == "DEFAULT" ]]; then microImage="$bids_T1map"; else microImage="${input_im}"; fi
Note "Microstructural image =" "$microImage"

# Check microstructural image to registrer
if [[ "$mpc_reg" == "DEFAULT" ]]; then regImage="${bids_inv1}"; else regImage="${mpc_reg}"; fi
Note "Microstructural image for registration =" "$regImage"

# Exit if microImage or Registration image do not exists
if [ ! -f "${microImage}" ]; then Error "Image for MPC was not found or the path is wrong!!!"; exit; fi
if [ ! -f "${regImage}" ]; then Error "Image for MPC registration was not found or the path is wrong!!!"; exit; fi

#------------------------------------------------------------------------------#
Title "Microstructural Profiles Covariance\n\t\tmicapipe $Version, $PROC"
micapipe_software
bids_print.variables-post
Note "Saving temporal dir : " "${nocleanup}"
Note "Parallel processing : " "${threads} threads"
Note "tmp dir   : " "${tmpDir}"
Note "recon     : " "${recon}"
Note "synth_reg : " ${synth_reg}

#	Timer
aloita=$(date +%s)
Nsteps=0
N=0

# Create script specific temp directory
tmp="${tmpDir}/${RANDOM}_micapipe_post-MPC_${id}"
Do_cmd mkdir -p "$tmp"

# TRAP in case the script fails
trap 'cleanup $tmp $nocleanup $here' SIGINT SIGTERM

# Freesurface SUBJECTs directory
export SUBJECTS_DIR="$dir_surf"
outDir="${subject_dir}/mpc/${mpc_p}"
Note "acqMRI:" "${mpc_str}"

# json file
qt1_json="${dir_maps}/${idBIDS}_space-nativepro_map-${mpc_str}.json"

#------------------------------------------------------------------------------#
# Affine registration between both images
T1_in_fs=${tmp}/orig.nii.gz
qT1_fsnative=${proc_struct}/${idBIDS}_space-fsnative_${mpc_str}.nii.gz
mat_fsnative_affine=${dir_warp}/${idBIDS}_from-fsnative_to_${mpc_str}_
qT1_fsnative_affine=${mat_fsnative_affine}0GenericAffine.mat

if [[ ! -f "$qT1_fsnative" ]] || [[ ! -f "$qT1_fsnative_affine" ]]; then ((N++))
    Do_cmd mrconvert "$T1surf" "$T1_in_fs"
    # Registration with synthseg
    if [[ "${synth_reg}" == "TRUE" ]]; then
      Info "Running label based affine registrations"
      qT1_synth="${tmp}/qT1_synthsegGM.nii.gz"
      T1_synth="${tmp}/T1w_synthsegGM.nii.gz"
      Do_cmd mri_synthseg --i "${T1_in_fs}" --o "${tmp}/T1w_synthseg.nii.gz" --robust --threads "$threads" --cpu
      Do_cmd fslmaths "${tmp}/T1w_synthseg.nii.gz" -uthr 42 -thr 42 -bin -mul -39 -add "${tmp}/T1w_synthseg.nii.gz" "${T1_synth}"

      Do_cmd mri_synthseg --i "$regImage" --o "${tmp}/qT1_synthseg.nii.gz" --robust --threads "$threads" --cpu
      Do_cmd fslmaths "${tmp}/qT1_synthseg.nii.gz" -uthr 42 -thr 42 -bin -mul -39 -add "${tmp}/qT1_synthseg.nii.gz" "${qT1_synth}"

      # Affine from func to t1-nativepro
      Do_cmd antsRegistrationSyN.sh -d 3 -f "$qT1_synth" -m "$T1_synth" -o "$mat_fsnative_affine" -t a -n "$threads" -p d
    else
      Info "Running volume based affine registrations"
      Do_cmd antsRegistrationSyN.sh -d 3 -f "$regImage" -m "$T1_in_fs" -o "$mat_fsnative_affine" -t a -n "$threads" -p d
    fi

    Do_cmd antsApplyTransforms -d 3 -i "$microImage" -r "$T1_in_fs" -t ["${qT1_fsnative_affine}",1] -o "$qT1_fsnative" -v -u int
    if [[ -f ${qT1_fsnative} ]]; then ((Nsteps++)); fi
else
    Info "Subject ${id} has a ${mpc_str} on Surface space"; ((Nsteps++)); ((N++))
fi

# Convert the ANTs transformation file for wb_command
wb_affine="${tmp}/${idBIDS}_from-fsnative_to_qMRI_wb.mat"
Do_cmd c3d_affine_tool -itk "$qT1_fsnative_affine" -inv -o "${wb_affine}"

##------------------------------------------------------------------------------#
## Register qT1 intensity to surface
num_surfs=14
[[ ! -d "$outDir" ]] && mkdir -p "$outDir" && chmod -R 770 "$outDir"
json_mpc "$microImage" "${outDir}/${idBIDS}_MPC-${mpc_str}.json"

MPC_fsLR5k="${outDir}/${idBIDS}_surf-fsLR-5k_desc-MPC.shape.gii"
if [[ ! -f "${MPC_fsLR5k}" ]]; then ((N++))
    for hemi in lh rh ; do
        [[ "$hemi" == lh ]] && HEMI=L || HEMI=R
        unset LD_LIBRARY_PATH
        tot_surfs=$((num_surfs + 2))
        Do_cmd python "$MICAPIPE"/functions/generate_equivolumetric_surfaces.py \
            "${dir_subjsurf}/surf/${hemi}.pial" \
            "${dir_subjsurf}/surf/${hemi}.white" \
            "$tot_surfs" \
            "${outDir}/${hemi}.${num_surfs}surfs" \
            "$tmp" \
            --software freesurfer --subject_id "$idBIDS"

        # remove top and bottom surface
        Do_cmd rm -rfv "${outDir}/${hemi}.${num_surfs}surfs0.0.pial" "${outDir}/${hemi}.${num_surfs}surfs1.0.pial"

        # find all equivolumetric surfaces and list by creation time
        x=$(ls -t "$outDir"/"$hemi".${num_surfs}surfs*)
        for n in $(seq 1 1 "$num_surfs") ; do
            which_surf=$(sed -n "$n"p <<< "$x")
            surf_gii="${tmp}/${hemi}.${n}by${num_surf}_space-fsnative.surf.gii"
            surf_tmp="${tmp}/${hemi}.${n}by${num_surf}_no_offset.surf.gii"
            out_surf="${tmp}/${hemi}.${n}by${num_surf}_space-qMRI.surf.gii"
            out_feat="${outDir}/${idBIDS}_hemi-${HEMI}_surf-fsnative_label-MPC-${n}.func.gii"
            # Register surface to qMRI space
            Do_cmd mris_convert "$which_surf" "${surf_gii}"
            # Remove offset-to-origin from any gifti surface derived from FS
            Do_cmd python "$MICAPIPE"/functions/removeFSoffset.py "${surf_gii}" "${surf_tmp}"
            # Apply transformation to register surface to nativepro
            Do_cmd wb_command -surface-apply-affine "${surf_tmp}" "${wb_affine}" "${out_surf}"
            # Sample intensity and resample to other surfaces
            map_to-surfaces "${microImage}" "${out_surf}" "${out_feat}" "${HEMI}" "MPC-${n}" "${outDir}"
            # remove tmp surfaces
            rm "${surf_tmp}" "${which_surf}"
        done
    done
    ((Nsteps++))
else
    Info "Subject ${id} has microstructural intensities mapped to native surface";((Nsteps++)); ((N++));
fi

#------------------------------------------------------------------------------#
### qT1 registration to nativepro ###

# Register nativepro and qt1
str_qt1_affine="${dir_warp}/${idBIDS}_from-${mpc_str}_to-nativepro_mode-image_desc-affine_"
qmriNP="${dir_maps}/${idBIDS}_space-nativepro_map-${mpc_str}.nii.gz"
if [[ ! -f "$qmriNP" ]]; then
  Info "${mpc_str} registration to nativepro"
    if [[ "${synth_reg}" == "TRUE" ]]; then
      T1natpro_synth="${tmp}/T1nativepro_synthsegGM.nii.gz"
      Do_cmd mri_synthseg --i "${T1nativepro}" --o "${tmp}/T1nativepro_synthseg.nii.gz" --robust --threads "$threads" --cpu
      Do_cmd fslmaths "${tmp}/T1nativepro_synthseg.nii.gz" -uthr 42 -thr 42 -bin -mul -39 -add "${tmp}/T1nativepro_synthseg.nii.gz" "${T1natpro_synth}"

      # Affine from func to t1-nativepro
      Do_cmd antsRegistrationSyN.sh -d 3 -f "$T1natpro_synth" -m "$qT1_synth" -o "$str_qt1_affine" -t a -n "$threads" -p d
    else
      Do_cmd antsRegistrationSyN.sh -d 3 -f "$T1nativepro_brain" -m "$regImage" -o "$str_qt1_affine" -t a -n "$threads" -p d
    fi
    Do_cmd antsApplyTransforms -d 3 -i "$microImage" -r "$T1nativepro_brain" -t "$str_qt1_affine"0GenericAffine.mat -o "$qmriNP" -v -u float
    ((Nsteps++)); ((N++))
else
    Info "Subject ${id} ${mpc_str} is registered to nativepro"; ((Nsteps++)); ((N++))
fi

# Write json file
json_nativepro_qt1 "$qmriNP" \
    "antsApplyTransforms -d 3 -i ${microImage} -r ${T1nativepro_brain} -t ${str_qt1_affine}0GenericAffine.mat -o ${qmriNP} -v -u float" \
    "$qt1_json"

#------------------------------------------------------------------------------#
# Map to surface: midthickness, white
Nmorph=$(ls "${dir_maps}/"*"${mpc_str}"*gii 2>/dev/null | wc -l)
if [[ "$Nmorph" -lt 16 ]]; then ((N++))
    Info "Mapping ${mpc_str} to fsLR-32k, fsLR-5k and fsaverage5"
    for HEMI in L R; do
        for label in midthickness white; do
            surf_fsnative="${dir_conte69}/${idBIDS}_hemi-${HEMI}_space-nativepro_surf-fsnative_label-${label}.surf.gii"
            # MAPPING metric to surfaces
            map_to-surfaces "${qmriNP}" "${surf_fsnative}" "${dir_maps}/${idBIDS}_hemi-${HEMI}_surf-fsnative_label-${label}_${mpc_str}.func.gii" "${HEMI}" "${label}_${mpc_str}" "${dir_maps}"
        done
    done
    Nmorph=$(ls "${dir_maps}/"*${mpc_str}*gii 2>/dev/null | wc -l)
    if [[ "$Nmorph" -eq 16 ]]; then ((Nsteps++)); fi
else
    Info "Subject ${idBIDS} has ${mpc_str} mapped to surfaces"; ((Nsteps++)); ((N++))
fi

#------------------------------------------------------------------------------#
# Create MPC connectomes and Intensity profiles per parcellations
parcellations=($(find "$dir_volum" -name "*atlas*" ! -name "*cerebellum*" ! -name "*subcortical*"))
for seg in "${parcellations[@]}"; do
    parc=$(echo "${seg/.nii.gz/}" | awk -F 'atlas-' '{print $2}')
    parc_annot="${parc}_mics.annot"
    MPC_int="${outDir}/${idBIDS}_atlas-${parc}_desc-intensity_profiles.shape.gii"
    if [[ ! -f "$MPC_int" ]]; then ((N++))
        Info "Running MPC on $parc"
        Do_cmd python "$MICAPIPE"/functions/surf2mpc.py "$out" "$id" "$SES" "$num_surfs" "$parc_annot" "$dir_subjsurf" "${mpc_p}"
        if [[ -f "$MPC_int" ]]; then ((Nsteps++)); fi
    else Info "Subject ${id} has MPC connectome and intensity profile on ${parc}"; ((Nsteps++)); ((N++)); fi
done

#------------------------------------------------------------------------------#
# Create vertex-wise MPC connectome and directory cleanup
if [[ ! -f "${MPC_fsLR5k}" ]]; then ((N++))
  Info "Running MPC vertex-wise on fsLR-5k"
  Do_cmd python "$MICAPIPE"/functions/build_mpc-vertex.py "$out" "$id" "$SES" "${mpc_p}"
  ((Nsteps++))
else Info "Subject ${id} has MPC vertex-wise on fsLR-5k"; ((Nsteps++)); ((N++)); fi
rm "${dir_warp}/${idBIDS}"*_Warped.nii.gz

#------------------------------------------------------------------------------#
# QC notification of completition
lopuu=$(date +%s)
eri=$(echo "$lopuu - $aloita" | bc)
eri=$(echo print "$eri"/60 | perl)

# Notification of completition
micapipe_completition_status "MPC"
micapipe_procStatus "${id}" "${SES/ses-/}" "MPC-${mpc_str}" "${out}/micapipe_processed_sub.csv"
Do_cmd micapipe_procStatus_json "${id}" "${SES/ses-/}" "MPC-${mpc_str}" "${module_json}"
cleanup "$tmp" "$nocleanup" "$here"
