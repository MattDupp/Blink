"""Measures the app's own trainer against the Python route: the same pictures, the same
splits, the same scoring.

    make compare

The app trains its model in Swift (BlinkCore's EyeTrainer); this folder trains it in
Python (learning.py). Two trainers can only be compared on THE SAME work, so the work is
laid out here, once, as a list of "jobs" (train on these pictures, answer on those). Each
side runs the jobs and returns its answers, and both are scored by evaluate.py's own
functions.

    uv run python compare.py jobs       write out/compare/jobs.json
    uv run python compare.py python     run the jobs with the Python route -> python.json
    .build/release/BlinkTrain training/out/compare/jobs.json training/out/compare/swift.json
    uv run python compare.py score      the tables, for every result there is

Three kinds of jobs:
  A. cross-validation by session, as `make train` does it;
  B. blink counting, as `make evaluate` does it: each capture judged by a model trained
     without its pictures, over several seeds (COMPARE_SEEDS=7,8,9);
  C. what a NEW user has: recorder sessions only, one to all of them.

Everything is written to out/, which is never committed: the files hold the paths of the
pictures and the answers given on them.
"""

import itertools
import json
import os
import sys
import time

from captures import all_captures
from data import load
from evaluate import Rule, Score, read_truth, score
from paths import BLINKS, LIVE, OUT, RAW

FOLDER = OUT / "compare"
EPOCHS = 30
# evaluate.py uses seed 7; more seeds show how much a seed moves the count.
SEEDS = tuple(int(s) for s in os.environ.get("COMPARE_SEEDS", "7,8,9").split(","))
# COMPARE_ONLY=eval/ narrows a run to one kind of job.
ONLY = os.environ.get("COMPARE_ONLY", "")


def build():
    """The picture table (every training picture, then every capture frame) and the jobs."""
    data = load((RAW, BLINKS))
    captures = all_captures(LIVE)

    pictures = [row["path"] for row in data.rows]
    labels = [int(label) for label in data.labels.tolist()]
    frames_of: dict[str, dict[str, list[int]]] = {}
    for capture in captures:
        frames_of[capture.name] = {}
        for side in ("L", "R"):
            start = len(pictures)
            pictures += [str(capture.picture(frame, side)) for frame in capture.frames]
            labels += [-1] * len(capture.frames)
            frames_of[capture.name][side] = list(range(start, len(pictures)))
    all_frames = [i for sides in frames_of.values() for index in sides.values() for i in index]

    def rows_in(sessions: set[str]) -> list[int]:
        return data.indices(sessions).tolist()

    raw = sorted(p.name for p in RAW.iterdir() if (p / "manifest.csv").is_file())
    jobs = []
    # A. Cross-validation by session (seed 0 + fold, as train.py).
    for fold, held_out in enumerate(data.sessions):
        jobs.append(
            {
                "name": f"cv/{held_out}",
                "train": rows_in(set(data.sessions) - {held_out}),
                "predict": rows_in({held_out}),
                "seed": fold,
            }
        )
    # B. Blink counting: each capture judged by a model trained without that capture.
    for seed in SEEDS:
        for capture in captures:
            jobs.append(
                {
                    "name": f"eval/{seed}/{capture.name}",
                    "train": rows_in(set(data.sessions) - {capture.name}),
                    "predict": frames_of[capture.name]["L"] + frames_of[capture.name]["R"],
                    "seed": seed,
                }
            )
    # C. Recorder sessions only, 1 to all of them, no real blink frame. Tested on the
    #    recorder sessions left out, and on every capture.
    number = 0
    for k in range(1, len(raw) + 1):
        for subset in itertools.combinations(raw, k):
            jobs.append(
                {
                    "name": f"curve/{k}/{'+'.join(s[-6:] for s in subset)}",
                    "train": rows_in(set(subset)),
                    "predict": rows_in(set(raw) - set(subset)) + all_frames,
                    "seed": 100 + number,
                }
            )
            number += 1
    jobs = [job for job in jobs if job["name"].startswith(ONLY)]
    for job in jobs:
        job["epochs"] = EPOCHS
    return data, captures, pictures, labels, frames_of, jobs


def write_jobs() -> None:
    _, _, pictures, labels, _, jobs = build()
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "jobs.json").write_text(json.dumps({"pictures": pictures, "labels": labels, "jobs": jobs}))
    print(f"{len(pictures)} pictures, {len(jobs)} trainings -> {FOLDER / 'jobs.json'}")


def run_python() -> None:
    import numpy as np
    import torch
    from PIL import Image

    from learning import device, predict, train

    _, _, pictures, labels, _, jobs = build()
    on = device()
    stack = np.stack([np.asarray(Image.open(p).convert("RGB")) for p in pictures])
    images = torch.from_numpy(stack).permute(0, 3, 1, 2).contiguous().to(on)
    truth = torch.tensor(labels, dtype=torch.float32).to(on)

    results = {}
    FOLDER.mkdir(parents=True, exist_ok=True)
    for job in jobs:
        started = time.time()
        index = torch.tensor(job["train"]).to(on)
        model = train(images[index], truth[index], epochs=job["epochs"], seed=job["seed"])
        seconds = time.time() - started
        answers = predict(model, images[torch.tensor(job["predict"]).to(on)]).tolist()
        results[job["name"]] = {"closed": answers, "seconds": seconds}
        print(f"  {job['name']:44s} {len(job['train']):5d} pictures  {seconds:5.1f} s", flush=True)
        (FOLDER / "python.json").write_text(json.dumps(results))


def tables(names: list[str]) -> None:
    data, captures, _, labels, frames_of, jobs = build()
    by_name = {job["name"]: job for job in jobs}
    truths = {capture.name: read_truth(capture) for capture in captures}
    rule = Rule("current rules")

    for source in [FOLDER / f"{name}.json" for name in names]:
        if not source.is_file():
            continue
        results = json.loads(source.read_text())

        def answers(name: str, results=results) -> dict[int, float]:
            return dict(zip(by_name[name]["predict"], results[name]["closed"], strict=True))

        def count(found: dict[int, float], capture) -> Score:
            left = [found[i] for i in frames_of[capture.name]["L"]]
            right = [found[i] for i in frames_of[capture.name]["R"]]
            return score(capture, truths[capture.name], rule.count(capture, left, right))

        def wrong(found: dict[int, float], rows: list[int]) -> tuple[int, int, int]:
            phantom = sum(1 for i in rows if found[i] > 0.5 and labels[i] == 0)
            missed = sum(1 for i in rows if found[i] <= 0.5 and labels[i] == 1)
            return phantom, missed, len(rows)

        seconds = [results[name]["seconds"] for name in results]
        fastest, slowest = min(seconds), max(seconds)
        print(f"\n===== {source.stem}: {len(results)} trainings, {fastest:.1f} to {slowest:.1f} s each")

        print("\nA. Pictures of a session never seen (cross-validation by session)")
        phantom = missed = total = 0
        for job in jobs:
            if job["name"].startswith("cv/") and job["name"] in results:
                p, m, n = wrong(answers(job["name"]), job["predict"])
                phantom, missed, total = phantom + p, missed + m, total + n
                took = results[job["name"]]["seconds"]
                print(f"  {job['name'][3:]:28s} {p + m:3d} wrong of {n:4d}   ({took:.1f} s)")
        if total:
            print(
                f"  all: {100 * (1 - (phantom + missed) / total):.2f}% right; "
                f"open called closed {phantom}, closed called open {missed}, of {total}"
            )

        print("\nB. Blinks counted, each capture judged by a model trained without it")
        seeds = sorted({name.split("/")[1] for name in results if name.startswith("eval/")}, key=int)
        everything = Score()
        for seed in seeds:
            if any(f"eval/{seed}/{capture.name}" not in results for capture in captures):
                continue
            total_score = Score()
            parts = []
            for capture in captures:
                result = count(answers(f"eval/{seed}/{capture.name}"), capture)
                total_score += result
                parts.append(f"{result.found}/{result.blinks}+{result.false}f")
            everything += total_score
            print(f"  seed {seed}: {total_score}    [{'  '.join(parts)}]")
        if everything.blinks:
            print(f"  all seeds: {everything.found} of {everything.blinks} found, {everything.false} false")

        print("\nC. Recorder sessions only (what a new user has), by number of sessions")
        raw = sorted({row["session"] for row in data.rows if "/raw/" in row["path"]})
        for k in range(1, len(raw) + 1):
            lines = []
            for name in sorted(n for n in results if n.startswith(f"curve/{k}/")):
                found = answers(name)
                held = [i for i in by_name[name]["predict"] if labels[i] >= 0]
                total_score = Score()
                for capture in captures:
                    total_score += count(found, capture)
                p, m, n = wrong(found, held) if held else (0, 0, 0)
                accuracy = f"{100 * (1 - (p + m) / n):6.2f}% of {n}" if n else "      -        "
                lines.append((name.split("/")[2], accuracy, total_score, results[name]["seconds"]))
            for subset, accuracy, total_score, took in lines:
                print(
                    f"  {k} session(s) {subset:28s} pictures {accuracy}   blinks {total_score.found:2d} of "
                    f"{total_score.blinks}, {total_score.false} false   ({took:.1f} s)"
                )
            if lines:
                found = [line[2].found for line in lines]
                false = [line[2].false for line in lines]
                mean_found, mean_false = sum(found) / len(found), sum(false) / len(false)
                print(
                    f"    -> {k}: found {min(found)} to {max(found)} (mean {mean_found:.1f}) of "
                    f"{lines[0][2].blinks}; false {min(false)} to {max(false)} (mean {mean_false:.1f})"
                )


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "jobs":
        write_jobs()
    elif command == "python":
        run_python()
    elif command == "score":
        tables(sys.argv[2:] or ["python", "swift"])
    else:
        raise SystemExit(__doc__)
