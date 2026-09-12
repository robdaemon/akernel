#!/bin/bash
mkdir -p share/
make run QEMU_ARGS="-display gtk -fsdev local,id=fs0,path=./share,security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=host,addr=0x9"
