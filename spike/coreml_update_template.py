"""SPIKE: an untrained, UPDATABLE Core ML copy of EyeNet, for `MLUpdateTask`.

    cd training && uv run python ../spike/coreml_update_template.py ../spike/out/updatable [--batch-norm]

Core ML can train a model on the device, within limits (coremltools guide, "Neural Network
Classifier"): only the older NeuralNetwork format, only convolution and fully-connected
layers, cross-entropy on a softmax or mean squared error, SGD or Adam. So this template is
EyeNet with what those limits leave:

  - no batch normalisation that learns (with --batch-norm the layers are there, frozen at
    "do nothing", and the script also asks Core ML to train them, to see what it answers);
  - two outputs through a softmax instead of one through a sigmoid (the same thing for
    two classes, and the only form the cross-entropy loss accepts);
  - no dropout, no weight decay, no one-cycle rate: none exists in the update task.

It holds random weights and no personal data.
"""

# ruff: noqa: E402  (settings come before some imports, on purpose)

import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import AdamParams, NeuralNetworkBuilder

CHANNELS = [1, 16, 32, 64, 64]


def build(folder: Path, batch_norm: bool, train_batch_norm: bool = False) -> Path:
    rng = np.random.default_rng(0)
    builder = NeuralNetworkBuilder(
        [("eye", datatypes.Array(1, 64, 64))], [("probabilities", datatypes.Array(2))]
    )
    # The preprocessing of model.py: same average brightness, same contrast.
    builder.add_mvn(
        "standardise", "eye", "stage0", across_channels=True, normalize_variance=True, epsilon=1e-5
    )
    trained = []
    for stage in range(4):
        inputs, outputs = CHANNELS[stage], CHANNELS[stage + 1]
        # He initialisation: without batch normalisation the starting scale matters.
        bound = np.sqrt(6.0 / (9 * inputs))
        builder.add_convolution(
            f"conv{stage}", kernel_channels=inputs, output_channels=outputs, height=3, width=3,
            stride_height=1, stride_width=1, border_mode="same", groups=1,
            W=rng.uniform(-bound, bound, (3, 3, inputs, outputs)).astype(np.float32),
            b=np.zeros(outputs, dtype=np.float32), has_bias=True,
            input_name=f"stage{stage}", output_name=f"conv{stage}_out",
        )  # fmt: skip
        trained.append(f"conv{stage}")
        last = f"conv{stage}_out"
        if batch_norm:
            builder.add_batchnorm(
                f"norm{stage}", channels=outputs, gamma=np.ones(outputs, dtype=np.float32),
                beta=np.zeros(outputs, dtype=np.float32), mean=np.zeros(outputs, dtype=np.float32),
                variance=np.ones(outputs, dtype=np.float32), input_name=last, output_name=f"norm{stage}_out",
            )  # fmt: skip
            last = f"norm{stage}_out"
            if train_batch_norm:
                trained.append(f"norm{stage}")
        builder.add_activation(f"relu{stage}", "RELU", last, f"relu{stage}_out")
        builder.add_pooling(
            f"pool{stage}", height=2, width=2, stride_height=2, stride_width=2, layer_type="MAX",
            padding_type="VALID", input_name=f"relu{stage}_out", output_name=f"stage{stage + 1}",
        )  # fmt: skip
    builder.add_pooling(
        "average", height=4, width=4, stride_height=4, stride_width=4, layer_type="AVERAGE",
        padding_type="VALID", input_name="stage4", output_name="summary", is_global=True,
    )  # fmt: skip
    builder.add_inner_product(
        "linear", W=rng.uniform(-0.125, 0.125, (2, 64)).astype(np.float32), b=np.zeros(2, dtype=np.float32),
        input_channels=64, output_channels=2, has_bias=True, input_name="summary", output_name="scores",
    )  # fmt: skip
    trained.append("linear")
    builder.add_softmax("softmax", "scores", "probabilities")

    builder.make_updatable(trained)
    builder.set_categorical_cross_entropy_loss(name="loss", input="probabilities")
    builder.set_adam_optimizer(AdamParams(lr=1e-3, batch=128))
    builder.set_epochs(30, allowed_set=[1, 5, 10, 30, 60])
    builder.set_shuffle(seed=0)

    folder.mkdir(parents=True, exist_ok=True)
    name = "EyeNetUpdatable" + ("BN" if batch_norm else "") + ("Trained" if train_batch_norm else "")
    model = ct.models.MLModel(builder.spec, skip_model_load=True)
    model.save(str(folder / f"{name}.mlmodel"))
    compiled = folder / f"{name}.mlmodelc"
    ct.utils.compile_model(str(folder / f"{name}.mlmodel"), str(compiled))
    size = sum(f.stat().st_size for f in compiled.rglob("*") if f.is_file())
    print(f"{compiled.name}: {size / 1024:.0f} KB, trainable layers: {', '.join(trained)}")
    return compiled


if __name__ == "__main__":
    target = Path(sys.argv[1]).resolve()
    build(target, batch_norm=False)
    if "--batch-norm" in sys.argv:
        build(target, batch_norm=True)
        try:
            build(target, batch_norm=True, train_batch_norm=True)
        except Exception as error:  # the answer to "can batch normalisation be trained?"
            print(f"Marking batch normalisation as trainable was refused: {error}")
