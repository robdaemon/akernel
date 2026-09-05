#!/usr/bin/env python3
#  befs_get.py — host-side BeFS file extractor (M93).
#
#  Reads a file (or directory tree) out of a BeFS partition image,
#  the host-side counterpart to mkbefs.py's staging. Needed once
#  Sys: moves off FAT32: the run recipe's ScreenMode env read and
#  the Prefs/Env carry-over across disk rebuilds can no longer use
#  mtools/mcopy.
#
#  usage:
#    befs_get.py IMAGE OFFSET_BYTES VOLUME_PATH
#        print the file's bytes to stdout
#    befs_get.py IMAGE OFFSET_BYTES VOLUME_PATH -o HOST_DIR
#        copy the file (or the whole directory tree, when
#        VOLUME_PATH names a directory) under HOST_DIR
#
#  VOLUME_PATH is '/' + components ("" = volume root). Directories
#  may carry a trailing '/'. The parser assumes the single-leaf
#  btree shape mkbefs.py writes (every dir < one node): the images
#  this tool reads are freshly built (run recipe, ENV carry-over),
#  never post-fuzz images. Loud error otherwise.

import os
import struct
import sys

BLK = 1024
AG_SHIFT = 13


def le16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def le32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def le64(b, o):
    return struct.unpack_from("<q", b, o)[0]


def run(b, o):
    ag, start, ln = struct.unpack_from("<iHH", b, o)
    return (ag << AG_SHIFT) + start, ln


def key_align(n):
    return (n + 7) & ~7


class Vol:
    def __init__(self, data):
        self.data = data          #  whole partition bytes
        sb = data[512:1024]
        if le32(sb, 32) != 0x42465331:   #  'BFS1'
            raise SystemExit("not a BeFS superblock")
        root_run = run(sb, 116)
        self.root = root_run[0]

    def block(self, n):
        return self.data[n * BLK:(n + 1) * BLK]

    def inode(self, b):
        node = self.block(b)
        if le32(node, 0) != 0x3BBE0AD9:  #  INODE_MAGIC1
            raise SystemExit("bad inode magic at block %d" % b)
        return node

    def stream_bytes(self, node):
        #  concat the data-stream runs (direct only)
        out = b""
        for j in range(12):
            ag, start, ln = struct.unpack_from("<iHH", node, 72 + 8 * j)
            if ln == 0:
                break
            base = (ag << AG_SHIFT) + start
            for k in range(ln):
                out += self.block(base + k)
        return out

    def dir_entry(self, dir_block, name):
        #  resolve one name in dir_block: single-leaf btree assumed
        node = self.inode(dir_block)
        stream = self.stream_bytes(node)
        if le32(stream, 0) != 0x69F6C2E8:  #  BTREE_MAGIC
            raise SystemExit("bad btree magic (multi-leaf dir?)")
        root_off = le64(stream, 16)
        leaf = stream[root_off:root_off + BLK]
        count = le16(leaf, 24)
        klen = le16(leaf, 26)
        keys = leaf[28:28 + klen]
        pos = key_align(28 + klen)
        lens = [le16(leaf, pos + 2 * j) for j in range(count)]
        pos += 2 * count
        koff = 0
        for j in range(count):
            key = keys[koff:koff + lens[j]]
            if key == name:
                return le64(leaf, pos + 8 * j)
            koff += lens[j]
        return None

    def file_bytes(self, file_block):
        node = self.inode(file_block)
        size = le64(node, 208)
        return self.stream_bytes(node)[:size]

    def resolve(self, path):
        #  returns (kind, block) where kind is 'f' or 'd'
        comps = [c for c in path.split("/") if c]
        b = self.root
        if not comps:
            return 'd', b
        for i, c in enumerate(comps):
            nb = self.dir_entry(b, c.encode("utf-8"))
            if nb is None:
                return None, None
            node = self.inode(nb)
            is_dir = (le32(node, 20) & 0o170000) == 0o040000
            if i == len(comps) - 1:
                return ('d' if is_dir else 'f'), nb
            b = nb
        return None, None

    def list_dir(self, dir_block):
        node = self.inode(dir_block)
        stream = self.stream_bytes(node)
        root_off = le64(stream, 16)
        leaf = stream[root_off:root_off + BLK]
        count = le16(leaf, 24)
        klen = le16(leaf, 26)
        keys = leaf[28:28 + klen]
        pos = key_align(28 + klen)
        lens = [le16(leaf, pos + 2 * j) for j in range(count)]
        pos += 2 * count
        koff = 0
        out = []
        for j in range(count):
            key = keys[koff:koff + lens[j]]
            koff += lens[j]
            if key in (b".", b".."):
                continue
            blk = le64(leaf, pos + 8 * j)
            nd = self.inode(blk)
            out.append((key, 'd' if (le32(nd, 20) & 0o170000)
                        == 0o040000 else 'f'))
        return out


def main():
    if len(sys.argv) not in (4, 6) or \
            (len(sys.argv) == 6 and sys.argv[4] != "-o"):
        raise SystemExit(
            "usage: befs_get.py IMAGE OFFSET_BYTES VOLUME_PATH\n"
            "       befs_get.py IMAGE OFFSET_BYTES VOLUME_PATH "
            "-o HOST_DIR")
    image, off, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with open(image, "rb") as f:
        f.seek(off)
        data = f.read()
    vol = Vol(data)
    kind, blk = vol.resolve(path)
    if kind is None:
        raise SystemExit("befs_get: %s not found" % path)
    if len(sys.argv) == 4:
        if kind != 'f':
            raise SystemExit("befs_get: %s is a directory" % path)
        sys.stdout.buffer.write(vol.file_bytes(blk))
        return
    host = sys.argv[5]
    if kind == 'f':
        os.makedirs(host, exist_ok=True)
        name = os.path.basename(path.rstrip("/"))
        with open(os.path.join(host, name), "wb") as f:
            f.write(vol.file_bytes(blk))
        return
    #  directory tree copy
    def copy_dir(dir_block, vol_path, host_path):
        os.makedirs(host_path, exist_ok=True)
        for name, k in vol.list_dir(dir_block):
            sub = os.path.join(host_path, name.decode("utf-8"))
            if k == 'd':
                copy_dir(vol.dir_entry(dir_block, name),
                         vol_path + "/" + name.decode("utf-8"), sub)
            else:
                nb = vol.dir_entry(dir_block, name)
                with open(sub, "wb") as f:
                    f.write(vol.file_bytes(nb))
    copy_dir(blk, path, host)


if __name__ == "__main__":
    main()
