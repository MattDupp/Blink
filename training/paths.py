"""Where everything is: every folder of the project, named once."""

from pathlib import Path

TRAINING = Path(__file__).resolve().parent
PROJECT = TRAINING.parent

DATA = PROJECT / "data"
RAW = DATA / "raw"  # sessions made by the recorder: eyes held open or closed
LIVE = DATA / "live"  # captures made by the app's Live View window: every frame
REPLAY = DATA / "replay"  # captures that also kept whole frames (make monitor WHOLE_FRAMES=1)
BLINKS = DATA / "blinks"  # real blink frames taken from the captures and labelled
REMOVED = DATA / "removed"  # pictures set aside while cleaning labels

MODELS = PROJECT / "models"
MODEL_FILE = MODELS / "eyenet.pt"

OUT = TRAINING / "out"  # sheets and tables to look at; never committed
DOCS_IMAGES = PROJECT / "docs" / "img"
