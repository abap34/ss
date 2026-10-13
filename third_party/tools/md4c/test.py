#!/usr/bin/env python3
"""Build and run the bundled MD4C parser's upstream tests."""

import os
import pathlib
import signal
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "third_party" / "md4c"
BUILD = ROOT / ".ss-cache" / "md4c"


def run(args, timeout, cwd=ROOT):
    print("+ " + " ".join(str(arg) for arg in args), flush=True)
    with subprocess.Popen(args, cwd=cwd, start_new_session=True) as child:
        try:
            result = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
    if result:
        raise subprocess.CalledProcessError(result, args)


def main():
    run([
        "cmake", "-S", str(SOURCE), "-B", str(BUILD),
        "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
    ], timeout=60)
    run(["cmake", "--build", str(BUILD), "--parallel", "2"], timeout=120)
    program = str(BUILD / "md2html" / "md2html")
    suites = sorted((SOURCE / "test").glob("*.txt"))
    for suite in suites:
        run([
            sys.executable, "run-testsuite.py", "-s", str(suite), "-p", program,
        ], timeout=60, cwd=SOURCE / "test")
    run([
        sys.executable, "pathological-tests.py", "-p", program,
    ], timeout=120, cwd=SOURCE / "test")
    print(f"MD4C: {len(suites)} upstream suites and pathological inputs passed", flush=True)


if __name__ == "__main__":
    main()
