#!/usr/bin/env python3
"""Measures Clip, so an optimisation claim can carry a number.

Launches a Release build against a SANDBOX library, seeds a realistic amount of
data, then drives the same code paths a person drives and reads the timings and
counters back out.

    ./perf-probe.py                 # measure Release
    ./perf-probe.py --debug         # measure the Debug build too
    ./perf-probe.py --save NAME     # record the run as a named baseline
    ./perf-probe.py --compare NAME  # print this run against a saved one
    ./perf-probe.py --render        # also launch non-headless, for the M10
                                     # render-side tab-switch metric and the
                                     # panel show-latency metric (both need a
                                     # real panel; headless never builds one,
                                     # so they read as skipped otherwise)

Set `CLIP_QA_SANDBOX_NAME` and `CLIP_SYNC_TEST_PORT` before running this to
give a lane its own Application Support directory and sync port, so several
lanes' probes can run on the same machine at once without one's launch
deleting another's command/state files or database mid-run.

The counters matter as much as the milliseconds. "The filter pipeline ran
eleven times when you pressed the down arrow" explains lag in a way a
millisecond figure never does.
"""
import json, os, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
# `CLIP_QA_SANDBOX_NAME` lets several lanes run this probe at once, each
# against its own Application Support directory - see `AppPaths.sandboxName`.
# Without it every lane shared "Clip-QA", so one lane's `launch()` deleting
# the command/state files and sqlite out from under another mid-run looked
# like a flaky test but was really two probes fighting over one directory.
SANDBOX_NAME = os.environ.get("CLIP_QA_SANDBOX_NAME", "Clip-QA")
SUPPORT = os.path.expanduser("~/Library/Application Support/%s" % SANDBOX_NAME)
CMD = os.path.join(SUPPORT, "qa-command.txt")
STATE = os.path.join(SUPPORT, "qa-state.json")
# Where this script remembers the PID it last launched, so a leftover from a
# run that crashed before reaching `proc.terminate()` can be cleaned up
# without guessing at anyone else's process - see `launch()`.
PIDFILE = os.path.join(SUPPORT, "perf-probe.pid")
BASELINES = os.path.join(HERE, "perf-baselines")
CORPUS = os.path.expanduser("~/Desktop/awesome-design-md-main/design-md")

# A realistic library, not a toy one. Performance problems in this app are all
# scale problems: everything is instant at twenty items.
HISTORY_ITEMS = 2000


def _percentile(samples, pct):
    """Nearest-rank percentile over a small sample list, rounded to 2dp."""
    if not samples:
        return None
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round(pct / 100 * (len(ordered) - 1))))
    return round(ordered[index], 2)


def state():
    for _ in range(1200):
        try:
            with open(STATE) as f:
                return json.load(f)
        except Exception:
            time.sleep(0.05)
    raise SystemExit("no state file - did the app start?")


def send(verb, arg="", wait=True, timeout=120):
    cid = "%d" % (time.time() * 1e6)
    with open(CMD, "w") as f:
        f.write("%s %s %s" % (cid, verb, arg))
    if not wait:
        return {}
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = state()
        if s.get("ack") == cid:
            return s
        time.sleep(0.03)
    raise SystemExit("timed out waiting for %s" % verb)


def _killOwnLeftover():
    """Ends a Clip process THIS SCRIPT started on a previous run that never
    reached `proc.terminate()` (killed itself, or the run crashed first).

    Used to be `pkill -f "Clip.app/Contents/MacOS/Clip"` - a blanket kill by
    process name that takes down every OTHER lane's Clip.app on a shared
    machine along with it, and the real installed copy in /Applications too.
    Measured on this machine while this file was being worked on: five other
    worktrees' builds were running at once. PID-target only: read back the
    exact pid this script itself wrote in a previous `launch()`, confirm it
    is still alive, and stop only that one.
    """
    try:
        with open(PIDFILE) as f:
            old_pid = int(f.read().strip())
    except (OSError, ValueError):
        return
    try:
        os.kill(old_pid, 0)          # alive? raises ProcessLookupError if not
    except ProcessLookupError:
        return
    except PermissionError:
        return                        # not ours to touch
    os.kill(old_pid, signal.SIGTERM)
    for _ in range(40):
        try:
            os.kill(old_pid, 0)
            time.sleep(0.05)
        except ProcessLookupError:
            return
    # Still alive after 2s of asking nicely - SIGKILL the one PID, still
    # never anything matched by name.
    try:
        os.kill(old_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def launch(app):
    os.makedirs(SUPPORT, exist_ok=True)
    _killOwnLeftover()
    for path in (CMD, STATE, PIDFILE):
        try:
            os.remove(path)
        except OSError:
            pass
    # A stale sandbox database makes launch measure the previous run's leftovers
    # rather than the app. Every run starts from nothing.
    for name in ("clip.sqlite", "clip.sqlite-wal", "clip.sqlite-shm"):
        try:
            os.remove(os.path.join(SUPPORT, name))
        except OSError:
            pass
    env = dict(os.environ,
               CLIP_QA="1", CLIP_QA_SANDBOX="1", CLIP_PERF="1",
               CLIP_QA_SANDBOX_NAME=SANDBOX_NAME)
    # A private sync port, so this lane's own SyncManager (if it starts one)
    # never collides with another lane's on the same machine. Passed through
    # when the caller set one; left to the app's own default otherwise.
    if "CLIP_SYNC_TEST_PORT" in os.environ:
        env["CLIP_SYNC_TEST_PORT"] = os.environ["CLIP_SYNC_TEST_PORT"]
    # Every other metric here is model-side and does not care whether a real
    # window exists, so headless is the default - it is the only mode that can
    # run unattended in CI. The M10 render-side metric (`tabsRender`, below) is
    # the one exception: under `CLIP_HEADLESS=1`, `PanelController.open()` never
    # builds the real panel (see `ActionPanel.swift`'s own doc comment), so
    # `m0_tabRenderSamples` would read back near-zero and record a baseline that
    # measures nothing. `--render` drops CLIP_HEADLESS for a run that wants that
    # number to mean something; the state file itself carries `m0_headless` too,
    # so a saved baseline is never silently ambiguous about which mode made it.
    if "--render" not in sys.argv:
        env["CLIP_HEADLESS"] = "1"
    started = time.time()
    proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/Clip")], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Recorded so a crashed run can clean up after exactly this process next
    # time, and nothing else - see `_killOwnLeftover`.
    with open(PIDFILE, "w") as f:
        f.write(str(proc.pid))
    state()                       # first state file written = app is ready
    return proc, (time.time() - started) * 1000


def seed():
    """The standard library every measurement runs against."""
    # Set the cap explicitly. It is a user preference, so leaving it alone meant
    # the library size depended on whatever the last run happened to leave
    # behind: one measurement ran against 745 items and the next against 94,
    # which makes two numbers that cannot be compared.
    send("historyLimit", str(HISTORY_ITEMS * 2), timeout=60)
    send("seed", str(HISTORY_ITEMS), timeout=300)
    if os.path.isdir(CORPUS):
        send("importDesignLibrary", CORPUS, timeout=300)
    else:
        print("  ! design corpus missing at %s - documents not measured" % CORPUS)
    s = state()
    print("  library: %d items" % s.get("itemCount", 0))
    return s.get("itemCount", 0)


def run(app, label):
    print("\n=== %s ===" % label)
    proc, launch_ms = launch(app)
    print("  launch to ready: %.0f ms" % launch_ms)
    count = seed()

    out = {"label": label, "launchMs": round(launch_ms), "items": count}

    def block(name, verb, arg):
        send("perfReset")
        s = send(verb, arg, timeout=300)
        perf = s.get("perf", {})
        out[name] = perf
        return perf

    # Typing. The cost that hurts most, because it repeats per character.
    p = block("type", "perfType", "typography")
    print("  typing 10 chars: pipeline ran %s times, median %s ms, p95 %s ms"
          % ((p.get("count.visibleItems") or 0), p.get("ms.visibleItems.median"),
             p.get("ms.visibleItems.p95")))

    # Arrow keys. Selection only: every pipeline run here is wasted work.
    p = block("navigate", "perfNavigate", "10")
    print("  10 arrow keys:   pipeline ran %s times  <- should be 0"
          % (p.get("count.visibleItems") or 0))

    p = block("tabs", "perfTabCycle", "8")
    print("  8 tab switches:  pipeline ran %s times, median %s ms"
          % ((p.get("count.visibleItems") or 0), p.get("ms.visibleItems.median")))

    # M10: the RENDER-side cost of a tab switch, as distinct from the
    # MODEL-side one just above. `perfTabCycle` proves `computeVisibleItems`
    # is cheap (0.07 ms); a person does not feel that number, they feel the
    # layout commit that follows it, which is what the bridge's "tab" command
    # times (the delay of the next main run-loop turn after `setTab`). Only
    # meaningful with a real panel, so it is skipped under `CLIP_HEADLESS=1`
    # rather than recording a number that measures nothing.
    if state().get("m0_headless"):
        out["tabsRenderMs"] = None
        print("  8 tab switches:  render timing SKIPPED (m0_headless - "
              "re-run with --render for a real window)")
    else:
        send("open")
        visible_tabs = ["all", "role:prompt", "role:note", "role:design",
                        "all", "role:prompt", "role:note", "role:design"]
        for tab in visible_tabs:
            send("tab", tab)
            time.sleep(0.12)
        samples = state().get("m0_tabRenderSamples") or []
        recent = samples[-len(visible_tabs):]
        out["tabsRenderMs"] = {
            "median": _percentile(recent, 50),
            "p95": _percentile(recent, 95),
            "max": max(recent) if recent else None,
        }
        print("  8 tab switches:  render median %s ms, p95 %s ms, max %s ms"
              % (out["tabsRenderMs"]["median"], out["tabsRenderMs"]["p95"],
                 out["tabsRenderMs"]["max"]))

    # Panel show latency: timed INSIDE `PanelController.open()` (entry to the
    # panel actually being on screen and key), not from here. A figure taken
    # by polling this probe's own state file included that polling's 30ms
    # floor in every sample - real enough to look like a number, wrong enough
    # to be useless. Only meaningful with a real panel, same reason as
    # `tabsRenderMs` above.
    if state().get("m0_headless"):
        out["panelShowMs"] = None
        print("  panel show latency: SKIPPED (m0_headless - re-run with --render)")
    else:
        send("close")
        send("perfReset")
        for _ in range(6):
            send("open")
            send("close")
        p = state().get("perf", {})
        out["panelShowMs"] = {
            "median": p.get("ms.panelShow.median"),
            "p95": p.get("ms.panelShow.p95"),
            "n": p.get("ms.panelShow.n"),
        }
        print("  panel show latency: %s ms median (n=%s samples), p95 %s ms"
              % (out["panelShowMs"]["median"], out["panelShowMs"]["n"],
                 out["panelShowMs"]["p95"]))

    p = block("readList", "perfReadList", "100")
    print("  100 list reads:  median %s ms, total %s ms"
          % (p.get("ms.visibleItems.median"),
             round((p.get("ms.visibleItems.median") or 0) * 100, 1)))

    # Derived colors and date labels: the per-row, per-frame costs.
    # Timed inside the app: measuring these from here included a fixed ~130 ms
    # of command-bridge latency in every reading.
    p = block("rowColors", "perfTheme", "200")
    out["rowColorsMs"] = p.get("ms.rowColors.median")
    print("  one row's worth of theme colors: %s ms median, %s ms p95"
          % (out["rowColorsMs"], p.get("ms.rowColors.p95")))

    p = block("dateLabel", "perfDateLabels", "1")
    out["dateLabelMs"] = p.get("ms.dateLabel.median")
    print("  one date label:                  %s ms median, %s ms p95"
          % (out["dateLabelMs"], p.get("ms.dateLabel.p95")))

    out["rssMB"] = state().get("rssMB")
    print("  resident memory: %s MB" % out["rssMB"])

    proc.terminate()
    time.sleep(0.5)
    try:
        os.remove(PIDFILE)   # clean exit - nothing for the next run to find
    except OSError:
        pass
    return out


def main():
    args = sys.argv[1:]
    apps = [(os.path.join(HERE, "build-testing/Build/Products/Testing/Clip.app"), "Release")]
    if "--debug" in args:
        apps.append((os.path.join(HERE, "build/Build/Products/Debug/Clip.app"), "Debug"))

    results = []
    for app, label in apps:
        if not os.path.isdir(app):
            print("missing build: %s" % app)
            continue
        results.append(run(app, label))

    if "--save" in args:
        name = args[args.index("--save") + 1]
        os.makedirs(BASELINES, exist_ok=True)
        path = os.path.join(BASELINES, name + ".json")
        with open(path, "w") as f:
            json.dump(results, f, indent=2)
        print("\nsaved baseline: %s" % path)

    if "--compare" in args:
        name = args[args.index("--compare") + 1]
        with open(os.path.join(BASELINES, name + ".json")) as f:
            before = {r["label"]: r for r in json.load(f)}
        print("\n=== against baseline '%s' ===" % name)
        for now in results:
            was = before.get(now["label"])
            if not was:
                continue
            print("\n %s" % now["label"])
            for key in ("launchMs", "rowColorsMs", "dateLabelMs", "rssMB"):
                a, b = was.get(key), now.get(key)
                if a and b:
                    print("   %-10s %8s -> %8s  (%+.0f%%)"
                          % (key, a, b, (b - a) / a * 100))
            for blk in ("type", "navigate", "tabs", "readList"):
                a = (was.get(blk) or {}).get("count.visibleItems")
                b = (now.get(blk) or {}).get("count.visibleItems")
                am = (was.get(blk) or {}).get("ms.visibleItems.median")
                bm = (now.get(blk) or {}).get("ms.visibleItems.median")
                print("   %-10s runs %5s -> %-5s   median %8s -> %s"
                      % (blk, a, b, am, bm))
            wr, nr = was.get("tabsRenderMs"), now.get("tabsRenderMs")
            if wr and nr:
                print("   tabsRender render median %s -> %s ms   p95 %s -> %s ms   max %s -> %s ms"
                      % (wr.get("median"), nr.get("median"),
                         wr.get("p95"), nr.get("p95"),
                         wr.get("max"), nr.get("max")))


if __name__ == "__main__":
    main()
