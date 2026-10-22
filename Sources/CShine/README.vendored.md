# CShine — vendored MP3 encoder

Source: shine fixed-point MP3 encoder, https://github.com/toots/shine
License: GNU LGPL v2 (see COPYING).
Vendored verbatim from `src/lib/` (the encoder library only; the CLI in `src/bin`
is not included). `layer3.h` is the public API and lives in `include/`; all other
`.c`/`.h` files are the private implementation.

Why vendored: macOS AudioToolbox can decode but not *encode* MP3, and the gen-1
Sonos PLAY:5 only accepts Streaming MP3 (not PCM/WAV or AAC) over its internet-radio
URI (`x-rincon-mp3radio://`). shine encodes PCM to MP3 frames incrementally, which
suits a live endless stream.
