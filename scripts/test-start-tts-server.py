#!/usr/bin/env python3
"""Check optional Japanese installation without uv, downloads, or an audio server."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("start-tts-server.sh")


class JapaneseSidecarSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="pace-tts-setup-")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        binary_directory = self.root / "bin"
        binary_directory.mkdir()
        uvx = binary_directory / "uvx"
        uvx.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ["STUB_UVX_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
arguments = sys.argv[1:]
python_arguments = arguments[arguments.index("python") + 1:]
if python_arguments[0] == "-":
    os.execv(sys.executable, [sys.executable, *python_arguments])
""")
        uvx.chmod(0o755)
        unidic = self.root / "unidic"
        unidic.mkdir()
        (unidic / "__init__.py").write_text('import os\nDICDIR = os.environ["STUB_DICTIONARY"]\n')
        (unidic / "__main__.py").write_text("""import os
from pathlib import Path
dictionary = Path(os.environ["STUB_DICTIONARY"])
dictionary.mkdir(parents=True, exist_ok=True)
Path(os.environ["STUB_DOWNLOAD_LOG"]).write_text("downloaded")
(dictionary / "mecabrc").touch()
if os.environ.get("STUB_INCOMPLETE_DOWNLOAD") != "1":
    (dictionary / "sys.dic").touch()
""")
        self.dictionary = self.root / "dictionary"
        self.voice_support = self.root / "voice-support"
        self.receipt = self.voice_support / "japanese.enabled"
        self.invocations = self.root / "uvx.jsonl"
        self.download = self.root / "downloaded"
        self.environment = {
            **os.environ,
            "PATH": f"{binary_directory}:{os.environ['PATH']}",
            "PYTHONPATH": str(self.root),
            "PACE_VOICE_SUPPORT_DIRECTORY": str(self.voice_support),
            "STUB_UVX_LOG": str(self.invocations),
            "STUB_DICTIONARY": str(self.dictionary),
            "STUB_DOWNLOAD_LOG": str(self.download),
        }

    def run_script(self, *arguments, succeeds=True):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *arguments], env=self.environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result

    def uvx_arguments(self):
        return [json.loads(line) for line in self.invocations.read_text().splitlines()]

    def test_ordinary_startup_keeps_english_dependencies_and_does_not_download(self):
        self.run_script()
        arguments = self.uvx_arguments()[0]
        self.assertIn("misaki[en]==0.9.4", arguments)
        self.assertNotIn("misaki[en,ja]==0.9.4", arguments)
        self.assertFalse(self.download.exists())
        self.assertFalse(self.voice_support.exists())

    def test_explicit_install_and_enabled_startup_use_the_same_environment(self):
        self.run_script("--install-japanese")
        self.assertTrue(self.receipt.is_file())
        self.assertTrue((self.dictionary / "mecabrc").is_file())
        self.assertTrue((self.dictionary / "sys.dic").is_file())
        self.run_script()
        installer, server = self.uvx_arguments()
        self.assertIn("misaki[en,ja]==0.9.4", installer)
        self.assertEqual(installer[:installer.index("python")], server[:server.index("python")])
        self.download.unlink()
        self.run_script("--install-japanese")
        self.assertFalse(self.download.exists())
        self.assertEqual(list(self.voice_support.iterdir()), [self.receipt])

    def test_missing_dictionary_binary_requires_download_even_with_mecabrc(self):
        self.dictionary.mkdir()
        (self.dictionary / "mecabrc").touch()
        self.run_script("--install-japanese")
        self.assertTrue(self.download.exists())
        self.assertTrue((self.dictionary / "sys.dic").is_file())
        self.assertTrue(self.receipt.is_file())

    def test_incomplete_dictionary_does_not_enable_japanese(self):
        self.environment["STUB_INCOMPLETE_DOWNLOAD"] = "1"
        self.run_script("--install-japanese", succeeds=False)
        self.assertFalse(self.receipt.exists())
        self.run_script()
        self.assertIn("misaki[en]==0.9.4", self.uvx_arguments()[-1])


if __name__ == "__main__":
    unittest.main()
