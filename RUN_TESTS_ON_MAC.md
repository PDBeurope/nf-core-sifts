# Testing `fasta_makedb_taxonomy_mmseqs_blast` on macOS

> **Temporary document.** Delete it, and the `standalone/` folder, before this
> branch goes into a pull request.

This guide runs the `fasta_makedb_taxonomy_mmseqs_blast` subworkflow on a Mac,
using Docker. The subworkflow builds a taxonomy-aware protein database from a
FASTA file and an accession-to-taxid mapping, with either MMseqs2 or BLAST.

There are two ways to run it:

- **Steps 1–5:** run its nf-test suite with the bundled test data. It takes about
  15 minutes the first time, mostly installing tools and pulling containers. The
  tests run in under a minute.
- **Step 6:** build a database from your own data and check its taxonomy, after
  doing steps 1–3.

## 1. Install the tools

You need [Homebrew](https://brew.sh). Then:

```bash
brew install nextflow colima docker
```

`nextflow` pulls in the Java it needs. Check you have Nextflow 25.10.4 or newer:

```bash
nextflow -version
```

nf-test is not on Homebrew. Install it into `~/.local/bin`:

```bash
mkdir -p ~/.local/bin && cd ~/.local/bin && curl -fsSL https://get.nf-test.com | bash && cd -
```

If `nf-test version` says "command not found", add `~/.local/bin` to your
`PATH` (for example in `~/.zshrc`) and open a new terminal:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 2. Start Docker (colima)

The test snapshots were generated on **linux/amd64**, so on Apple Silicon
(M1/M2/M3/M4) the containers must run under amd64 emulation. Check your chip
with `uname -m`: `arm64` means Apple Silicon, `x86_64` means Intel.

**Apple Silicon:** install Rosetta once, then start colima with Rosetta
emulation:

```bash
softwareupdate --install-rosetta --agree-to-license
```

```bash
colima start --vm-type vz --vz-rosetta --cpu 4 --memory 8
```

**Intel Mac:**

```bash
colima start --cpu 4 --memory 8
```

Check that amd64 containers work. This should print `x86_64`:

```bash
docker run --rm --platform linux/amd64 alpine:3.20 uname -m
```

> Already using Docker Desktop instead of colima? That works too. On Apple
> Silicon, turn on "Use Rosetta for x86_64/amd64 emulation" in its settings,
> then skip to the check above.

## 3. Get the pipeline branch

Clone somewhere under your home folder, because colima only shares your home
directory with the containers:

```bash
git clone --branch fasta_makedb_taxonomy_mmseqs_blast https://github.com/PDBeurope/nf-core-sifts.git ~/nf-core-sifts
```

```bash
cd ~/nf-core-sifts
```

## 4. Point the tests at the test data

The test files (`uniprot_sprot_mini.fasta` and its taxid mapping) are not in
nf-core/test-datasets yet. They are on the `add-uniprot-sprot-mini` branch of
the PDBeurope fork. Create two small override configs in `testing/`, a folder
git already ignores:

```bash
mkdir -p testing
cat > testing/nextflow.config <<'EOF'
includeConfig '../tests/nextflow.config'
params.modules_testdata_base_path = 'https://raw.githubusercontent.com/PDBeurope/test-datasets/add-uniprot-sprot-mini/data/'
EOF
sed 's#configFile = "tests/nextflow.config"#configFile = "testing/nextflow.config"#' nf-test.config > testing/nf-test.config
```

Nothing tracked by git changes. Running `git status` should show no new files.

## 5. Run the tests

From `~/nf-core-sifts`:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 nf-test test subworkflows/local/fasta_makedb_taxonomy_mmseqs_blast/tests/main.nf.test --config testing/nf-test.config --profile +docker
```

`DOCKER_DEFAULT_PLATFORM` forces the amd64 containers, and `--profile +docker`
adds Docker to the pipeline's `test` profile. The first run is slow while
Docker pulls the containers.

### What success looks like

Five tests run, and the run ends with:

```
SUCCESS: Executed 5 tests in ...
```

The third test, `unsupported tool`, prints `[FAILED]` for its workflow and still
reports `PASSED`. That is expected: it checks that the subworkflow rejects an
unknown tool name.

**Do not run with `--update-snapshot`.** A snapshot mismatch is exactly what
this test is meant to catch, so report it instead.

## 6. Run with your own data

The subworkflow is not wired into the pipeline yet, so use the standalone runner
in `standalone/`. It runs only this subworkflow, with the pipeline's own config,
then reads the taxids back out of the database it built and compares them with
your mapping.

### Prepare your inputs

You need:

- **A protein FASTA**, plain or gzipped. The ID MMseqs2/BLAST take from each
  header must match the first column of the mapping. For UniProt headers such
  as `>sp|P0DTC4|VEMP_SARS2 ...`, that ID is the accession, `P0DTC4`.
- **A taxid mapping**: two tab-separated columns, `accession<TAB>taxid`, with no
  header row. For a UniProt FASTA, you can build it from the `OX=` field of the
  headers:

  ```bash
  gzip -dcf proteins.fasta.gz | awk '/^>/ { split($1, id, "|"); if (match($0, /OX=[0-9]+/)) print id[2] "\t" substr($0, RSTART + 3, RLENGTH - 3) }' > tax_mapping.tsv
  ```

- **An NCBI taxdump** (MMseqs2 only): either the `.tar.gz` or an unpacked folder
  that directly contains `names.dmp` and `nodes.dmp`. To get the current one:

  ```bash
  curl -O https://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz
  ```

Keep your inputs under your home folder, so colima can share them with the
containers.

### Run

From `~/nf-core-sifts`, with MMseqs2:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 nextflow run standalone/fasta_makedb_taxonomy_mmseqs_blast.nf -c standalone/standalone.config -profile docker --fasta /path/to/proteins.fasta.gz --tax_mapping /path/to/tax_mapping.tsv --tool mmseqs --taxdump /path/to/taxdump.tar.gz --outdir my_results
```

With BLAST, drop `--taxdump` and use `--tool blast`:

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 nextflow run standalone/fasta_makedb_taxonomy_mmseqs_blast.nf -c standalone/standalone.config -profile docker --fasta /path/to/proteins.fasta.gz --tax_mapping /path/to/tax_mapping.tsv --tool blast --outdir my_results
```

Run it from the repository folder: the runner relies on the pipeline's
`nextflow.config` there for the `docker` profile and module settings.

Other options:

| Option | Default | Meaning |
|---|---|---|
| `--db_id` | `uniprot` | Name of the database folder. For MMseqs2, also the file prefix inside it. |
| `--max_memory` | `8.GB` | Memory cap per task. Keep it below what colima has (`--memory` in step 2). |
| `--max_cpus` | `4` | CPU cap per task. Keep it at or below colima's `--cpu`. |

The caps matter: without them, the pipeline's defaults ask for 200 GB for the
MMseqs2 indexing step and Nextflow refuses to start it. For large inputs, restart
colima with more memory (`colima stop`, then `colima start ... --memory 16`) and
raise `--max_memory` to match.

### Check the result

The run ends with a summary like this:

```
Database: /Users/you/nf-core-sifts/my_results/database/uniprot
Taxonomy check (details in .../my_results/database/taxonomy_check.tsv):
Sequences in database:                    10
  taxid matches input mapping (OK):       10
  taxid differs from mapping (MISMATCH):  0
  no taxid in database (NO_TAXID):        0
  accession not in mapping:               0
Mapping accessions absent from database:  0
```

`my_results/database/` holds the database folder and `taxonomy_check.tsv`, one
row per accession. Rows with problems are sorted to the top:

| Status | Meaning |
|---|---|
| `OK` | The database stores the taxid your mapping gives. |
| `MISMATCH` | The database stores a different taxid. This would point to a bug, so please report it. |
| `NO_TAXID` | The accession is in your mapping, but the database has no taxid for it. With MMseqs2, check that the taxid exists in your taxdump. |
| `NOT_IN_MAPPING` | The sequence is in the database, but its ID matched nothing in your mapping, so it has no taxid. Usually the FASTA header IDs and the mapping's first column don't agree. |
| `NOT_IN_DB` | The accession is in your mapping, but no sequence in the FASTA has that ID. |

This checks that the database stores the taxids you gave it. It does not check
that those taxids are right: a wrong taxid in your mapping shows as `OK`.

## 7. If something fails

Send back:

- the full terminal output of the `nf-test test` command
- the output of `uname -m`, `nextflow -version`, `nf-test version` and `colima version`
- the `.nf-test.log` file from `~/nf-core-sifts`

Common problems:

| Symptom | Likely cause and fix |
|---|---|
| `Cannot connect to the Docker daemon` | colima is not running: `colima start ...` as in step 2. |
| Snapshot mismatch in the `mmseqs` or `blast` tests | Containers ran as arm64. Check the `x86_64` check in step 2 and that `DOCKER_DEFAULT_PLATFORM=linux/amd64` is on the same line as `nf-test`. |
| `No such file` / 404 for `uniprot_sprot_mini` | The override config is not being used. Check that `--config testing/nf-test.config` is in the command and step 4 ran in `~/nf-core-sifts`. |
| Permission or mount errors inside the container | The clone or your input files are outside your home folder. Move them under `~`. |
| `Task requirement exceeds available memory` (step 6) | `--max_memory` is higher than the machine allows, or the caps are missing because `-c standalone/standalone.config` was left out. |
| `--taxdump ... has no names.dmp` (step 6) | The folder you passed contains another folder. Point `--taxdump` at the one that directly holds `names.dmp`, or pass the `.tar.gz` instead. |

## 8. Clean up

```bash
rm -rf ~/nf-core-sifts/.nf-test ~/nf-core-sifts/.nf-test.log ~/nf-core-sifts/testing
```

If you ran step 6, also remove Nextflow's work folder and logs (and your
`--outdir` folder, once you no longer need the database):

```bash
rm -rf ~/nf-core-sifts/work ~/nf-core-sifts/.nextflow ~/nf-core-sifts/.nextflow.log*
```

```bash
colima stop
```
