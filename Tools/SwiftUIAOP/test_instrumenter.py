#!/usr/bin/env python3
"""Run with Xcode selected through DEVELOPER_DIR. Generates only temporary copies."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PREPARE = Path(__file__).with_name("prepare.sh")

class InstrumentationTests(unittest.TestCase):
    def test_compilation_overlay_preserves_sources_and_supports_syntax(self):
        with tempfile.TemporaryDirectory(prefix="lookin aop ") as folder:
            root = Path(folder)
            source = root / "Business 中文.swift"
            source.write_text('''import SwiftUI
struct Payload<T> where T: Equatable { var item: T; let token = "fixed" }
struct Sample: View {
    @State private var 计数 = 1
    @State var `repeat` = "test"
    public var body: some View { return Text("\\(计数)") }
}
''')
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            env = dict(os.environ, DERIVED_FILE_DIR=str(root / "derived"), CONFIGURATION="Debug")
            subprocess.run([str(PREPARE), str(source)], env=env, check=True)
            output = root / "derived/LookinSwiftUIAOP"
            overlay = json.loads((output / "overlay.json").read_text())
            self.assertEqual(overlay["roots"][0]["name"], str(source))
            generated = Path(overlay["roots"][0]["external-contents"])
            text = generated.read_text()
            self.assertIn("Payload<T>: LKSInspectableModel", text)
            self.assertIn("self.$计数", text)
            self.assertIn("self.$repeat", text)
            self.assertIn("public var body: some SwiftUI.View", text)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), digest)
            timestamp = generated.stat().st_mtime_ns
            subprocess.run([str(PREPARE), str(source)], env=env, check=True)
            self.assertEqual(generated.stat().st_mtime_ns, timestamp)
            source.write_text("struct Broken {")
            result = subprocess.run([str(PREPARE), str(source)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot parse", result.stderr)

    def test_release_creates_no_instrumentation(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "derived"
            subprocess.run([str(PREPARE), "does-not-exist.swift"], env=dict(os.environ, CONFIGURATION="Release", DERIVED_FILE_DIR=str(output)), check=True)
            self.assertFalse(output.exists())

if __name__ == "__main__":
    unittest.main()
