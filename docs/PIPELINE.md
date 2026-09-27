# Processing pipeline

Acquisition hands over a directory (or a `.pkg`). Everything after that is
format inspection, and the package decides the strategy — never the Workshop
tags alone, because tags describe what the author claimed.

## Container formats

**PKG (`PKGV0022`)** — a flat archive: 16-byte header, then one directory entry
per file (`name_length`, `name`, `offset`, `size`), then the data section.
Entry offsets are relative to the start of the data section and are honoured
literally; assuming entries are contiguous breaks on packages with gaps.

**TEX (`TEXV0005`)** — a texture container: `TEXI0001` carries format, flags and
dimensions; `TEXB0002/3/4` wraps the payload, with different header lengths per
version. The payload is one of:

- a complete **MP4/ISOBMFF video stream** (this is how video wallpapers store
  their video),
- a PNG/JPEG/GIF/WebP image,
- GPU-compressed pixel data (DXT/BCn).

An embedded MP4 is located by validating the ISOBMFF box-length prefix before
`ftyp`, not by searching for the string, so `ftyp` bytes occurring inside
compressed pixel data cannot cause a false positive.

## Strategy selection

| Strategy | Chosen when | Fidelity | Re-encoded |
| --- | --- | --- | --- |
| `passthrough` | Package holds an MP4 (loose or inside a `.tex`) | `identical` | No — file copied verbatim |
| `remux` | Package holds WebM/MKV/MOV | `identical` | No — stream copied, container changed |
| `encode_animation` | GIF/APNG only | `near_identical` | Yes |
| `encode_still` | A single image only | `static_only` | Yes |
| `render_scene` | `scene.json` and assets, no finished video | `approximate` | Requires a renderer |
| `unsupported` | Nothing usable found | `none` | — |

The passthrough path is covered by a byte-exact test: the exported file must
equal the original stream, not merely resemble it.

## Scene wallpapers

A scene package is a program, not a recording: `scene.json`, shaders, models,
textures, audio. Producing a video requires running it and capturing frames.

This is reported as `approximate`, never silently downgraded to a still frame.
Wallpapers tagged `Audio responsive`, `Interactive`, `Clock`, or
`Media Integration` also carry an explicit warning, because those react at
runtime and no video can reproduce that.
