#!/usr/bin/env python3
"""tests/runner.py - run the cases of tests/cases/ concurrently (tests/run.sh is the entry point; see its header).

Each case file is a bash script that tests/case.sh runs in its own process, after tests/lib.sh. Its header says
    # group: render|policy|admission|gatedset   (which CI job runs it)
    # needs: CASE ...                          (cases whose output under TMP it reads: they finish first)
    # secs: N                                  (a rough duration, used to start long cases first and to balance shards)
Every case of a run shares one TMP. A case's output is held until it ends, then printed in one piece, so the ok/FAIL lines of
two cases never interleave; the failing cases' output is printed again at the end, above the total.
"""
import argparse, os, re, signal, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
APRON = os.path.dirname(HERE)
CASES = os.path.join(HERE, "cases")


class Case:
    def __init__(self, path, order):
        self.path, self.order = path, order
        self.name = re.sub(r"^\d+-", "", os.path.basename(path)[:-3])
        self.group, self.needs, self.secs = "render", [], 1.0
        with open(path) as f:
            for l in f:
                if not l.startswith("#"):
                    break
                m = re.match(r"#\s*(group|needs|secs):\s*(.*)", l)
                if m:
                    k, v = m.group(1), m.group(2).strip()
                    if k == "group":
                        self.group = v
                    elif k == "needs":
                        self.needs = v.split()
                    else:
                        self.secs = float(v)
        self.setup = False   # run only because a selected case needs it: its counts are not the run's
        self.state = "wait"  # wait, run, done, failed
        self.passed = self.failed = 0
        self.elapsed = 0.0
        self.output = ""


def load():
    files = sorted(f for f in os.listdir(CASES) if f.endswith(".sh"))
    cases = [Case(os.path.join(CASES, f), i) for i, f in enumerate(files)]
    by = {c.name: c for c in cases}
    if len(by) != len(cases):
        sys.exit("tests/cases: two case files have the same name")
    for c in cases:
        for n in c.needs:
            if n not in by:
                sys.exit(f"tests/cases/{os.path.basename(c.path)}: needs {n}, which is not a case")
            if by[n].order >= c.order:
                sys.exit(f"tests/cases/{os.path.basename(c.path)}: needs {n}, which must come before it")
    return cases, by


def shard(cases, i, n):
    """Cases i of n (1-based), balanced on secs: longest first, each to the least loaded shard. Deterministic."""
    bins = [[0.0, []] for _ in range(n)]
    for c in sorted(cases, key=lambda c: (-c.secs, c.order)):
        b = min(bins, key=lambda b: b[0])
        b[0] += c.secs
        b[1].append(c)
    return bins[i - 1][1]


PROCS, PROCS_LOCK = set(), threading.Lock()


def stop_cases():
    """End every running case's process group and reap it."""
    with PROCS_LOCK:
        procs = list(PROCS)
    for p in procs:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()


def run_case(c, tmp):
    fd, res = tempfile.mkstemp(prefix="result-", dir=tmp)
    os.close(fd)
    env = dict(os.environ, APRON_TEST_TMP=tmp, APRON_CASE_RESULT=res)
    t = time.time()
    # its own process group, so a stopped run can end the case and whatever it started (renders, envtest servers)
    p = subprocess.Popen(["bash", os.path.join(HERE, "case.sh"), os.path.basename(c.path)], cwd=APRON, env=env,
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    with PROCS_LOCK:
        PROCS.add(p)
    try:
        out, _ = p.communicate()
    finally:
        with PROCS_LOCK:
            PROCS.discard(p)
    c.elapsed = time.time() - t
    c.output = out.decode(errors="replace")
    with open(res) as f:
        r = f.read().split()
    os.unlink(res)
    if len(r) == 2:
        c.passed, c.failed = int(r[0]), int(r[1])
    else:  # it died before its end (set -u, a syntax error, a signal): what it did not reach is not a pass
        c.passed = c.output.count("\n  ok   ") + c.output.startswith("  ok   ")
        c.failed = c.output.count("\n  FAIL ") + c.output.startswith("  FAIL ") + 1
        c.output += f"  FAIL {c.name}: the case ended early (exit {p.returncode}) before it finished\n"
    if p.returncode and len(r) == 2:
        c.failed += 1
        c.output += f"  FAIL {c.name}: exit {p.returncode}\n"


def main():
    ap = argparse.ArgumentParser(prog="tests/run.sh", description="Apron's offline tests, run concurrently.")
    ap.add_argument("-j", "--jobs", type=int, default=int(os.environ.get("APRON_TEST_JOBS") or 0) or
                    min(8, max(4, os.cpu_count() or 4)), help="cases at a time (default 4-8 by CPU count; APRON_TEST_JOBS)")
    ap.add_argument("--group", help="only the cases of these groups (comma-separated: render, policy, admission, gatedset)")
    ap.add_argument("--shard", help="I/N: the I-th of N balanced slices of the selected cases (CI)")
    ap.add_argument("--list", action="store_true", help="print the selected cases and exit")
    ap.add_argument("case", nargs="*", help="only these cases (and, as setup, what they need)")
    a = ap.parse_args()
    if a.jobs < 1:
        ap.error("-j/APRON_TEST_JOBS must be 1 or more")
    cases, by = load()
    sel = cases
    if a.case:
        bad = [n for n in a.case if n not in by]
        if bad:
            sys.exit("no such case: " + " ".join(bad) + " (tests/run.sh --list)")
        sel = [by[n] for n in a.case]
    if a.group:
        gs = a.group.split(",")
        sel = [c for c in sel if c.group in gs]
    if a.shard:
        i, n = (int(x) for x in a.shard.split("/"))
        if not 1 <= i <= n:
            sys.exit("--shard I/N needs 1 <= I <= N")
        sel = shard(sel, i, n)
    if not sel:
        sys.exit("no case selected")
    run = {c.name for c in sel}
    todo = list(sel)
    while todo:  # what the selected cases need, run first as setup
        c = todo.pop()
        for n in c.needs:
            if n not in run:
                run.add(n)
                by[n].setup = True
                todo.append(by[n])
    run = sorted((by[n] for n in run), key=lambda c: c.order)
    if a.list:
        for c in run:
            print(f"{c.name:28s} {c.group:9s} {c.secs:6.0f}s  {'(setup) ' if c.setup else ''}{' '.join(c.needs)}")
        return 0
    # start the case with the longest chain of work behind it first
    users = {c.name: [] for c in run}
    for c in run:
        for n in c.needs:
            users[n].append(c)
    prio = {}
    for c in reversed(run):
        prio[c.name] = c.secs + max((prio[u.name] for u in users[c.name]), default=0)

    tmp = tempfile.mkdtemp(prefix="apron-tests-")
    lock = threading.Condition()
    running, t0 = [], time.time()

    def worker(c):
        try:
            run_case(c, tmp)
        except Exception as e:  # noqa: BLE001 - a runner error is a failed case, not a hung run
            c.failed, c.output = 1, f"  FAIL {c.name}: the runner could not run it: {e}\n"
        with lock:
            c.state = "failed" if c.failed else "done"
            running.remove(c)
            for_ = ", ".join(u.name for u in users[c.name] if not u.setup)
            tag = (f"setup for {for_}" if for_ else "setup") if c.setup else c.group
            if c.setup and not c.failed:
                print(f"== {c.name} ({tag}, {c.elapsed:.1f}s): {c.passed} ok, not counted here", flush=True)
            else:
                print(f"== {c.name} ({tag}, {c.elapsed:.1f}s)\n{c.output}", end="" if c.output.endswith("\n") else "\n",
                      flush=True)
            lock.notify_all()

    def stop(*_):
        sys.exit(130)
    signal.signal(signal.SIGTERM, stop)
    try:
        with lock:
            while True:
                for c in run:  # a case whose need failed does not run: it fails, naming the need
                    if c.state == "wait" and any(by[n].state == "failed" for n in c.needs):
                        c.state, c.failed = "failed", 1
                        c.output = f"  FAIL {c.name}: not run: needs {', '.join(n for n in c.needs if by[n].state == 'failed')}, which failed\n"
                        print(f"== {c.name}\n{c.output}", end="", flush=True)
                ready = [c for c in run if c.state == "wait" and all(by[n].state == "done" for n in c.needs)]
                ready.sort(key=lambda c: (-prio[c.name], c.order))
                while ready and len(running) < a.jobs:
                    c = ready.pop(0)
                    c.state = "run"
                    running.append(c)
                    threading.Thread(target=worker, args=(c,), daemon=True).start()
                if not running and not ready:
                    break
                lock.wait()
    finally:
        stop_cases()  # nothing left on a normal end; on a signal, the cases go before their directory does
        subprocess.run(["rm", "-rf", tmp])
    counted = [c for c in run if not c.setup or c.failed]
    p = sum(c.passed for c in counted if not c.setup)
    f = sum(c.failed for c in counted)
    failed = [c for c in run if c.failed]
    if failed:
        print("\n== failed cases (their whole output again)")
        for c in failed:
            print(f"-- {c.name} ({os.path.relpath(c.path, APRON)})\n{c.output}", end="" if c.output.endswith("\n") else "\n")
    have_yaml = subprocess.run(["python3", "-c", "import yaml"], capture_output=True).returncode == 0
    print(f"\n{len([c for c in run if not c.setup])} cases ({len([c for c in run if c.setup])} more as setup), "
          f"{a.jobs} at a time, {time.time() - t0:.0f}s")
    print(f"{p} passed, {f} failed{'' if have_yaml else ' (YAML parse skipped: no PyYAML)'}")
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
