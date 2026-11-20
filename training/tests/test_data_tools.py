"""The data tools, on tiny made-up sessions and captures written to a temporary folder."""

import csv
import importlib.util
from pathlib import Path

from PIL import Image

import data
import label_captures

PROJECT = Path(__file__).resolve().parents[2]
HEADER = label_captures.HEADER


def picture(path: Path, grey: int = 128) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (64, 64), (grey, grey, grey)).save(path)


def session(root: Path, name: str, rows: list[dict]) -> Path:
    """Writes a session folder: the pictures and a manifest with one line per row."""
    folder = root / name
    folder.mkdir(parents=True)
    with (folder / "manifest.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER, restval="")
        writer.writeheader()
        for row in rows:
            picture(folder / row["file"])
            writer.writerow({"session": name, **row})
    return folder


def row(label: str, name: str, side: str = "L", yaw: str = "") -> dict:
    return {"label": label, "variant": "test", "side": side, "file": f"{label}/{name}", "yaw": yaw}


# --- loading -----------------------------------------------------------------------------


def test_far_eye_rule():
    assert data.is_far_eye({"yaw": "0.785", "side": "R"})
    assert data.is_far_eye({"yaw": "-0.785", "side": "L"})
    assert not data.is_far_eye({"yaw": "0.785", "side": "L"})
    assert not data.is_far_eye({"yaw": "0.000", "side": "R"})
    assert not data.is_far_eye({"yaw": "", "side": "R"})


def test_load_reads_every_session_and_skips_what_it_should(tmp_path):
    recorded, blinks = tmp_path / "raw", tmp_path / "blinks"
    session(
        recorded, "s1", [row("open", "a.png"), row("closed", "b.png"), row("closed", "far.png", "R", "0.785")]
    )
    folder = session(blinks, "s2", [row("closed", "c.png"), row("open", "gone.png")])
    (folder / "open/gone.png").unlink()  # deleted by hand, manifest not synced

    loaded = data.load((recorded, blinks))

    assert tuple(loaded.images.shape) == (3, 3, 64, 64)
    assert loaded.sessions == ["s1", "s2"]
    by_file = {r["file"]: label for r, label in zip(loaded.rows, loaded.labels.tolist(), strict=True)}
    assert by_file == {"open/a.png": 0.0, "closed/b.png": 1.0, "closed/c.png": 1.0}
    assert [loaded.rows[i]["file"] for i in loaded.indices({"s2"})] == ["closed/c.png"]


# --- labelling a capture -----------------------------------------------------------------


def capture(root: Path, frames: list[tuple[float, float, float, float]]) -> Path:
    """A capture whose frames are (p_left, p_right, outline_left, outline_right)."""
    folder = root / "cap"
    (folder / "frames").mkdir(parents=True)
    with (folder / "trace.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "frame",
                "time",
                "p_left",
                "p_right",
                "p_mean",
                "open_left",
                "open_right",
                "state",
                "event",
                "tick",
            ]
        )
        for i, (left, right, outline_left, outline_right) in enumerate(frames):
            writer.writerow(
                [i, f"{i / 30:.4f}", left, right, (left + right) / 2, outline_left, outline_right, "", "", ""]
            )
            for side in "LR":
                picture(folder / "frames" / f"f{i:06d}_{side}.png")
    return folder


def test_one_eye_labels_the_other(tmp_path):
    calm = (0.0, 0.0, 0.25, 0.28)
    frames = (
        [calm] * 20
        + [
            (0.10, 1.00, 0.09, 0.19),  # right eye sure, left outline flat      -> left labelled closed
            (0.10, 1.00, 0.20, 0.19),  # right eye sure, left outline NOT flat  -> left left alone
            (0.95, 0.95, 0.09, 0.19),  # both sure
        ]
        + [calm] * 20
    )

    closed, opened, by_other_eye = label_captures.label_capture(
        capture(tmp_path / "live", frames), tmp_path / "out"
    )

    labelled = {
        line["file"]: line["variant"] for line in csv.DictReader((tmp_path / "out/cap/manifest.csv").open())
    }
    assert labelled["closed/f000020_L.png"] == "blink-other-eye"
    assert labelled["closed/f000020_R.png"] == "blink"
    assert "closed/f000021_L.png" not in labelled and "open/f000021_L.png" not in labelled
    assert labelled["closed/f000022_L.png"] == "blink"
    assert len(by_other_eye) == 1
    assert closed == 5  # frame 20: both eyes, frame 21: the right eye, frame 22: both eyes
    # Open pictures come only from calm stretches, one frame in six, never next to the blink.
    assert opened > 0
    assert all(
        int(Path(f).stem[1:7]) not in range(14, 29) for f, v in labelled.items() if v == "between-blinks"
    )
    assert all((tmp_path / "out/cap" / f).is_file() for f in labelled)


# --- keeping manifests in step with the pictures ------------------------------------------


def test_sync_removes_only_the_lines_without_a_picture(tmp_path):
    spec = importlib.util.spec_from_file_location("sync_manifests", PROJECT / "scripts/sync_manifests.py")
    sync = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sync)

    folder = session(tmp_path, "s1", [row("open", "a.png"), row("closed", "b.png"), row("closed", "c.png")])
    (folder / "closed/b.png").unlink()
    picture(folder / "open/unlisted.png")

    assert sync.sync_session(folder, check_only=True) == (2, 1, 1)
    assert len((folder / "manifest.csv").read_text().splitlines()) == 4  # --check changes nothing

    assert sync.sync_session(folder, check_only=False) == (2, 1, 1)
    files = [line["file"] for line in csv.DictReader((folder / "manifest.csv").open())]
    assert files == ["open/a.png", "closed/c.png"]
    assert (folder / "open/unlisted.png").is_file()  # a picture is never deleted
