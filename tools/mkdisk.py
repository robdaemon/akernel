#!/usr/bin/env python3
"""Create the akernel GPT/FAT32 data disk without host sgdisk/mtools.

Replicates the Makefile disk.img recipe:
  - 64 MiB raw image
  - GPT with one partition starting at sector 2048, named "Sys"
  - FAT32 filesystem in that partition (1 sector/cluster)
  - Population: README.TXT, BIG.BIN, SUBDIR/HELLO.TXT,
    LongFileName.txt, System/{Bureau,Terminal,Shell,Demo,Startup},
    C/{Dir,Type,Copy,Delete,Rename,Makedir,Info,Set,Get,Unset,
       Assign,Echo,Which,Version,Fault}
"""

import sys
import struct
import uuid
import os

SECTOR = 512
DISK_SECTORS = 64 * 1024 * 1024 // SECTOR   # 131072
PART_START = 2048
# 60 MiB partition like the Makefile recipe
PART_SECTORS = 60 * 1024 * 1024 // SECTOR   # 122880
# But Makefile uses +60M (not 60M exactly); 122880 sectors is close.
# Use the exact value from the recipe: partition fills to end minus backup GPT.

# Keep backup GPT at last 34 sectors. Use 245760 sectors for 60 MiB? Wait 64MiB total.
# The Makefile: -n 1:2048:+60M => 60MiB = 122880 sectors. Partmgr reads up to partition size.
# Use PART_SECTORS = 122880.

BPB = {
    'BytesPerSector': 512,
    'SectorsPerCluster': 1,
    'ReservedSectorCount': 32,
    'NumFATs': 2,
    'Media': 0xF8,
    'SectorsPerTrack': 32,
    'Heads': 64,
    'HiddenSectors': PART_START,
    'TotalSectors32': PART_SECTORS,
    'VolumeLabel': 'Sys',
    'VolumeSerial': 0x12345678,
}

# Compute FAT size: data clusters = PART_SECTORS - Reserved - 2*FATsize
# Iterate to fixed point.
def compute_fat_size(total, reserved):
    fat = 1
    while True:
        data = total - reserved - 2 * fat
        need = (data + 2) * 4
        new = (need + SECTOR - 1) // SECTOR
        if new <= fat:
            return fat
        fat = new

FAT_SECTORS = compute_fat_size(PART_SECTORS, BPB['ReservedSectorCount'])
DATA_START_REL = BPB['ReservedSectorCount'] + BPB['NumFATs'] * FAT_SECTORS
ROOT_CLUSTER = 2  # cluster 2 is the traditional root; allocated below

def rel_to_abs(sector):
    return PART_START + sector

# In-memory FAT (cluster -> next, 0 = free, EOC = 0x0FFFFFFF)
fat = [0] * (PART_SECTORS - DATA_START_REL + 2)
fat[0] = 0x0FFFFFF8  # media/reserved cluster 0
fat[1] = 0x0FFFFFFF  # reserved cluster 1
next_cluster = 2

def alloc_chain(length):
    global next_cluster
    if length == 0:
        return 0
    start = next_cluster
    for i in range(length):
        c = next_cluster
        next_cluster += 1
        fat[c] = 0x0FFFFFFF if i == length - 1 else c + 1
    return start

def cluster_sector_abs(c):
    return rel_to_abs(DATA_START_REL + (c - 2) * BPB['SectorsPerCluster'])

# Disk image bytearray
img = bytearray(DISK_SECTORS * SECTOR)

def write_sector_abs(asec, data):
    off = asec * SECTOR
    img[off:off + len(data)] = data

def read_sector_abs(asec):
    off = asec * SECTOR
    return img[off:off + SECTOR]

def pack16(v):
    return struct.pack('<H', v)

def pack32(v):
    return struct.pack('<I', v)

def fat32_short_checksum(name11):
    s = 0
    for b in name11:
        s = ((s >> 1) + ((s & 1) << 7) + b) & 0xFF
    return s

def norm83(name):
    """Return 11-byte uppercase short name padded with spaces."""
    if '.' in name and name != '.' and name != '..':
        base, ext = name.rsplit('.', 1)
    else:
        base, ext = name, ''
    base = base.upper()[:8].ljust(8)
    ext = ext.upper()[:3].ljust(3)
    return (base + ext).encode('ascii')

def make_lfn_entries(name, short_name11):
    """Return list of LFN entries (newest first) plus the short name bytes."""
    if len(name) <= 12:
        # Can fit in 8.3; caller should just use short name.
        return []
    ucs = list(name.encode('utf-16-le'))
    #  Pad UCS-2 bytes to a multiple of one LFN entry (26 bytes):
    #  a 0x0000 terminator right after the last real character (only
    #  when the name does not end exactly on an entry boundary), then
    #  0xFFFF fill to the boundary.
    ucs = bytes(ucs)
    if len(ucs) % 26:
        ucs += b'\x00\x00'
    while len(ucs) % 26:
        ucs += b'\xff\xff'
    total = len(ucs) // 26
    checksum = fat32_short_checksum(short_name11)
    entries = []
    for i in range(total):
        # Physical entries are stored tail-first; the entry
        # immediately preceding the short name carries the head.
        part = ucs[(total - i - 1) * 26:(total - i) * 26]
        seq = total - i
        if i == 0:
            seq |= 0x40  # last physical entry flag
        entry = bytearray(32)
        entry[0] = seq
        entry[1:11] = part[0:10]
        entry[11] = 0x0F
        entry[12] = 0
        entry[13] = checksum
        entry[14:26] = part[10:22]
        entry[26:28] = b'\x00\x00'
        entry[28:32] = part[22:26]
        entries.append(bytes(entry))
    return entries

def make_short_entry(name, attr, cluster, size, is_dir=False):
    ent = bytearray(32)
    ent[0:11] = norm83(name)
    ent[11] = attr
    ent[14:16] = pack16(0)       # create time
    ent[16:18] = pack16(0x5A21)  # create date 2025-01-01
    ent[18:20] = pack16(0x5A21)  # access date
    ent[20:22] = pack16((cluster >> 16) & 0xFFFF)
    ent[22:24] = pack16(0)       # write time
    ent[24:26] = pack16(0x5A21)  # write date
    ent[26:28] = pack16(cluster & 0xFFFF)
    ent[28:32] = pack32(size)
    return bytes(ent)

# Build directory trees as lists of (name, kind, content_or_children)
# content_or_children: bytes for file, list for dir

tree = {
    'README.TXT': b'Hello from the akernel FAT32 volume.\n',
    'BIG.BIN': bytes((i * 7 + 3) & 0xFF for i in range(65536)),
    'LongFileName.txt': b'A long file name body.\n',
    'SUBDIR': {
        'HELLO.TXT': b'Subdir hello!\n',
    },
    'System': {
        'Startup': b'System/Bureau\nSystem/Terminal\nSystem/Demo\n',
    },
    'C': {},
}

#  Crate lists come from the Makefile (single source of truth —
#  make new-crate edits it, and a hardcoded copy here silently
#  drifted once already).
import re

def crate_list(var):
    with open('Makefile') as f:
        m = re.search(r'^' + var + r'\s*:?=\s*(.*)$', f.read(),
                      re.MULTILINE)
    if not m:
        raise RuntimeError(var + ' not found in Makefile')
    return m.group(1).split()

DISK_CRATES_SYSTEM = crate_list('DISK_CRATES_SYSTEM')
DISK_CRATES_C = crate_list('DISK_CRATES_C')
BIN = 'bin/userspace'

def cap_name(n):
    return n[0].upper() + n[1:]

for c in DISK_CRATES_SYSTEM:
    path = os.path.join(BIN, c + '.elf')
    with open(path, 'rb') as f:
        tree['System'][cap_name(c)] = f.read()
for c in DISK_CRATES_C:
    path = os.path.join(BIN, c + '.elf')
    with open(path, 'rb') as f:
        tree['C'][cap_name(c)] = f.read()

#  Write directories and files recursively.  Directories span as
#  many clusters as their records need (the C: drawer with 15
#  commands no longer fits one cluster).

def entry_count(name):
    """32-byte slots a name's dirent + LFN run occupies."""
    if len(name) <= 12:
        return 1
    return len(make_lfn_entries(name, norm83(name))) + 1

def write_records_into(start, records):
    """Write records into an already-allocated contiguous chain."""
    data = b''.join(records)
    i = 0
    while i * SECTOR < len(data):
        chunk = data[i * SECTOR:(i + 1) * SECTOR]
        write_sector_abs(cluster_sector_abs(start + i),
                         chunk + b'\x00' * (SECTOR - len(chunk)))
        i += 1

def build_dir(name, subtree, parent_cluster):
    #  Children first (they allocate their own chains), then size
    #  and allocate this directory's chain.
    pending = []
    for entry_name, value in subtree.items():
        if isinstance(value, dict):
            pending.append((entry_name,
                            build_dir(entry_name, value, None)))
        else:
            file_cluster, file_size = write_file(value)
            pending.append((entry_name, file_cluster, file_size))
    total = 2 + sum(entry_count(n) for n, *_ in pending)
    my_cluster = alloc_chain((total * 32 + SECTOR - 1) // SECTOR)
    records = [make_short_entry('.', 0x10, my_cluster, 0),
               make_short_entry('..', 0x10,
                                parent_cluster if parent_cluster else 0,
                                0)]
    for rec in pending:
        if len(rec) == 2:
            records.extend(make_dir_entry(rec[0], rec[1]))
        else:
            records.extend(make_file_entries(rec[0], rec[1], rec[2]))
    write_records_into(my_cluster, records)
    return my_cluster

def write_file(content):
    length = len(content)
    clusters = (length + SECTOR - 1) // SECTOR
    start = alloc_chain(clusters)
    for i in range(clusters):
        c = start + i
        chunk = content[i * SECTOR:(i + 1) * SECTOR]
        sec = cluster_sector_abs(c)
        write_sector_abs(sec, chunk + b'\x00' * (SECTOR - len(chunk)))
    return start, length

def make_dir_entry(name, cluster):
    if len(name) <= 12:
        return [make_short_entry(name, 0x10, cluster, 0)]
    short11 = norm83(name)
    # numeric-tail collision unlikely for these names; use short as alias.
    lfn = make_lfn_entries(name, short11)
    short = make_short_entry(name, 0x10, cluster, 0)
    return lfn + [short]

def make_file_entries(name, cluster, size):
    if len(name) <= 12:
        return [make_short_entry(name, 0x20, cluster, size)]
    short11 = norm83(name)
    lfn = make_lfn_entries(name, short11)
    short = make_short_entry(name, 0x20, cluster, size)
    return lfn + [short]

#  The root chain must START at cluster 2 (BPB RootCluster), so it
#  is the first allocation; size it from the top-level entry count
#  (volume label + one run per entry).
root_slots = 1 + sum(entry_count(n) for n in tree)
root_cluster = alloc_chain((root_slots * 32 + SECTOR - 1) // SECTOR)
assert root_cluster == 2, 'root chain must start at cluster 2'

# Build subdirectories first to know their clusters.  FAT32 root
# children carry '..' = 0 (host mkfs convention; fsck rejects the
# root cluster number there).
sub_clusters = {}
for entry_name, value in tree.items():
    if isinstance(value, dict):
        sub_clusters[entry_name] = build_dir(entry_name, value, None)

# Now build root records.
root_records = []
# volume label entry
vol = bytearray(32)
vol[0:11] = (BPB['VolumeLabel'].ljust(11)).encode('ascii')
vol[11] = 0x08
root_records.append(bytes(vol))

for entry_name, value in tree.items():
    if isinstance(value, dict):
        root_records.extend(make_dir_entry(entry_name, sub_clusters[entry_name]))
    else:
        c, s = write_file(value)
        root_records.extend(make_file_entries(entry_name, c, s))

write_records_into(root_cluster, root_records)

# Write FATs
fat_bytes = b''.join(struct.pack('<I', e & 0x0FFFFFFF) for e in fat)
if len(fat_bytes) < FAT_SECTORS * SECTOR:
    fat_bytes += b'\x00' * (FAT_SECTORS * SECTOR - len(fat_bytes))
fat1_start = rel_to_abs(BPB['ReservedSectorCount'])
fat2_start = fat1_start + FAT_SECTORS
for base in (fat1_start, fat2_start):
    for i in range(FAT_SECTORS):
        write_sector_abs(base + i, fat_bytes[i * SECTOR:(i + 1) * SECTOR])

# Write BPB
bpb = bytearray(SECTOR)
# bytes 0-2: jmp instruction
bpb[0:3] = b'\xEB\x58\x90'
# OEM name
bpb[3:11] = b'mkfs.fat'
# BPB
bpb[11:13] = pack16(BPB['BytesPerSector'])
bpb[13] = BPB['SectorsPerCluster']
bpb[14:16] = pack16(BPB['ReservedSectorCount'])
bpb[16] = BPB['NumFATs']
bpb[17:19] = pack16(0)  # RootEntryCount (FAT32: 0)
bpb[19:21] = pack16(0)  # TotalSectors16 (0 for FAT32)
bpb[21] = BPB['Media']
bpb[22:24] = pack16(0)  # FAT16 sectors per FAT (0)
bpb[24:26] = pack16(BPB['SectorsPerTrack'])
bpb[26:28] = pack16(BPB['Heads'])
bpb[28:32] = pack32(BPB['HiddenSectors'])
bpb[32:36] = pack32(BPB['TotalSectors32'])
# FAT32 extended BPB
bpb[36:40] = pack32(FAT_SECTORS)        # SectorsPerFAT32
bpb[40:42] = pack16(0)                  # ExtFlags
bpb[42:44] = pack16(0)                  # FSVersion
bpb[44:48] = pack32(root_cluster)       # RootCluster
bpb[48:50] = pack16(1)                  # FSInfo
bpb[50:52] = pack16(6)                  # BackupBootSector
bpb[52:64] = b'\x00' * 12               # Reserved
bpb[64] = 0x80                          # DriveNumber
bpb[65] = 0                             # Reserved1
bpb[66] = 0x29                          # BootSig
bpb[67:71] = pack32(BPB['VolumeSerial'])
bpb[71:82] = BPB['VolumeLabel'].ljust(11).encode('ascii')
bpb[82:90] = b'FAT32   '
bpb[510:512] = b'\x55\xAA'
write_sector_abs(rel_to_abs(0), bytes(bpb))
#  Backup boot sector (BPB says sector 6) + backup FSInfo (7).
write_sector_abs(rel_to_abs(6), bytes(bpb))

# FSInfo sector
fsinfo = bytearray(SECTOR)
fsinfo[0:4] = struct.pack('<I', 0x41615252)
fsinfo[484:488] = struct.pack('<I', 0x61417272)
free_count = (PART_SECTORS - DATA_START_REL) - (next_cluster - 2)
fsinfo[488:492] = struct.pack('<I', free_count)
fsinfo[492:496] = struct.pack('<I', next_cluster)
fsinfo[508:512] = struct.pack('<I', 0xAA550000)
write_sector_abs(rel_to_abs(1), bytes(fsinfo))
write_sector_abs(rel_to_abs(7), bytes(fsinfo))

# GPT
# Protective MBR in sector 0
gpt_guid = uuid.uuid4()
part_guid = uuid.uuid4()
part_type_guid = uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7')  # Microsoft basic data

mbr = bytearray(SECTOR)
mbr[510:512] = b'\x55\xAA'
# protective partition entry starting at sector 1, max size 0xFFFFFFFF
mbr[446:450] = b'\x00\x02\x00\x00'  # CHS start
mbr[450] = 0xEE  # GPT protective
mbr[451:454] = b'\xFE\xFF\xFF'  # CHS end (large)
mbr[454:458] = struct.pack('<I', 1)  # LBA start
mbr[458:462] = struct.pack('<I', DISK_SECTORS - 1)
write_sector_abs(0, bytes(mbr))

# GPT header at sector 1
def crc32(data):
    import binascii
    return binascii.crc32(data) & 0xFFFFFFFF

backup_lba = DISK_SECTORS - 1
last_usable = DISK_SECTORS - 34

def gpt_header(current_lba, backup, entries_lba, entries_crc):
    h = bytearray(SECTOR)
    h[0:8] = b'EFI PART'
    h[8:12] = struct.pack('<I', 0x00010000)   # revision 1.0
    h[12:16] = struct.pack('<I', 92)           # header size
    h[24:32] = struct.pack('<Q', current_lba)
    h[32:40] = struct.pack('<Q', backup)
    h[40:48] = struct.pack('<Q', PART_START)   # first usable LBA
    h[48:56] = struct.pack('<Q', last_usable)
    h[56:72] = gpt_guid.bytes_le
    h[72:80] = struct.pack('<Q', entries_lba)
    h[80:84] = struct.pack('<I', 128)          # entry count
    h[84:88] = struct.pack('<I', 128)          # entry size
    h[88:92] = struct.pack('<I', entries_crc)  # entry array CRC32
    for_crc = bytearray(h[:92])
    for_crc[16:20] = b'\x00\x00\x00\x00'
    h[16:20] = struct.pack('<I', crc32(bytes(for_crc)))
    return h

# Partition entry array: 128 entries * 128 bytes = 32 sectors
entries_sector = bytearray(32 * SECTOR)
ent = bytearray(128)
ent[0:16] = part_type_guid.bytes_le
ent[16:32] = part_guid.bytes_le
ent[32:40] = struct.pack('<Q', PART_START)
ent[40:48] = struct.pack('<Q', PART_START + PART_SECTORS - 1)
ent[48:56] = struct.pack('<Q', 0)  # attributes
name = 'Sys'.encode('utf-16-le')
ent[56:56 + len(name)] = name
entries_sector[:128] = ent
entries_crc = crc32(bytes(entries_sector))

write_sector_abs(1, bytes(gpt_header(1, backup_lba, 2, entries_crc)))
write_sector_abs(2, bytes(entries_sector))
# Backup: entry array at backup_lba - 32 .., header at backup_lba
write_sector_abs(backup_lba - 32, bytes(entries_sector))
write_sector_abs(backup_lba,
                 bytes(gpt_header(backup_lba, 1, backup_lba - 32,
                                  entries_crc)))

with open(sys.argv[1] if len(sys.argv) > 1 else 'disk.img', 'wb') as f:
    f.write(img)

print(f"created {sys.argv[1]}: {len(img)} bytes, FAT sectors {FAT_SECTORS}, data start {DATA_START_REL}")
