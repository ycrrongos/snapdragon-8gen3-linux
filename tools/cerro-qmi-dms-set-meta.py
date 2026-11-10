#!/usr/bin/env python3
"""Send Cerro's exact stock DMS Meta_Build_ID initialization once.

This is intentionally not a generic QMI writer.  Its only state-changing
request is DMS 0x69 with TLV 0x11 and the exact Meta_Build_ID read from this
phone's modem firmware.  Follow-up requests are read-only DMS state queries.
"""

import argparse
import os
import socket
import struct
import sys
import time


META_BUILD_ID = b"Lanai.LA.1.0.r1-00725-STD.PROD-2.46586.100"
SENT_MARKER = "/tmp/cerro-qmi-dms-set-meta.sent"
QMI_RESULT_NAMES = {0: "success", 1: "failure"}
OPERATING_MODE_NAMES = {
    0: "online",
    1: "low-power",
    2: "factory-test",
    3: "offline",
    4: "resetting",
    5: "shutting-down",
    6: "persistent-low-power",
    7: "mode-only-low-power",
}


def parse_tlvs(payload):
    result = {}
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < 3:
            raise ValueError("truncated TLV header")
        tlv_type, tlv_len = struct.unpack_from("<BH", payload, offset)
        offset += 3
        if len(payload) - offset < tlv_len:
            raise ValueError("truncated TLV value")
        result[tlv_type] = payload[offset : offset + tlv_len]
        offset += tlv_len
    return result


def send_request(node, port, transaction, message_id, payload, timeout):
    family = getattr(socket, "AF_QIPCRTR", None)
    if family is None:
        raise RuntimeError("Python has no AF_QIPCRTR support")

    request = struct.pack("<BHHH", 0x00, transaction, message_id, len(payload)) + payload
    deadline = time.monotonic() + timeout

    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(request, (node, port))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("matching QMI response timed out")
            sock.settimeout(remaining)
            data, _address = sock.recvfrom(4096)
            if len(data) < 7:
                continue
            flags, rx_transaction, rx_message_id, payload_len = struct.unpack_from(
                "<BHHH", data, 0
            )
            if rx_transaction != transaction or rx_message_id != message_id:
                continue
            if flags != 0x02:
                raise ValueError(f"unexpected response flags 0x{flags:02x}")
            if payload_len != len(data) - 7:
                raise ValueError("QMI payload length mismatch")
            return parse_tlvs(data[7:])


def parse_result(tlvs):
    value = tlvs.get(0x02)
    if value is None or len(value) != 4:
        raise ValueError("missing QMI result TLV")
    return struct.unpack("<HH", value)


def query_init_state(node, port, transaction, timeout):
    tlvs = send_request(node, port, transaction, 0x007C, b"", timeout)
    result, error = parse_result(tlvs)
    init_tlv = tlvs.get(0x10)
    fail_tlv = tlvs.get(0x11)
    init_state = (
        str(struct.unpack("<I", init_tlv)[0])
        if init_tlv is not None and len(init_tlv) == 4
        else "absent"
    )
    fail_reason = (
        str(struct.unpack("<I", fail_tlv)[0])
        if fail_tlv is not None and len(fail_tlv) == 4
        else "absent"
    )
    return result, error, init_state, fail_reason


def query_operating_mode(node, port, transaction, timeout):
    tlvs = send_request(node, port, transaction, 0x002D, b"", timeout)
    result, error = parse_result(tlvs)
    mode_tlv = tlvs.get(0x01)
    mode = mode_tlv[0] if mode_tlv is not None and len(mode_tlv) == 1 else None
    return result, error, mode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    if len(META_BUILD_ID) != 42:
        raise RuntimeError("compiled Meta_Build_ID length is not 42")

    try:
        marker_fd = os.open(SENT_MARKER, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError("one-shot marker already exists; refusing a second send")
    else:
        os.write(marker_fd, b"attempted\n")
        os.close(marker_fd)

    payload = struct.pack("<BH", 0x11, len(META_BUILD_ID)) + META_BUILD_ID
    response = send_request(args.node, args.port, 0x6901, 0x0069, payload, args.timeout)
    result, error = parse_result(response)
    print(f"set_meta_qmi_result={QMI_RESULT_NAMES.get(result, result)} error={error}")
    if result or error:
        return 2

    for poll_index, delay in enumerate((0, 1, 2, 4), start=1):
        if delay:
            time.sleep(delay)
        result, error, init_state, fail_reason = query_init_state(
            args.node, args.port, 0x7000 + poll_index, args.timeout
        )
        print(
            f"poll={poll_index} init_qmi_result={QMI_RESULT_NAMES.get(result, result)} "
            f"error={error} init_state={init_state} fail_reason={fail_reason}"
        )

    result, error, mode = query_operating_mode(
        args.node, args.port, 0x7101, args.timeout
    )
    mode_text = "absent" if mode is None else f"{OPERATING_MODE_NAMES.get(mode, 'unknown')}({mode})"
    print(
        f"final_mode_qmi_result={QMI_RESULT_NAMES.get(result, result)} "
        f"error={error} operating_mode={mode_text}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"set_meta_error={type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
