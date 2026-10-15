import unittest

from invoice import total_with_tax


class InvoiceTests(unittest.TestCase):
    def test_tax_is_added_to_net(self):
        self.assertEqual(total_with_tax(100, 0.2), 120)

    def test_zero_tax_preserves_net(self):
        self.assertEqual(total_with_tax(100, 0), 100)
