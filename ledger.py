"""Import a public Hugging Face split using the native IRIS HFSplit.Importer class."""
import argparse
from contextlib import closing
import os
import sys

import iris
import iris.dbapi


def connect():
    """Connect the SDK to the configured namespace, using client TLS when configured."""
    options = {"sslconfig": os.environ["IRIS_SSL_CONFIG"]} if os.getenv("IRIS_SSL_CONFIG") else {}
    return iris.dbapi.connect(os.environ.get("IRIS_DSN", "localhost:1972/USER"),
                              os.environ["IRIS_USER"], os.environ["IRIS_PASSWORD"], **options)


def main():
    """Pass CLI arguments to IRIS, where pagination, validation and storage run."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset")
    parser.add_argument("config")
    parser.add_argument("split")
    parser.add_argument("--limit", type=int, help="Refresh only the first N rows")
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    with closing(connect()) as conn:
        count = iris.createIRIS(conn).classMethodInteger(
            "HFSplit.Importer", "Import", args.dataset, args.config, args.split, args.limit or 0,
            os.environ.get("HF_VIEWER_TLS", "HFViewerTLS"))
    print(f"Committed {count} rows for {args.dataset} / {args.config} / {args.split}.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Import failed: {error}")
