#!/usr/bin/env python3
"""
reu_load.py - Load REU file into MiSTer FPGA core via HPS I/O bridge.

Bypasses MGL/OSD by directly using the FIO SPI protocol through /dev/mem.
Based on MiSTer Main's fpga_io.cpp and user_io.cpp.

Usage: python3 reu_load.py <reu_file> [index]
  index defaults to 2 (F2 REU slot in C64 core)
"""

import sys
import mmap
import struct
import time
import os

# FPGA Manager base address (lightweight HPS-to-FPGA bridge)
FPGA_MGR_BASE = 0xFF000000
FPGA_MGR_SIZE = 0x01000000  # 16MB window

# GPIO offsets within the FPGA manager for SPI-like protocol
# Based on MiSTer Main fpga_io.cpp
GPO_OFFSET = 0x10  # General Purpose Output
GPI_OFFSET = 0x14  # General Purpose Input

# FIO commands (from user_io.h)
FIO_FILE_TX     = 0x53
FIO_FILE_TX_DAT = 0x54
FIO_FILE_INDEX  = 0x55
FIO_FILE_INFO   = 0x56

# SPI protocol bits
SPI_ACTIVE = 0x0100  # Active/SS line
SPI_DIN    = 0x00FF  # Data input mask
SPI_DOUT   = 0x00FF  # Data output mask from GPI


def spi_begin(mem, base):
    """Assert SPI chip select."""
    # Read current GPO, set active bit
    struct.pack_into('<I', mem, base + GPO_OFFSET, SPI_ACTIVE | 0xFF)

def spi_end(mem, base):
    """Deassert SPI chip select."""
    struct.pack_into('<I', mem, base + GPO_OFFSET, 0x0000 | 0xFF)

def spi_w(mem, base, data):
    """Write a byte via SPI (active must already be asserted)."""
    # Write data with active bit
    struct.pack_into('<I', mem, base + GPO_OFFSET, SPI_ACTIVE | (data & 0xFF))
    # Toggle clock by reading back
    time.sleep(0.000001)

def spi_uio_cmd(mem, base, cmd):
    """Send a UIO command byte."""
    spi_begin(mem, base)
    spi_w(mem, base, cmd)

def spi_uio_cmd_end(mem, base, cmd):
    """Send a UIO command byte and deassert."""
    spi_uio_cmd(mem, base, cmd)
    spi_end(mem, base)

def spi_uio_cmd8(mem, base, cmd, val):
    """Send UIO command followed by one data byte."""
    spi_begin(mem, base)
    spi_w(mem, base, cmd)
    spi_w(mem, base, val)
    spi_end(mem, base)

def spi_uio_cmd16(mem, base, cmd, val):
    """Send UIO command followed by 16-bit value (little-endian)."""
    spi_begin(mem, base)
    spi_w(mem, base, cmd)
    spi_w(mem, base, val & 0xFF)
    spi_w(mem, base, (val >> 8) & 0xFF)
    spi_end(mem, base)


def load_reu(filepath, index=2):
    """Load REU file into FPGA core via FIO protocol."""

    filesize = os.path.getsize(filepath)
    print(f"Loading {filepath} ({filesize} bytes) with ioctl_index={index}")

    # Open /dev/mem
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    mem = mmap.mmap(fd, FPGA_MGR_SIZE, mmap.MAP_SHARED,
                    mmap.PROT_READ | mmap.PROT_WRITE,
                    offset=FPGA_MGR_BASE)

    try:
        # Step 1: Set file index
        print(f"Setting file index to {index}...")
        spi_uio_cmd8(mem, 0, FIO_FILE_INDEX, index)

        # Step 2: Send file extension info
        ext = b'REU\x00'
        spi_begin(mem, 0)
        spi_w(mem, 0, FIO_FILE_INFO)
        for b in ext:
            spi_w(mem, 0, b)
        spi_end(mem, 0)

        # Step 3: Begin file transfer
        print("Starting file transfer...")
        spi_uio_cmd8(mem, 0, FIO_FILE_TX, 0xFF)  # 0xFF = start

        # Step 4: Send file data in chunks
        CHUNK_SIZE = 4096
        with open(filepath, 'rb') as f:
            sent = 0
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break

                spi_begin(mem, 0)
                spi_w(mem, 0, FIO_FILE_TX_DAT)
                for b in chunk:
                    spi_w(mem, 0, b)
                spi_end(mem, 0)

                sent += len(chunk)
                if sent % (1024*1024) == 0:
                    print(f"  {sent // (1024*1024)} MB / {filesize // (1024*1024)} MB")

        # Step 5: End file transfer
        print(f"Transfer complete: {sent} bytes sent")
        spi_uio_cmd8(mem, 0, FIO_FILE_TX, 0x00)  # 0x00 = stop

    finally:
        mem.close()
        os.close(fd)

    print("Done.")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 reu_load.py <reu_file> [index]")
        print("  index: ioctl_index (default 2 for C64 F2 REU slot)")
        sys.exit(1)

    filepath = sys.argv[1]
    index = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    load_reu(filepath, index)
