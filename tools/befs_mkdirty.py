#!/usr/bin/env python3
#  befs_mkdirty.py — test fixture for the M82e journal replay.
#
#  Injects a pending (crashed-mid-commit) journal transaction into
#  a BeFS partition image: one run_array block + one content block
#  whose destination is README.TXT's data block, with the ORIGINAL
#  content (so replay is a semantic no-op). The superblock is left
#  DIRT with log_start != log_end, exactly what a crash between
#  the log write and the clean checkpoint leaves behind.
#
#  The guest's Bfs_Engine must replay it at mount (printing
#  "bfs: journal replayed") and re-checkpoint; every fuzz check
#  then sees unchanged fixture contents.
#
#  usage: befs_mkdirty.py IMAGE OFFSET_BYTES

import struct
import sys

BLK = 1024


def le16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def le32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def le64(b, o):
    return struct.unpack_from("<q", b, o)[0]


def brun(b, o):
    return struct.unpack_from("<iHH", b, o)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: befs_mkdirty.py IMAGE OFFSET_BYTES")
    with open(sys.argv[1], "r+b") as f:
        f.seek(int(sys.argv[2]))
        buf = bytearray(f.read(8 * 1024 * 1024))

    sb = buf[512:1024]
    if le32(sb, 32) != 0x42465331:  #  'BFS1'
        raise SystemExit("not a BeFS superblock")
    log_ag, log_start_blk, log_len = brun(sb, 88)
    log_pos_start = le64(sb, 96)
    log_pos_end = le64(sb, 104)
    if log_pos_start != log_pos_end:
        raise SystemExit("log already dirty — replay it first")
    root = brun(sb, 116)[1]

    #  Root dir btree -> README.TXT inode -> first data run.
    rnode = buf[root * BLK:(root + 1) * BLK]
    srun = brun(rnode, 72)
    leaf = buf[(srun[1] + 1) * BLK:(srun[1] + 2) * BLK]
    count = le16(leaf, 24)
    klen = le16(leaf, 26)
    keys = leaf[28:28 + klen]
    pos = (28 + klen + 7) & ~7
    lens = [le16(leaf, pos + 2 * i) for i in range(count)]
    pos += 2 * count
    readme_i = None
    koff = 0
    for i in range(count):
        if keys[koff:koff + lens[i]] == b"README.TXT":
            readme_i = le64(leaf, pos + 8 * i)
        koff += lens[i]
    if readme_i is None:
        raise SystemExit("README.TXT not found")
    inode = buf[readme_i * BLK:(readme_i + 1) * BLK]
    data_blk = brun(inode, 72)[1]
    content = bytes(buf[data_blk * BLK:(data_blk + 1) * BLK])

    #  Transaction at log position log_pos_end: run_array + content.
    pos = log_pos_end % log_len
    arr = bytearray(BLK)
    struct.pack_into("<ii", arr, 0, 1, 127)      #  count, max_runs
    struct.pack_into("<iHH", arr, 8, 0, data_blk, 1)
    base = (log_start_blk + pos) * BLK
    buf[base:base + BLK] = arr
    buf[base + BLK:base + 2 * BLK] = content

    #  Superblock: DIRT, log_end past the transaction.
    struct.pack_into("<I", buf, 512 + 84, 0x44495254)   #  'DIRT'
    struct.pack_into("<q", buf, 512 + 96, log_pos_start)
    struct.pack_into("<q", buf, 512 + 104, log_pos_end + 2)

    with open(sys.argv[1], "r+b") as f:
        f.seek(int(sys.argv[2]))
        f.write(buf)
    print("befs_mkdirty: journaled block %d at log %d..%d (DIRT)"
          % (data_blk, log_pos_end, log_pos_end + 2))


if __name__ == "__main__":
    main()
