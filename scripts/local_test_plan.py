"""Conservative, measured-cost scheduling for four local test processes.

Only reviewed suites move out of the protected remainder; new suites stay
protected. The review mark lives in the test source as the `.localParallel`
tag, so editing a reviewed file keeps its admission (#4279). The full run's
TestInventoryFreezeTests fails when this list and the tagged suites differ.
A listed file that no longer exists falls back to the protected worker.
single_worker runs everything in one process: the inventory baseline writer,
and every --real-boundary run, whose real models and GPU work must not overlap.
"""

import math
from pathlib import Path


def plan_groups(root, profile, *, single_worker=False):
    if profile.get("schema") != 2 or profile.get("slots") != 4:
        raise ValueError("local test profile must describe four worker slots")
    costs = profile["costs"]
    if not costs or any(not isinstance(v, (int, float)) or isinstance(v, bool)
                        or not math.isfinite(v) or v < 0 for v in costs.values()):
        raise ValueError("invalid measured suite costs")
    if single_worker:
        return [("serial", ())], [sum(costs.values())]
    admitted, seen, blocks = set(), set(), []
    for block in profile["blocks"]:
        selected = []
        for entry in block["suites"]:
            if set(entry) != {"suite", "file"}:
                raise ValueError(f"admitted entry must hold exactly suite and file: {entry}")
            name, relative = entry["suite"], entry["file"]
            if name in seen or name not in costs or not name.startswith("EnviousWisprTests/"):
                raise ValueError(f"invalid or duplicate admitted suite: {name}")
            seen.add(name)
            path = Path(relative)
            if (path.is_absolute() or ".." in path.parts
                    or not relative.startswith("Tests/EnviousWisprTests/")):
                raise ValueError(f"invalid reviewed test path: {relative}")
            if not (root / path).is_file():
                print(f"==> Protected fallback (test file missing): {name}", flush=True)
                continue
            admitted.add(name)
            selected.append(name)
        if selected:
            # All AST consumers share one block, preserving the process cache.
            blocks.append((sum(costs[name] for name in selected), tuple(sorted(selected))))
    selections = [[], [], [], []]
    loads = [sum(v for name, v in costs.items() if name not in admitted), 0.0, 0.0, 0.0]
    for cost, names in sorted(blocks, key=lambda b: (-b[0], b[1])):
        slot = min(range(4), key=lambda i: (loads[i], i))
        selections[slot].extend(names)
        loads[slot] += cost
    # Slot zero owns every unlisted suite across all three bundles. Suites
    # assigned back to it need no selector; their costs already enter its load.
    groups = [("serial", tuple(sorted(selections[0])))]
    groups.extend((f"worker-{i}", tuple(sorted(selections[i])))
                  for i in range(1, 4) if selections[i])
    return groups, loads
