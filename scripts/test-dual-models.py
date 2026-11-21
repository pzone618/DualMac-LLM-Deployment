#!/usr/bin/env python3
"""Run on the master. Load config/cluster.env and export it before invocation."""
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, build_opener, ProxyHandler

env = os.environ
host = env["M6_IP"]
rpc = int(env.get("TEST_RPC_PORT", 50152))
api = int(env.get("TEST_API_PORT", 8183))
ai_root = Path(env.get("AI_ROOT", Path.home() / "AI"))
binary = ai_root / "llama.cpp/build/bin/llama-server"
models = Path(env.get("MODELS_DIR", ai_root / "models"))
logs = Path(tempfile.mkdtemp(prefix="dual-model-tests-"))
ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", f'{env["M6_USER"]}@{host}']
http = build_opener(ProxyHandler({}))


def listening(address, port):
    try:
        with socket.create_connection((address, port), timeout=2):
            return True
    except OSError:
        return False


def wait_for(process, probe, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"process exited with {process.returncode}")
        if probe():
            return
        time.sleep(1)
    raise TimeoutError(f"not ready after {seconds}s")


def ready():
    try:
        with http.open(f"http://127.0.0.1:{api}/health", timeout=3) as res:
            return json.load(res).get("status") == "ok"
    except OSError:
        return False


def run(path, log):
    if listening(host, rpc) or listening("127.0.0.1", api):
        raise RuntimeError("test port already occupied")
    # EOF on SSH stdin also cleans up after a disconnected controller.
    remote = ('export GGML_RPC_NO_RDMA=1; "$HOME/AI/llama.cpp/build/bin/ggml-rpc-server" '
              f'-H {shlex.quote(host)} -p {rpc} -c </dev/null & pid=$!; '
              'trap \'kill "$pid" 2>/dev/null; wait "$pid"\' EXIT; read -r unused')
    worker = subprocess.Popen(ssh + ["bash -c " + shlex.quote(remote)], stdin=subprocess.PIPE,
                              stdout=log, stderr=subprocess.STDOUT)
    master = None
    try:
        wait_for(worker, lambda: listening(host, rpc), 25)
        embedding = "embedding" in path.name.lower()
        args = [str(binary), "-m", str(path), "-ngl", "99", "-c", env.get("CTX_SIZE", "4096"),
                "--rpc", f"{host}:{rpc}", "--host", "127.0.0.1", "--port", str(api)]
        if embedding:
            args.append("--embedding")
        master = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                  env=dict(env, GGML_RPC_NO_RDMA="1"))
        wait_for(master, ready, 600)
        route, body = (("v1/embeddings", {"input": "hello", "encoding_format": "float"}) if embedding
                       else ("completion", {"prompt": "Hello", "n_predict": 2}))
        req = Request(f"http://127.0.0.1:{api}/{route}", data=json.dumps(body).encode(),
                      headers={"Content-Type": "application/json"})
        with http.open(req, timeout=120) as res:
            data = json.load(res)
        if not (data["data"][0]["embedding"] if embedding else data["tokens_predicted"] > 0):
            raise RuntimeError("empty inference result")
    finally:
        try:
            if master and master.poll() is None:
                master.terminate()
                try:
                    master.wait(20)
                except subprocess.TimeoutExpired:
                    master.kill()
                    master.wait()
        finally:
            worker.stdin.close()
            worker.wait(30)
        if listening(host, rpc) or listening("127.0.0.1", api):
            raise RuntimeError("test port still open after cleanup")


def primary_models():
    for path in models.rglob("*.gguf"):
        if any(part.startswith(".") for part in path.relative_to(models).parts):
            continue
        name = path.name.lower()
        if name.startswith(("mmproj", "eagle3-")):
            continue
        if not re.search(r"-(?!00001)\d{5}-of-\d{5}\.gguf$", name) and path.is_file():
            yield path


def main():
    paths = sorted(primary_models(), key=lambda p: p.stat().st_size)
    if not paths:
        raise SystemExit("No model files found")
    print(logs, flush=True)
    failed = False
    for i, path in enumerate(paths, 1):
        print(f"[{i}/{len(paths)}] {path.name}", flush=True)
        logfile = logs / f"{i:02}.log"
        try:
            with logfile.open("w") as log:
                run(path, log)
            status = "PASS"
        except Exception as err:
            failed = True
            status = f"FAIL: {err}"
        with (logs / "results.jsonl").open("a") as out:
            print(json.dumps(dict(model=str(path), status=status, log=str(logfile))), file=out)
        print(status, flush=True)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
