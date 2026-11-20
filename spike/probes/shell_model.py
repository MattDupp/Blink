"""PROBE: a Core ML model that holds NO weights. The weights are inputs.

    cd training && uv run python ../spike/probes/shell_model.py ../spike/out/shell

If Core ML accepts it, the app could ship this one fixed model (no personal data) and hand
it each user's trained numbers at every call, with nothing but the public API.
"""

# ruff: noqa: E402  (settings come before some imports, on purpose)

import shutil
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import coremltools as ct
import torch
import torch.nn.functional as F

CHANNELS = [1, 16, 32, 64, 64]
NAMES = [f"{kind}{stage}" for stage in range(4) for kind in ("w", "b")] + ["wl", "bl"]


class Shell(torch.nn.Module):
    def forward(self, eye, w0, b0, w1, b1, w2, b2, w3, b3, wl, bl):
        gray = 0.299 * eye[:, 0:1] + 0.587 * eye[:, 1:2] + 0.114 * eye[:, 2:3]
        centered = gray - gray.mean(dim=(1, 2, 3), keepdim=True)
        x = centered / ((centered * centered).mean(dim=(1, 2, 3), keepdim=True).sqrt() + 1e-4)
        for w, b in ((w0, b0), (w1, b1), (w2, b2), (w3, b3)):
            x = F.max_pool2d(F.relu(F.conv2d(x, w, b, padding=1)), 2)
        return torch.sigmoid(F.linear(x.mean(dim=(2, 3)), wl, bl))


def shapes():
    out = []
    for stage in range(4):
        out += [(CHANNELS[stage + 1], CHANNELS[stage], 3, 3), (CHANNELS[stage + 1],)]
    return out + [(1, 64), (1,)]


def main() -> None:
    folder = Path(sys.argv[1]).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    example = [torch.rand(1, 3, 64, 64)] + [torch.rand(*shape) for shape in shapes()]
    traced = torch.jit.trace(Shell().eval(), example)
    eye = ct.ImageType(name="eye", shape=(1, 3, 64, 64), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)
    inputs = [eye]
    inputs += [ct.TensorType(name=name, shape=shape) for name, shape in zip(NAMES, shapes(), strict=True)]
    model = ct.convert(
        traced, inputs=inputs, outputs=[ct.TensorType(name="closed")], convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32,
    )  # fmt: skip
    package = folder / "EyeNetShell.mlpackage"
    shutil.rmtree(package, ignore_errors=True)
    model.save(str(package))
    compiled = folder / "EyeNetShell.mlmodelc"
    shutil.rmtree(compiled, ignore_errors=True)
    ct.utils.compile_model(str(package), str(compiled))
    size = sum(f.stat().st_size for f in compiled.rglob("*") if f.is_file())
    print(f"{compiled}: {size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
