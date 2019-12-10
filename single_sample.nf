#!/usr/bin/env nextflow
/*
Author: Ólavur Mortensen <olavur@fargen.fo>
*/


/*
TODO:


*/

// Input parameters.
params.fastq_r1 = null
params.fastq_r2 = null
params.reference = null
params.targets = null
params.whitelist = null
params.bcbins = null
params.dbsnp = null
params.outdir = null
params.help = false

// TODO: make help string
// Help message
helpMessage = """
Parameters:
--outdir            Desired path/name of folder to store output in.
""".stripIndent()

// Show help when needed
if (params.help){
    log.info helpMessage
        exit 0
}

// Make sure necessary input parameters are assigned.
assert params.fastq_r1 != null, 'Input parameter "fastq_r1" cannot be unasigned.'
assert params.fastq_r2 != null, 'Input parameter "fastq_r2" cannot be unasigned.'
assert params.reference != null, 'Input parameter "reference" cannot be unasigned.'
assert params.targets != null, 'Input parameter "targets" cannot be unasigned.'
assert params.whitelist != null, 'Input parameter "whitelist" cannot be unasigned.'
assert params.bcbins != null, 'Input parameter "bcbins" cannot be unasigned.'
assert params.dbsnp != null, 'Input parameter "dbsnp" cannot be unasigned.'
assert params.outdir != null, 'Input parameter "outdir" cannot be unasigned.'

println "P I P E L I N E     I P U T S    "
println "================================="
println "fastq_r1           : ${params.fastq_r1}"
println "fastq_r2           : ${params.fastq_r2}"
println "reference          : ${params.reference}"
println "targets            : ${params.targets}"
println "whitelist          : ${params.whitelist}"
println "bcbins             : ${params.bcbins}"
println "dbsnp              : ${params.dbsnp}"
println "outdir             : ${params.outdir}"
println '=================================='

// Get file handlers for input files.
reference = file(params.reference, checkIfExists: true)
targets = file(params.targets, checkIfExists: true)
whitelist = file(params.whitelist, checkIfExists: true)
dbsnp = file(params.dbsnp, checkIfExists: true)
outdir = file(params.outdir)

/*
TODO:

* Could check if the file is compressed, using cheking that item.getExtension() is 'gz'.
* Could check that there there are matching lanes, R1 and R2 for L0001 and so on.
* Check that FASTQs are "valid", e.g. with FastQValidator:
    * https://genome.sph.umich.edu/wiki/FastQValidator

*/

// Get channels of the read 1 and 2 FASTQ files.
Channel.fromPath(params.fastq_r1).into { fastq_r1_print_ch; fastq_r1_check_ch; fastq_r1_merge_ch; fastq_readgroup_ch; fastq_samplename_ch }
Channel.fromPath(params.fastq_r2).into { fastq_r2_print_ch; fastq_r2_check_ch; fastq_r2_merge_ch }

// Check that the there are at least one FASTQ files for read 1 and 2, and that there are an equal number of files for read 1 and 2.
process check_fastq {
    input:
    val fastq_r1 from fastq_r1_check_ch.toList()
    val fastq_r2 from fastq_r2_check_ch.toList()
    
    output:
    val 'done' into check_fastq_status_ch

    exec:
    assert fastq_r1.size() > 0, 'The "fastq_r1" input parameter pattern did not match any files.'
    assert fastq_r2.size() > 0, 'The "fastq_r2" input parameter pattern did not match any files.'
    assert fastq_r1.size() == fastq_r2.size(), 'There is an unequal number of lanes in read 1 and read 2; the fastq_r1 and fastq_r2 patterns matched an unequal number of files.'
}

// Print some info about the input FASTQ files.
process print_fastq {
    echo true
    
    input:
    val status from check_fastq_status_ch
    val fastq_r1 from fastq_r1_print_ch.toList()
    val fastq_r2 from fastq_r2_print_ch.toList()
    
    output:
    val 'done' into print_fastq_status_ch

    exec:
    println '\nFASTQ path\t\t\t\t\tRead in pair\tSize (bytes)\tNumber of reads'
    fastq_r1.each { item ->
        println "${item.getName()}\t\tFirst\t\t${item.size()}\t\t${item.countFastq()}"
    }
    fastq_r2.each { item ->
        println "${item.getName()}\t\tSecond\t\t${item.size()}\t\t${item.countFastq()}"
    }
    println '==================================\n'
}

/*
First, we align the data to reference with EMA. In order to do so, we need to do some pre-processing, including,
but not limited to, merging lanes, counting barcodes, and binning reads.
*/

// Merge all lanes in read 1 and 2.
process merge_lanes {
    input:
    val status from print_fastq_status_ch
    val fastq_r1 from fastq_r1_merge_ch.toList()
    val fastq_r2 from fastq_r2_merge_ch.toList()

    output:
    file 'R1.fastq' into merged_fastq_r1_ch
    file 'R2.fastq' into merged_fastq_r2_ch

    script:
    r1_list = fastq_r1.join(' ')
    r2_list = fastq_r2.join(' ')
    """
    zcat $r1_list > 'R1.fastq'
    zcat $r2_list > 'R2.fastq'
    """
}

// Interleave reads 1 and 2.
process interleave_fastq {
    input:
    file r1 from merged_fastq_r1_ch
    file r2 from merged_fastq_r2_ch

    output:
    file 'interleaved.fastq' into fastq_count_ch, fastq_preproc_ch

    script:
    """
    interleave_fastq.sh $r1 $r2 > 'interleaved.fastq'
    """
}

// Count barcodes in FASTQ.
process bc_count {
    input:
    file fastq from fastq_count_ch

    output:
    set file('*.ema-fcnt'), file('*.ema-ncnt') into bc_count_ch

    script:
    """
    cat $fastq | ema count -w $whitelist -o bc_count
    """
}

// Statistical binning of reads, splitting the reads into bins.
// TODO:
// How many bins to use?
// Number of bins seems to have a large effect on how many reads end up in the "non-barcode" (nobc) bin.
// The ema GitHub recomments 500 bins.
// Barcode correction report?
process preproc {
    input:
    file fastq from fastq_preproc_ch
    set file(fcnt), file(ncnt) from bc_count_ch

    output:
    file "preproc_dir/ema-bin-*" into bins_ema_ch mode flatten
    file "preproc_dir/ema-nobc" into nobc_bin_bwa_ch

    script:
    """
    cat $fastq | ema preproc -h -w $whitelist -n ${params.bcbins} -t ${task.cpus} -o 'preproc_dir' $ncnt
    """
}

// Construct a readgroup from the filename of one of the input FASTQ files.
process get_samplename {
    input:
    file fastq_list from fastq_samplename_ch.toList()

    output:
    stdout sample_ch

    script:
    // Use just the first FASTQ file in the list.
    fastq = fastq_list[0]
    """
    get_samplenames.py $fastq
    """
}

// Construct a readgroup from the sequence identifier in one of the input FASTQ files.
process get_readgroup {
    input:
    file fastq_list from fastq_readgroup_ch.toList()

    output:
    stdout readgroup_ch

    script:
    // Use just the first FASTQ file in the list.
    fastq = fastq_list[0]
    """
    get_readgroups.py $fastq
    """
}

// Duplicate the readgroup channel.
readgroup_ch.into { readgroup_ema_ch; readgroup_bwa_ch }

// Combine the readgroup channel with the EMA bins channel so that each instance of the ema_align process gets
// a readgroup object.
bins_ema_ch = readgroup_ema_ch.combine(bins_ema_ch)

// Align reads from each bin with EMA.
process ema_align {
    input:
    set rg, file(bin) from bins_ema_ch

    output:
    file "${bin}.bam" into ema_bam_ch

    script:
    """
    ema align -t ${task.cpus} -d -r $reference -R '$rg' -s $bin | \
        samtools view -b -o ${bin}.bam
    """
}

// Align the no-barcode bin. These reads had barcodes that didn't match the whitelist.
process map_nobc {
    input:
    file nobc_bin from nobc_bin_bwa_ch
    val rg from readgroup_bwa_ch

    output:
    file "nobc.bam" into nobc_bam_ch

    script:
    """
    bwa mem -p -t ${task.cpus} -M -R '$rg' $reference $nobc_bin | \
        samtools view -b -o nobc.bam
    """
}

// Combine BAMs from EMA and BWA into a single channel for merging.
aligned_bam_merge_ch = ema_bam_ch.concat(nobc_bam_ch)

// Merge BAMs from both EMA and BWA.
// All BAMs have the same readgroup, so the RG and PG headers wil be combined.
process merge_bams {
    input:
    file bams from aligned_bam_merge_ch.collect()

    output:
    file "merged.bam" into merged_bam_sort_ch

    script:
    bam_list = (bams as List).join(' ')
    """
    samtools merge -@ ${task.cpus} -O bam -l 0 -c -p "merged.bam" $bam_list
    """
}

// Coordinate sort BAM.
process sort_bam {
    input:
    file bam from merged_bam_sort_ch

    output:
    file "sorted.bam" into sorted_bam_markdup_ch

    script:
    """
    samtools sort -@ ${task.cpus} -O bam -l 0 -m 4G -o "sorted.bam" $bam
    """
}

// Mark duplicates in BAM.
// NOTE:
// MarkDuplicates has the following option, I wonder why:
// --BARCODE_TAG:String          Barcode SAM tag (ex. BC for 10X Genomics)  Default value: null.                          
process mark_dup {
    input:
    file bam from sorted_bam_markdup_ch

    output:
    file "marked_dup.bam" into marked_bam_index_ch

    script:
    """
    gatk MarkDuplicates -I $bam -O "marked_dup.bam" -M "marked_dup_metrics.txt"
    """
}

// Index the BAM.
process index_bam {
    input:
    file bam from marked_bam_index_ch
    val sample from sample_ch

    output:
    set sample, file("$bam"), file("${bam}.bai") into indexed_bam_prepare_ch, indexed_bam_apply_ch

    script:
    """
    gatk BuildBamIndex -I $bam -O "${bam}.bai"
    """
}

/*
The next three processes, prepare_bqsr_table, analyze_covariates, and apply_bqsr, deal with base quality score
recalibration, in preparation for GATK best practices.
BQSR: https://software.broadinstitute.org/gatk/documentation/article?id=44
*/

// Generate recalibration table for BQSR.
process prepare_bqsr_table {
    input:
    set sample, file(bam), file(bai) from indexed_bam_prepare_ch

    output:
    set sample, file('bqsr.table') into bqsr_table_analyze_ch, bqsr_table_apply_ch

    script:
    """
    mkdir tmp
    gatk BaseRecalibrator \
            -I $bam \
            -R $reference \
            --known-sites $dbsnp \
            -O 'bqsr.table' \
            --tmp-dir=tmp \
            --java-options "-Xmx${task.memory.toGiga()}g -Xms${task.memory.toGiga()}g"
    """
}

// Evaluate BQSR.
process analyze_covariates {
    publishDir "$outdir/bam/recalibrated/$sample", mode: 'copy', overwrite: true

    input:
    set sample, file(bqsr_table) from bqsr_table_analyze_ch

    output:
    set sample, file('AnalyzeCovariates.pdf') into bqsr_analysis_ch

    script:
    """
    gatk AnalyzeCovariates \
        -bqsr $bqsr_table \
        -plots 'AnalyzeCovariates.pdf'
    """
}

// Pair the BAM and the BQSR table in one "set" channel.
data_apply_bqsr_ch = indexed_bam_apply_ch.join(bqsr_table_apply_ch)

// Apply recalibration to BAM file.
process apply_bqsr {
    publishDir "$outdir/bam/recalibrated/$sample", mode: 'copy', pattern: '*.bam', overwrite: true,
        saveAs: { filename -> "${sample}.bam" }
    publishDir "$outdir/bam/recalibrated/$sample", mode: 'copy', pattern: '*.bam.bai', overwrite: true,
        saveAs: { filename -> "${sample}.bam.bai" }

    input:
    set sample, file(bam), file(bai), file(bqsr_table) from data_apply_bqsr_ch

    output:
    set sample, file("recalibrated.bam"), file("recalibrated.bam.bai") into recalibrated_bam_call_ch, recalibrated_bam_qualimap_ch

    script:
    """
    mkdir tmp
    gatk ApplyBQSR \
        -R $reference \
        -I $bam \
        --bqsr-recal-file $bqsr_table \
        -L $targets \
        -O "recalibrated.bam" \
        --tmp-dir=tmp \
        --java-options "-Xmx${task.memory.toGiga()}g -Xms${task.memory.toGiga()}g"
    mv "recalibrated.bai" "recalibrated.bam.bai"
    """
}

// Call variants in sample with HapltypeCaller, yielding a GVCF.
process call_sample {
    publishDir "$outdir/gvcf", mode: 'copy', overwrite: true

    input:
    set sample, file(bam), file(bai) from recalibrated_bam_call_ch

    output:
    set sample, file("${sample}.g.vcf"), file("${sample}.g.vcf.idx") into gvcf_ch

    script:
    """
    mkdir tmp
    gatk HaplotypeCaller  \
        -I $bam \
        -O "${sample}.g.vcf" \
        -R $reference \
        -L $targets \
        --dbsnp $dbsnp \
        -ERC GVCF \
        --create-output-variant-index \
        --annotation MappingQualityRankSumTest \
        --annotation QualByDepth \
        --annotation ReadPosRankSumTest \
        --annotation RMSMappingQuality \
        --annotation FisherStrand \
        --annotation Coverage \
        --verbosity INFO \
        --tmp-dir=tmp \
        --java-options "-Xmx${task.memory.toGiga()}g -Xms${task.memory.toGiga()}g"
    """
}

/*
Below we perform QC of data.
*/

// Run Qualimap for QC metrics of recalibrated BAM.
process qualimap_analysis {
    publishDir "$outdir/bam/recalibrated/$sample", mode: 'copy', overwrite: true

    input:
    set sample, file(bam), file(bai) from recalibrated_bam_qualimap_ch

    output:
    set sample, file("qualimap_results") into qualimap_results_ch

    script:
    """
    # This first line adds two columns to our BED file with target regions, as QualiMap expects these.
    # The fifth and sixth column are respectively just "0" and ".", which has no information about the
    # regions.
    awk 'BEGIN{OFS="\\t"}{ if(NR > 2) { print \$1,\$2,\$3,\$4,0,"." } }' $targets > 'targets_6_fields.bed'

    # FIXME:
    # remove this when done testing.
    # and uncomment awk command above
    #echo 'track name="dummy" description="dummy BED" color=0,0,128 db=hg38' > 'targets_6_fields.bed'
    #echo 'chr17    1  83257441 allchr17   0   .' > 'targets_6_fields.bed'
    # FIXME

    # Make sure QualiMap doesn't attemt to open a display server.
    unset DISPLAY
    # Run QualiMap.
    qualimap bamqc \
        -gd HUMAN \
        -bam $bam \
        -gff 'targets_6_fields.bed' \
        -outdir "qualimap_results" \
        --skip-duplicated \
        --collect-overlap-pairs \
        -nt ${task.cpus} \
        --java-mem-size=${task.memory.toGiga()}G
    """
}

