"""Trains the eye model and measures, honestly, how good it is.

    cd training
    uv run python train.py

It does three things, in this order:

  1. CROSS-VALIDATION BY SESSION - the measurement. For each session in turn: train a model
     on all the OTHER sessions, then test it on that session, which it has never seen.
     Every picture is therefore judged by a model that did not train on its session.
  2. SUSPICIOUS PICTURES - where a model that never saw a picture strongly disagrees with
     its label, either the model is wrong or the LABEL is (a blink during an "open" pose).
     They are gathered on one sheet for you to look at.
  3. THE FINAL MODEL - trained on every session, saved to models/eyenet.pt.
"""

import argparse
import csv
import time
from pathlib import Path

import torch

import sheets
from data import EyeData, load
from learning import device, predict, train
from model import EyeNet, count_weights
from paths import MODEL_FILE, OUT, PROJECT


def cross_validate(data: EyeData, on: torch.device, epochs: int, seed: int) -> torch.Tensor:
    """Returns, for every picture, the probability "closed" given by a model that never
    saw that picture's session."""
    images, labels = data.images.to(on), data.labels.to(on)
    probabilities = torch.zeros(len(data))

    for fold, held_out in enumerate(data.sessions):
        test = data.indices({held_out})
        rest = data.indices(set(data.sessions) - {held_out})
        print(
            f"\n  Round {fold + 1} of {len(data.sessions)}: learn from {len(rest)} pictures, "
            f"test on session {held_out} ({len(test)} pictures)"
        )
        started = time.time()
        model = train(
            images[rest.to(on)],
            labels[rest.to(on)],
            epochs,
            seed + fold,
            watch=(images[test.to(on)], labels[test.to(on)]),
        )
        probabilities[test] = predict(model, images[test.to(on)])
        print(f"    done in {time.time() - started:.0f} s")
    return probabilities


def report(data: EyeData, probabilities: torch.Tensor) -> list[int]:
    """Prints the results and returns the wrongly answered pictures, worst first."""
    said_closed = probabilities > 0.5
    is_closed = data.labels > 0.5
    wrong = said_closed != is_closed

    print("\n" + "=" * 78)
    print("RESULT ON PICTURES THE MODEL HAD NEVER SEEN (its session was held out)")
    print("=" * 78)
    majority = max(is_closed.sum().item(), (~is_closed).sum().item()) / len(data)
    print(
        f"  Right answers: {100 * (1 - wrong.float().mean().item()):.2f}%   "
        f"(always answering the more common label would score {100 * majority:.1f}%)"
    )
    # The two kinds of error do not cost the same in a blink counter.
    phantom = (said_closed & ~is_closed).sum().item()
    missed = (~said_closed & is_closed).sum().item()
    print(
        f"  Open eyes called closed:  {phantom:4d} of {(~is_closed).sum().item()}"
        "   -> would count blinks that did not happen"
    )
    print(f"  Closed eyes called open:  {missed:4d} of {is_closed.sum().item()}   -> would miss blinks")

    print("\n  By session:")
    for session in data.sessions:
        index = data.indices({session})
        errors = wrong[index].sum().item()
        note = data.rows[index[0]]["condition"] or "-"
        print(
            f"    {session}   {errors:3d} wrong of {len(index):4d}   "
            f"({100 * (1 - errors / len(index)):.1f}% right)   conditions: {note}"
        )

    print("\n  By pose (where does it fail?):")
    poses: dict[tuple[str, str], list[int]] = {}
    for i, row in enumerate(data.rows):
        poses.setdefault((row["label"], row["variant"]), []).append(i)
    for (label, variant), index in sorted(poses.items(), key=lambda kv: -wrong[kv[1]].float().mean().item()):
        errors = wrong[index].sum().item()
        bar = "#" * round(40 * errors / len(index))
        print(f"    {label:6s} {variant:10s} {errors:3d} wrong of {len(index):3d}  {bar}")

    disagreement = (probabilities - data.labels).abs()
    return [i for i in disagreement.argsort(descending=True).tolist() if wrong[i]]


def save_review(data: EyeData, probabilities: torch.Tensor, worst: list[int]) -> None:
    """Writes the wrongly answered pictures to a sheet and a list, worst first."""
    OUT.mkdir(exist_ok=True)

    with (OUT / "cv_predictions.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["session", "file", "label", "variant", "side", "p_closed"])
        for row, p in zip(data.rows, probabilities.tolist(), strict=True):
            writer.writerow(
                [row["session"], row["file"], row["label"], row["variant"], row["side"], f"{p:.4f}"]
            )

    with (OUT / "suspicious.txt").open("w", encoding="utf-8") as handle:
        for i in worst:
            row = data.rows[i]
            handle.write(
                f"{Path(row['path']).relative_to(PROJECT)}\tlabel={row['label']}\t"
                f"model_p_closed={probabilities[i]:.2f}\tpose={row['variant']}\n"
            )

    if worst:
        tiles = [
            sheets.Tile(
                Path(data.rows[i]["path"]),
                f"#{position + 1} label {data.rows[i]['label']}\nmodel: {100 * probabilities[i]:.0f}% closed",
            )
            for position, i in enumerate(worst[:96])
        ]
        sheets.flow(tiles, columns=8, tile=128).save(OUT / "review_suspicious.png")


def main() -> None:
    parser = argparse.ArgumentParser(description="Train and evaluate the eye model.")
    parser.add_argument("--epochs", type=int, default=30, help="passes over the pictures (default 30)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--skip-final", action="store_true", help="measure only, save no model")
    arguments = parser.parse_args()

    on = device()

    data = load()
    if len(data.sessions) < 2:
        raise SystemExit("At least two sessions are needed: one must be held out for testing.")
    print(f"The model has {count_weights(EyeNet()):,} weights. Training on: {on}")

    print("\nSTEP 1 - cross-validation by session")
    probabilities = cross_validate(data, on, arguments.epochs, arguments.seed)
    worst = report(data, probabilities)

    print("\nSTEP 2 - pictures to look at")
    save_review(data, probabilities, worst)
    print(f"  {len(worst)} pictures were answered wrongly.")
    if worst:
        print(f"  Sheet (the 96 worst): {OUT / 'review_suspicious.png'}")
        print(f"  List:                 {OUT / 'suspicious.txt'}")

    if arguments.skip_final:
        return
    print(f"\nSTEP 3 - the final model, trained on all {len(data.sessions)} sessions")
    started = time.time()
    model = train(data.images.to(on), data.labels.to(on), arguments.epochs, arguments.seed + 1000)
    MODEL_FILE.parent.mkdir(exist_ok=True)
    wrong = (probabilities > 0.5) != (data.labels > 0.5)
    torch.save(
        {
            "weights": model.cpu().state_dict(),
            "input": "RGB picture of one eye, 64x64, values 0..1, shape (N, 3, 64, 64)",
            "output": "one score per picture; sigmoid(score) = probability that the eye is closed",
            "sessions": data.sessions,
            "pictures": len(data),
            "epochs": arguments.epochs,
            "cross_validated_accuracy": 1 - wrong.float().mean().item(),
        },
        MODEL_FILE,
    )
    print(
        f"  Saved {MODEL_FILE} ({MODEL_FILE.stat().st_size / 1024:.0f} KB) in {time.time() - started:.0f} s"
    )


if __name__ == "__main__":
    main()
