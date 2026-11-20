"""Converts the trained model to Core ML, the format Mac apps run, and PROVES the copy
gives the same answers as the original.

    cd training
    uv run python convert.py

WHY CONVERT. models/eyenet.pt only makes sense to PyTorch, a 300 MB Python library - not
something to ship inside a menu-bar app. Core ML is built into macOS: the app loads one
small file and the system runs it. Conversion translates the network operation by
operation (convolution -> Core ML convolution, and so on) and copies the weights across.

WHY VERIFY. A translation can go subtly wrong: colours in another order, values 0..255
where 0..1 was expected, an operation rounded differently. Nothing crashes; the model
just answers worse, and nobody knows why. So the last step runs the SAME real pictures
through both models and compares the answers, number by number.

It writes:
    models/EyeNet.mlpackage        the Core ML model
    models/EyeNet.mlmodelc         the same, compiled: the form the app loads
    models/eyenet_reference.json   pictures with the answer the model must give - the
                                   Swift code checks itself against it in its self-test
"""

import json
import shutil
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")  # coremltools is noisy about versions it has not tested

import coremltools as ct
import torch
from PIL import Image

from data import load
from model import EyeNet

HERE = Path(__file__).resolve().parent
MODELS = HERE.parent / "models"


class Exported(torch.nn.Module):
    """What the app gets: the trained network, plus the final squeeze into a probability.

    The network's raw score runs from minus to plus infinity; `sigmoid` turns it into
    "probability that the eye is closed", 0..1. Doing it here means the app receives the
    number it wants and has no formula of its own to get wrong.
    """

    def __init__(self, network: EyeNet) -> None:
        super().__init__()
        self.network = network

    def forward(self, eye: torch.Tensor) -> torch.Tensor:
        return torch.sigmoid(self.network(eye))


def main() -> None:
    saved = torch.load(MODELS / "eyenet.pt", weights_only=True)
    network = EyeNet()
    network.load_state_dict(saved["weights"])
    exported = Exported(network).eval()  # evaluation mode: dropout off, fixed batch-norm

    # 1. "Tracing": run one example through the model and record every operation it
    #    performs. The recording, not the Python code, is what gets translated.
    example = torch.rand(1, 3, 64, 64)
    traced = torch.jit.trace(exported, example)

    # 2. Translate. The input is declared as an IMAGE, so the app hands over a picture
    #    and Core ML itself turns it into numbers: `scale` maps the pixels' 0..255 to the
    #    0..1 the network was trained on, and the colour order is stated, not assumed.
    core_ml = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="eye", shape=(1, 3, 64, 64), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)
        ],
        outputs=[ct.TensorType(name="closed")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        # 32-bit numbers, like PyTorch: the model is tiny, so there is nothing to gain
        # from halving the precision, and the answers stay comparable digit for digit.
        compute_precision=ct.precision.FLOAT32,
    )
    core_ml.short_description = "Open or closed eye, from a 64x64 picture of one eye."
    core_ml.input_description["eye"] = "One eye, 64x64, colour, as cut out by BlinkCore's EyeCropper."
    core_ml.output_description["closed"] = "Probability that the eye is closed (0 = open, 1 = closed)."
    core_ml.user_defined_metadata["sessions"] = ", ".join(saved["sessions"])
    core_ml.user_defined_metadata["pictures"] = str(saved["pictures"])
    core_ml.user_defined_metadata["cross_validated_accuracy"] = f"{saved['cross_validated_accuracy']:.4f}"

    package = MODELS / "EyeNet.mlpackage"
    core_ml.save(str(package))
    size = sum(f.stat().st_size for f in package.rglob("*") if f.is_file())
    print(f"Saved {package} ({size / 1024:.0f} KB)")

    # An .mlpackage is the model's "source" form. Before running it, Core ML compiles it
    # into an .mlmodelc folder laid out for fast loading. Xcode does this when it builds
    # an app; we build without Xcode, so we compile here and the app loads the result.
    compiled = MODELS / "EyeNet.mlmodelc"
    shutil.rmtree(compiled, ignore_errors=True)
    ct.utils.compile_model(str(package), str(compiled))
    print(f"Compiled {compiled}")

    # 3. Verify on real pictures: every 12th picture of the dataset, from every session.
    data = load()
    chosen = list(range(0, len(data), 12))
    with torch.no_grad():
        expected = exported(data.images[chosen].float() / 255.0).tolist()

    worst, disagreements, reference = 0.0, 0, []
    for position, i in enumerate(chosen):
        picture = Image.open(data.rows[i]["path"]).convert("RGB")
        answer = float(core_ml.predict({"eye": picture})["closed"].reshape(-1)[0])
        worst = max(worst, abs(answer - expected[position]))
        disagreements += (answer > 0.5) != (expected[position] > 0.5)
        if position % 8 == 0:
            reference.append(
                {
                    "file": str(Path(data.rows[i]["path"]).relative_to(HERE.parent)),
                    "label": data.rows[i]["label"],
                    "closed": round(expected[position], 6),
                }
            )

    print(f"Compared PyTorch and Core ML on {len(chosen)} real pictures:")
    print(f"  largest difference between the two probabilities: {worst:.6f}")
    print(f"  pictures where they disagree on open / closed:    {disagreements}")
    if worst > 0.001:
        raise SystemExit("FAILED: the Core ML model does not reproduce the PyTorch model.")

    (MODELS / "eyenet_reference.json").write_text(json.dumps(reference, indent=1), encoding="utf-8")
    print(f"Wrote {len(reference)} reference answers to {MODELS / 'eyenet_reference.json'}")
    print("RESULT: the Core ML model matches the trained model.")


if __name__ == "__main__":
    main()
