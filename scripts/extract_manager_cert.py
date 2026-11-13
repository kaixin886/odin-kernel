#!/usr/bin/env python3
"""Extract the first signer certificate from an APK (signature scheme v2/v3).

Prints the two values FinaSU/KernelSU need at kernel build time:
    KSU_EXPECTED_SIZE=0x<cert length in hex>
    KSU_EXPECTED_HASH=<sha256 of the DER certificate, hex>

The kernel checks the manager APK's signer certificate against these
compile-time constants, so they must come from the exact manager build
that will be installed on the device.
"""

import hashlib
import struct
import sys

SIG_BLOCK_MAGIC = b"APK Sig Block 42"
ID_V2 = 0x7109871A
ID_V3 = 0xF05368C0


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def find_signing_block(data):
    # End of central directory: scan the tail for the EOCD signature.
    tail = data[-65557:]
    idx = tail.rfind(b"PK\x05\x06")
    if idx < 0:
        raise SystemExit("EOCD not found: not an APK/ZIP?")
    eocd = len(data) - len(tail) + idx
    cd_offset = u32(data, eocd + 16)
    # Footer right before the central directory: size(8) + magic(16).
    footer = cd_offset - 24
    if data[footer + 8 : footer + 24] != SIG_BLOCK_MAGIC:
        raise SystemExit("APK signing block magic not found (v1-only APK?)")
    block_size = u64(data, footer)
    block_start = cd_offset - (block_size + 8)
    return data[block_start : cd_offset]


def lp_pairs(block):
    """Yield (id, value) from a signing block body."""
    # Skip leading size field; pairs run until the trailing size field.
    off = 8
    end = len(block) - 24
    while off < end:
        length = u64(block, off)
        pair_id = u32(block, off + 8)
        value = block[off + 12 : off + 8 + length]
        yield pair_id, value
        off += 8 + length


def read_lp(buf, off):
    """Read one length-prefixed chunk; return (chunk, next_offset)."""
    length = u32(buf, off)
    return buf[off + 4 : off + 4 + length], off + 4 + length


def first_cert(signer_block):
    # signer block: signed_data (lp), signatures (lp), public key (lp)
    signed_data, _ = read_lp(signer_block, 0)
    # signed_data: digests (lp-seq), certificates (lp-seq), attrs (lp-seq)
    digests, off = read_lp(signed_data, 0)
    certs, off = read_lp(signed_data, off)
    cert, _ = read_lp(certs, 0)
    return cert


def main():
    with open(sys.argv[1], "rb") as fh:
        data = fh.read()
    block = find_signing_block(data)
    for pair_id, value in lp_pairs(block):
        if pair_id in (ID_V2, ID_V3):
            # value: signers (lp-sequence of lp signer blocks)
            signers, _ = read_lp(value, 0)
            signer, _ = read_lp(signers, 0)
            cert = first_cert(signer)
            print(f"KSU_EXPECTED_SIZE={hex(len(cert))}")
            print(f"KSU_EXPECTED_HASH={hashlib.sha256(cert).hexdigest()}")
            return
    raise SystemExit("no v2/v3 signer block found")


if __name__ == "__main__":
    main()
