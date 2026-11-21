# HF Split Ledger

English · [简体中文](README.zh-CN.md)

Load a public Hugging Face Dataset Viewer split into InterSystems IRIS with one command. Each row keeps its zero-based source index and its JSON document, including nested fields. The source table identifies the dataset, configuration and split. This makes it possible to compare the imported rows with the original viewer page.

## Run from the IRIS terminal

[HFSplit.Importer](src/HFSplit/Importer.cls) is the ObjectScript implementation. It fetches Viewer pages over HTTPS, validates the JSON, resolves source identities and writes the rows in an IRIS transaction. Existing splits keep their original source keys.

1. Open the target application namespace with [InterSystems Package Manager (IPM)](https://github.com/intersystems/ipm) installed. Copy or mount the checkout on the IRIS host and replace the path below with the directory containing `module.xml`. The installing account needs permission to compile classes in this namespace.

```objectscript
zpm "load /opt/hf-split-ledger"
```

   If your configured registry carries the module, you can also run `zpm "install hf-split-ledger 1.0.0"`.

   To compile manually, mount the checkout at `/app` and run the following in the target namespace.

```objectscript
set sc=$system.OBJ.Load("/app/src/HFSplit/Importer.cls","ck")
if $system.Status.IsError(sc) do $system.Status.DisplayError(sc)
```

2. Configure an IRIS client TLS profile with peer verification. On a clean Linux IRIS 2026.2 container an administrator can create the following profile in the `%SYS` namespace. Use the appropriate trusted CA file on other systems.

```objectscript
set p("Enabled")=1,p("Type")=0,p("VerifyPeer")=2
set p("CAFile")="/etc/ssl/certs/ca-certificates.crt"
set sc=##class(Security.SSLConfigs).Create("HFViewerTLS",.p)
do $system.Status.DisplayError(sc)
```

3. Return to the application namespace. The command below returns `101`. Omit the fourth argument to import the whole split. Pass an existing TLS profile name as the fifth argument if needed. The user needs permission to create and update the application tables in `HFSplit`. The IRIS host needs HTTPS access to Dataset Viewer.

```objectscript
write ##class(HFSplit.Importer).Import("cornell-movie-review-data/rotten_tomatoes","default","test",101)
```

## Run from the shell

The compatible Python 3.10+ CLI passes its arguments to the ObjectScript class using the official driver. Set `HF_VIEWER_TLS` to select the outbound IRIS profile. For a remote database connection, set `IRIS_SSL_CONFIG` to your client TLS configuration. The CLI account needs permission to invoke the importer through the IRIS Native API in the application namespace.

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-cli.txt
export IRIS_DSN='localhost:1972/USER'
export IRIS_USER='your-import-user'
# Set IRIS_PASSWORD in your shell or secret manager.
python ledger.py cornell-movie-review-data/rotten_tomatoes default test --limit 101
```

Expected output for the sample is `Committed 101 rows for cornell-movie-review-data/rotten_tomatoes / default / test.` Omit `--limit` to refresh the entire split. Run this SQL in the same IRIS namespace to inspect the page boundary.

```sql
SELECT r.SourceRow, r.JsonBody
FROM HFSplit.Records r
JOIN HFSplit.Sources s ON s.SourceKey = r.SourceKey
WHERE s.DatasetName = 'cornell-movie-review-data/rotten_tomatoes'
  AND s.ConfigName = 'default' AND s.SplitName = 'test'
  AND r.SourceRow IN (99, 100)
ORDER BY r.SourceRow
```

## Refresh behavior

Each dataset/config/split has its own key. A full refresh inserts or updates source rows and removes stale trailing rows in one transaction. A limited import updates only the requested prefix and preserves any previous suffix. A failed page or IRIS write rolls back the run. Use this tool for small and medium splits that fit in one IRIS transaction.

The source must expose complete JSON rows through the public Dataset Viewer API. Rows with truncated fields or inconsistent offsets are rejected. The importer checks the reported total and, when provided, the revision header while paging. It does not pin an immutable revision when the server omits that header. Network access to the viewer is required.

## Verify

In a disposable test namespace, compile the deterministic page fixture from a checkout mounted at `/app` (adjust the path as needed). Use the same namespace for the verification commands below.

```objectscript
set sc=$system.OBJ.Load("/app/tests/HFSplitTest.Fixture.cls","ck")
do $system.Status.DisplayError(sc)
```

```sh
python -m unittest -v
python verify_live.py
```

The native tests cover page boundaries, preserved suffixes, empty splits and rollback on truncated rows or a revision change. The live script imports the complete public split twice and compares the total and two boundary rows with the source. Both runs on IRIS 2026.2 produced 1,066 rows.

Platform interfaces: [Dataset Viewer rows](https://huggingface.co/docs/dataset-viewer/en/rows) and [InterSystems Python DB-API](https://docs.intersystems.com/irislatest/csp/docbook/DocBook.UI.Page.cls?KEY=BPYDBAPI_refapi).

Community Bounty idea: [Load datasets from Hugging Face into IRIS](https://ideas.intersystems.com/ideas/DPI-I-543).
