/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { FASTQC                 } from '../modules/nf-core/fastqc/main'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_dnangs_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/


include { FASTQ_ALIGN_BWA } from '../subworkflows/nf-core/fastq_align_bwa'
include { GATK4_HAPLOTYPECALLER } from '../modules/nf-core/gatk4/haplotypecaller'

process CUSTOM_VCF_ANNOTATE {
    tag "${sample_id}"
    publishDir "${params.outdir}/vcf", mode: 'copy', overwrite: true
    container 'quay.io/biocontainers/bcftools:1.17--h3cc6cd4_2'
    cpus 2
    memory '4 GB'

    input:
    tuple val(sample_id), path(vcf)

    output:
    tuple val(sample_id), path("${sample_id}.annot.vcf.gz"), emit: vcf

    script:
    """
    bcftools annotate --set-id +'%CHROM:%POS:%REF:%ALT' ${vcf} -Oz -o ${meta.id}.annot.vcf.gz
    """
}

process ADD_READ_GROUP {
    tag "${meta.id}"
    publishDir "${params.outdir}/bam", mode: 'copy', overwrite: true
    container 'biocontainers/samtools:1.21--h50ea8bc_0'
    cpus 2
    memory '4 GB'

    input:
    tuple val(meta), path(bam), path(bai)

    output:
    tuple val(meta), path("${meta.id}.rg.bam"), path("${meta.id}.rg.bam.bai")

    script:
    """
    samtools addreplacerg \\
        -r "ID:${meta.rg_id}\tSM:${meta.rg_sm}\tPL:${meta.rg_pl}\tLB:${meta.rg_lb}" \\
        -o ${meta.id}.rg.bam \\
        ${bam}
    samtools index ${meta.id}.rg.bam
    """
}

workflow DNANGS {

    take:
    ch_samplesheet // channel: samplesheet read in from --input
    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()
    //
    // MODULE: Run FastQC
    //
    //FASTQC (
    //    ch_samplesheet
    //)
    //ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]})
    //ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    
    reads_ch = Channel.fromFilePairs(params.reads)
        .map { id, files -> [[id: id, single_end: true, rg_id: "${id}_group", rg_sm: id, rg_pl: 'ILLUMINA', rg_lb: 'lib1'], files] }
    bwa_index_ch = Channel.fromPath(params.bwa_index)
        .collect()  // There are 5 index files, this is how to group all of them into a single object
        .map { index -> [[id: 'refindex'], index] }

    // Triggering FASTQ_ALIGN_BWA subworkflow
    FASTQ_ALIGN_BWA(reads_ch, bwa_index_ch, Channel.value(true), [[], []])

    bam_rg_ch = ADD_READ_GROUP(FASTQ_ALIGN_BWA.out.bam.join(FASTQ_ALIGN_BWA.out.bai, by: 0))
    
    // Preparing input channels for GATK
    fasta_ch = Channel.fromPath(params.ref_fasta)
        .map { fasta -> [[id: 'ref'], fasta] }
    fai_ch = Channel.fromPath(params.ref_fasta_fai)
        .map { fai -> [[id: 'ref'], fai] }
    dict_ch = Channel.fromPath(params.ref_dict)
        .map { dict -> [[id: 'ref'], dict] }
    //gatk_input_ch = FASTQ_ALIGN_BWA.out.bam
    //    .join(FASTQ_ALIGN_BWA.out.bai, by: 0) // Joining BAM with BAI
    //    .map { meta, bam, bai -> [meta, bam, bai, [], []] }
    gatk_input_ch = bam_rg_ch.map { meta, bam, bai -> [meta, bam, bai, [], []] }

    vcf_ch = GATK4_HAPLOTYPECALLER(
        gatk_input_ch, fasta_ch, fai_ch, dict_ch, [ [], [] ], [ [], [] ]
    )

    // Changing variant identifiers
    //CUSTOM_VCF_ANNOTATE(vcf_ch.vcf)


    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_'  +  'dnangs_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }


    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    emit:multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
