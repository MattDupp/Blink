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

import os

# A few operations are not available on the Mac's GPU yet; let PyTorch run those on the
# CPU instead of stopping. Must be set before torch is imported.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import argparse
import csv
import math
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from PIL import Image, ImageDraw

from data import EyeData, load
from model import EyeNet, count_weights

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
MODEL_FILE = HERE.parent / "models" / "eyenet.pt"

MAX_ROTATION_DEGREES = 35


# --------------------------------------------------------------------------------------
# Augmentation
# --------------------------------------------------------------------------------------


def augment(x: torch.Tensor) -> torch.Tensor:
    """Returns a randomly altered copy of a batch of pictures (N, 3, 64, 64), values 0..1.

    WHY. We have a few thousand pictures, all of one person, taken in one morning. A
    network shown the exact same pictures again and again ends up memorising them
    ("overfitting"): perfect on those pictures, poor on new ones. So every time a picture
    is shown, it is changed a little, in ways that do NOT change the answer: a closed eye
    is still closed when shifted, tilted, mirrored, darker or blurrier. The network never
    sees the same picture twice, and it learns that these changes do not matter.
    """
    n, device = x.shape[0], x.device

    def uniform(low: float, high: float, *shape: int) -> torch.Tensor:
        return torch.rand(*shape, device=device) * (high - low) + low

    # 1. Mirror half of the pictures. A left eye mirrored looks like a right eye, so the
    #    model treats both eyes alike and the app needs no "which eye is this" logic.
    mirror = torch.rand(n, device=device) < 0.5
    x = torch.where(mirror[:, None, None, None], x.flip(3), x)

    # 2. Rotate, zoom (85%..115%) and shift (up to 10% of the picture): the head tilts,
    #    the face moves nearer, the eye square is never perfectly centred. All three are
    #    one "affine" transformation, written as a 2x3 matrix per picture.
    #
    #    Rotation: up to 35 degrees. FIRST TRAINING RUN (2026-11-20), with 15 degrees:
    #    23 of the 54 wrong answers were closed eyes of the "tilt" pose, where the head
    #    leans about 30 degrees - an angle the model had been shown too rarely.
    angle = uniform(-math.radians(MAX_ROTATION_DEGREES), math.radians(MAX_ROTATION_DEGREES), n)
    zoom = uniform(0.85, 1.15, n)
    shift = uniform(-0.2, 0.2, n, 2)  # the picture spans -1..1, so 0.2 = 10%
    cos, sin = torch.cos(angle) / zoom, torch.sin(angle) / zoom
    matrix = torch.stack(
        [
            torch.stack([cos, -sin, shift[:, 0]], dim=1),
            torch.stack([sin, cos, shift[:, 1]], dim=1),
        ],
        dim=1,
    )
    grid = F.affine_grid(matrix, list(x.shape), align_corners=False)
    # "border": where the transformed picture has no pixel, repeat its edge instead of
    # painting black corners the model could learn to recognise.
    x = F.grid_sample(x, grid, mode="bilinear", padding_mode="border", align_corners=False)

    # 3. Lose detail in a third of the pictures (shrink, then enlarge back): a face far
    #    from the camera, or an eyelid blurred by its own movement during a real blink.
    soft = torch.rand(n, device=device) < 0.33
    if soft.any():
        size = int(torch.randint(24, 49, (1,)).item())
        small = F.interpolate(x[soft], size=(size, size), mode="bilinear", align_corners=False)
        x[soft] = F.interpolate(small, size=x.shape[-2:], mode="bilinear", align_corners=False)

    # 4. Bend the brightness curve (gamma) and add a little sensor noise. The model's
    #    own preprocessing already cancels plain "darker / lighter"; gamma changes how
    #    shadows relate to highlights, which it cannot cancel.
    gamma = torch.exp(uniform(-0.4, 0.4, n, 1, 1, 1))
    x = x.clamp(1e-4, 1.0) ** gamma
    x = x + torch.randn_like(x) * uniform(0.0, 0.03, n, 1, 1, 1)
    return x.clamp(0.0, 1.0)


# --------------------------------------------------------------------------------------
# Training and prediction
# --------------------------------------------------------------------------------------


def as_input(images: torch.Tensor) -> torch.Tensor:
    """Stored pictures are whole numbers 0..255; the model takes fractions 0..1."""
    return images.float() / 255.0


@torch.no_grad()
def predict(model: EyeNet, images: torch.Tensor) -> torch.Tensor:
    """The model's probability that each picture is a closed eye (no augmentation)."""
    model.eval()  # evaluation mode: dropout off, batch-norm uses its learned averages
    scores = [model(as_input(images[i : i + 512])) for i in range(0, len(images), 512)]
    return torch.sigmoid(torch.cat(scores)).cpu()


def train(
    images: torch.Tensor,
    labels: torch.Tensor,
    epochs: int,
    seed: int,
    watch: tuple[torch.Tensor, torch.Tensor] | None = None,
) -> EyeNet:
    """Trains a new model on these pictures (already on the training device).

    THE LOOP. Take a small batch of pictures. Ask the model for its answers. Measure how
    wrong they are with one number, the LOSS. Compute, for each of the 60,000 weights, in
    which direction it should move to make that loss smaller (the "gradient", obtained by
    backpropagation). Move every weight a small step that way. Repeat. One pass over all
    the pictures is an EPOCH.
    """
    torch.manual_seed(seed)  # same seed = same random numbers = the same run again
    device = images.device
    model = EyeNet().to(device)

    batch_size = 128
    steps_per_epoch = math.ceil(len(images) / batch_size)

    # AdamW decides the size of each weight's step. weight_decay gently pulls weights
    # towards zero: a model with smaller weights draws smoother, simpler boundaries.
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    # The step size ("learning rate") rises during the first epochs, then falls to zero:
    # careful at the start, bold in the middle, fine adjustments at the end.
    schedule = torch.optim.lr_scheduler.OneCycleLR(
        optimizer, max_lr=2e-3, total_steps=epochs * steps_per_epoch
    )
    # The loss for a yes / no answer. It is small when the model is confident and right,
    # and grows without limit when it is confident and wrong.
    loss_function = torch.nn.BCEWithLogitsLoss()

    for epoch in range(1, epochs + 1):
        model.train()  # training mode: dropout on, batch-norm uses the batch itself
        order = torch.randperm(len(images), device=device)  # a new shuffle every epoch
        total = 0.0
        for start in range(0, len(images), batch_size):
            batch = order[start : start + batch_size]
            scores = model(augment(as_input(images[batch])))
            loss = loss_function(scores, labels[batch])

            optimizer.zero_grad()  # forget the previous batch's gradients
            loss.backward()  # backpropagation: the gradient of the loss for every weight
            optimizer.step()  # move the weights
            schedule.step()
            total += loss.item() * len(batch)

        if watch is not None and (epoch == 1 or epoch % 5 == 0 or epoch == epochs):
            held_images, held_labels = watch
            wrong = ((predict(model, held_images) > 0.5).float() != held_labels.cpu()).sum().item()
            print(
                f"    epoch {epoch:2d}: training loss {total / len(images):.3f}   "
                f"unseen session: {wrong} wrong of {len(held_images)} "
                f"({100 * (1 - wrong / len(held_images)):.1f}% right)"
            )
    return model


# --------------------------------------------------------------------------------------
# The three steps
# --------------------------------------------------------------------------------------


def cross_validate(data: EyeData, device: torch.device, epochs: int, seed: int) -> torch.Tensor:
    """Returns, for every picture, the probability "closed" given by a model that never
    saw that picture's session."""
    images, labels = data.images.to(device), data.labels.to(device)
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
            images[rest.to(device)],
            labels[rest.to(device)],
            epochs,
            seed + fold,
            watch=(images[test.to(device)], labels[test.to(device)]),
        )
        probabilities[test] = predict(model, images[test.to(device)])
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

    root = HERE.parent
    with (OUT / "suspicious.txt").open("w", encoding="utf-8") as handle:
        for i in worst:
            row = data.rows[i]
            handle.write(
                f"{Path(row['path']).relative_to(root)}\tlabel={row['label']}\t"
                f"model_p_closed={probabilities[i]:.2f}\tpose={row['variant']}\n"
            )

    shown = worst[:96]
    if not shown:
        return
    tile, caption, columns = 128, 30, 8
    lines = math.ceil(len(shown) / columns)
    sheet = Image.new("RGB", (columns * tile, lines * (tile + caption)), "white")
    draw = ImageDraw.Draw(sheet)
    for position, i in enumerate(shown):
        row = data.rows[i]
        x, y = (position % columns) * tile, (position // columns) * (tile + caption)
        picture = Image.open(row["path"]).convert("RGB").resize((tile, tile), Image.NEAREST)
        sheet.paste(picture, (x, y))
        draw.text(
            (x + 3, y + tile + 2),
            f"#{position + 1} label {row['label']}\nmodel: {100 * probabilities[i]:.0f}% closed",
            fill="black",
        )
    sheet.save(OUT / "review_suspicious.png")


def main() -> None:
    parser = argparse.ArgumentParser(description="Train and evaluate the eye model.")
    parser.add_argument("--epochs", type=int, default=30, help="passes over the pictures (default 30)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="auto", help="auto, mps (the Mac's GPU) or cpu")
    parser.add_argument("--skip-final", action="store_true", help="measure only, save no model")
    arguments = parser.parse_args()

    if arguments.device == "auto":
        arguments.device = "mps" if torch.backends.mps.is_available() else "cpu"
    device = torch.device(arguments.device)

    data = load()
    if len(data.sessions) < 2:
        raise SystemExit("At least two sessions are needed: one must be held out for testing.")
    print(f"The model has {count_weights(EyeNet()):,} weights. Training on: {device}")

    print("\nSTEP 1 - cross-validation by session")
    probabilities = cross_validate(data, device, arguments.epochs, arguments.seed)
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
    model = train(data.images.to(device), data.labels.to(device), arguments.epochs, arguments.seed + 1000)
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
