"""Did the app itself see the edit, or only its accessibility surface?

The read-back in `measure_replace.py` proves the text CHANGED. It cannot prove
the app's own editor model changed with it. A rich editor like Slack's or
Gmail's keeps its document in JavaScript and paints from that; a write that
lands on the accessibility layer but not the model shows the right text and
then sends the wrong one. That failure is invisible to every check run so far,
and it is exactly the shape that has already burned this work once — an
accessibility call returning success while doing nothing.

The discriminator is to keep typing. If the model saw the edit, one more
character lands at the end and everything is coherent. If the model is stale,
the editor repaints from its own copy and the typed character exposes it.

Routes worth this scrutiny are the two that do not go through a real editing
gesture:
  B  AX set range + paste    selection is set by accessibility, text arrives by
                             a genuine Cmd+V, so the editor should see it
  E  AXValue whole rewrite   nothing but accessibility, no gesture at all
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_replace as M  # noqa: E402
import probe_replace_routes as R  # noqa: E402

POKE = "!"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("surface", choices=sorted(M.SURFACES))
    args = parser.parse_args()

    surface = M.SURFACES[args.surface]
    front = surface.activate()
    print(f"\n{surface.name}  (frontmost: {front})")
    print("  replace, then type one more character and see if it lands\n")

    for label, route in R.ROUTES:
        if not label.startswith(("B", "E")):
            continue
        element = surface.element()
        problem = surface.stage(element)
        if problem:
            print(f"  {label:28} HARNESS: {problem}")
            continue
        caret = surface.caret(element)
        unavailable, _ = R.run_route(route, element, len(M.SPAN), M.REPLACEMENT, caret)
        time.sleep(0.3)
        if unavailable:
            print(f"  {label:28} UNAVAILABLE ({unavailable})")
            continue
        replaced = surface.read(element)
        if replaced is None or replaced.strip() != M.EXPECTED:
            print(f"  {label:28} replace itself failed, nothing to test")
            continue

        R.type_text(POKE)
        time.sleep(0.5)
        after = surface.read(element)
        wanted = M.EXPECTED + POKE
        if after is not None and after.strip() == wanted:
            verdict = "MODEL AGREES   the app kept typing where the edit ended"
        else:
            verdict = f"MODEL STALE    {after!r}"
        print(f"  {label:28} {verdict}")

    element = surface.element()
    if not surface.clear(element):
        print("\n  CLEANUP FAILED — the field still holds probe text")
        return 1
    print("\n  field cleared")
    return 0


if __name__ == "__main__":
    sys.exit(main())
