"""The learning itself: altering the pictures, training a model, asking it for answers.

train.py (the command), evaluate.py and figures.py all use these functions.

TRIED AND NOT KEPT (2026-11-20). Training with vertical motion blur and low-light noise,
to imitate a real blink on the darker side of the face, sounded like the obvious remedy
for the blinks the first model missed. Measured on 216 held-out blinks it found 198 and
counted 3 false ones, against 201 and 1 without it. It was removed; the measurement is
why (see docs/LESSONS.md, and `git log` for the code).
"""

import os

# A few operations are not available on the Mac's GPU yet; let PyTorch run those on the
# CPU instead of stopping. Must be set before torch is imported.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import math

import torch
import torch.nn.functional as F

from model import EyeNet

MAX_ROTATION_DEGREES = 35


def device() -> torch.device:
    """The Mac's GPU ("mps") when there is one, else the processor."""
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


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
