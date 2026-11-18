#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    TEMPORARY standalone runner for FASTA_MAKEDB_TAXONOMY_MMSEQS_BLAST
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Runs the subworkflow on your own data, outside the pipeline, then checks that
    the taxids stored in the database match the input mapping.
    Delete the standalone/ folder before this branch goes into a pull request.

    Run from the repository root:
        nextflow run standalone/fasta_makedb_taxonomy_mmseqs_blast.nf \
            -c standalone/standalone.config -profile docker \
            --fasta proteins.fasta --tax_mapping tax_mapping.tsv \
            --tool mmseqs --taxdump taxdump.tar.gz --outdir results
----------------------------------------------------------------------------------------
*/

include { UNTAR                              } from '../modules/nf-core/untar/main'
include { FASTA_MAKEDB_TAXONOMY_MMSEQS_BLAST } from '../subworkflows/local/fasta_makedb_taxonomy_mmseqs_blast/main'

// Read accession -> taxid back out of the built database and compare it with the input mapping
process CHECK_TAXONOMY {
    tag "${meta.id}"
    label 'process_single'

    container "${ tool == 'blast'
        ? 'community.wave.seqera.io/library/blast:2.17.0--d4fb881691596759'
        : 'community.wave.seqera.io/library/mmseqs2:18.8cc5c--af05c9a98d9f6139' }"

    input:
    tuple val(meta), path(db), path(tax_mapping)
    val tool

    output:
    tuple val(meta), path("taxonomy_check.tsv")        , emit: tsv
    tuple val(meta), path("taxonomy_check_summary.txt"), emit: summary

    script:
    def db_taxids_cmd = tool == 'blast'
        ? "blastdbcmd -dbtype prot -db \"\$(ls ${db}/*.pin | head -n 1 | sed 's/\\.pin\$//')\" -entry all -outfmt '%a\t%T' > db_taxids.tsv"
        : "awk 'BEGIN { FS = OFS = \"\\t\" } NR == FNR { tax[\$1] = \$2; next } { print \$2, (\$1 in tax ? tax[\$1] : 0) }' ${db}/${meta.id}_mapping ${db}/${meta.id}.lookup > db_taxids.tsv"
    """
    ${db_taxids_cmd}

    awk 'BEGIN { FS = OFS = "\\t" }
        FNR == 1 { file++ }
        file == 1 { sub(/\\r\$/, ""); expected[\$1] = \$2; next }
        file == 2 { if (!(\$1 in found)) n_db++; found[\$1] = \$2 }
        END {
            print "accession", "expected_taxid", "db_taxid", "status"
            for (a in found) {
                if (!(a in expected))            { status = "NOT_IN_MAPPING"; n_extra++ }
                else if (found[a] == 0)          { status = "NO_TAXID";       n_missing++ }
                else if (found[a] == expected[a]) { status = "OK";             n_ok++ }
                else                             { status = "MISMATCH";       n_bad++ }
                print a, (a in expected ? expected[a] : "-"), found[a], status
            }
            for (a in expected) if (!(a in found)) { print a, expected[a], "-", "NOT_IN_DB"; n_absent++ }
            printf "Sequences in database:                    %d\\n", n_db + 0            > "taxonomy_check_summary.txt"
            printf "  taxid matches input mapping (OK):       %d\\n", n_ok + 0            > "taxonomy_check_summary.txt"
            printf "  taxid differs from mapping (MISMATCH):  %d\\n", n_bad + 0           > "taxonomy_check_summary.txt"
            printf "  no taxid in database (NO_TAXID):        %d\\n", n_missing + 0       > "taxonomy_check_summary.txt"
            printf "  accession not in mapping:               %d\\n", n_extra + 0         > "taxonomy_check_summary.txt"
            printf "Mapping accessions absent from database:  %d\\n", n_absent + 0        > "taxonomy_check_summary.txt"
        }' ${tax_mapping} db_taxids.tsv > taxonomy_check.unsorted.tsv

    { head -n 1 taxonomy_check.unsorted.tsv; tail -n +2 taxonomy_check.unsorted.tsv | sort -k4,4 -k1,1; } > taxonomy_check.tsv
    rm taxonomy_check.unsorted.tsv db_taxids.tsv
    """
}

// Named wrapper so process names match the pipeline (and conf/modules.config selectors)
workflow RUN_FASTA_MAKEDB {

    take:
    ch_fasta_taxmap
    ch_taxdump
    val_tool

    main:
    FASTA_MAKEDB_TAXONOMY_MMSEQS_BLAST(ch_fasta_taxmap, ch_taxdump, val_tool)

    CHECK_TAXONOMY(
        FASTA_MAKEDB_TAXONOMY_MMSEQS_BLAST.out.db
            .join(ch_fasta_taxmap.map { meta, _fasta, tax_mapping -> [ meta, tax_mapping ] }, failOnMismatch: true),
        val_tool
    )

    emit:
    db      = FASTA_MAKEDB_TAXONOMY_MMSEQS_BLAST.out.db
    summary = CHECK_TAXONOMY.out.summary
}

workflow {

    main:
    if (!params.fasta)       { error("Missing --fasta: protein FASTA to index") }
    if (!params.tax_mapping) { error("Missing --tax_mapping: tab-separated accession<TAB>taxid file, no header") }
    if (!params.outdir)      { error("Missing --outdir: where to write the database") }
    if (!(params.tool in ['mmseqs', 'blast'])) {
        error("Unsupported --tool '${params.tool}': expected 'mmseqs' or 'blast'")
    }
    if (params.tool == 'mmseqs' && !params.taxdump) {
        error("Missing --taxdump: NCBI taxdump directory or .tar.gz, required for --tool mmseqs")
    }

    def ch_fasta_taxmap = channel.of([
        [ id: params.db_id ],
        file(params.fasta, checkIfExists: true),
        file(params.tax_mapping, checkIfExists: true)
    ])

    def ch_taxdump = channel.value([ [], [] ])
    if (params.tool == 'mmseqs') {
        def taxdump = file(params.taxdump, checkIfExists: true)
        if (taxdump.isDirectory()) {
            if (!taxdump.resolve('names.dmp').exists()) {
                error("--taxdump ${taxdump} has no names.dmp: point it at the folder that directly contains names.dmp and nodes.dmp")
            }
            ch_taxdump = channel.value([ [ id: 'taxdump' ], taxdump ])
        }
        else {
            UNTAR(channel.of([ [ id: 'taxdump' ], taxdump ]))
            ch_taxdump = UNTAR.out.untar
        }
    }

    RUN_FASTA_MAKEDB(ch_fasta_taxmap, ch_taxdump, params.tool)

    RUN_FASTA_MAKEDB.out.db.view { _meta, db -> "Database: ${file(params.outdir).toAbsolutePath()}/database/${db.name}" }
    RUN_FASTA_MAKEDB.out.summary.view { _meta, summary ->
        "Taxonomy check (details in ${file(params.outdir).toAbsolutePath()}/database/taxonomy_check.tsv):\n${summary.text}"
    }
}
