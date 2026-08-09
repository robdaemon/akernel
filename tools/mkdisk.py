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

# Allocate the root cluster up front so subdirectories cannot
# overwrite it.
root_cluster = alloc_chain(1)

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
    # Pad UCS-2 bytes to a multiple of one LFN entry (26 bytes).
    # The terminator (two zero bytes) is placed immediately after the
    # last real character; remaining slots are filled with 0xFFFF.
    while len(ucs) % 26:
        if len(ucs) % 26 == 2:
            ucs += b'\x00\x00'
        else:
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
    ent[16:18] = pack16(0x5021)  # create date 2025-01-01
    ent[18:20] = pack16(0x5021)  # access date
    ent[20:22] = pack16((cluster >> 16) & 0xFFFF)
    ent[22:24] = pack16(0)       # write time
    ent[24:26] = pack16(0x5021)  # write date
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

DISK_CRATES_SYSTEM = ['bureau', 'terminal', 'demo', 'shell']
DISK_CRATES_C = ['dir', 'type', 'copy', 'delete', 'rename', 'makedir',
                 'info', 'set', 'get', 'unset', 'assign', 'echo',
                 'which', 'version', 'fault']
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

# Write directories and files recursively, tracking entries per directory cluster.
dir_contents = {}  # cluster -> list of 32-byte entry records

def build_dir(name, subtree, parent_cluster):
    my_cluster = alloc_chain(1)
    # . and .. handled by writing to my_cluster sector
    dot = make_short_entry('.', 0x10, my_cluster, 0)
    dotdot = make_short_entry('..', 0x10, parent_cluster, 0)
    write_sector_abs(cluster_sector_abs(my_cluster), dot + dotdot + b'\x00' * (SECTOR - 64))
    records = []
    for entry_name, value in subtree.items():
        if isinstance(value, dict):
            child_cluster = build_dir(entry_name, value, my_cluster)
            records.append(make_dir_entry(entry_name, child_cluster))
        else:
            file_cluster, file_size = write_file(value)
            records.extend(make_file_entries(entry_name, file_cluster, file_size))
    dir_contents[my_cluster] = records
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

# Root is cluster 2, parent cluster conventionally 0 for ..
# Initialize root cluster (will be overwritten later by root entries)
write_sector_abs(cluster_sector_abs(root_cluster), b'\x00' * SECTOR)

# Build subdirectories first to know their clusters.
sub_clusters = {}
for entry_name, value in tree.items():
    if isinstance(value, dict):
        sub_clusters[entry_name] = build_dir(entry_name, value, root_cluster)

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

# Pad root records to sector boundary and write to root cluster
root_data = b''.join(root_records)
if len(root_data) > SECTOR:
    raise RuntimeError('root directory too large for one cluster')
write_sector_abs(cluster_sector_abs(root_cluster), root_data + b'\x00' * (SECTOR - len(root_data)))

# Write subdirectory entry records into their clusters
for cluster, records in dir_contents.items():
    data = b''.join(records)
    if len(data) > SECTOR:
        raise RuntimeError('directory too large for one cluster')
    write_sector_abs(cluster_sector_abs(cluster), data + b'\x00' * (SECTOR - len(data)))

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
bpb[24:25] = bytes([BPB['SectorsPerTrack']])
bpb[25:26] = bytes([BPB['Heads']])
bpb[26:30] = pack32(BPB['HiddenSectors'])
bpb[30:34] = pack32(BPB['TotalSectors32'])
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

# FSInfo sector
fsinfo = bytearray(SECTOR)
fsinfo[0:4] = struct.pack('<I', 0x41615252)
fsinfo[484:488] = struct.pack('<I', 0x61417272)
free_count = (PART_SECTORS - DATA_START_REL) - (next_cluster - 2)
fsinfo[488:492] = struct.pack('<I', free_count)
fsinfo[492:496] = struct.pack('<I', next_cluster)
fsinfo[508:512] = struct.pack('<I', 0xAA550000)
write_sector_abs(rel_to_abs(1), bytes(fsinfo))

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
gpt_header = bytearray(SECTOR)
gpt_header[0:8] = b'EFI PART'
gpt_header[8:12] = struct.pack('<I', 0x00010000)  # revision
gpt_header[12:16] = struct.pack('<I', 92)          # header size
gpt_header[16:20] = struct.pack('<I', 0)           # CRC32 placeholder
gpt_header[24:28] = struct.pack('<I', 1)           # current LBA
backup_lba = DISK_SECTORS - 1
gpt_header[32:40] = struct.pack('<Q', backup_lba)
gpt_header[40:48] = struct.pack('<Q', PART_START)  # first usable LBA
gpt_header[48:56] = struct.pack('<Q', DISK_SECTORS - 34)  # last usable LBA
gpt_header[56:72] = gpt_guid.bytes_le
gpt_header[72:80] = struct.pack('<Q', 2)  # partition entry LBA
gpt_header[80:84] = struct.pack('<I', 128) # entry size
gpt_header[84:88] = struct.pack('<I', 128) # entry count
# CRC of header bytes 0..91 (header size)
def crc32(data):
    import binascii
    return binascii.crc32(data) & 0xFFFFFFFF
header_for_crc = bytearray(gpt_header[:92])
header_for_crc[16:20] = b'\x00\x00\x00\x00'
gpt_header[16:20] = struct.pack('<I', crc32(bytes(header_for_crc)))
write_sector_abs(1, bytes(gpt_header))

# Partition entry array at sector 2..33 (128 entries * 128 bytes = 16384 bytes = 32 sectors)
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
write_sector_abs(2, bytes(entries_sector))

# Backup GPT header at last sector
backup_header = bytearray(gpt_header)
backup_header[24:28] = struct.pack('<I', 0)  # CRC placeholder
backup_header[32:40] = struct.pack('<Q', 1)  # backup LBA = original
backup_header[40:48] = struct.pack('<Q', backup_lba)  # original LBA? Actually header at backup, current=backup_lba
backup_header[24:28] = struct.pack('<I', backup_lba)  # current LBA
backup_header[72:80] = struct.pack('<Q', backup_lba - 32)  # partition entry array LBA (32 sectors before backup)
header_for_crc2 = bytearray(backup_header[:92])
header_for_crc2[16:20] = b'\x00\x00\x00\x00'
backup_header[16:20] = struct.pack('<I', crc32(bytes(header_for_crc2)))
write_sector_abs(backup_lba, bytes(backup_header))
# Backup partition entries at backup_lba - 32 .. backup_lba -1
write_sector_abs(backup_lba - 32, bytes(entries_sector))

with open(sys.argv[1] if len(sys.argv) > 1 else 'disk.img', 'wb') as f:
    f.write(img)

print(f"created {sys.argv[1]}: {len(img)} bytes, FAT sectors {FAT_SECTORS}, data start {DATA_START_REL}")
