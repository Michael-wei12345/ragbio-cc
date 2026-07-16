#!/usr/bin/env python3
import csv
import json
import math
import sys

def expit(value: float) -> float:
    return 1 / (1 + math.exp(-value))

def main() -> None:
    with open(sys.argv[1], newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError("No rows supplied")
    ys, vs = [], []
    for row in rows:
        events, total = float(row["events"]), float(row["n"])
        if total <= 0 or events < 0 or events > total:
            raise ValueError("Invalid events or denominator")
        ys.append(math.log((events + 0.5) / (total - events + 0.5)))
        vs.append(1 / (events + 0.5) + 1 / (total - events + 0.5))
    fixed = [1 / value for value in vs]
    fixed_mean = sum(w * y for w, y in zip(fixed, ys)) / sum(fixed)
    q = sum(w * (y - fixed_mean) ** 2 for w, y in zip(fixed, ys))
    k = len(rows)
    c = sum(fixed) - sum(w * w for w in fixed) / sum(fixed)
    tau2 = max(0, (q - (k - 1)) / c) if c > 0 else 0
    weights = [1 / (value + tau2) for value in vs]
    mean = sum(w * y for w, y in zip(weights, ys)) / sum(weights)
    se = math.sqrt(1 / sum(weights))
    result = {
        "k": k,
        "events": sum(int(float(row["events"])) for row in rows),
        "n": sum(int(float(row["n"])) for row in rows),
        "pooled": expit(mean),
        "ci_low": expit(mean - 1.96 * se),
        "ci_high": expit(mean + 1.96 * se),
        "i2": max(0, (q - (k - 1)) / q) * 100 if q > 0 else 0,
        "tau2": tau2,
        "model": "random-effects logit proportion with 0.5 continuity correction",
    }
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
