"""Conservative, measured-cost scheduling for four local test processes.

Only reviewed suites move out of the protected remainder. A changed test file
loses its parallel admission until reviewed again; new suites stay protected.
"""

import hashlib
import math
from pathlib import Path


def plan_groups(root, profile, *, baseline_writer=False):
    if profile.get("schema") != 1 or profile.get("slots") != 4:
        raise ValueError("local test profile must describe four worker slots")
    costs = profile["costs"]
    if not costs or any(not isinstance(v, (int, float)) or isinstance(v, bool)
                        or not math.isfinite(v) or v < 0 for v in costs.values()):
        raise ValueError("invalid measured suite costs")
    if baseline_writer:
        return [("serial", ())], [sum(costs.values())]
    admitted, seen, blocks, hashes = set(), set(), [], {}
    for block in profile["blocks"]:
        selected = []
        for entry in block["suites"]:
            name, relative = entry["suite"], entry["file"]
            if name in seen or name not in costs or not name.startswith("EnviousWisprTests/"):
                raise ValueError(f"invalid or duplicate admitted suite: {name}")
            seen.add(name)
            path = Path(relative)
            if path.is_absolute() or ".." in path.parts or not relative.startswith("Tests/"):
                raise ValueError(f"invalid reviewed test path: {relative}")
            if relative not in hashes:
                try:
                    hashes[relative] = hashlib.sha256((root / path).read_bytes()).hexdigest()
                except FileNotFoundError:
                    hashes[relative] = None
            if hashes[relative] != entry["sha256"]:
                print(f"==> Protected fallback (test source changed): {name}", flush=True)
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
