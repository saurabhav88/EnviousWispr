"""Two-way control for the paste arrival probe's unreadable-trial handling (#3118).

An unreadable focused field sends no paste, so it is not a timing result. `measure`
must fail the run instead of counting it, and ordinary trials beside it must still
be recorded, so a `measure` that refused everything cannot pass.

Run: `python3 Tests/RuntimeUAT/paste_arrival_probe_test.py`
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import paste_arrival_probe as probe  # noqa: E402

failures: list[str] = []


def check(name: str, ok: bool) -> None:
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        failures.append(name)


def run_measure(verdicts: list[dict]):
    queue = list(verdicts)
    real = (probe.focused_element, probe.one_trial, probe.time.sleep)
    probe.focused_element = lambda pid: object()
    probe.one_trial = lambda *args, **kwargs: queue.pop(0)
    probe.time.sleep = lambda _seconds: None
    try:
        return probe.measure("com.example.app", 1, len(verdicts), 1.0), None
    except RuntimeError as error:
        return None, str(error)
    finally:
        probe.focused_element, probe.one_trial, probe.time.sleep = real


results, error = run_measure(
    [{"verdict": "arrived", "arrived_ms": 40}, {"verdict": "arrived", "arrived_ms": 50}])
check("arrived trials are recorded", error is None and results is not None and len(results) == 2)

results, error = run_measure(
    [{"verdict": "arrived", "arrived_ms": 40}, {"verdict": "unreadable", "why": "no AX"}])
check("an unreadable trial fails the run", results is None and error is not None)
check("the failure names the trial and the reason",
      error is not None and "paste 2/2" in error and "no AX" in error)

results, error = run_measure([{"verdict": "unreadable", "why": "no AX"}])
check("a run of only unreadable trials fails instead of reporting nothing arrived",
      results is None and error is not None)

sys.exit(1 if failures else 0)
