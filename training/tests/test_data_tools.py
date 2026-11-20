"""The data tools, on tiny made-up sessions and captures written to a temporary folder."""

import csv
import importlib.util
import re
from pathlib import Path

from PIL import Image

import annotate
import captures
import data
import evaluate
import label_captures
from captures import Capture

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


# --- captures: reading, labelling, annotating ----------------------------------------------


def capture(root: Path, frames: list[tuple[float, float, float, float]]) -> Capture:
    """A capture whose frames are (p_left, p_right, outline_left, outline_right)."""
    folder = root / "cap"
    (folder / "frames").mkdir(parents=True)
    with (folder / "trace.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(captures.TRACE_HEADER.split(","))
        for i, (left, right, outline_left, outline_right) in enumerate(frames):
            mean = (left + right) / 2
            writer.writerow([i, f"{i / 30:.4f}", left, right, mean, outline_left, outline_right, "", "", ""])
            for side in "LR":
                picture(folder / "frames" / f"f{i:06d}_{side}.png")
    return Capture.load(folder)


CALM = (0.0, 0.0, 0.25, 0.28)
ONE_BLINK = [CALM] * 20 + [
    (0.10, 1.00, 0.09, 0.19),  # right eye sure, left outline flat      -> left labelled closed
    (0.10, 1.00, 0.20, 0.19),  # right eye sure, left outline NOT flat  -> left left alone
    (0.95, 0.95, 0.09, 0.19),  # both sure
] + [CALM] * 20  # fmt: skip


def test_a_capture_is_read_into_numbers(tmp_path):
    loaded = capture(tmp_path, ONE_BLINK)
    assert len(loaded.frames) == 43
    frame = loaded.frames[20]
    assert (frame.number, frame.left, frame.right, frame.counted, frame.tick) == (
        20,
        0.10,
        1.00,
        False,
        False,
    )
    assert frame.answer("R") == 1.00
    assert loaded.picture(frame, "L").name == "f000020_L.png"
    assert abs(loaded.seconds - 42 / 30) < 1e-6
    # Outlines are rescaled per eye: 0 = most closed in this capture, 1 = usual open.
    assert loaded.outline("L")[0] == 1.0 and loaded.outline("L")[20] == 0.0


def test_one_eye_labels_the_other(tmp_path):
    closed, opened, by_other_eye = label_captures.label_capture(
        capture(tmp_path / "live", ONE_BLINK), tmp_path / "out"
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


def test_annotating_again_keeps_every_answer(tmp_path):
    loaded = capture(tmp_path, ONE_BLINK)
    assert annotate.annotate(loaded, tmp_path / "sheets") == (1, 1, 0)  # one candidate, to answer

    answers = loaded.folder / "blinks.csv"
    lines = list(csv.DictReader(answers.open()))
    lines[0] |= {"kind": "blink", "note": "clear"}
    # A second answered line, about frames that are no candidate (any more).
    lines.append({"id": 2, "first_frame": 5, "last_frame": 6, "kind": "none", "note": ""})
    with answers.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=annotate.FIELDS)
        writer.writeheader()
        writer.writerows(lines)

    assert annotate.annotate(loaded, tmp_path / "sheets") == (1, 0, 1)  # nothing to answer, one line kept
    kept = {(line["first_frame"], line["kind"]): line["note"] for line in csv.DictReader(answers.open())}
    assert kept == {("5", "none"): "[no longer a candidate]", ("20", "blink"): "clear"}


def test_an_answer_follows_a_candidate_whose_frames_shifted():
    old = [{"first_frame": "100", "last_frame": "104", "kind": "blink", "note": "n"}]
    lines, orphans = annotate.carry_answers(old, [(101, 106), (300, 302)])
    assert [(line["kind"], line["note"]) for line in lines] == [("blink", "n"), ("", "")]
    assert orphans == []


def test_two_answers_merged_into_one_candidate_are_asked_again():
    old = [
        {"first_frame": "100", "last_frame": "102", "kind": "blink", "note": ""},
        {"first_frame": "104", "last_frame": "106", "kind": "none", "note": ""},
    ]
    lines, orphans = annotate.carry_answers(old, [(100, 106)])
    assert lines[0]["kind"] == "" and lines[0]["note"] == "was: blink + none"
    assert orphans == []


def test_labelling_leaves_a_labelled_capture_alone(tmp_path, monkeypatch, capsys):
    loaded = capture(tmp_path / "live", ONE_BLINK)
    monkeypatch.setattr(label_captures, "all_captures", lambda: [loaded])
    monkeypatch.setattr(label_captures, "BLINKS", tmp_path / "blinks")
    monkeypatch.setattr(label_captures, "OUT", tmp_path / "out")
    kept = tmp_path / "blinks" / "cap" / "cleaned-by-hand.txt"
    kept.parent.mkdir(parents=True)
    kept.write_text("mine")

    monkeypatch.setattr("sys.argv", ["label_captures.py"])
    label_captures.main()
    assert kept.read_text() == "mine"
    assert "already labelled" in capsys.readouterr().out


# --- the formats shared with the Swift code -------------------------------------------------


def swift(path: str, pattern: str) -> str:
    match = re.search(pattern, (PROJECT / path).read_text(), re.S)
    assert match, f"{pattern} not found in {path}"
    return match.group(1)


def test_the_manifest_columns_are_the_ones_swift_writes():
    declared = swift(
        "Sources/BlinkCore/Recording/SessionWriter.swift", r'static let header = ((?:\s*\+?\s*"[^"]*")+)'
    )
    assert "".join(re.findall(r'"([^"]*)"', declared)).split(",") == label_captures.HEADER


def test_the_trace_columns_are_the_ones_swift_writes():
    declared = swift("Sources/BlinkCore/Recording/CaptureWriter.swift", r'static let header = "([^"]*)"')
    assert declared == captures.TRACE_HEADER


def test_the_scoring_window_is_the_swift_one():
    score = "Sources/BlinkCore/Detection/BlinkScore.swift"
    before, after = swift(score, r"framesBefore = (\d+)"), swift(score, r"framesAfter = (\d+)")
    assert (int(before), int(after)) == (evaluate.FRAMES_BEFORE, evaluate.FRAMES_AFTER)


def test_a_count_is_scored_as_swift_scores_it(tmp_path):
    # The same marks, the same counts and the same expected numbers as `BlinkScoreTests.score`
    # in Tests/BlinkCoreTests/WholeFrameTests.swift: the two languages are held to one answer.
    # A capture of 700 frames, every one read, numbered from 0: a position is a frame number.
    loaded = capture(tmp_path, [CALM] * 700)
    truth = [
        evaluate.Truth(100, 103, "blink"),
        evaluate.Truth(200, 202, "none"),
        evaluate.Truth(300, 302, "partial"),
        evaluate.Truth(400, 404, "blink"),
        evaluate.Truth(600, 603, "blink"),
    ]
    result = evaluate.score(loaded, truth, [108, 109, 106, 203, 303, 398, 500])
    assert (result.blinks, result.found, result.missed, result.false) == (3, 2, 1, 4)


def test_the_head_turn_limit_is_the_swift_one():
    declared = swift("Sources/BlinkCore/Vision/EyeLocator.swift", r"maxYawForBothEyes = ([0-9.]+)")
    assert float(declared) == data.MAX_YAW_FOR_BOTH_EYES


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
