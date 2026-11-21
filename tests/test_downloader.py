"""Pure offline unit tests for the downloader's safety and source routing."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hf_download.py"
spec = importlib.util.spec_from_file_location("hf_download", SCRIPT)
hf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hf)

class MockSibling:
    def __init__(self, rfilename, size=5, sha=None):
        self.rfilename = rfilename
        self.size = size
        self.lfs = {"sha256": sha} if sha else None

class MockInfo:
    def __init__(self, names):
        self.id = "owner/repo"
        self.sha = "a" * 40
        self.siblings = [MockSibling(x) for x in names]
        self.private = False
        self.gated = False

class Tests(unittest.TestCase):
    def test_endpoint_selection(self):
        self.assertEqual(hf.endpoints("auto"), [hf.OFFICIAL, hf.MIRROR])
        self.assertEqual(hf.endpoints("mirror"), [hf.MIRROR])
        with self.assertRaises(RuntimeError): hf.endpoints("attacker.example")

    def test_mirror_has_no_auth(self):
        self.assertEqual(hf.auth_config(hf.MIRROR), {"token": False})
        self.assertEqual(hf.auth_config(hf.OFFICIAL), {"token": None})

    def test_repo_and_filename_validation(self):
        self.assertEqual(hf.clean_repo("owner/repo"), "owner/repo")
        for invalid in ("../repo", "owner/../repo", "owner/repo/other", "owner/../../x"):
            with self.assertRaises(RuntimeError): hf.clean_repo(invalid)
        for invalid in ("../model.gguf", "/model.gguf", "a\\b.gguf", "./x.gguf", "model.bin"):
            with self.assertRaises(RuntimeError): hf.clean_filename(invalid)

    def test_shard_completeness(self):
        info = MockInfo(["q4-00001-of-00002.gguf", "q4-00002-of-00002.gguf", "q8.gguf"])
        self.assertEqual(len(hf.select_files(info, None, "q4-*.gguf")), 2)
        with self.assertRaises(RuntimeError): hf.select_files(info, "q4-00001-of-00002.gguf", None)
        with self.assertRaises(RuntimeError): hf.select_files(info, None, "q4-00001*.gguf")

    def test_manifest_conflict_blocks_cross_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / "model.gguf"
            original = {"repo":"owner/repo", "revision":"a" * 40,
                        "filename":"model.gguf", "size":5, "upstream_sha256":None}
            hf.prepare(f, original)
            changed = dict(original, revision="b" * 40)
            with self.assertRaises(RuntimeError): hf.prepare(f, changed)

    def test_upstream_sha_and_size_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / "x.gguf"
            f.write_bytes(b"hello")
            expected = {"repo":"owner/repo", "revision":"a" * 40,
                        "filename":"x.gguf", "size":5,
                        "upstream_sha256":hf.sha256(f)}
            self.assertEqual(hf.verify_file(f, expected)["verification"], "upstream_sha256")
            expected["upstream_sha256"] = "0" * 64
            with self.assertRaises(RuntimeError): hf.verify_file(f, expected)

    def test_partial_marker_blocks_verification(self):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / "x.gguf"
            f.write_bytes(b"hello")
            hf.partial_marker(f).write_text("not complete")
            with self.assertRaises(RuntimeError): hf.verify_file(f, {"size":5})

    def test_download_auto_switches_to_mirror_and_verifies_bytes(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp:
            payload = b"hello"
            import hashlib
            upstream = hashlib.sha256(payload).hexdigest()
            info = MockInfo(["x.gguf"])
            info.siblings[0] = MockSibling("x.gguf", len(payload), upstream)
            args = SimpleNamespace(root=Path(temp), source="auto", engine="aria2", sha256=None)
            attempts = []
            def fake_aria2(repo, file, revision, path, endpoint):
                attempts.append(endpoint)
                if endpoint == hf.OFFICIAL:
                    path.write_bytes(payload[:2])
                    hf.partial_marker(path).write_bytes(b"partial")
                    raise OSError("simulated connection failure")
                path.write_bytes(payload)
                hf.partial_marker(path).unlink()
            with patch.object(hf, "download_aria2", side_effect=fake_aria2):
                hf.download_one(args, "owner/repo", "x.gguf", info, hf.OFFICIAL)
            self.assertEqual(attempts, [hf.OFFICIAL, hf.MIRROR])
            manifest = json.loads(hf.manifest_path(Path(temp)/"owner"/"repo"/"x.gguf").read_text())
            self.assertEqual(manifest["verification"], "upstream_sha256")
            self.assertEqual(manifest["download_endpoint"], hf.MIRROR)

    def test_private_repo_cannot_use_mirror_or_aria2(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp:
            info = MockInfo(["x.gguf"])
            info.gated = "auto"
            args = SimpleNamespace(root=Path(temp), source="mirror", engine="aria2", sha256=None)
            with self.assertRaisesRegex(RuntimeError, "Private/gated"):
                hf.download_one(args, "owner/repo", "x.gguf", info, hf.MIRROR)

    def test_mirror_fallback_metadata(self):
        seen = []
        class Api:
            def __init__(self, endpoint, token):
                seen.append((endpoint, token))
                self.endpoint = endpoint
            def model_info(self, repo_id, revision, files_metadata):
                if self.endpoint == hf.OFFICIAL:
                    raise RuntimeError("connection timed out")
                return MockInfo(["x.gguf"])
        with patch.dict(sys.modules, {"huggingface_hub": types.SimpleNamespace(HfApi=Api)}):
            info, origin = hf.fetch_info("owner/repo", "main", "auto")
        self.assertEqual(origin, hf.MIRROR)
        self.assertEqual(seen, [(hf.OFFICIAL, None), (hf.MIRROR, False)])

if __name__ == "__main__":
    unittest.main()
