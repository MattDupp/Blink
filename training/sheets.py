"""Sheets of small pictures, to be looked at.

Looking at the data is half of this project: the pictures the model gets wrong, the labels
a rule produced, a blink frame by frame. Every tool that shows pictures builds its sheet
here, so they all look alike and the layout arithmetic exists once.
"""

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

INK, PAPER, MUTED = (30, 30, 34), (255, 255, 255), (120, 120, 128)


def font(size: int) -> ImageFont.ImageFont:
    for path in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


@dataclass
class Tile:
    """One picture of a sheet, with the text written under it."""

    picture: Image.Image | Path
    caption: str = ""
    muted: bool = False  # written in grey: context, not the subject

    def image(self, side: int) -> Image.Image:
        source = self.picture if isinstance(self.picture, Image.Image) else Image.open(self.picture)
        return source.convert("RGB").resize((side, side), Image.LANCZOS)


def grid(
    rows: list[list[Tile]],
    *,
    tile: int = 96,
    row_titles: list[str] | None = None,
    title: str = "",
    text_size: int = 12,
) -> Image.Image:
    """Rows of tiles. Each row gets room for its captions; `row_titles` go on the left,
    `title` above."""
    text, bold = font(text_size), font(text_size + 2)
    line = text_size + 3
    left = 8 + max((len(t) for t in row_titles), default=0) * (text_size // 2 + 2) if row_titles else 0
    top = line + 2 if title else 0
    gap = 4
    heights = [
        tile + gap + max((t.caption.count("\n") + 1 if t.caption else 0) for t in row) * line for row in rows
    ]
    columns = max(len(row) for row in rows)

    sheet = Image.new("RGB", (left + columns * (tile + gap) + gap, top + sum(heights) + gap), PAPER)
    draw = ImageDraw.Draw(sheet)
    if title:
        draw.text((gap, 1), title, fill=INK, font=bold)
    y = top + gap
    for index, row in enumerate(rows):
        if row_titles:
            draw.text((gap, y + tile // 2 - line // 2), row_titles[index], fill=INK, font=bold)
        for column, item in enumerate(row):
            x = left + gap + column * (tile + gap)
            sheet.paste(item.image(tile), (x, y))
            if item.caption:
                draw.multiline_text(
                    (x + 1, y + tile + 2),
                    item.caption,
                    fill=MUTED if item.muted else INK,
                    font=text,
                    spacing=1,
                )
        y += heights[index]
    return sheet


def flow(tiles: list[Tile], columns: int, **options) -> Image.Image:
    """One long list of tiles, wrapped into rows of `columns`."""
    return grid([tiles[i : i + columns] for i in range(0, len(tiles), columns)], **options)


def stack(images: list[Image.Image], columns: int = 1, gap: int = 10) -> Image.Image:
    """Whole images laid out in a grid of `columns` (all the size of the first one)."""
    width, height = images[0].size
    lines = -(-len(images) // columns)
    sheet = Image.new("RGB", (columns * (width + gap) - gap, lines * (height + gap) - gap), PAPER)
    for position, image in enumerate(images):
        sheet.paste(image, ((position % columns) * (width + gap), (position // columns) * (height + gap)))
    return sheet
