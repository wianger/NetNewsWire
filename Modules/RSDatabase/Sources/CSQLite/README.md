# CSQLite

The SQLite amalgamation, used by RSDatabase on platforms without a system SQLite module
(Windows, Linux). Apple platforms use the system SQLite instead.

- Version: 3.54.1 (`sqlite-amalgamation-3540100.zip` from https://www.sqlite.org/download.html)
- SHA3-256 of the zip: `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`
- Compile options are in `Modules/RSDatabase/Package.swift`. They enable FTS3/4/5
  (the articles search table uses FTS4), matching Apple's system SQLite.

To update: download the new amalgamation, verify its SHA3-256 against the download page,
copy `sqlite3.c` here and `sqlite3.h` into `include/`, and update this file.
