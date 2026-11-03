## MK Studio 1.0.0-rc.1 - release candidate

A workbench for Metakit databases: browse, query (SQL-like), design and edit, as one self-contained program.
This is a **release candidate**: everything below is tested, but it has not yet had months of use by other people.
Please try it on copies of databases you care about and report what you find.

### Downloads

| System | File | Notes |
|---|---|---|
| Windows 10/11 (64-bit) | `MKStudio-<version>-windows-x64-setup.exe` | per-user installer, no administrator rights; or the single file `mkstudio-windows-x86_64.exe` |
| macOS (Apple silicon) | `MKStudio-<version>-macos-arm64.dmg` | drag to Applications |
| macOS (Intel) | `MKStudio-<version>-macos-x86_64.dmg` | drag to Applications |
| Linux (x86-64) | `mkstudio_<version>_amd64.deb`, `MKStudio-<version>-linux-x86_64.tar.gz` | tarball installs to `~/.local` without root |
| any | `mkstudio-<platform>` | the bare program (what "Check for Updates" replaces itself with) |

`SHA256SUMS` lists the checksum of every file.

### These files are not signed

There is no code-signing certificate behind them. In practice:

- **Windows** SmartScreen shows "Windows protected your PC" - choose *More info > Run anyway*.
- **macOS** the program inside the app is signed ad hoc only (the app bundle itself is not sealed: `codesign` refuses a
  starpack as a bundle's main executable); the first time, right-click the app > *Open* and confirm.
- **Linux** nothing to confirm.
- The checksums catch a damaged download, **not** a malicious one: if someone took over the project's GitHub account they could
  publish matching checksums. Download from the project's own releases page only.

### Safety of your data

- Nothing is written to a database until you commit; an interrupted commit (program killed, power cut) is undone the next time
  the file is opened, so the file is the state before that commit.
- Each commit is forced to disk (`sync` on Linux and macOS, `FlushFileBuffers` through PowerShell on Windows), a checksum of the
  finished file is kept next to it (`.sum`) and a copy of the file from before an editing session (`.bak`). A file that no
  longer matches its checksum is reported when it is opened, with the option to restore the backup.
- What this cannot do: a disk or SSD that lies about having written data, files over 512 MB (no checksum or backup), and anything
  Metakit itself gets wrong. Tested with simulated power cuts and real kills - not with real power cuts. Keep your own backups.

### Updates and crash reports

- *Help > Check for Updates* asks GitHub for the newest release (one request; only the program name and version are sent). It
  can replace the program itself after checking the download's SHA-256 against `SHA256SUMS` and starting the new one once as a
  test; the previous version stays next to it as `.old`. Installed copies (`.deb`, `.app`) are updated by downloading the new
  installer. Turn the automatic daily check off under the same menu.
- If the program hits a bug it saves a report (version, system, error, call stack as procedure names, the last things it did)
  to a local folder (*Help > Open Crash Reports Folder*). It contains no SQL and no data. Nothing is sent unless you press
  *Report on GitHub* and submit it yourself. A crash the program cannot catch is noticed at the next start.

### Known limits

See the README: Metakit is unmaintained and has no checksums of its own; concurrent writers are prevented by an advisory lock only;
macOS builds use Tcl/Tk 8.6.16 built in CI, Windows and Linux use the 2014 Tcl/Tk 8.6.3 runtime.
