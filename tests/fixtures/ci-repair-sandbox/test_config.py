import json
import unittest
from pathlib import Path


class ConfigTests(unittest.TestCase):
    def test_service_uses_fixed_unprivileged_port(self):
        config = json.loads(Path(__file__).with_name("service.json").read_text())
        self.assertGreaterEqual(config["port"], 1024)
        self.assertLessEqual(config["port"], 65535)
