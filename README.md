# MusicSync

A simple Swift app for MacOS that helps organize loose MP3s into folders and provides a one-way sync utility to copy those folders to an external drive.  I use this to keep USB sticks up-to-date for my car audio systems.  Probably of little use to anyone these days in the era of Bluetooth and streaming, but I'm still stuck in my ways, I guess. Written entirely with Claude Code. Feel free to use/fork as you wish, but I provide no guarantees on the functionality/safety of the app :)

## Build and run

Needs the Xcode Command Line Tools (no full Xcode). Or just download the latest MusicSync.app and run it.

```bash
./build.sh
```

```bash
open MusicSync.app
```

`./test.sh` runs the sync engine tests.

## Organize tab

Moves loose `.mp3` files named `Band - Song` or `Song - Band` into
`Destination/Band/Song.ext`. Scan shows a table of each file with the detected
band and song; both are editable and each row has a swap button. Nothing moves
until you press Move.

The band side is decided by, in order: the file's embedded artist/title tags, a
matching band folder already in the destination, and a name that repeats across
the files. If none apply the row is a guess (`Song - Band`), flagged and left
unticked. Matching ignores case, accents, punctuation and a leading "The".
Existing files are never overwritten; only files directly in the source folder
are considered.

## Stick Sync tab

- **Destination** is a whole external drive, picked from the list of connected
  drives. The Mac's internal disk never appears in the list.
- **Only `.mp3` files** are copied. Other files in the source are ignored, and
  anything else on the drive is removed like any other extra.
- **Changed** means a different size, or a modified time more than 2 seconds apart.
- **Exclude folders**: comma-separated. `Podcasts` skips any folder with that
  name; `Rock/Live` skips that exact path. Excluded folders are not copied, and
  if one already exists on the drive it is left alone.
- **Eject** unmounts the selected drive and confirms when it is safe to unplug.
- **Deletions** are shown for confirmation before anything is removed.
- Never copied or deleted: `.DS_Store`, `._*` files, and the drive's own system
  folders (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, …). Links in the source
  are skipped.
- The source folder, exclude list and last drive are remembered between launches.
