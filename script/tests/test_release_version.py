import unittest
from datetime import date
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import next_version, parse_tag


class ReleaseVersionTests(unittest.TestCase):
    def test_first_release(self):
        self.assertEqual(next_version([], "20260912"), "20260912.1")

    def test_same_day_numeric_increment_and_gaps(self):
        tags = ["20260912.1", "v20260912.2", "20260912.10", "20260912.4"]
        self.assertEqual(next_version(tags, "20260912"), "20260912.11")

    def test_next_day_resets(self):
        self.assertEqual(next_version(["20260911.99"], "20260912"), "20260912.1")

    def test_malformed_tags_are_ignored(self):
        tags = ["latest", "20260912", "20260912.0", "20260912.01", "20260931.2", "v20260912.3-extra"]
        self.assertEqual(next_version(tags, "20260912"), "20260912.1")
        self.assertIsNone(parse_tag("20260931.2"))

    def test_invalid_dates(self):
        with self.assertRaises(ValueError):
            next_version([], "20260229")
        with self.assertRaises(ValueError):
            next_version([], "20261")
        with self.assertRaises(ValueError):
            next_version([], "2026912")
        with self.assertRaises(ValueError):
            next_version([], "２０２６０９１２")

        self.assertIsNone(parse_tag("２０２６０９１２.1"))

    def test_future_date_prevents_rollback(self):
        with self.assertRaisesRegex(ValueError, "later"):
            next_version(["20260913.1"], "20260912")


if __name__ == "__main__":
    unittest.main()
