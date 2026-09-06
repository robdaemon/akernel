#!/usr/bin/env python3
#  befs_dump.py — read-only BeFS lister (milestone 82b ground truth
#  and M82c reference). Parses a BeFS image (or a partition region
#  carved out of disk.img) and prints the superblock, the directory
#  tree with per-inode small_data attributes, and the indices.
#
#  usage: befs_dump.py IMAGE [OFFSET_BYTES]

import struct
import sys

BTREE_MAGIC = 0x69F6C2E8
BTREE_NULL = 0xFFFFFFFFFFFFFFFF
INODE_MAGIC1 = 0x3BBE0AD9
FILE_NAME_NAME = 0x13

S_IFMT = 0o170000
S_IFDIR = 0o040000
S_INDEX_DIR = 0o4000000000


def le16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def le32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def le64(b, o):
    return struct.unpack_from("<q", b, o)[0]


def ule32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def run(b, o):
    ag, start, length = struct.unpack_from("<iHH", b, o)
    return ((ag << 13) + start, length)


class Befs:
    def __init__(self, buf):
        self.buf = buf
        sb = buf[512:1024]
        if ule32(sb, 32) != 0x42465331:
            raise SystemExit("not BeFS (bad magic1)")
        self.name = sb[0:32].split(b"\0")[0].decode()
        self.block_size = ule32(sb, 40)
        self.block_shift = ule32(sb, 44)
        self.num_blocks = le64(sb, 48)
        self.used_blocks = le64(sb, 56)
        self.inode_size = le32(sb, 64)
        self.num_ags = le32(sb, 80)
        self.ag_shift = ule32(sb, 76)
        self.log_blocks = run(sb, 88)
        self.log_start = le64(sb, 96)
        self.log_end = le64(sb, 104)
        self.root_dir = run(sb, 116)
        self.indices = run(sb, 124)

    def block(self, n):
        s = n * self.block_size
        return self.buf[s:s + self.block_size]

    def inode(self, block):
        node = self.block(block)
        if ule32(node, 0) != INODE_MAGIC1:
            raise SystemExit("bad inode magic at block %d" % block)
        return node

    def attrs(self, node):
        #  small_data walk: [type u32][name_size u16][data_size u16]
        #  [name][NUL+2 pad][data][NUL]
        out = []
        pos = 232
        while pos + 8 <= self.inode_size:
            atype = ule32(node, pos)
            nsz = le16(node, pos + 4)
            dsz = le16(node, pos + 6)
            if nsz == 0:
                break
            name = node[pos + 8:pos + 8 + nsz]
            data = node[pos + 8 + nsz + 3:pos + 8 + nsz + 3 + dsz]
            out.append((atype, name, data))
            pos += 8 + nsz + 3 + dsz + 1
        return out

    def stream_runs(self, node):
        runs = []
        for i in range(12):
            start, length = run(node, 72 + i * 8)
            if length:
                runs.append((start, length))
        size = le64(node, 208)
        return runs, size

    def read_stream(self, node):
        runs, size = self.stream_runs(node)
        out = bytearray()
        for start, length in runs:
            s = start * self.block_size
            out += self.buf[s:s + length * self.block_size]
        return bytes(out[:size])

    def btree_node(self, stream, node_size, off):
        #  Parse one node: (left, right, overflow, [(key, val), ...]).
        node = stream[off:off + node_size]
        left, right, ovfl = (le64(node, 0), le64(node, 8),
                             le64(node, 16))
        count = le16(node, 24)
        klen = le16(node, 26)
        keys = node[28:28 + klen]
        pos = ((28 + klen) + 7) & ~7
        lens = [le16(node, pos + 2 * i) for i in range(count)]
        pos += 2 * count
        entries = []
        koff = 0
        for i in range(count):
            key = keys[koff:koff + lens[i]]
            val = le64(node, pos + 8 * i)
            entries.append((key, val))
            koff += lens[i]
        return left, right, ovfl, entries

    def btree_entries(self, stream):
        #  Header at offset 0; internal entry (k, v) means child v
        #  covers keys in [prev_k, k), the overflow link is the
        #  rightmost child. Descend first children to the leftmost
        #  leaf, then walk the leaf chain via right links.
        if ule32(stream, 0) != BTREE_MAGIC:
            raise SystemExit("bad btree magic")
        node_size = ule32(stream, 4)
        depth = ule32(stream, 8)
        off = le64(stream, 16)
        for _ in range(depth):
            left, right, ovfl, entries = self.btree_node(
                stream, node_size, off)
            if ovfl == -1:
                break  # leaf
            off = entries[0][1]  # first child
        entries = []
        seen = set()
        while off != -1:
            if off in seen or len(seen) > 4096:
                raise SystemExit("btree leaf chain loops")
            seen.add(off)
            left, right, ovfl, ents = self.btree_node(
                stream, node_size, off)
            entries.extend(ents)
            off = right
        return entries

    def dump_dir(self, ino, path, depth):
        node = self.inode(ino)
        entries = self.btree_entries(self.read_stream(node))
        for key, val in entries:
            name = key.decode()
            if name in (".", ".."):
                continue
            child = self.inode(val)
            mode = le32(child, 20)
            is_dir = (mode & S_IFMT) == S_IFDIR
            _, size = self.stream_runs(child)
            line = "  " * depth + ("%s/" % name if is_dir else
                                   "%s  (%d bytes)" % (name, size))
            print(line)
            for atype, aname, adata in self.attrs(child):
                if aname == bytes([FILE_NAME_NAME]):
                    continue
                t = struct.pack(">I", atype).decode("ascii",
                                                    errors="replace")
                try:
                    shown = adata.decode()
                except UnicodeDecodeError:
                    shown = adata.hex()
                print("  " * (depth + 1) + "@%s (%s): %s"
                      % (aname.decode(), t, shown))
            if is_dir and not (mode & S_INDEX_DIR):
                self.dump_dir(val, path + name + "/", depth + 1)

    def dump(self):
        print("volume %r: %d blocks x %d bytes, %d used, %d AG(s)"
              % (self.name, self.num_blocks, self.block_size,
                 self.used_blocks, self.num_ags))
        print("log: blocks %d..%d, start %d end %d (%s)"
              % (self.log_blocks[0],
                 self.log_blocks[0] + self.log_blocks[1] - 1,
                 self.log_start, self.log_end,
                 "empty" if self.log_start == self.log_end else "DIRTY"))
        print("root dir inode block %d, indices inode block %d"
              % (self.root_dir[0], self.indices[0]))
        print("tree:")
        self.dump_dir(self.root_dir[0], "/", 1)
        print("indices:")
        idx_node = self.inode(self.indices[0])
        for key, val in self.btree_entries(self.read_stream(idx_node)):
            inode = self.inode(val)
            entries = self.btree_entries(self.read_stream(inode))
            print("  %s: %d entries" % (key.decode(), len(entries)))
            for k, v in entries:
                try:
                    shown = k.decode()
                except UnicodeDecodeError:
                    shown = k.hex()
                print("    %s -> inode block %d" % (shown, v))


def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        raise SystemExit("usage: befs_dump.py IMAGE [OFFSET_BYTES]")
    with open(sys.argv[1], "rb") as f:
        buf = f.read()
    if len(sys.argv) == 3:
        off = int(sys.argv[2])
        buf = buf[off:]
    Befs(buf).dump()


if __name__ == "__main__":
    main()
