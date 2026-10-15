import importlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

total_with_tax = importlib.import_module("invoice").total_with_tax


class InvoiceTests(unittest.TestCase):
    def test_tax_is_added_to_net(self):
        self.assertEqual(total_with_tax(100, 0.2), 120)

    def test_zero_tax_preserves_net(self):
        self.assertEqual(total_with_tax(100, 0), 100)
