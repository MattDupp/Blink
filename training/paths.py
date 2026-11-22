"""Where everything is: every folder of the project, named once."""

import os
from pathlib import Path

TRAINING = Path(__file__).resolve().parent
PROJECT = TRAINING.parent

# The recordings and the models are private and stay out of the repository. They are
# normally in the project folder; BLINK_DATA and BLINK_MODELS name other places (the
# Makefile sets them from DATA= and MODELS=), so that recordings kept in another checkout
# can be trained on and judged where they are, without copying them.
DATA = Path(os.environ.get("BLINK_DATA") or PROJECT / "data")
RAW = DATA / "raw"  # recorded sessions (make recorder): eyes held open or closed
LIVE = DATA / "live"  # captures made by the app's Live View window: every frame
REPLAY = DATA / "replay"  # captures that also kept whole frames (make monitor WHOLE_FRAMES=1)
BLINKS = DATA / "blinks"  # real blink frames taken from the captures and labelled
REMOVED = DATA / "removed"  # pictures set aside while cleaning labels

MODELS = Path(os.environ.get("BLINK_MODELS") or PROJECT / "models")
MODEL_FILE = MODELS / "eyenet.pt"

OUT = TRAINING / "out"  # sheets and tables to look at; never committed
DOCS_IMAGES = PROJECT / "docs" / "img"
