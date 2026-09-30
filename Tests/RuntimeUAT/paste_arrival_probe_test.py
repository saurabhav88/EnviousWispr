"""Two-way controls for the paste arrival probe (#3118, #3119).

#3118: an unreadable focused field sends no paste, so it is not a timing result.
`measure` must fail the run instead of counting it, and ordinary trials beside it
must still be recorded, so a `measure` that refused everything cannot pass.

#3119: the polling loop reads whichever field is focused. A focus move mid-trial
must fail the run, not report `not_seen` for a paste that landed in the original
field; the same trial with focus held must still return its verdict.

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


class Read:
    def __init__(self, value, ok: bool = True):
        self.ok, self.why = ok, "readable" if ok else "AX read failed"
        self.fields = [type("Field", (), {"value": value})()] if ok else []


def run_one_trial(focus_after_post, arrive: bool, limit_s: float = 0.02,
                  unreadable_after_post: bool = False):
    """One trial with stubbed AX. `focus_after_post` is the element reported focused once the
    paste is dispatched; `chosen` is the field the person picked."""
    chosen, phrase = "field-A", {}
    state = {"posted": False}
    saved = (probe.ax_oracle.read_focused, probe.ax_oracle.is_frontmost, probe.focused_element,
             probe.same_element, probe.set_clipboard_text, probe.simulate_input.press_key,
             probe.time.sleep)
    probe.ax_oracle.read_focused = lambda bundle, pid=None: Read(
        phrase["text"] if arrive and state["posted"] else "",
        ok=not (unreadable_after_post and state["posted"]))
    probe.ax_oracle.is_frontmost = lambda pid: True
    probe.focused_element = lambda pid: focus_after_post if state["posted"] else chosen
    probe.same_element = lambda a, b: a == b
    probe.set_clipboard_text = lambda text: phrase.update(text=text)
    probe.simulate_input.press_key = lambda *a, **k: state.update(posted=True)
    probe.time.sleep = lambda _seconds: None
    try:
        return probe.one_trial("com.example.app", 1, chosen, limit_s), None
    except RuntimeError as error:
        return None, str(error)
    finally:
        (probe.ax_oracle.read_focused, probe.ax_oracle.is_frontmost, probe.focused_element,
         probe.same_element, probe.set_clipboard_text, probe.simulate_input.press_key,
         probe.time.sleep) = saved


result, error = run_one_trial("field-A", arrive=True)
check("focus held and the paste lands: arrived", error is None and result["verdict"] == "arrived")

result, error = run_one_trial("field-A", arrive=False)
check("focus held and nothing lands: not_seen", error is None and result["verdict"] == "not_seen")

result, error = run_one_trial("field-B", arrive=False)
check("focus moved and nothing seen in the new field: the run fails, not not_seen",
      result is None and error is not None and "lost focus during the trial" in error)

result, error = run_one_trial("field-B", arrive=True)
check("focus moved even when the phrase is read: the run fails",
      result is None and error is not None and "at arrival" in error)

result, error = run_one_trial("field-A", arrive=False, unreadable_after_post=True)
check("every read fails after the paste: the run fails, not not_seen",
      result is None and error is not None and "unreadable at time-out" in error)

sys.exit(1 if failures else 0)
