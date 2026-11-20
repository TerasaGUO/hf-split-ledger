"""Verify the public demo against a disposable IRIS namespace (network required)."""
from contextlib import closing
import json
from pathlib import Path
import subprocess
import sys

import requests
from ledger import connect


def verify():
    """Import a split twice, compare the page boundary against the source."""
    source = ("cornell-movie-review-data/rotten_tomatoes", "default", "test")
    command = [sys.executable, str(Path(__file__).with_name("ledger.py")), *source]
    for _ in range(2):
        subprocess.run(command, check=True)
    response = requests.get("https://datasets-server.huggingface.co/rows",
                            params=dict(zip(("dataset", "config", "split"), source), offset=99, length=2), timeout=60)
    response.raise_for_status()
    origin = response.json()
    with closing(connect()) as connection, closing(connection.cursor()) as cursor:
        cursor.execute("""SELECT SourceKey FROM HFSplit.Sources
            WHERE DatasetName=? AND ConfigName=? AND SplitName=?""", source)
        key = cursor.fetchone()[0]
        cursor.execute("SELECT COUNT(*) FROM HFSplit.Records WHERE SourceKey=?", (key,))
        count = cursor.fetchone()[0]
        if count != origin["num_rows_total"]:
            raise AssertionError(f"IRIS count {count} differs from viewer total.")

        def boundary():
            """Read the two rows spanning the page boundary for comparison with the source JSON."""
            cursor.execute("""SELECT SourceRow, JsonBody FROM HFSplit.Records
                WHERE SourceKey=? AND SourceRow IN (99, 100) ORDER BY SourceRow""", (key,))
            return [(row[0], json.loads(row[1])) for row in cursor.fetchall()]

        expected = [(item["row_idx"], item["row"]) for item in origin["rows"]]
        if boundary() != expected:
            raise AssertionError("Boundary rows differ from source.")

    print(f"PASS: {count} unique rows after two imports; source rows 99/100 match.")


if __name__ == "__main__":
    verify()
