"""The model: a small convolutional neural network that looks at one 64x64 eye picture
and answers with one number - how sure it is that the eye is CLOSED.

WHAT A NEURAL NETWORK IS. A function with many adjustable numbers inside (its "weights";
here about 60,000). Given a picture it computes an answer. Training nudges the weights,
a little at a time, so that the answers get closer to the labels. Nobody writes the rule
"an eye is closed when..."; the rule ends up encoded in the weights.

WHY CONVOLUTIONS. A convolution slides a tiny 3x3 pattern detector over the whole picture
and reports, at every position, how strongly the pattern is present there. Two properties
make it the right tool for pictures:
  - the SAME detector is used everywhere, so an eyelid edge is recognised wherever it is;
  - it needs very few weights (3x3 per detector), so it can learn from few pictures.
The first layer learns simple things (edges, dark blobs); each next layer combines the
previous layer's detections into larger shapes (a lash line, an iris, a closed lid).
"""

import torch
from torch import nn


class Preprocess(nn.Module):
    """Turns a colour picture into what the network really needs - and nothing more.

    This lives INSIDE the model on purpose. Any preparation done outside the model has to
    be redone, identically, by the app; a small difference there is the most common reason
    a model that worked in training fails in the product. Inside the model it is done once,
    the same way, forever.
    """

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (N, 3, 64, 64), values 0..1.
        # 1. Colour is irrelevant to open / closed, and it changes with the light (a warm
        #    lamp, a blue screen). Keep the brightness only: the standard weighted mix of
        #    red, green and blue that matches how bright each looks to the eye.
        gray = 0.299 * x[:, 0:1] + 0.587 * x[:, 1:2] + 0.114 * x[:, 2:3]
        # 2. Give every picture the same average brightness (0) and the same contrast (1).
        #    A picture taken in a dim room and the same one in daylight become identical.
        #    (The standard deviation is spelled out with elementary operations - subtract,
        #    square, average, square root - because every one of them has an exact twin
        #    in Core ML, the format the Mac app will run.)
        centered = gray - gray.mean(dim=(1, 2, 3), keepdim=True)
        std = (centered * centered).mean(dim=(1, 2, 3), keepdim=True).sqrt()
        return centered / (std + 1e-4)


def block(inputs: int, outputs: int) -> nn.Sequential:
    """One stage of the network: detect patterns, then halve the picture."""
    return nn.Sequential(
        # `outputs` different 3x3 detectors, each looking at all `inputs` maps.
        nn.Conv2d(inputs, outputs, kernel_size=3, padding=1, bias=False),
        # Keeps the numbers flowing through the network in a steady range while it trains;
        # without it, training small networks is slow and fragile.
        nn.BatchNorm2d(outputs),
        # "If the detection is negative, call it zero." Without such a bend between
        # layers, a stack of layers would collapse into a single linear formula.
        nn.ReLU(inplace=True),
        # Keep the strongest detection of every 2x2 square: the picture halves in size,
        # and the next layer therefore sees a region twice as large.
        nn.MaxPool2d(2),
    )


class EyeNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.preprocess = Preprocess()
        self.features = nn.Sequential(
            block(1, 16),  # 64x64 -> 32x32, 16 maps of simple patterns
            block(16, 32),  # 32x32 -> 16x16
            block(32, 64),  # 16x16 ->  8x8
            block(64, 64),  #  8x8  ->  4x4, 64 maps of eye-sized shapes
        )
        self.head = nn.Sequential(
            # Average each map over its 4x4 positions: "how much of this shape is in the
            # picture", wherever it is. 64 numbers describe the eye.
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
            # During training, randomly silence a fifth of those numbers each time, so the
            # decision cannot hang on one of them. It is switched off when the model is used.
            nn.Dropout(0.2),
            # A weighted sum of the 64 numbers: the final score.
            nn.Linear(64, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Returns one raw score per picture (a "logit"): above 0 leans closed, below 0
        leans open. `torch.sigmoid` squeezes it into a probability between 0 and 1."""
        return self.head(self.features(self.preprocess(x))).squeeze(1)


def count_weights(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())
