# Manual QA checklist

Everything automation could check is checked on every commit (see the table in the README). What is left is what a CI runner
cannot do: real hardware, real people, real operating-system prompts. About an hour, once per release candidate, on a machine
you do not mind breaking. Tick each line; anything that fails is a bug to report with the crash-report folder
(*Help > Open Crash Reports Folder*).

Always work on a **copy** of a database you care about until this list has passed.

## 1. Real power loss (the one thing only hardware can show)
Use a spare machine or a VM whose virtual disk you can power off without a clean shutdown (VirtualBox "Power off", not "Shut down").

- [ ] Open a copy of a large database (50 MB+), change a cell, press **Save**. The instant Save returns, power off.
      Boot, open the file: the change is there *or* the old data is there, never an error. Repeat 10 times.
- [ ] Same, but power off *during* a Save of a big change (add a column to a 500,000-row table). The file opens, and shows
      the data from before the save. If it says the file was damaged, *Restore Backup* offers the copy from before the session.
- [ ] After each of the above, `<file>.commit` is gone (or the next open repaired it silently).

## 2. First run on each operating system
- [ ] **Windows 10/11, installer**: download `MKStudio-...-setup.exe`. SmartScreen warns "unknown publisher" (the build is not
      signed): *More info > Run anyway*. Installs without asking for administrator rights. Start-menu entry works.
      Double-clicking a `.mk` file offers MK Studio under *Open with*. *Uninstall* leaves no folder behind.
- [ ] **Windows, stand-alone `.exe`**: runs from any folder, including one with a space and a non-ASCII letter in its name.
- [ ] **macOS 15 (Sequoia)**: open the `.dmg`, drag to Applications, double-click: blocked. *System Settings > Privacy &
      Security > Open Anyway*. Then it opens, and a `.mk` file dropped on the icon opens.
- [ ] **Linux**: `.deb` installs (`sudo apt install ./mkstudio_*.deb`), the launcher appears, `mkstudio --version` answers.
      The tarball's `sh install.sh` works without root.
- [ ] Antivirus (Windows Defender) does not quarantine the installer or the exe. If it does, note the detection name.

## 3. Updating
- [ ] Install the *previous* release, then *Help > Check for Updates*: it finds the new one, shows the notes, downloads,
      verifies, restarts into the new version. (Windows: the swap happens after you close the old window, then it restarts.)
- [ ] Disconnect from the network and check again: a plain message, no crash.
- [ ] Installed copies (`.deb`, `.app`) open the release page instead of replacing themselves.

## 3b. Windows saves and the flush
- [ ] *mkstudio --info FILE* (on Windows: `mkstudio-windows-x86_64.exe --info %TEMP%\info.txt`, then read the file) says
      `flush native (FlushFileBuffers)` on Windows, `native (fsync)` on Linux, `native (F_FULLFSYNC)` on macOS. If it says
      `PowerShell` or `sync`, the native library did not load: note why (a `noexec` temp folder? an antivirus?) and that *Save* then
      takes a second or two longer on Windows.
- [ ] On Windows, *Save* of a big change returns in about the time Linux takes (no PowerShell window flashes, no console window).
- [ ] A database in a folder with an accented letter and a space in its name (`C:\Users\José\My Data\x.mk`) can be opened,
      edited and saved, and the program can be updated while it sits in such a folder.

## 4. Using it
- [ ] Open a database; sort, filter, edit a cell, add a row, delete a row, **Save**, **Roll Back**. Close, reopen: as expected.
- [ ] Run a query that returns 500,000 rows; scroll fast; the window stays responsive. Cancel a long query: it stops.
- [ ] Open the same file in two copies of MK Studio: the second says who owns it and opens read-only.
- [ ] Kill MK Studio (task manager / `kill -9`) while a database is open, start it again and open the same file: *Database in use*
      does not appear (the dead process's lock is recognised). If it does appear, *Remove Lock...* clears it after a confirmation.
- [ ] **SQL**: run `SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 5` on the sample database; a `JOIN` with
      `departments`; a `WITH` query; an `UPDATE`, then *Roll Back* (nothing changed) and again then *Commit* (kept after reopening).
      A typo (`SELEC 1`) is underlined in the editor with a message. *Cancel* stops a long query (a cross join of the 500,000-row
      table with itself) within a second or two.
- [ ] Kill MK Studio from the task manager while editing, start it again: no complaint about the file, it opens, the last *saved* state is there.
- [ ] High-DPI screen / 150% scaling: text and grid are readable, nothing is cut off.
- [ ] Dark mode of the operating system: nothing unreadable.

## 5. Crash reports
- [ ] *Help > Open Crash Reports Folder* opens a folder. After forcing a crash (kill -9), the next start offers to report it, and the
      report text contains no SQL and no cell values (read it before sending).
