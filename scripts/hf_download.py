#!/usr/bin/env python3
"""GGUF downloader: Hugging Face / hf-mirror.com, pinned revisions, aria2 resume.

For PUBLIC repos, --source official|mirror|auto controls endpoint selection.
For gated/private repos, official Hugging Face + --engine hf is mandatory.
All downloads are checked against pinned-revision metadata; SHA256 is verified
against upstream LFS SHA256 whenever that information is available.

Requires huggingface_hub. For --engine aria2, also requires aria2c.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

OFFICIAL = "https://huggingface.co"
MIRROR = "https://hf-mirror.com"
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")
SHA_RE = re.compile(r"^[a-fA-F0-9]{64}$")
COMMIT_RE = re.compile(r"^[a-fA-F0-9]{40}$")
SHARD_RE = re.compile(r"^(.*?)-(\d{5})-of-(\d{5})\.gguf$", re.I)


def die(message: str):
    raise RuntimeError(message)


def clean_repo(repo: str) -> str:
    if not REPO_RE.fullmatch(repo) or ".." in repo:
        die(f"Invalid owner/repo: {repo!r}")
    return repo


def clean_filename(filename: str) -> str:
    path = PurePosixPath(filename)
    if (not filename or filename.startswith("/") or "\\" in filename
            or any(part in {"", ".", ".."} for part in filename.split("/"))
            or path.suffix.lower() != ".gguf"):
        die(f"Unsafe or non-GGUF file path: {filename!r}")
    return filename


def endpoints(source: str):
    if source == "official":
        return [OFFICIAL]
    if source == "mirror":
        return [MIRROR]
    if source == "auto":
        return [OFFICIAL, MIRROR]
    die(f"Unsupported source: {source!r}")


def auth_config(endpoint: str) -> dict:
    # Never forward a cached HF access token to a third-party mirror.
    return {"token": None if endpoint == OFFICIAL else False}


def fetch_info(repo: str, revision: str, source: str):
    from huggingface_hub import HfApi
    errors = []
    for endpoint in endpoints(source):
        try:
            api = HfApi(endpoint=endpoint, **auth_config(endpoint))
            info = api.model_info(repo_id=repo, revision=revision, files_metadata=True)
            if not info.sha or not COMMIT_RE.fullmatch(info.sha):
                die(f"Endpoint {endpoint} did not return a valid immutable commit SHA")
            return info, endpoint
        except Exception as error:
            errors.append(f"{endpoint}: {error}")
            print(f"[metadata] {endpoint} failed: {type(error).__name__}", file=sys.stderr)
    die("Cannot resolve repository metadata; " + " | ".join(errors))


def upstream_metadata(info, filename: str, checksum: str | None = None) -> dict:
    sibling = next((s for s in (info.siblings or []) if s.rfilename == filename), None)
    if sibling is None:
        die(f"File not present in pinned revision: {filename}")
    lfs = getattr(sibling, "lfs", None) or {}
    sha = lfs.get("sha256") if isinstance(lfs, dict) else getattr(lfs, "sha256", None)
    if checksum:
        if not SHA_RE.fullmatch(checksum):
            die("--sha256 expects 64 hexadecimal characters")
        if sha and checksum.lower() != sha.lower():
            die("Supplied SHA256 differs from upstream LFS SHA256")
        sha = checksum
    return {
        "repo": info.id,
        "revision": info.sha,
        "filename": filename,
        "size": getattr(sibling, "size", None),
        "upstream_sha256": sha.lower() if sha else None,
    }


def select_files(info, one: str | None, pattern: str | None):
    files = [s.rfilename for s in (info.siblings or []) if s.rfilename.lower().endswith(".gguf")]
    if one:
        clean_filename(one)
        if one not in files:
            die(f"File {one!r} not found in {info.id}@{info.sha}")
        if SHARD_RE.fullmatch(one):
            die("A single shard was selected; select all shards with --pattern '*Q4_K_M*.gguf'")
        return [one]
    if not pattern or not pattern.lower().endswith(".gguf"):
        die("--pattern must explicitly end with .gguf")
    matches = sorted(f for f in files if fnmatch.fnmatchcase(f, pattern))
    if not matches:
        die(f"Pattern {pattern!r} matched no GGUF files")
    if len(matches) > 128:
        die("Pattern selected too many files; narrow to a single quantization")
    for filename in matches:
        clean_filename(filename)
    shards = [f for f in matches if SHARD_RE.fullmatch(f)]
    groups = {}
    for filename in shards:
        match = SHARD_RE.fullmatch(filename)
        assert match
        key = (match.group(1), int(match.group(3)))
        groups.setdefault(key, set()).add(int(match.group(2)))
    for (_, total), indices in groups.items():
        if indices != set(range(1, total + 1)):
            die(f"Incomplete shard selection; got {len(indices)}/{total}")
    # Reject a mix of shards and independent GGUFs, unless user targets a single family.
    if shards and len(shards) != len(matches):
        die("Pattern mixes split and unsplit GGUFs; narrow your pattern")
    return matches


def atomic_json(path: Path, obj: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".hf-meta-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def manifest_path(path: Path):
    return path.with_name("." + path.name + ".source.json")


def partial_marker(path: Path):
    return path.with_name(path.name + ".aria2")


def prepare(path: Path, metadata: dict):
    manifest_file = manifest_path(path)
    if manifest_file.exists():
        with manifest_file.open(encoding="utf-8") as handle:
            old = json.load(handle)
        keys = ("repo", "revision", "filename", "size", "upstream_sha256")
        if any(old.get(key) != metadata.get(key) for key in keys):
            die(f"Model changed since partial download: {manifest_file}. "
                "Keep the old download separate; do not mix revisions or checksums.")
        return old
    if path.exists() or partial_marker(path).exists():
        die(f"Untracked pre-existing file: {path}. Move it aside; refusing unsafe overwrite.")
    atomic_json(manifest_file, metadata)
    return metadata


def sha256(path: Path) -> str:
    hash_obj = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(8 * 1024 * 1024)
            if not chunk:
                break
            hash_obj.update(chunk)
    return hash_obj.hexdigest()


def verify_file(path: Path, data: dict):
    if not path.is_file():
        die(f"Missing model file: {path}")
    if partial_marker(path).exists():
        die(f"aria2 partial state still present: {partial_marker(path)}")
    actual_size = path.stat().st_size
    expected_size = data.get("size")
    if expected_size is not None and actual_size != expected_size:
        die(f"File size mismatch: {actual_size} != {expected_size}")
    computed = sha256(path)
    expected_sha = data.get("upstream_sha256")
    recorded_sha = data.get("local_sha256")
    if expected_sha and expected_sha.lower() != computed:
        die(f"UPSTREAM SHA256 mismatch for {path.name}: {computed}")
    if recorded_sha and recorded_sha.lower() != computed:
        die(f"Recorded SHA256 mismatch for {path.name}: {computed}")
    data["local_sha256"] = computed
    data["verification"] = "upstream_sha256" if expected_sha else (
        "size+local_sha256_only" if expected_size is not None else "local_sha256_only")
    atomic_json(manifest_path(path), data)
    return data


def download_aria2(repo: str, filename: str, revision: str, path: Path, endpoint: str):
    if not shutil.which("aria2c"):
        die("aria2c missing. Install with: brew install aria2")
    from huggingface_hub import hf_hub_url
    url = hf_hub_url(repo_id=repo, filename=filename, revision=revision, endpoint=endpoint)
    cmd = [
        "aria2c", "--continue=true", "--always-resume=true", "--auto-save-interval=10",
        "--auto-file-renaming=false", "--allow-overwrite=false",
        "--file-allocation=none", "--max-tries=5", "--retry-wait=10",
        "--connect-timeout=30", "--timeout=120", "--split=1",
        "--max-connection-per-server=1",
        f"--dir={path.parent}", f"--out={path.name}", url,
    ]
    print(f"[aria2] {endpoint} {repo}@{revision[:12]} -> {filename}", flush=True)
    subprocess.run(cmd, check=True)


def download_hf(repo: str, filename: str, revision: str, root: Path, endpoint: str):
    from huggingface_hub import hf_hub_download
    print(f"[HF] {endpoint} {repo}@{revision[:12]} -> {filename}", flush=True)
    hf_hub_download(repo_id=repo, filename=filename, revision=revision,
                    local_dir=str(root), endpoint=endpoint, **auth_config(endpoint))


def model_root(root: Path) -> Path:
    root = root.expanduser().resolve()
    if len(root.parts) >= 3 and root.parts[1] == "Volumes":
        volume = Path(*root.parts[:3])
        if not volume.is_mount():
            die(f"Model volume is not mounted: {volume}")
    return root


@contextmanager
def model_lock(path: Path):
    # Keep the lock inode across runs so concurrent callers always lock the same file.
    with path.with_name("." + path.name + ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            die(f"Another download or verification is active for {path}")
        yield


def download_one(args, repo: str, filename: str, info, metadata_endpoint: str):
    model_base = model_root(args.root) / repo
    path = model_base / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    with model_lock(path):
        download_locked(args, repo, filename, info, model_base, path)


def download_locked(args, repo, filename, info, model_base, path):
    selected = upstream_metadata(info, filename, args.sha256)
    data = prepare(path, selected)
    marker = partial_marker(path)
    if path.is_file() and not marker.exists():
        # May have completed before last metadata flush; verify full-size files.
        if (data.get("size") is not None and path.stat().st_size == data["size"]) or data.get("local_sha256"):
            verified = verify_file(path, data)
            print(f"[verified existing] {path} / {verified['verification']}")
            return

    if bool(getattr(info, "private", False)) or bool(getattr(info, "gated", False)):
        if args.source != "official" or args.engine != "hf":
            die("Private/gated model: use --source official --engine hf; do NOT send tokens to hf-mirror.com")
        choices = [OFFICIAL]
    else:
        choices = endpoints(args.source)

    if args.engine == "hf" and marker.exists():
        die("Cannot mix official HF downloader with .aria2 partial data; finish with --engine aria2")

    failures = []
    for endpoint in choices:
        try:
            if args.engine == "aria2":
                download_aria2(repo, filename, info.sha, path, endpoint)
            else:
                download_hf(repo, filename, info.sha, model_base, endpoint)
            verified = verify_file(path, data)
            verified["download_endpoint"] = endpoint
            verified["download_engine"] = args.engine
            atomic_json(manifest_path(path), verified)
            print(f"[OK] {path} SHA256={verified['local_sha256']} ({verified['verification']})")
            return
        except Exception as err:
            # Network failure: keep the same path, pinned revision, and .aria2 state.
            # Checksum failures are NOT retries: require manual inspection, not blind
            # reuse of suspicious bytes from a different endpoint.
            if isinstance(err, RuntimeError) and any(s in str(err) for s in
                ("SHA256 mismatch", "size mismatch", "Recorded SHA256 mismatch")):
                raise
            failures.append(f"{endpoint}: {err}")
            print(f"[warning] {endpoint} failed ({type(err).__name__}); preserving partial bytes", file=sys.stderr)
    die("All download endpoints failed; re-run the SAME command to resume: " + " | ".join(failures))


def cmd_download(args):
    repo = clean_repo(args.repo)
    info, endpoint = fetch_info(repo, args.revision, args.source)
    print(f"[pinned] {repo} -> {info.sha} (metadata via {endpoint})")
    selected = select_files(info, args.file, args.pattern)
    if args.sha256 and len(selected) != 1:
        die("--sha256 requires a single file")
    if bool(getattr(info, "private", False)) or bool(getattr(info, "gated", False)):
        if args.source != "official" or args.engine != "hf":
            die("Gated/private models require --source official --engine hf")
    print(f"[selected] {len(selected)} GGUF file(s): " + ", ".join(selected))
    for filename in selected:
        download_one(args, repo, filename, info, endpoint)


def cmd_verify(args):
    clean_repo(args.repo)
    clean_filename(args.file)
    path = model_root(args.root) / args.repo / args.file
    manifest_file = manifest_path(path)
    if not manifest_file.is_file():
        die(f"Missing metadata: {manifest_file}; download with this package first")
    with model_lock(path):
        with manifest_file.open(encoding="utf-8") as handle:
            data = json.load(handle)
        if data.get("repo") != args.repo or data.get("filename") != args.file:
            die("Metadata does not match requested repo/file")
        result = verify_file(path, data)
    print(f"[OK] {path} / {result['verification']} / SHA256={result['local_sha256']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("resolve", help="print immutable full commit SHA")
    r.add_argument("repo")
    r.add_argument("--revision", default="main")
    r.add_argument("--source", choices=["official", "mirror", "auto"], default="auto")
    d = sub.add_parser("download", help="pinned and verified GGUF download")
    d.add_argument("repo")
    sel = d.add_mutually_exclusive_group(required=True)
    sel.add_argument("--file")
    sel.add_argument("--pattern")
    d.add_argument("--revision", default="main")
    d.add_argument("--source", choices=["official", "mirror", "auto"], default="auto")
    d.add_argument("--engine", choices=["aria2", "hf"], default="aria2")
    d.add_argument("--sha256")
    d.add_argument("--root", type=Path, default=Path.home() / "AI" / "models")
    v = sub.add_parser("verify", help="verify an already-downloaded GGUF")
    v.add_argument("repo")
    v.add_argument("file")
    v.add_argument("--root", type=Path, default=Path.home() / "AI" / "models")
    args = parser.parse_args()
    try:
        if args.command == "resolve":
            repo = clean_repo(args.repo)
            info, _ = fetch_info(repo, args.revision, args.source)
            print(info.sha)
        elif args.command == "download":
            cmd_download(args)
        else:
            cmd_verify(args)
    except (RuntimeError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
