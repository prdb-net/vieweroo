"""Build the local test library with FFmpeg and the Python standard library."""
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib
from pathlib import Path

# Each studio has an art direction and five independently titled releases.
STUDIOS = [
    ("Paper Lantern Films", "471c40 ed664a f3d495", ["Lanterns at Dusk", "Copper Kite", "Folded Light", "Passing Ember", "The Red Courtyard"]),
    ("Tideglass Studio", "0b3552 1d9caa a1e8cf", ["Low Water", "Brackish Blue", "Salt Lines", "Estuary", "Under the Breakwater"]),
    ("Copper Finch", "41304d c97534 edc484", ["Saffron Clock", "Wingbeat", "Rust and Ochre", "Second Sundial", "The Long Exposure"]),
    ("Aster Relay", "202445 806bc9 f1b3c8", ["Night Receiver", "Violet Array", "Antenna Field", "Silent Transit", "Orbital Window"]),
    ("Mossframe", "19463f 669b61 d6df8a", ["Fern Atlas", "Lichen Map", "Canopy Study", "Understory", "The Green Interval"]),
    ("Glacier Loom", "303e67 6caacf dce7dd", ["Blue Moraine", "Cold Meridian", "Ice Thread", "The Thaw Line", "Across the Shelf"]),
    ("Velvet Kiln", "431c35 a93657 f1a36d", ["Fired Earth", "Carmine Veil", "Glaze Test", "Last Furnace", "Reduction"]),
    ("Solar Parcel", "4e3259 dc7466 f0d264", ["Gold Courier", "Daybreak Circuit", "Parcel of Sun", "Prism Mail", "Return at Noon"]),
]
CAST = ["Nico Alder", "Mara Fen", "Arden Vale", "Jules Echo", "Ren Cedar", "Aya Lumen",
        "Ellis Reed", "Sora Finch", "Noa Grey", "Ivo Bay", "Remy Ash", "Tess Nova",
        "Oren Wren", "Lio West", "Kira Dune", "Kit Lake"]


def identifier(kind, name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://vieweroo.invalid/{kind}/{name}"))


def oshash(path):
    size = path.stat().st_size
    if size < 131072:
        raise ValueError(f"Video too short for OSHash: {path.name}")
    with path.open("rb") as video:
        head = video.read(65536)
        video.seek(-65536, os.SEEK_END)
        tail = video.read(65536)
    return f"{(size + sum(struct.unpack('<16384Q', head + tail))) % (1 << 64):016x}"


def portrait(index, path):
    """Draw a three-color profile medallion for each fictional cast member."""
    palette = [bytes.fromhex(color) for color in STUDIOS[index % len(STUDIOS)][1].split()]
    pixels = bytearray()
    for y in range(96):
        pixels.append(0)  # PNG filter for this scanline
        for x in range(96):
            u = x if index % 2 else 95 - x
            head = ((u - 47) / 17) ** 2 + ((y - 39) / 23) ** 2 < 1
            nose = 59 <= u <= 68 and 35 <= y <= 47 and u - 59 <= (y - 35) * 0.8
            neck = 39 <= u <= 53 and 55 <= y <= 70
            shoulders = ((u - 46) / 36) ** 2 + ((y - 95) / 31) ** 2 < 1
            hair = head and y < 32 + 4 * math.sin(u * (0.08 + index * 0.005))
            color = palette[0] if hair or shoulders else palette[2] if head or nose or neck else palette[1]
            pixels.extend(color)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 96, 96, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(pixels))) + chunk(b"IEND", b""))
    if not path.exists() or path.read_bytes() != png:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temp:
            temp.write(png)
        Path(temp.name).replace(path)


def make_movie(path, index, palette, staging):
    if not shutil.which("ffmpeg"):
        sys.exit("Install FFmpeg with libx264 to generate the test library (brew install ffmpeg).")
    print(f"Generating {index + 1:02d}/40 · {path.stem}", flush=True)
    colors = palette.split()
    kind = ["spiral", "radial", "square", "circular", "linear"][index % 5]
    effect = (f"gradients=s=640x360:r=15:seed={index}:n=3:c0=0x{colors[0]}:c1=0x{colors[1]}:"
              f"c2=0x{colors[2]}:type={kind}:x0={96 + index * 9}:y0={48 + index * 3}:"
              f"x1={444 - index * 3}:y1=310:speed=0.015")
    output = staging / path.name
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                    "-f", "lavfi", "-i", effect, "-f", "lavfi", "-i", f"sine=frequency={150 + 5 * index}",
                    "-t", str(24 + index % 9 * 3), "-af", "volume=0.2", "-c:a", "aac", "-b:a", "48k",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-threads", "2", "-preset", "veryfast",
                    "-b:v", "240k", "-minrate", "240k", "-maxrate", "240k", "-bufsize", "480k",
                    "-x264-params", "nal-hrd=cbr", "-movflags", "+faststart",
                    "-f", "mov" if path.suffix == ".mov" else "mp4", str(output)], check=True)
    oshash(output)
    output.replace(path)


def generate(root):
    artwork = root / "Portraits"
    artwork.mkdir(parents=True, exist_ok=True)
    cast = []
    for i, name in enumerate(CAST):
        actor_id = identifier("performers", name)
        portrait(i, artwork / (actor_id + ".png"))
        cast.append({"id": actor_id, "name": name, "images": [
            {"imageType": 3, "url": f"https://portraits.vieweroo.invalid/{actor_id}.png"}]})

    manifest_path = root / "prdb.json"
    previous = {}
    if manifest_path.exists():
        previous = {row["video"]["id"]: row for row in json.loads(manifest_path.read_text(encoding="utf-8"))}
    records = []
    with tempfile.TemporaryDirectory(dir=root) as stage:
        for studio_index, (studio, palette, titles) in enumerate(STUDIOS):
            directory = root / "Media" / studio
            directory.mkdir(parents=True, exist_ok=True)
            site = {"id": identifier("studios", studio), "title": studio}
            platforms = {"Copper Finch": ("OnlyFans", "vieweroo_demo_finch"), "Aster Relay": ("Fansly", "vieweroo_demo_aster")}
            if studio in platforms:
                platform, handle = platforms[studio]
                site.update(platformId=identifier("platforms", platform), platformKey=platform.lower(),
                            platformTitle=platform, accountHandle=handle)
            for slot, title in enumerate(titles):
                index = 5 * studio_index + slot
                suffix = ["mp4", "mp4", "mov", "mp4", "m4v"][slot]
                path = directory / f"Reel-{index + 1:03d}.{suffix}"
                video_id = identifier("videos", title)
                old = previous.get(video_id)
                if not (old and path.is_file() and path.stat().st_size == old["filesize"]
                        and oshash(path) == old["osHash"]):
                    make_movie(path, index, palette, Path(stage))
                actors = [cast[index % len(cast)], cast[(index + 3 + slot) % len(cast)]]
                video = {"id": video_id, "title": title, "site": site,
                         "actors": actors, "images": [],
                         "alternativeTitle": f"{title} Study" if slot != 4 else None,
                         "durationSeconds": 25 + index % 9 * 3 if slot != 4 else None,
                         "tags": ["abstract", "color-study", "geometric", "motion-design"] if slot != 4 else []}
                records.append({"osHash": oshash(path), "filesize": path.stat().st_size, "video": video})
        if len(set(record["osHash"] for record in records)) != len(records):
            raise ValueError("The test videos must have distinct OSHashes.")
        manifest = Path(stage) / "prdb.json"
        manifest.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        manifest.replace(manifest_path)
    print(f"Ready: {len(records)} videos, {len(STUDIOS)} studios, {len(cast)} performers.", flush=True)


if __name__ == "__main__":
    generate(Path(sys.argv[1]).resolve())
