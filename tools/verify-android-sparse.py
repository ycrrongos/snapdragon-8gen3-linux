#!/usr/bin/env python3
"""Validate an Android sparse image, optionally compare and expand it sparsely."""

from __future__ import annotations

import argparse
import errno
import hashlib
import os
import struct
import sys
from pathlib import Path


SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4
COPY_SIZE = 4 * 1024 * 1024


def read_exact(stream, size: int) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise ValueError(f"short read: wanted {size}, got {len(data)}")
    return data


def check_zero_extent(fd: int, start: int, end: int) -> int:
    """Check allocated extents in [start, end); filesystem holes are already zero."""
    checked = 0
    try:
        pos = os.lseek(fd, start, os.SEEK_DATA)
    except OSError as exc:
        if exc.errno == errno.ENXIO:
            return 0
        raise RuntimeError("source filesystem does not support SEEK_DATA") from exc

    zero = bytes(COPY_SIZE)
    while pos < end:
        try:
            hole = os.lseek(fd, pos, os.SEEK_HOLE)
        except OSError as exc:
            if exc.errno == errno.ENXIO:
                hole = end
            else:
                raise
        limit = min(hole, end)
        os.lseek(fd, pos, os.SEEK_SET)
        while pos < limit:
            count = min(COPY_SIZE, limit - pos)
            data = os.read(fd, count)
            if len(data) != count:
                raise ValueError(f"short source read at byte {pos}")
            if data != zero[:count]:
                for offset, value in enumerate(data):
                    if value:
                        raise ValueError(
                            f"DONT_CARE covers nonzero source byte {pos + offset}"
                        )
            pos += count
            checked += count
        if limit >= end:
            break
        try:
            pos = os.lseek(fd, limit, os.SEEK_DATA)
        except OSError as exc:
            if exc.errno == errno.ENXIO:
                break
            raise
    return checked


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sparse", type=Path)
    parser.add_argument("--compare-raw", type=Path)
    parser.add_argument("--output-raw", type=Path)
    args = parser.parse_args()

    output = None
    source_fd = None
    stats = {"raw": 0, "fill": 0, "dont_care": 0, "crc32": 0}
    defined_bytes = 0
    checked_zero_bytes = 0
    digest = hashlib.sha256()

    try:
        if args.compare_raw:
            source_fd = os.open(args.compare_raw, os.O_RDONLY)
        if args.output_raw:
            output = args.output_raw.open("xb")

        with args.sparse.open("rb") as sparse:
            header = read_exact(sparse, 28)
            digest.update(header)
            (
                magic,
                major,
                minor,
                file_header_size,
                chunk_header_size,
                block_size,
                total_blocks,
                total_chunks,
                image_checksum,
            ) = struct.unpack("<I4H4I", header)
            if magic != SPARSE_MAGIC:
                raise ValueError(f"bad sparse magic 0x{magic:08x}")
            if major != 1 or file_header_size < 28 or chunk_header_size < 12:
                raise ValueError("unsupported sparse format")
            if block_size == 0 or block_size % 4:
                raise ValueError(f"invalid block size {block_size}")
            if file_header_size > 28:
                extra = read_exact(sparse, file_header_size - 28)
                digest.update(extra)

            output_offset = 0
            for index in range(total_chunks):
                chunk_header = read_exact(sparse, chunk_header_size)
                digest.update(chunk_header)
                chunk_type, _reserved, chunk_blocks, total_size = struct.unpack(
                    "<2H2I", chunk_header[:12]
                )
                chunk_bytes = chunk_blocks * block_size
                payload_size = total_size - chunk_header_size
                if payload_size < 0:
                    raise ValueError(f"chunk {index}: invalid total size")

                if chunk_type == CHUNK_RAW:
                    if payload_size != chunk_bytes:
                        raise ValueError(f"chunk {index}: invalid RAW size")
                    stats["raw"] += 1
                    remaining = chunk_bytes
                    if source_fd is not None:
                        os.lseek(source_fd, output_offset, os.SEEK_SET)
                    while remaining:
                        count = min(COPY_SIZE, remaining)
                        data = read_exact(sparse, count)
                        digest.update(data)
                        if source_fd is not None:
                            expected = os.read(source_fd, count)
                            if expected != data:
                                raise ValueError(
                                    f"RAW source mismatch at byte {output_offset + chunk_bytes - remaining}"
                                )
                        if output is not None:
                            output.write(data)
                        remaining -= count
                    defined_bytes += chunk_bytes
                    output_offset += chunk_bytes
                elif chunk_type == CHUNK_FILL:
                    if payload_size != 4:
                        raise ValueError(f"chunk {index}: invalid FILL size")
                    fill = read_exact(sparse, 4)
                    digest.update(fill)
                    stats["fill"] += 1
                    remaining = chunk_bytes
                    if source_fd is not None:
                        os.lseek(source_fd, output_offset, os.SEEK_SET)
                    while remaining:
                        count = min(COPY_SIZE, remaining)
                        data = (fill * ((count + 3) // 4))[:count]
                        if source_fd is not None and os.read(source_fd, count) != data:
                            raise ValueError(f"FILL source mismatch at byte {output_offset}")
                        if output is not None:
                            output.write(data)
                        remaining -= count
                    defined_bytes += chunk_bytes
                    output_offset += chunk_bytes
                elif chunk_type == CHUNK_DONT_CARE:
                    if payload_size != 0:
                        raise ValueError(f"chunk {index}: invalid DONT_CARE size")
                    stats["dont_care"] += 1
                    if source_fd is not None:
                        checked_zero_bytes += check_zero_extent(
                            source_fd, output_offset, output_offset + chunk_bytes
                        )
                    if output is not None:
                        output.seek(chunk_bytes, os.SEEK_CUR)
                    output_offset += chunk_bytes
                elif chunk_type == CHUNK_CRC32:
                    if payload_size != 4 or chunk_blocks != 0:
                        raise ValueError(f"chunk {index}: invalid CRC32 size")
                    digest.update(read_exact(sparse, 4))
                    stats["crc32"] += 1
                else:
                    raise ValueError(f"chunk {index}: unknown type 0x{chunk_type:04x}")

            expected_bytes = total_blocks * block_size
            if output_offset != expected_bytes:
                raise ValueError(
                    f"logical size mismatch: chunks={output_offset}, header={expected_bytes}"
                )
            if sparse.read(1):
                raise ValueError("trailing bytes after final sparse chunk")
            if source_fd is not None and os.fstat(source_fd).st_size != expected_bytes:
                raise ValueError("source raw logical size differs from sparse output size")
            if output is not None:
                output.truncate(expected_bytes)
                output.flush()
                os.fsync(output.fileno())

        print(f"PASS sparse_sha256={digest.hexdigest()}")
        print(
            f"logical_bytes={output_offset} block_size={block_size} "
            f"total_blocks={total_blocks} chunks={total_chunks}"
        )
        print(
            "chunk_counts=" + ",".join(f"{key}:{value}" for key, value in stats.items())
        )
        print(
            f"defined_bytes={defined_bytes} checked_allocated_zero_bytes={checked_zero_bytes} "
            f"header_checksum=0x{image_checksum:08x} version={major}.{minor}"
        )
        return 0
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        if output is not None:
            output.close()
        if source_fd is not None:
            os.close(source_fd)


if __name__ == "__main__":
    raise SystemExit(main())
