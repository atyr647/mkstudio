/*
 * mksync - make files durable.  A Tcl extension of one file and two commands, loaded by MK Studio when it is there; every caller
 * has a fallback that starts a program instead (coreutils `sync`, PowerShell), so a machine where it cannot be loaded loses speed,
 * not safety.
 *
 *   mksync::flush path ?path ...?   Ask the system to put each file (and, on Unix, each folder entry) on stable storage, and wait.
 *                                   A path that does not exist is skipped.  Returns the number of paths flushed.
 *                                   An error (with a message that names the path) when the system refuses or the disk reports a
 *                                   failure - the caller must not treat the data as safe then.
 *   mksync::method                  What this build does: fsync | F_FULLFSYNC | FlushFileBuffers
 *
 *   Linux, BSD   fsync(2) on the file and on its folder.
 *   macOS        fcntl(F_FULLFSYNC) - the only call that also empties the drive's own write cache (fsync does not on macOS) -
 *                falling back to fsync where the file system cannot do it.
 *   Windows      FlushFileBuffers on a handle opened with every sharing flag (a file another program has open is flushed, not
 *                refused).  NTFS journals folder entries, so folders are skipped; so is a read-only file (the call needs write access,
 *                and nothing of ours was written through it).
 *
 * Built against the Tcl stubs (Tcl_InitStubs "8.5"), so one binary loads into every Tcl 8.5 / 8.6 / 9.0 of its platform.
 * Licence: MIT, like the rest of MK Studio.
 */
#include <tcl.h>
#include <string.h>

#ifdef _WIN32
#  include <windows.h>
#  define METHOD "FlushFileBuffers"
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <sys/stat.h>
#  ifdef __APPLE__
#    define METHOD "F_FULLFSYNC"
#  else
#    define METHOD "fsync"
#  endif
#endif

#ifdef _WIN32
/* The wide-character form of a path, with a \\?\ prefix for long absolute paths (CreateFileW stops at 260 characters otherwise). */
static WCHAR *WidePath(const char *utf, Tcl_DString *ds)
{
    Tcl_DString tmp;
    WCHAR *w;
    size_t i, n;
    Tcl_DStringInit(&tmp);
    Tcl_UtfToUniCharDString(utf, -1, &tmp);
    w = (WCHAR *) Tcl_DStringValue(&tmp);
    n = wcslen(w);
    for (i = 0; i < n; i++) if (w[i] == L'/') w[i] = L'\\';
    Tcl_DStringInit(ds);
    if (n >= 248 && n > 2 && w[1] == L':' && w[2] == L'\\') {
        Tcl_DStringAppend(ds, "\\\0\\\0?\0\\\0", 8);                      /* \\?\ in UTF-16 */
    }
    Tcl_DStringAppend(ds, (char *) w, (int) ((n + 1) * sizeof(WCHAR)));
    Tcl_DStringFree(&tmp);
    return (WCHAR *) Tcl_DStringValue(ds);
}

/* 0 = flushed, 1 = not there (skipped), -1 = failed (message in *err) */
static int FlushOne(const char *path, Tcl_DString *err)
{
    Tcl_DString ds;
    HANDLE h;
    DWORD attr, code;
    WCHAR *w = WidePath(path, &ds);
    int rc = 0;
    attr = GetFileAttributesW(w);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        code = GetLastError();
        Tcl_DStringFree(&ds);
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) return 1;
        Tcl_DStringAppend(err, "cannot look at the file (Windows error ", -1);
        { char b[16]; sprintf(b, "%lu", (unsigned long) code); Tcl_DStringAppend(err, b, -1); }
        Tcl_DStringAppend(err, ")", -1);
        return -1;
    }
    if (attr & FILE_ATTRIBUTE_DIRECTORY) { Tcl_DStringFree(&ds); return 1; }   /* NTFS journals folder entries: skipped */
    h = CreateFileW(w, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    Tcl_DStringFree(&ds);
    if (h == INVALID_HANDLE_VALUE) {
        char b[16];
        code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) return 1;
        /* FlushFileBuffers needs write access; a read-only file cannot have been written through anything of ours: skipped */
        if (code == ERROR_ACCESS_DENIED && (attr & FILE_ATTRIBUTE_READONLY)) return 1;
        sprintf(b, "%lu", (unsigned long) code);
        Tcl_DStringAppend(err, "cannot open the file (Windows error ", -1);
        Tcl_DStringAppend(err, b, -1);
        Tcl_DStringAppend(err, ")", -1);
        return -1;
    }
    if (!FlushFileBuffers(h)) {
        char b[16];
        sprintf(b, "%lu", (unsigned long) GetLastError());
        Tcl_DStringAppend(err, "FlushFileBuffers failed (Windows error ", -1);
        Tcl_DStringAppend(err, b, -1);
        Tcl_DStringAppend(err, ")", -1);
        rc = -1;
    }
    CloseHandle(h);
    return rc;
}
#else
static int FlushOne(const char *path, Tcl_DString *err)
{
    struct stat st;
    int fd, rc = 0, isdir;
    Tcl_DString ds;
    const char *native;
    Tcl_DStringInit(&ds);
    native = Tcl_UtfToExternalDString(NULL, path, -1, &ds);
    if (stat(native, &st) != 0) {
        int e = errno;
        Tcl_DStringFree(&ds);
        if (e == ENOENT || e == ENOTDIR) return 1;
        Tcl_DStringAppend(err, strerror(e), -1);
        return -1;
    }
    isdir = S_ISDIR(st.st_mode);
    fd = open(native, O_RDONLY
#ifdef O_CLOEXEC
              | O_CLOEXEC
#endif
              );
    Tcl_DStringFree(&ds);
    if (fd < 0) {
        Tcl_DStringAppend(err, strerror(errno), -1);
        return -1;
    }
#ifdef __APPLE__
    if (fcntl(fd, F_FULLFSYNC) != 0) {
        /* a file system that cannot do it (network share, some FUSE): the plain call is the best there is */
        if (fsync(fd) != 0) { int e = errno; if (!(isdir && (e == EINVAL || e == ENOTSUP))) { Tcl_DStringAppend(err, strerror(e), -1); rc = -1; } }
    }
#else
    if (fsync(fd) != 0) {
        int e = errno;
        /* some file systems cannot flush a folder (EINVAL / ENOTSUP / EBADF on a read-only handle): not a failure of OUR data */
        if (!(isdir && (e == EINVAL || e == ENOTSUP || e == EBADF || e == EROFS))) { Tcl_DStringAppend(err, strerror(e), -1); rc = -1; }
    }
#endif
    close(fd);
    return rc;
}
#endif

static int FlushCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    int i, n = 0;
    (void) cd;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "path ?path ...?"); return TCL_ERROR; }
    for (i = 1; i < objc; i++) {
        Tcl_DString err;
        const char *path = Tcl_GetString(objv[i]);
        int rc;
        Tcl_DStringInit(&err);
        rc = FlushOne(path, &err);
        if (rc < 0) {
            Tcl_ResetResult(interp);
            Tcl_AppendResult(interp, "could not flush \"", path, "\": ", Tcl_DStringValue(&err), (char *) NULL);
            Tcl_SetErrorCode(interp, "MKSYNC", "FLUSH", path, (char *) NULL);
            Tcl_DStringFree(&err);
            return TCL_ERROR;
        }
        Tcl_DStringFree(&err);
        if (rc == 0) n++;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(n));
    return TCL_OK;
}

static int MethodCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    (void) cd;
    if (objc != 1) { Tcl_WrongNumArgs(interp, 1, objv, ""); return TCL_ERROR; }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(METHOD, -1));
    return TCL_OK;
}

#ifdef _WIN32
__declspec(dllexport)
#elif defined(__GNUC__)
__attribute__((visibility("default")))
#endif
int Mksync_Init(Tcl_Interp *interp)
{
    if (Tcl_InitStubs(interp, "8.5", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "mksync::flush", FlushCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "mksync::method", MethodCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "mksync", "1.0");
}
