#!/usr/bin/env python3
#  mkbefs.py — BeFS image generator (milestone 82b fixture tool).
#
#  Writes a small, valid, clean BeFS volume from scratch, following
#  Haiku's BFS implementation (src/add-ons/kernel/file_systems/bfs,
#  MIT) and Giampaolo's "Practical File System Design with the Be
#  File System". Layout for the default 8 MiB size (1024-byte
#  blocks, one allocation group):
#
#    block 0        boot sector (zeroed) + superblock at offset 512
#    block 1        block bitmap (bit i = block i, LE uint32 words)
#    blocks 2..513  log area (log_start == log_end: empty journal)
#    blocks 514..   inodes / btree streams / file data (bump alloc)
#
#  The fixture tree:
#
#    /README.TXT     small file, BEOS:TYPE + META:comment attrs
#    /EMPTY.TXT      zero-length file
#    /FRAGMENT.BIN   2560 bytes in two non-adjacent direct runs
#                    (block 543 deliberately left free between them)
#    /SUBDIR/HELLO.TXT
#
#  plus the standard mkbfs indices (name — populated; BEOS:APP_SIG,
#  last_modified, size — empty trees) and the root's be:volume_id
#  attribute. After writing, the image is parsed back and verified
#  (magics, bitmap/used_blocks agreement, tree walk, file bytes).

import struct
import sys

BLK = 1024
SHIFT = 10

#  Multichar constants are big-endian-ordered uint32s on disk via
#  the endian-neutral int32 fields (packed little-endian here, the
#  whole volume is little-endian: fs_byte_order = 'BIGE').
def ccode(s):
    return struct.unpack(">I", s.encode("ascii"))[0]

SB_MAGIC1 = ccode("BFS1")
SB_MAGIC2 = 0xDD121031
SB_MAGIC3 = 0x15B6830E
SB_FS_LENDIAN = ccode("BIGE")
SB_CLEAN = ccode("CLEN")
INODE_MAGIC1 = 0x3BBE0AD9
BTREE_MAGIC = 0x69F6C2E8
BTREE_NULL = 0xFFFFFFFFFFFFFFFF  # -1 as u64
BTREE_STRING = 0
BTREE_INT64 = 3

S_IFDIR = 0o040000
S_IFREG = 0o100000
S_STR_INDEX = 0o0100000000
S_LONG_LONG_INDEX = 0o0010000000
S_INDEX_DIR = 0o4000000000

INODE_IN_USE = 0x00000001

FILE_NAME_TYPE = ccode("CSTR")
FILE_NAME_NAME = 0x13
B_STRING_TYPE = ccode("CSTR")
B_MIME_STRING_TYPE = ccode("MIMS")
B_INT64_TYPE = ccode("LLNG")
B_UINT64_TYPE = ccode("ULLG")

FIXED_SEC = 1735689600  # 2025-01-01 00:00:00 UTC
INODE_TIME = FIXED_SEC << 16  # bfs_inode::ToInode format


def le16(x):
    return struct.pack("<H", x & 0xFFFF)


def le32(x):
    return struct.pack("<I", x & 0xFFFFFFFF)


def le64(x):
    return struct.pack("<Q", x & 0xFFFFFFFFFFFFFFFF)


def brun(ag, start, length):
    #  block_run: int32 allocation_group, uint16 start, uint16 length
    return struct.pack("<iHH", ag, start, length)


def key_align(n):
    return (n + 7) & ~7


AG_SHIFT = 13
BLOCKS_PER_AG = 1       #  bitmap blocks per AG (Haiku: blocks_per_ag
                        #  counts BITMAP blocks; data span is
                        #  1 << ag_shift blocks)
LOG_LEN = 512           #  numBlocks <= 20480 -> logSize 512
RESERVED = 2 + LOG_LEN  #  superblock + bitmap + log


class Image:
    def __init__(self, num_blocks):
        self.num_blocks = num_blocks
        self.buf = bytearray(num_blocks * BLK)
        self.bitmap = bytearray(BLK)  #  one bitmap block covers all
        self.next_free = RESERVED
        self.used = RESERVED

    def alloc(self, count=1):
        start = self.next_free
        self.next_free += count
        if self.next_free > self.num_blocks:
            raise SystemExit("image too small")
        self.used += count
        return start

    def mark(self, block, count=1):
        for b in range(block, block + count):
            self.bitmap[b >> 3] |= 1 << (b & 7)

    def put(self, block, data):
        self.buf[block * BLK:(block + 1) * BLK] = data

    def finish_bitmap(self):
        self.mark(0, RESERVED)
        #  everything between RESERVED and next_free except the
        #  deliberate hole(s) was allocated via alloc(); the hole is
        #  handled by FRAGMENT layout below (mark only real use)
        self.put(1, bytes(self.bitmap))


def btree_node(entries):
    #  Single leaf node (all our trees fit). entries: sorted list of
    #  (key_bytes, value_i64). Node layout (bplustree_node): links,
    #  counts, keys right after the 28-byte header, key lengths at
    #  key_align(header + all_key_length), values after the lengths.
    n = len(entries)
    keys = b"".join(k for k, _ in entries)
    node = bytearray(1024)
    node[0:28] = (le64(BTREE_NULL) + le64(BTREE_NULL) + le64(BTREE_NULL)
                  + le16(n) + le16(len(keys)))
    node[28:28 + len(keys)] = keys
    pos = key_align(28 + len(keys))
    for k, _ in entries:
        node[pos:pos + 2] = le16(len(k))
        pos += 2
    for _, v in entries:
        node[pos:pos + 8] = le64(v)
        pos += 8
    if pos > 1024:
        raise SystemExit("btree node overflow")
    return bytes(node)


def btree_stream(data_type, entries):
    #  bplustree_header at stream offset 0 (one node_size block),
    #  root node at offset node_size.
    hdr = (le32(BTREE_MAGIC) + le32(1024) + le32(1) + le32(data_type)
           + le64(1024) + le64(BTREE_NULL) + le64(2048))
    hdr = hdr + bytes(1024 - len(hdr))
    return hdr + btree_node(entries)


def data_stream(runs, size):
    #  runs: list of (start_block, length); fills direct[] then
    #  max_direct_range; indirect/double-indirect stay zero.
    direct = [brun(0, 0, 0)] * 12
    total = 0
    for i, (start, length) in enumerate(runs):
        direct[i] = brun(0, start, length)
        total += length
    return (b"".join(direct) + le64(total << SHIFT)
            + brun(0, 0, 0) + le64(0) + brun(0, 0, 0) + le64(0)
            + le64(size))


def small_data(attrs):
    #  attrs: list of (type_u32, name_bytes, data_bytes); entry =
    #  header + name + NUL + 2 pad + data + NUL (Inode._AddSmallData).
    out = bytearray()
    for atype, name, data in attrs:
        out += le32(atype) + le16(len(name)) + le16(len(data))
        out += name + b"\0\0\0" + data + b"\0"
    #  terminating zeroed header (name_size == 0 ends the list)
    out += bytes(8)
    return bytes(out)


def inode(block, mode, parent_block, attrs, runs, size, type_code=0):
    node = bytearray(BLK)
    node[0:4] = le32(INODE_MAGIC1)
    node[4:12] = brun(0, block, 1)               #  inode_num
    node[12:16] = le32(0)                        #  uid
    node[16:20] = le32(0)                        #  gid
    node[20:24] = le32(mode)
    node[24:28] = le32(INODE_IN_USE)
    node[28:36] = le64(INODE_TIME)               #  create_time
    node[36:44] = le64(INODE_TIME)               #  last_modified_time
    node[44:52] = brun(0, parent_block, 1)       #  parent
    node[52:60] = brun(0, 0, 0)                  #  attributes (none)
    node[60:64] = le32(type_code)
    node[64:68] = le32(BLK)                      #  inode_size
    node[68:72] = le32(0)                        #  etc
    node[72:216] = data_stream(runs, size)
    node[216:224] = le64(INODE_TIME)             #  status_change_time
    sd = small_data(attrs)
    node[232:232 + len(sd)] = sd
    return bytes(node)


def dir_inode(block, parent_block, stream_start, mode):
    return inode(block, mode, parent_block, [],
                 [(stream_start, 2)], 2 * BLK)


def build(path, mib):
    global AG_SHIFT
    num_blocks = mib * 1024 * 1024 // BLK
    img = Image(num_blocks)

    #  --- inodes and streams (bump allocation from block 514) ---
    root_i = img.alloc()
    root_s = img.alloc(2)
    idx_i = img.alloc()
    idx_s = img.alloc(2)

    ix_name_i = img.alloc()
    ix_name_s = img.alloc(2)
    ix_appsig_i = img.alloc()
    ix_appsig_s = img.alloc(2)
    ix_mtime_i = img.alloc()
    ix_mtime_s = img.alloc(2)
    ix_size_i = img.alloc()
    ix_size_s = img.alloc(2)

    readme_i = img.alloc()
    readme_d = img.alloc()
    empty_i = img.alloc()
    fragment_i = img.alloc()
    fragment_r1 = img.alloc(2)
    img.next_free += 1                 #  the deliberate free hole
    fragment_r2 = img.alloc()
    subdir_i = img.alloc()
    subdir_s = img.alloc(2)
    hello_i = img.alloc()
    hello_d = img.alloc()

    readme_body = b"Hello from the akernel BeFS volume.\n"
    hello_body = b"Subdir hello from BeFS!\n"
    fragment_body = bytes((i * 5 + 1) & 0xFF for i in range(2560))

    #  --- btree streams ---
    root_entries = [(b".", root_i), (b"..", root_i),
                    (b"EMPTY.TXT", empty_i), (b"FRAGMENT.BIN", fragment_i),
                    (b"README.TXT", readme_i), (b"SUBDIR", subdir_i)]
    subdir_entries = [(b".", subdir_i), (b"..", root_i),
                      (b"HELLO.TXT", hello_i)]
    idx_entries = [(b"BEOS:APP_SIG", ix_appsig_i),
                   (b"last_modified", ix_mtime_i),
                   (b"name", ix_name_i), (b"size", ix_size_i)]
    name_index = [(b"EMPTY.TXT", empty_i), (b"FRAGMENT.BIN", fragment_i),
                  (b"HELLO.TXT", hello_i), (b"README.TXT", readme_i),
                  (b"SUBDIR", subdir_i)]

    root = btree_stream(BTREE_STRING, root_entries)
    img.put(root_s, root[:BLK])
    img.put(root_s + 1, root[BLK:])
    #  (stream spans two blocks: header in first, node in second)
    sub = btree_stream(BTREE_STRING, subdir_entries)
    img.put(subdir_s, sub[:BLK])
    img.put(subdir_s + 1, sub[BLK:])
    idx = btree_stream(BTREE_STRING, idx_entries)
    img.put(idx_s, idx[:BLK])
    img.put(idx_s + 1, idx[BLK:])
    ni = btree_stream(BTREE_STRING, name_index)
    img.put(ix_name_s, ni[:BLK])
    img.put(ix_name_s + 1, ni[BLK:])
    for blk, dtype in ((ix_appsig_s, BTREE_STRING),
                       (ix_mtime_s, BTREE_INT64), (ix_size_s, BTREE_INT64)):
        st = btree_stream(dtype, [])
        img.put(blk, st[:BLK])
        img.put(blk + 1, st[BLK:])

    #  --- file data ---
    img.put(readme_d, readme_body + bytes(BLK - len(readme_body)))
    img.put(hello_d, hello_body + bytes(BLK - len(hello_body)))
    img.put(fragment_r1, fragment_body[:BLK])
    img.put(fragment_r1 + 1, fragment_body[BLK:2 * BLK])
    img.put(fragment_r2, fragment_body[2 * BLK:] + bytes(BLK - 512))

    #  --- inodes ---
    dmode = S_IFDIR | S_STR_INDEX | 0o755
    img.put(root_i, inode(
        root_i, dmode, root_i,
        [(B_UINT64_TYPE, b"be:volume_id", le64(0x4D3832_4245_4653))],
        [(root_s, 2)], 2 * BLK))
    img.put(idx_i, inode(idx_i, S_INDEX_DIR | S_STR_INDEX | S_IFDIR | 0o700,
                         idx_i, [], [(idx_s, 2)], 2 * BLK))
    img.put(ix_name_i, inode(ix_name_i,
                             S_INDEX_DIR | S_IFDIR | S_STR_INDEX,
                             idx_i, [], [(ix_name_s, 2)], 2 * BLK,
                             type_code=B_STRING_TYPE))
    img.put(ix_appsig_i, inode(ix_appsig_i,
                               S_INDEX_DIR | S_IFDIR | S_STR_INDEX,
                               idx_i, [], [(ix_appsig_s, 2)], 2 * BLK,
                               type_code=B_STRING_TYPE))
    img.put(ix_mtime_i, inode(ix_mtime_i,
                              S_INDEX_DIR | S_IFDIR | S_LONG_LONG_INDEX,
                              idx_i, [], [(ix_mtime_s, 2)], 2 * BLK,
                              type_code=B_INT64_TYPE))
    img.put(ix_size_i, inode(ix_size_i,
                             S_INDEX_DIR | S_IFDIR | S_LONG_LONG_INDEX,
                             idx_i, [], [(ix_size_s, 2)], 2 * BLK,
                             type_code=B_INT64_TYPE))

    img.put(readme_i, inode(
        readme_i, S_IFREG | 0o644, root_i,
        [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), b"README.TXT"),
         (B_MIME_STRING_TYPE, b"BEOS:TYPE", b"text/plain"),
         (B_STRING_TYPE, b"META:comment", b"fixture comment")],
        [(readme_d, 1)], len(readme_body)))
    img.put(empty_i, inode(
        empty_i, S_IFREG | 0o644, root_i,
        [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), b"EMPTY.TXT")],
        [], 0))
    img.put(fragment_i, inode(
        fragment_i, S_IFREG | 0o644, root_i,
        [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), b"FRAGMENT.BIN")],
        [(fragment_r1, 2), (fragment_r2, 1)], len(fragment_body)))
    img.put(subdir_i, inode(
        subdir_i, dmode, root_i,
        [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), b"SUBDIR")],
        [(subdir_s, 2)], 2 * BLK))
    img.put(hello_i, inode(
        hello_i, S_IFREG | 0o644, subdir_i,
        [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), b"HELLO.TXT")],
        [(hello_d, 1)], len(hello_body)))

    #  --- bitmap + superblock ---
    for b in range(RESERVED, img.next_free):
        if b != fragment_r1 + 2:     #  the deliberate hole
            img.mark(b)
    img.finish_bitmap()

    sb = bytearray(512)
    sb[0:32] = b"Befs" + bytes(28)
    sb[32:36] = le32(SB_MAGIC1)
    sb[36:40] = le32(SB_FS_LENDIAN)
    sb[40:44] = le32(BLK)
    sb[44:48] = le32(SHIFT)
    sb[48:56] = le64(num_blocks)
    sb[56:64] = le64(img.used)
    sb[64:68] = le32(BLK)                    #  inode_size
    sb[68:72] = le32(SB_MAGIC2)
    sb[72:76] = le32(BLOCKS_PER_AG)
    sb[76:80] = le32(AG_SHIFT)
    sb[80:84] = le32(1)                      #  num_ags
    sb[84:88] = le32(SB_CLEAN)               #  flags
    sb[88:96] = brun(0, 2, LOG_LEN)          #  log_blocks
    sb[96:104] = le64(2)                     #  log_start
    sb[104:112] = le64(2)                    #  log_end
    sb[112:116] = le32(SB_MAGIC3)
    sb[116:124] = brun(0, root_i, 1)         #  root_dir
    sb[124:132] = brun(0, idx_i, 1)          #  indices
    img.buf[512:1024] = sb

    with open(path, "wb") as f:
        f.write(img.buf)

    verify(bytes(img.buf), num_blocks, img.used, root_i, readme_d,
           fragment_r1, fragment_r2, fragment_body, readme_body)
    print("mkbefs: %s: %d MiB, %d blocks, %d used, root inode block %d"
          % (path, mib, num_blocks, img.used, root_i))


def verify(buf, num_blocks, used_blocks, root_i, readme_d,
           fragment_r1, fragment_r2, fragment_body, readme_body):
    #  Read-back self-check: superblock magics, bitmap vs used_blocks,
    #  root inode + btree walk, fixture file bytes.
    import struct as st
    sb = buf[512:1024]
    assert st.unpack("<I", sb[32:36])[0] == SB_MAGIC1, "sb magic1"
    assert st.unpack("<I", sb[36:40])[0] == SB_FS_LENDIAN, "sb endian"
    assert st.unpack("<I", sb[68:72])[0] == SB_MAGIC2, "sb magic2"
    assert st.unpack("<I", sb[112:116])[0] == SB_MAGIC3, "sb magic3"
    assert st.unpack("<Q", sb[48:56])[0] == num_blocks, "num_blocks"
    assert st.unpack("<q", sb[56:64])[0] == used_blocks, "used_blocks"
    bm = buf[BLK:2 * BLK]
    popcount = sum(bin(b).count("1") for b in bm)
    assert popcount == used_blocks, "bitmap popcount %d != used %d" % (
        popcount, used_blocks)

    node = buf[root_i * BLK:(root_i + 1) * BLK]
    assert st.unpack("<I", node[0:4])[0] == INODE_MAGIC1, "inode magic"
    assert st.unpack("<iHH", node[4:12]) == (0, root_i, 1), "inode_num"
    size = st.unpack("<q", node[208:216])[0]
    assert size == 2 * BLK, "root stream size"

    #  root dir btree: header block then leaf node
    run0 = st.unpack("<iHH", node[72:80])
    hdr = buf[run0[1] * BLK:(run0[1] + 1) * BLK]
    assert st.unpack("<I", hdr[0:4])[0] == BTREE_MAGIC, "btree magic"
    assert st.unpack("<q", hdr[16:24])[0] == 1024, "root node ptr"
    leaf = buf[(run0[1] + 1) * BLK:(run0[1] + 2) * BLK]
    count = st.unpack("<H", leaf[24:26])[0]
    klen = st.unpack("<H", leaf[26:28])[0]
    keys = leaf[28:28 + klen]
    for want in (b".", b"..", b"EMPTY.TXT", b"FRAGMENT.BIN",
                 b"README.TXT", b"SUBDIR"):
        assert want in keys, "root dir missing %s" % want
    assert count == 6, "root entry count"

    assert buf[readme_d * BLK:readme_d * BLK + len(readme_body)] \
        == readme_body, "README body"
    frag = (buf[fragment_r1 * BLK:(fragment_r1 + 2) * BLK]
            + buf[fragment_r2 * BLK:fragment_r2 * BLK + 512])
    assert frag == fragment_body, "FRAGMENT body"


def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        raise SystemExit("usage: mkbefs.py OUTPUT [SIZE_MIB]")
    mib = int(sys.argv[2]) if len(sys.argv) == 3 else 8
    build(sys.argv[1], mib)


if __name__ == "__main__":
    main()
