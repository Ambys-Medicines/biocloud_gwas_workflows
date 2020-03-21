import "biocloud_gwas_workflows/biocloud_wdl_tools/plink/plink.wdl" as PLINK
import "biocloud_gwas_workflows/genotype_array_qc/impute2_id_conversion/impute2_id_conversion_wf.wdl" as IDCONVERT
import "biocloud_gwas_workflows/genotype_array_qc/STRUCTURE/structure_wf.wdl" as STRUCTURE
import "biocloud_gwas_workflows/genotype_array_qc/hwe_filter/hwe_filter_wf.wdl" as HWE
import "biocloud_gwas_workflows/genotype_array_qc/relatedness/relatedness_wf.wdl" as REL
import "biocloud_gwas_workflows/genotype_array_qc/sex_check/sex_check_wf.wdl" as SEX
import "biocloud_gwas_workflows/biocloud_wdl_tools/utils/utils.wdl" as UTILS

workflow genotype_array_qc_wf{
    File bed
    File bim
    File fam
    Array[String] chrs
    Array[File] id_legend_files
    String output_basename

    # Build code to use for PAR/NONPAR splitting
    String build_code

    # Sample filter cutoffs
    Float max_sample_missing_rate = 0.03
    Float min_sample_he = -0.2
    Float max_sample_he = 0.5

    # Variant filtering cutoffs
    Float max_missing_site_rate = 0.03
    Float hwe_filter_pvalue = 0.0001

    # LD-Filtering parameters for subworkflows (structure, relatedness, sex-check)
    File? ld_exclude_regions
    Float ld_maf_cutoff = 0.1
    String ld_type = "indep-pairphase"
    Int ld_window_size = 20000
    Int ld_step_size = 2000
    Float ld_r2_threshold = 0.5

    # Structure ancestry partitioning filtering parameters
    File structure_ref_bed
    File structure_ref_bim
    File structure_ref_fam
    File structure_ref_ancestry_psam
    Int max_structure_snps = 1000000

    # Ancestries to partition samples between
    Array[String] ancestries_to_include = ["EUR", "EAS", "AFR"]
    Int min_ancestry_samples_to_postprocess = 10

    # What level of ancestry is being examined [SUPERPOP | POP]
    String ancestry_pop_type = "SUPERPOP"

    # Cutoffs defining how to call ancestry from admixture proportions
    Array[String] ancestry_definitions = ["AFR=EAS<0.25;AFR>0.25", "EUR=EAS<0.25;AFR<0.25", "EAS=EAS>0.25;AFR<0.25"]

    # Various TeraStructure params
    Float terastructure_rfreq_perc = 0.2

    # Sex-check filter parameters
    Boolean filter_discrepant_sex = true
    Float max_female_f = 0.2
    Float min_male_f = 0.8

    # Path to phenotype file containing sex calls
    # Intended to be the phenotype file that you will use for downstream association testing
    # If that's the fam file that's fine too but the important thing is to check that the sex calls that will
    # Be used in association testing are actually accurate
    File sex_check_phenotype_file
    # Number of header rows (all header rows must be removed)
    Int phenotype_header_rows
    # 0-based indices of required columns for sex check
    Int phenotype_fid_col
    Int phenotype_iid_col
    Int phenotype_sex_col
    String phenotype_delimiter

    # Kinship filter parameters
    Boolean filter_related_samples = true
    Int degree = 3
    Int num_king_splits = 4

    # PCA parameters
    Int kinship_pcs_to_analyze = 3

    # Ancestral SNP filtering parameters
    Float ancestral_pca_loading_cutoff = 0.003
    Int max_kinship_snps = 100000
    Int min_kinship_snps = 10000
    Float ancestral_pca_loading_step_size = 0.001
    Float max_ancestral_pca_loading_cutoff = 0.01

    # Resources for various modules

    # General CPU/Mem for basically any PLINK task that runs on the whole dataset
    Int plink_filter_cpu = 1
    Int plink_filter_mem_gb = 2

    # General CPU/MEM for basically any PLINK task that runs on a single chr
    Int plink_chr_cpu = 1
    Int plink_chr_mem_gb = 2

    # General CPU/MEM for jobs that merge bed files either by chr or sample
    Int merge_bed_cpu = 4
    Int merge_bed_mem_gb = 8

    # Speicific tasks where resource limits may need to be adjusted for larger/smaller inputs
    Int terastructure_cpu = 32
    Int terastructure_mem_gb = 32
    Int sex_check_cpu = 4
    Int sex_check_mem_gb = 8
    Int king_cpu_per_split = 4
    Int king_mem_gb_per_split = 8
    Int pca_cpu = 4
    Int pca_mem_gb = 8

    # Remove phenotype from fam file
    call PLINK.remove_fam_phenotype{
        input:
            fam_in = fam,
            output_basename = "${output_basename}.no_pheno"
    }

    # Convert variant IDs to impute2 format and remove duplicate variants
    call IDCONVERT.impute2_id_conversion_wf as convert_impute2_ids{
        input:
            bed_in = bed,
            bim_in = bim,
            fam_in = remove_fam_phenotype.fam_out,
            output_basename = output_basename,
            chrs = chrs,
            id_legend_files = id_legend_files,
            remove_duplicates = true,
            build_code = build_code,
            no_fail = true,
            split_bed_cpu = plink_chr_cpu,
            split_bed_mem_gb = plink_chr_mem_gb,
            merge_bed_cpu = merge_bed_cpu,
            merge_bed_mem_gb = merge_bed_mem_gb
    }

    # Remove failed subjects with >99% missing data so they don't throw off anything downstream
    call PLINK.make_bed as filter_failed_samples{
        input:
            bed_in = convert_impute2_ids.bed_out,
            bim_in = convert_impute2_ids.bim_out,
            fam_in = convert_impute2_ids.fam_out,
            output_basename = "${output_basename}.filter_failed_samples",
            mind = 0.99,
            cpu = plink_filter_cpu,
            mem_gb = plink_filter_mem_gb
    }

    # STRUCTURE WF to partition by ancestry
    call STRUCTURE.structure_wf{
        input:
            bed_in = filter_failed_samples.bed_out,
            bim_in = filter_failed_samples.bim_out,
            fam_in = filter_failed_samples.fam_out,
            output_basename = "${output_basename}.structure",
            max_snps_to_analyze = max_structure_snps,
            ref_bed = structure_ref_bed,
            ref_bim = structure_ref_bim,
            ref_fam = structure_ref_fam,
            ancestry_psam = structure_ref_ancestry_psam,
            ancestries_to_include = ancestries_to_include,
            ancestry_pop_type = ancestry_pop_type,
            ancestry_definitions = ancestry_definitions,
            ld_exclude_regions = ld_exclude_regions,
            ld_type = ld_type,
            window_size = ld_window_size,
            step_size = ld_step_size,
            r2_threshold = ld_r2_threshold,
            ld_cpu = plink_filter_cpu,
            ld_mem_gb = plink_chr_mem_gb,
            min_ld_maf = ld_maf_cutoff,
            merge_bed_cpu = merge_bed_cpu,
            merge_bed_mem_gb = merge_bed_mem_gb,
            terastructure_rfreq_perc = terastructure_rfreq_perc,
            terastructure_cpu = terastructure_cpu,
            terastructure_mem_gb = terastructure_mem_gb
    }

    # Filter out any ancestries with less than a minimum cutoff of samples
    scatter(ancestry_index in range(length(ancestries_to_include))){
        # Count number of samples in each ancestry
        call UTILS.wc as count_samples{
            input:
                input_file = structure_wf.samples_by_ancestry[ancestry_index]
        }

        # Only include ancestries exceeding minimum number of samples
        if(count_samples.num_lines > min_ancestry_samples_to_postprocess){
            String ancestries_maybe = ancestries_to_include[ancestry_index]
            File ancestry_samples_maybe = structure_wf.samples_by_ancestry[ancestry_index]
        }
    }

    # Remove null values from filtered ancestries to create list of ancestries to postprocess
    Array[String] postprocess_ancestries = select_all(ancestries_maybe)
    Array[File] postprocess_ancestry_samples = select_all(ancestry_samples_maybe)

    # Split by ancestry group and process each separately
    scatter(ancestry_index in range(length(postprocess_ancestries))){
        String ancestry = postprocess_ancestries[ancestry_index]
        File ancestry_samples = postprocess_ancestry_samples[ancestry_index]

        # Partition data by ancestry and apply SNP call rate filter
        call PLINK.make_bed as subset_ancestry{
            input:
                bed_in = filter_failed_samples.bed_out,
                bim_in = filter_failed_samples.bim_out,
                fam_in = filter_failed_samples.fam_out,
                output_basename = "${output_basename}.${ancestry}.snp_miss",
                keep_samples = ancestry_samples,
                geno = max_missing_site_rate,
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Apply HWE filter
        call HWE.hwe_filter_wf{
            input:
                bed_in = subset_ancestry.bed_out,
                bim_in = subset_ancestry.bim_out,
                fam_in = subset_ancestry.fam_out,
                hwe_filter_pvalue = hwe_filter_pvalue,
                output_basename = "${output_basename}.${ancestry}.snp_miss.hwe",
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Set het haploids to missing
        call PLINK.make_bed as het_hap_to_missing{
            input:
                bed_in = hwe_filter_wf.bed_out,
                bim_in = hwe_filter_wf.bim_out,
                fam_in = hwe_filter_wf.fam_out,
                set_hh_missing = true,
                output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_auto",
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Get samples to filter based on call rate (autosomes)
        call PLINK.make_bed as get_low_called_samples{
            input:
                bed_in = het_hap_to_missing.bed_out,
                bim_in = het_hap_to_missing.bim_out,
                fam_in = het_hap_to_missing.fam_out,
                autosome = true,
                mind = max_sample_missing_rate,
                output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_miss",
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Filter out low call-rate samples
        call PLINK.make_bed as filter_low_called_samples{
            input:
                bed_in = het_hap_to_missing.bed_out,
                bim_in = het_hap_to_missing.bim_out,
                fam_in = het_hap_to_missing.fam_out,
                keep_samples = get_low_called_samples.fam_out,
                output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_miss.sample_miss",
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Get list of samples with excess homozygosity
        call PLINK.get_excess_homo_samples{
            input:
                bed_in = filter_low_called_samples.bed_out,
                bim_in = filter_low_called_samples.bim_out,
                fam_in = filter_low_called_samples.fam_out,
                output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_miss.sample_miss.het",
                min_he = min_sample_he,
                max_he = max_sample_he,
                cpu = plink_filter_cpu,
                mem_gb = plink_filter_mem_gb
        }

        # Filter them out (if they exist)
        if(size(get_excess_homo_samples.excess_homos) > 0){
            # Filter out low call-rate samples
            call PLINK.make_bed as remove_excess_homos{
                input:
                    bed_in = filter_low_called_samples.bed_out,
                    bim_in = filter_low_called_samples.bim_out,
                    fam_in = filter_low_called_samples.fam_out,
                    remove_samples = get_excess_homo_samples.excess_homos,
                    output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_miss.sample_miss.het",
                    cpu = plink_filter_cpu,
                    mem_gb = plink_filter_mem_gb
            }
        }

        File qc_bed = select_first([remove_excess_homos.bed_out, filter_low_called_samples.bed_out])
        File qc_bim = select_first([remove_excess_homos.bim_out, filter_low_called_samples.bim_out])
        File qc_fam = select_first([remove_excess_homos.fam_out, filter_low_called_samples.fam_out])

        # Relatedness workflow to identify related samples
        call REL.relatedness_wf{
            input:
                bed_in = qc_bed,
                bim_in = qc_bim,
                fam_in = qc_fam,
                output_basename = "${output_basename}.${ancestry}",
                num_king_splits = num_king_splits,
                degree = degree,
                num_pcs_to_analyze = kinship_pcs_to_analyze,
                ancestral_pca_loading_cutoff = ancestral_pca_loading_cutoff,
                max_kinship_snps = max_kinship_snps,
                min_kinship_snps = min_kinship_snps,
                ancestral_pca_loading_step_size = ancestral_pca_loading_step_size,
                max_ancestral_pca_loading_cutoff = max_ancestral_pca_loading_cutoff,
                hwe_pvalue = hwe_filter_pvalue,
                max_missing_site_rate = max_missing_site_rate,
                ld_exclude_regions = ld_exclude_regions,
                ld_type = ld_type,
                window_size = ld_window_size,
                step_size = ld_step_size,
                r2_threshold = ld_r2_threshold,
                min_ld_maf = ld_maf_cutoff,
                king_cpu_per_split = king_cpu_per_split,
                king_mem_gb_per_split = king_mem_gb_per_split,
                pca_cpu = pca_cpu,
                pca_mem_gb = pca_mem_gb,
                qc_cpu = plink_filter_cpu,
                qc_mem_gb = plink_filter_mem_gb,
                ld_cpu = plink_chr_cpu,
                ld_mem_gb = plink_chr_mem_gb,
                merge_bed_cpu = merge_bed_cpu,
                merge_bed_mem_gb = merge_bed_mem_gb,
        }

        # Sex check to see if sex matches phenotype file
        call SEX.sex_check_wf{
            input:
                bed_in = qc_bed,
                bim_in = qc_bim,
                fam_in = qc_fam,
                phenotype_file = sex_check_phenotype_file,
                female_max_f = max_female_f,
                male_min_f = min_male_f,
                output_basename = "${output_basename}.${ancestry}",
                header_rows = phenotype_header_rows,
                fid_col = phenotype_fid_col,
                iid_col = phenotype_iid_col,
                sex_col = phenotype_sex_col,
                delimiter = phenotype_delimiter,
                ld_exclude_regions = ld_exclude_regions,
                ld_type = ld_type,
                window_size = ld_window_size,
                step_size = ld_step_size,
                r2_threshold = ld_r2_threshold,
                min_ld_maf = ld_maf_cutoff,
                build_code = build_code,
                no_fail = true,
                ld_cpu = plink_chr_cpu,
                ld_mem_gb = plink_chr_mem_gb,
                sex_check_cpu = sex_check_cpu,
                sex_check_mem_gb = sex_check_mem_gb
        }

        # Optionally apply filter lists from sex/relatedness workflows to QC filtered samples
        # This section looks kinda weird but it's only because WDL doesn't have 'else/elseif'
        # Combine sample filter lists if filtering both
        if(filter_discrepant_sex && filter_related_samples){
            call UTILS.get_file_union{
                input:
                    input_files = [sex_check_wf.samples_to_remove, relatedness_wf.related_samples],
                    output_filename = "${output_basename}.sex.kin.remove"
            }
            String combined_suffix = "sex_check.unrelated"
        }

        # Set sex file if doing only sex removal
        if(filter_discrepant_sex && !filter_related_samples){
            File sex_remove = sex_check_wf.samples_to_remove
            String sex_suffix = "sex_check"
        }

        # Set kin file if doing only related removal
        if(filter_related_samples && !filter_discrepant_sex){
            File kin_remove = relatedness_wf.related_samples
            String kin_suffix = "unrelated"
        }


        # Now actually apply those filters
        if(filter_discrepant_sex || filter_related_samples){
            # Select the file that contains the set of samples that need to be filtered
            # One of these will necessarily be defined
            File final_filter = select_first([get_file_union.output_file, sex_remove, kin_remove])
            File final_suffix = select_first([combined_suffix, sex_suffix, kin_suffix])

            # Remove samples if resulting file isn't empty
            if(size(final_filter) > 0){
                # Filter out samples as determined by user options
                call PLINK.make_bed as filter_sex_and_kin{
                    input:
                        bed_in = qc_bed,
                        bim_in = qc_bim,
                        fam_in = qc_fam,
                        remove_samples = final_filter,
                        output_basename = "${output_basename}.${ancestry}.snp_miss.hwe.het_hap_miss.sample_miss.het.${final_suffix}",
                        cpu = plink_filter_cpu,
                        mem_gb = plink_filter_mem_gb
                }
            }
        }

        # Finally re-merge PAR/NONPAR regions of chrX
        File split_final_bed = select_first([filter_sex_and_kin.bed_out, qc_bed])
        File split_final_bim = select_first([filter_sex_and_kin.bim_out, qc_bim])
        File split_final_fam = select_first([filter_sex_and_kin.fam_out, qc_fam])
        String final_basename = basename(split_final_bed, ".bed") + ".xmerged"

        call PLINK.make_bed as final_merge_x_chr{
        input:
            bed_in = split_final_bed,
            bim_in = split_final_bim,
            fam_in = split_final_fam,
            output_basename = final_basename,
            merge_x = true,
            merge_no_fail = true,
            cpu = plink_filter_cpu,
            mem_gb = plink_filter_mem_gb
        }
    }

    output{
        # Fully filtered qc beds that have been through all filters
        Array[File] final_qc_bed = final_merge_x_chr.bed_out
        Array[File] final_qc_bim = final_merge_x_chr.bim_out
        Array[File] final_qc_fam = final_merge_x_chr.fam_out

        # Outputs summarizing TeraStructure ancestry analysis
        Array[File] ancestry_thetas = structure_wf.ancestry_thetas
        Array[File] triangle_plots = structure_wf.triangle_plots
        Array[File] samples_by_ancestry = structure_wf.samples_by_ancestry

        # Samples removed for low call rates or excess homozygosity for each ancestry
        Array[File] excess_homo_samples = get_excess_homo_samples.excess_homos

        # QC files that have gone through basic site/sample filter but no kinship/sex filters
        # Can be used later if you don't want to use kinship/sex-discrepancy filtered datasets
        Array[File] basic_qc_bed = qc_bed
        Array[File] basic_qc_bim = qc_bim
        Array[File] basic_qc_fam = qc_fam

        # Kinship estimation outputs for each ancestry
        Array[File] related_samples = relatedness_wf.related_samples
        Array[File] annotated_kinship = relatedness_wf.annotated_kinship_output
        # Kinship id maps for each ancestry bc annotated kinship results have dummy family ids
        Array[File] kinship_id_map =  relatedness_wf.kinship_id_map

        # Sex discrepancy outputs for each ancestry
        Array[File] sex_check_report = sex_check_wf.plink_sex_check_output
        Array[File] sex_check_failed_samples = sex_check_wf.samples_to_remove
    }
}