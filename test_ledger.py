"""Run against an IRIS namespace with src/ and tests/ loaded."""
from contextlib import closing
import json
import unittest
import uuid
import iris
from ledger import connect


class NativePaginationTests(unittest.TestCase):
    def setUp(self):
        """Give each native import a unique source in the disposable namespace."""
        self.conn = connect()
        self.addCleanup(self.conn.close)
        self.api = iris.createIRIS(self.conn)
        self.dataset = "fixture/" + uuid.uuid4().hex

    def refresh(self, mode, limit=0):
        """Run the production transaction with a synthetic Viewer response."""
        return self.api.classMethodInteger("HFSplitTest.Fixture", "Import", self.dataset,
                                           "default", "test", limit, mode)

    def rows(self):
        """Read only this test's stored JSON records, ordered by source index."""
        with closing(self.conn.cursor()) as cur:
            cur.execute("""SELECT r.SourceRow,r.JsonBody FROM HFSplit.Records r
                JOIN HFSplit.Sources s ON s.SourceKey=r.SourceKey
                WHERE s.DatasetName=? ORDER BY r.SourceRow""", (self.dataset,))
            return [(r[0], json.loads(r[1])) for r in cur.fetchall()]

    def tearDown(self):
        """Remove only this test's unique source and its records."""
        with closing(self.conn.cursor()) as cur:
            cur.execute("""DELETE FROM HFSplit.Records WHERE SourceKey IN
                (SELECT SourceKey FROM HFSplit.Sources WHERE DatasetName=?)""", (self.dataset,))
            cur.execute("DELETE FROM HFSplit.Sources WHERE DatasetName=?", (self.dataset,))

    def test_limit_preserves_suffix(self):
        """Cross a page boundary and preserve existing rows outside a limited refresh."""
        self.assertEqual(self.refresh("first"), 150)
        self.assertEqual(self.refresh("second", 101), 101)
        rows = self.rows()
        self.assertEqual(len(rows), 150)
        self.assertEqual(rows[100], (100, {"value": 100, "version": "second"}))
        self.assertEqual(rows[101], (101, {"value": 101, "version": "first"}))

    def test_bad_second_page_rolls_back(self):
        """An incomplete row or revision change must roll back all writes from the first page."""
        self.refresh("good")
        original = self.rows()
        for mode, message in [("broken", "Truncated"), ("revision", "revision changed")]:
            with self.subTest(mode=mode), self.assertRaisesRegex(Exception, message):
                self.refresh(mode)
            self.assertEqual(self.rows(), original)

    def test_empty_full_refresh(self):
        """An empty complete snapshot clears the old split."""
        self.refresh("original", 1)
        self.assertEqual(self.refresh("empty"), 0)
        self.assertEqual(self.rows(), [])
