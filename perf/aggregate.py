#!/usr/bin/env python3
"""Summarize k6 --summary-export JSON files without third-party packages."""

import json
import statistics
import sys
from pathlib import Path


def metric(summary, name, key):
    return summary["metrics"][name]["values"][key]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: aggregate.py RESULT_DIRECTORY", file=sys.stderr)
        return 2

    result_dir = Path(sys.argv[1])
    summaries = []
    for path in sorted(result_dir.glob("run-*-summary.json")):
        with path.open(encoding="utf-8") as file:
            summary = json.load(file)
        summaries.append(
            {
                "file": path.name,
                "rps": metric(summary, "http_reqs", "rate"),
                "p95_ms": metric(summary, "http_req_duration", "p(95)"),
                "error_rate": metric(summary, "http_req_failed", "rate"),
            }
        )

    if not summaries:
        print("No k6 summary files found.", file=sys.stderr)
        return 1

    report = {
        "runs": summaries,
        "aggregate": {
            "mean_rps": statistics.fmean(run["rps"] for run in summaries),
            "median_p95_ms": statistics.median(run["p95_ms"] for run in summaries),
            "mean_p95_ms": statistics.fmean(run["p95_ms"] for run in summaries),
            "worst_error_rate": max(run["error_rate"] for run in summaries),
        },
    }
    output = result_dir / "aggregate.json"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    aggregate = report["aggregate"]
    print(f"mean RPS: {aggregate['mean_rps']:.2f}")
    print(f"median p95: {aggregate['median_p95_ms']:.2f} ms")
    print(f"worst error rate: {aggregate['worst_error_rate']:.4%}")
    print(f"report: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
