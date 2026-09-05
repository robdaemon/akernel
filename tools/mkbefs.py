#!/usr/bin/env python3
#  mkbefs.py — BeFS image generator (milestone 82b fixture tool).
#
#  Writes a small, valid, clean BeFS volume from scratch, following
#  Haiku's BFS implementation (src/add-ons/kernel/file_systems/bfs,
#  MIT) and Giampaolo's "Practical File System Design with the Be
#  File System". Layout (1024-byte blocks, one bitmap block per
#  8192-block allocation group, ag_shift 13):
#
#    block 0         boot sector (zeroed) + superblock at offset 512
#    blocks 1..num_ags
#                    block bitmaps: block 1 + g is AG g's bitmap,
#                    bit i = global block g * 8192 + i (deviation
#                    from Haiku, which puts each AG's bitmap at its
#                    own group start — see bfs_engine.ads; the
#                    engine indexes the bitmap block by block/8192)
#    blocks 1+num_ags .. num_ags+512
#                    log area (log_start == log_end: empty journal)
#    blocks num_ags+513..
#                    inodes / btree streams / file data (bump alloc)
#
#  For the default 8 MiB size num_ags = 1 and this is exactly the
#  original single-bitmap layout (bitmap block 1, log 2..513,
#  data from 514).
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

import os
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


def rblk(block, length=1):
    #  block_run for a global block number (M93 multi-group): the
    #  group is block >> ag_shift, the start is block & (group-1).
    #  Identical to brun(0, block, length) for blocks below 8192.
    return brun(block >> AG_SHIFT, block & (GROUPSIZE - 1), length)


def key_align(n):
    return (n + 7) & ~7


AG_SHIFT = 13
GROUPSIZE = 1 << AG_SHIFT   #  8192 blocks per allocation group
LOG_LEN = 512               #  numBlocks <= 20480 -> logSize 512


class Image:
    def __init__(self, num_blocks):
        self.num_blocks = num_blocks
        self.num_ags = (num_blocks + GROUPSIZE - 1) // GROUPSIZE
        #  bitmap blocks 1..num_ags, log right after, data beyond
        self.reserved = 1 + self.num_ags + LOG_LEN
        self.buf = bytearray(num_blocks * BLK)
        self.bitmap = bytearray(self.num_ags * BLK)  #  one per AG
        self.next_free = self.reserved
        self.used = self.reserved

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
        self.mark(0, self.reserved)
        #  everything between reserved and next_free except the
        #  deliberate hole(s) was allocated via alloc(); the hole is
        #  handled by FRAGMENT layout below (mark only real use).
        #  Split the combined bitmap into per-AG blocks at 1..num_ags.
        for g in range(self.num_ags):
            lo = g * BLK
            self.put(1 + g, bytes(self.bitmap[lo:lo + BLK]))


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
    #  Start blocks are GLOBAL block numbers (M93): each run is
    #  split into (ag, group-relative start) by rblk.
    direct = [brun(0, 0, 0)] * 12
    total = 0
    for i, (start, length) in enumerate(runs):
        direct[i] = rblk(start, length)
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
    node[4:12] = rblk(block, 1)                  #  inode_num
    node[12:16] = le32(0)                        #  uid
    node[16:20] = le32(0)                        #  gid
    node[20:24] = le32(mode)
    node[24:28] = le32(INODE_IN_USE)
    node[28:36] = le64(INODE_TIME)               #  create_time
    node[36:44] = le64(INODE_TIME)               #  last_modified_time
    node[44:52] = rblk(parent_block, 1)          #  parent
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
    for b in range(img.reserved, img.next_free):
        if b != fragment_r1 + 2:     #  the deliberate hole
            img.mark(b)
    img.finish_bitmap()

    img.buf[512:1024] = superblock(img, num_blocks, root_i, idx_i)

    with open(path, "wb") as f:
        f.write(img.buf)

    verify(bytes(img.buf), num_blocks, img.used, root_i, readme_d,
           fragment_r1, fragment_r2, fragment_body, readme_body)
    print("mkbefs: %s: %d MiB, %d blocks, %d used, root inode block %d"
          % (path, mib, num_blocks, img.used, root_i))


def superblock(img, num_blocks, root_i, idx_i):
    #  Shared 512-byte superblock (block 0, offset 512).
    sb = bytearray(512)
    sb[0:32] = b"Befs" + bytes(28)
    sb[32:36] = le32(SB_MAGIC1)
    sb[36:40] = le32(SB_FS_LENDIAN)
    sb[40:44] = le32(BLK)
    sb[44:48] = le32(SHIFT)
    sb[48:56] = le64(num_blocks)
    sb[56:64] = le64(img.used)
    sb[64:68] = le32(BLK)                      #  inode_size
    sb[68:72] = le32(SB_MAGIC2)
    sb[72:76] = le32(1)                        #  blocks_per_ag
    sb[76:80] = le32(AG_SHIFT)
    sb[80:84] = le32(img.num_ags)              #  num_ags
    sb[84:88] = le32(SB_CLEAN)                 #  flags
    sb[88:96] = rblk(1 + img.num_ags, LOG_LEN)  #  log_blocks
    sb[96:104] = le64(2)                       #  log_start
    sb[104:112] = le64(2)                      #  log_end
    sb[112:116] = le32(SB_MAGIC3)
    sb[116:124] = rblk(root_i, 1)              #  root_dir
    sb[124:132] = rblk(idx_i, 1)               #  indices
    return bytes(sb)


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
    num_ags = st.unpack("<I", sb[80:84])[0]
    #  popcount across every AG bitmap block (1..num_ags)
    popcount = sum(bin(b).count("1")
                   for blk in range(num_ags)
                   for b in buf[(1 + blk) * BLK:(2 + blk) * BLK])
    assert popcount == used_blocks, "bitmap popcount %d != used %d" % (
        popcount, used_blocks)

    node = buf[root_i * BLK:(root_i + 1) * BLK]
    assert st.unpack("<I", node[0:4])[0] == INODE_MAGIC1, "inode magic"
    ino_ag, ino_start, ino_len = st.unpack("<iHH", node[4:12])
    assert (ino_ag << AG_SHIFT) + ino_start == root_i \
        and ino_len == 1, "inode_num"
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


def parse_manifest(manifest_path):
    #  Attr manifest: TAB-separated lines
    #    VOLUME_PATH \t TYPE4CC \t ATTR_NAME \t VALUE
    #  (VALUE is the raw attr data; the type fourcc is a literal
    #  like CSTR/MIMS/LLNG). One entry per (path, attr) pair; a
    #  path may repeat. The name pseudo-attribute is added
    #  automatically and must NOT be listed here.
    attrs = {}
    with open(manifest_path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise SystemExit(
                    "manifest %s:%d: want PATH<TAB>TYPE<TAB>NAME<TAB>VALUE"
                    % (manifest_path, lineno))
            vpath, typ, name, value = parts
            vpath = vpath.lstrip("/")
            attrs.setdefault(vpath, []).append(
                (ccode(typ), name.encode("utf-8"), value.encode("utf-8")))
    return attrs


def build_stage(path, mib, root_host, manifest):
    #  Populate a volume from a host staging tree (M93): every host
    #  file/dir under root_host becomes a BeFS entry under the
    #  volume root, name-preserving. Extra attributes (ICON etc.)
    #  come from the manifest (volume-relative path -> attrs).
    #  The volume-wide name/size/last_modified index trees are left
    #  EMPTY: staged files are static, and the engine keeps those
    #  indices in sync only for files it creates/modifies at
    #  runtime (documented deviation — queries match runtime files).
    #  Each directory's own btree must fit ONE leaf (entries <= the
    #  ~1024-byte node); assert loudly rather than write an invalid
    #  tree (the OS tree keeps every dir well under that).
    num_blocks = mib * 1024 * 1024 // BLK
    img = Image(num_blocks)

    #  --- pass 1: allocate inode/data/stream blocks + snapshot
    #  host metadata (recursive; returns the record tree) ---
    def alloc_node(host_path, vol_path, parent_block, is_dir):
        rec = {"is_dir": is_dir, "vol": vol_path,
               "block": img.alloc(1), "parent": parent_block,
               "name": os.path.basename(host_path).encode("utf-8")}
        if is_dir:
            rec["stream"] = img.alloc(2)
            rec["size"] = 2 * BLK
            rec["children"] = []
            for nm in sorted(os.listdir(host_path)):
                hp = os.path.join(host_path, nm)
                vp = vol_path + "/" + nm if vol_path else nm
                rec["children"].append(
                    alloc_node(hp, vp, rec["block"],
                               os.path.isdir(hp)))
        else:
            with open(host_path, "rb") as f:
                rec["data"] = f.read()
            rec["size"] = len(rec["data"])
            need = (rec["size"] + BLK - 1) // BLK
            runs = []
            if need > 0:
                start = img.alloc(need)   #  bump-allocated contiguous
                #  split at AG boundaries so no run crosses a group
                pos = 0
                while pos < need:
                    seg = min(need - pos,
                              GROUPSIZE - ((start + pos) % GROUPSIZE))
                    runs.append((start + pos, seg))
                    pos += seg
            rec["runs"] = runs
        return rec

    root = alloc_node(root_host, "", 0, True)
    #  the volume root's ".." points at itself (fixture parity)
    root["parent"] = root["block"]

    #  Indices root (referenced by the superblock, not the root
    #  dir): name/size/last_modified/appsig with EMPTY streams.
    idx_i = img.alloc(1)
    idx_s = img.alloc(2)
    index_names = [("name", BTREE_STRING, B_STRING_TYPE),
                   ("size", BTREE_INT64, B_INT64_TYPE),
                   ("last_modified", BTREE_INT64, B_INT64_TYPE),
                   ("BEOS:APP_SIG", BTREE_STRING, B_STRING_TYPE)]
    ix = {}
    for nm, dtype, typecode in index_names:
        ino = img.alloc(1)
        stb = img.alloc(2)
        ix[nm] = (ino, stb, dtype, typecode)

    #  --- pass 2: write file data, dir btrees, inodes ---
    def write_node(rec):
        if rec["is_dir"]:
            entries = [(b".", rec["block"]), (b"..", rec["parent"])]
            for ch in rec["children"]:
                entries.append((ch["name"], ch["block"]))
            stream = btree_stream(BTREE_STRING, entries)
            if len(stream) > 2 * BLK:
                raise SystemExit(
                    "mkbefs: dir %s does not fit one leaf" % rec["vol"])
            img.put(rec["stream"], stream[:BLK])
            img.put(rec["stream"] + 1, stream[BLK:2 * BLK])
            runs = [(rec["stream"], 2)]
            size = 2 * BLK
            mode = S_IFDIR | S_STR_INDEX | 0o755
        else:
            runs = rec["runs"]
            size = len(rec["data"])
            mode = S_IFREG | 0o644
            off = 0
            for (start, ln) in runs:
                base = start * BLK
                for k in range(ln):
                    chunk = rec["data"][off:off + BLK]
                    img.buf[base + k * BLK:base + (k + 1) * BLK] = \
                        chunk + bytes(BLK - len(chunk))
                    off += BLK
        #  the volume root carries no name pseudo-attribute (fixture
        #  parity); every other named inode has it first.
        attrs = [] if rec["vol"] == "" else \
            [(FILE_NAME_TYPE, bytes([FILE_NAME_NAME]), rec["name"])]
        attrs += manifest.get(rec["vol"], [])
        img.put(rec["block"], inode(
            rec["block"], mode, rec["parent"], attrs, runs, size))
        if rec["is_dir"]:
            for ch in rec["children"]:
                write_node(ch)

    write_node(root)

    #  indices root inode + children
    idx_entries = [(b"name", ix["name"][0]),
                   (b"size", ix["size"][0]),
                   (b"last_modified", ix["last_modified"][0]),
                   (b"BEOS:APP_SIG", ix["BEOS:APP_SIG"][0])]
    #  byte order: 'B'(0x42) < 'l'(0x6C) < 'n'(0x6E) < 's'(0x73) —
    #  the list above is already ascending.
    idx_stream = btree_stream(BTREE_STRING, idx_entries)
    img.put(idx_s, idx_stream[:BLK])
    img.put(idx_s + 1, idx_stream[BLK:2 * BLK])
    for nm, (ino, stb, dtype, typecode) in ix.items():
        st = btree_stream(dtype, [])
        img.put(stb, st[:BLK])
        img.put(stb + 1, st[BLK:])
        img.put(ino, inode(ino, S_INDEX_DIR | S_IFDIR |
                           (S_STR_INDEX if dtype == BTREE_STRING
                            else S_LONG_LONG_INDEX),
                           idx_i, [], [(stb, 2)], 2 * BLK,
                           type_code=typecode))
    img.put(idx_i, inode(idx_i,
                         S_INDEX_DIR | S_STR_INDEX | S_IFDIR | 0o700,
                         idx_i, [], [(idx_s, 2)], 2 * BLK))

    #  the volume root keeps its be:volume_id attribute
    attrs = [(B_UINT64_TYPE, b"be:volume_id", le64(0x4D3933_4245_4653))]
    attrs += manifest.get("", [])
    img.put(root["block"], inode(
        root["block"], S_IFDIR | S_STR_INDEX | 0o755,
        root["block"], attrs, [(root["stream"], 2)], 2 * BLK))

    #  --- bitmap + superblock ---
    for b in range(img.reserved, img.next_free):
        img.mark(b)
    img.finish_bitmap()
    img.buf[512:1024] = superblock(img, num_blocks, root["block"], idx_i)

    with open(path, "wb") as f:
        f.write(img.buf)

    #  read-back self-check: tree walk + sizes + data hashes
    buf = bytes(img.buf)
    sb = buf[512:1024]
    assert sb[32:36] == le32(SB_MAGIC1) and \
        sb[112:116] == le32(SB_MAGIC3), "sb magics"
    num_ags = struct.unpack("<I", sb[80:84])[0]
    pop = sum(bin(b).count("1")
              for blk in range(num_ags)
              for b in buf[(1 + blk) * BLK:(2 + blk) * BLK])
    assert pop == img.used, "bitmap popcount %d != used %d" % (
        pop, img.used)

    def rd_entry(leaf):
        count = struct.unpack_from("<H", leaf, 24)[0]
        klen = struct.unpack_from("<H", leaf, 26)[0]
        keys = leaf[28:28 + klen]
        pos = key_align(28 + klen)
        lens = [struct.unpack_from("<H", leaf, pos + 2 * j)[0]
                for j in range(count)]
        pos += 2 * count
        koff = 0
        names, vals = [], []
        for j in range(count):
            names.append(keys[koff:koff + lens[j]])
            vals.append(struct.unpack_from("<q", leaf, pos + 8 * j)[0])
            koff += lens[j]
        return names, vals

    def inode_runs(node):
        runs = []
        for j in range(12):
            ag, start, ln = struct.unpack_from("<iHH", node, 72 + 8 * j)
            if ln == 0:
                break
            runs.append(((ag << AG_SHIFT) + start, ln))
        return runs

    def check_node(rec):
        node = buf[rec["block"] * BLK:(rec["block"] + 1) * BLK]
        assert node[0:4] == le32(INODE_MAGIC1), "inode magic %s" % (
            rec["vol"])
        size = struct.unpack_from("<q", node, 208)[0]
        assert size == rec["size"], "size mismatch %s" % rec["vol"]
        if rec["is_dir"]:
            srun = struct.unpack_from("<iHH", node, 72)
            base = (srun[0] << AG_SHIFT) + srun[1]
            hdr = buf[base * BLK:(base + 1) * BLK]
            assert hdr[0:4] == le32(BTREE_MAGIC), "btree magic %s" % (
                rec["vol"])
            leaf = buf[(base + 1) * BLK:(base + 2) * BLK]
            names, vals = rd_entry(leaf)
            expect = [b".", b".."] + [ch["name"] for ch in
                                      rec["children"]]
            assert names == expect, "dir entries %s: %r != %r" % (
                rec["vol"], names, expect)
            for ch, blk in zip(rec["children"], vals[2:]):
                assert blk == ch["block"], "child block %s" % ch["vol"]
                check_node(ch)
        else:
            runs = inode_runs(node)
            assert runs == rec["runs"], "runs mismatch %s: %r != %r" % (
                rec["vol"], runs, rec["runs"])
            total = b""
            for (start, ln) in runs:
                base = start * BLK
                for k in range(ln):
                    total += buf[base + k * BLK:base + (k + 1) * BLK]
            assert total[:size] == rec["data"], "data mismatch %s" % (
                rec["vol"])

    check_node(root)
    print("mkbefs --stage: %s: %d MiB, %d blocks, %d used, staged"
          " tree verified"
          % (path, mib, num_blocks, img.used))


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--stage":
        root_host = sys.argv[2]
        path = sys.argv[3]
        mib = int(sys.argv[4]) if len(sys.argv) >= 5 else 8
        manifest = parse_manifest(sys.argv[5]) if len(sys.argv) >= 6 \
            else {}
        if not os.path.isdir(root_host):
            raise SystemExit("staging root %s is not a directory"
                             % root_host)
        build_stage(path, mib, root_host, manifest)
    elif len(sys.argv) < 2 or len(sys.argv) > 3:
        raise SystemExit(
            "usage: mkbefs.py OUTPUT [SIZE_MIB]\n"
            "       mkbefs.py --stage ROOT_DIR OUTPUT [SIZE_MIB] "
            "[ATTRS_MANIFEST]")
    else:
        mib = int(sys.argv[2]) if len(sys.argv) == 3 else 8
        build(sys.argv[1], mib)


if __name__ == "__main__":
    main()
