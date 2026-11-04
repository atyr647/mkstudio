#!/usr/bin/env python3
"""Replay a dm-log-writes log onto a copy of the original image, cut the power at many points, and check what MK Studio makes of each state.

The log (kernel Documentation/admin-guide/device-mapper/log-writes.rst, format as in xfstests' src/log-writes/log-writes.h) holds every write
the file system made, in the order the device completed them, simulating the worst case for a power failure: writes that were not yet covered
by a flush are logged after it.  The state after entry e is therefore a state the disk can really be in.  Marks put into the log by the
workload (begin-k / ack-k) say which commits had begun and which had been acknowledged at that point.

  blockdev_crash.py --log LOG --base BASE.img --work DIR --expected FILE --kit TCLKIT --db crash.mk [--max-points N] [--fs ext4]
"""
import argparse, os, shutil, struct, subprocess, sys, re

MAGIC = 0x6a736677736872
F_FLUSH, F_FUA, F_DISCARD, F_MARK, F_META = 1, 2, 4, 8, 16

def read_log(path):
    f = open(path, 'rb')
    magic, version, nr, ss = struct.unpack('<QQQI', f.read(28))
    if magic != MAGIC or version != 1:
        sys.exit("not a dm-log-writes log (magic %x, version %d)" % (magic, version))
    entries, pos = [], ss
    for i in range(nr):
        f.seek(pos)
        hdr = f.read(ss)
        sector, nsec, flags, dlen = struct.unpack('<QQQQ', hdr[:32])
        mark = hdr[32:32 + dlen].decode('latin-1') if flags & F_MARK else None
        data = pos + ss
        size = 0 if (flags & F_DISCARD) else nsec * ss
        entries.append(dict(i=i, sector=sector, nsec=nsec, flags=flags, mark=mark, data=data, size=size))
        pos = data + size
    return f, ss, entries

def sh(*cmd, check=True):
    return subprocess.run(cmd, check=check, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--log', required=True); ap.add_argument('--base', required=True); ap.add_argument('--work', required=True)
    ap.add_argument('--expected', required=True); ap.add_argument('--kit', required=True); ap.add_argument('--db', default='crash.mk')
    ap.add_argument('--max-points', type=int, default=int(os.environ.get('MKS_BLOCKCRASH_POINTS', '400')))
    ap.add_argument('--fs', default='ext4')
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    logf, ss, entries = read_log(a.log)
    nwrites = sum(1 for e in entries if not (e['flags'] & F_MARK))
    print("log: %d entries (%d writes), sector size %d" % (len(entries), nwrites, ss))
    marks = {e['mark']: e['i'] for e in entries if e['mark'] is not None}
    print("marks:", ", ".join("%s@%d" % (m, i) for m, i in sorted(marks.items(), key=lambda x: x[1])))
    if 'start' not in marks or 'begin-1' not in marks:
        sys.exit("the log has no 'start' / 'begin-1' marks: the workload did not run under the device")
    commits = sorted(int(m[6:]) for m in marks if m.startswith('begin-'))
    start = marks['start']

    # the crash points: after entry e has been applied, for every e from the 'start' mark on; if that is too many, an even sample that keeps
    # every entry within 3 of a begin / ack mark
    cand = [e['i'] + 1 for e in entries if e['i'] >= start and e['nsec'] and not (e['flags'] & F_MARK)]   # (a flush or a mark changes nothing on the disk)
    keep = set(cand)
    if len(cand) > a.max_points:
        keep = set(cand[::max(1, len(cand) // a.max_points)])
        for m, i in marks.items():
            if m.startswith(('begin-', 'ack-')):
                for d in range(-3, 4):
                    if i + d + 1 in set(cand): keep.add(i + d + 1)
        keep.add(cand[-1])
    points = sorted(keep)
    print("crash points: %d of %d candidates" % (len(points), len(cand)))

    cur = os.path.join(a.work, 'cur.img'); snap = os.path.join(a.work, 'snap.img'); mnt = os.path.join(a.work, 'snapmnt')
    os.makedirs(mnt, exist_ok=True)
    shutil.copyfile(a.base, cur)
    img = open(cur, 'r+b')
    applied = 0
    def apply_upto(n):
        nonlocal applied
        while applied < n:
            e = entries[applied]
            if e['flags'] & F_DISCARD:
                if e['nsec']:
                    img.seek(e['sector'] * ss); img.write(b'\0' * (e['nsec'] * ss))
            elif e['nsec'] and not (e['flags'] & F_MARK):
                logf.seek(e['data']); data = logf.read(e['size'])
                img.seek(e['sector'] * ss); img.write(data)
            applied += 1
        img.flush(); os.fsync(img.fileno())

    results = {}
    bad = []
    ack = sorted((marks['ack-%d' % k], k) for k in commits if ('ack-%d' % k) in marks)
    beg = sorted((marks['begin-%d' % k], k) for k in commits)
    for n, p in enumerate(points):
        apply_upto(p)                      # entries 0..p-1 are on the image
        lo = max([k for i, k in ack if i < p], default=0)
        hi = max([k for i, k in beg if i < p], default=0)
        sh('cp', '--sparse=always', cur, snap)
        loop = sh('losetup', '-f', '--show', snap).stdout.strip()
        try:
            m = sh('mount', '-t', a.fs, loop, mnt, check=False)
            if m.returncode != 0:
                bad.append((p, lo, hi, 'the file system does not mount: ' + m.stdout.strip())); continue
            try:
                r = sh(a.kit, os.path.join(here, 'blockdev_check.tcl'), os.path.join(mnt, a.db), a.expected, str(lo), str(hi), check=False)
            finally:
                sh('umount', mnt, check=False)
            line = (r.stdout.strip().splitlines() or ['(no output)'])[-1]
            if r.returncode != 0 or not line.startswith('STATE'):
                bad.append((p, lo, hi, line + ('' if r.returncode == 0 else ' [exit %d] %s' % (r.returncode, r.stdout.strip()[-300:]))))
            else:
                results[line.split()[1]] = results.get(line.split()[1], 0) + 1
        finally:
            sh('losetup', '-d', loop, check=False)
            try: os.remove(snap)
            except OSError: pass
        if n % 50 == 0: print("  ... %d/%d points checked" % (n + 1, len(points)), flush=True)
    print("states found (state: number of crash points): " + ", ".join("%s: %d" % kv for kv in sorted(results.items(), key=lambda x: int(x[0]))))
    for p, lo, hi, why in bad[:20]:
        print("FAIL at entry %d (acknowledged %d, begun %d): %s" % (p, lo, hi, why))
    print("block-level crash test: %d crash points, %d failed" % (len(points), len(bad)))
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
