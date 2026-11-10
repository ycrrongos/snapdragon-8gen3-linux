#!/usr/bin/env python3
"""Minimal read-only QMI/DMS probes over AF_QIPCRTR.

This intentionally supports only two empty-body GET requests:
  0x2d: Get Operating Mode (known framing check)
  0x7c: Get Device Initialization State (Cerro vendor DMS extension)
"""

import argparse
import socket
import struct
import sys
import time


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


def send_empty_request(node, port, transaction, message_id, timeout):
    family = getattr(socket, "AF_QIPCRTR", None)
    if family is None:
        raise RuntimeError("Python has no AF_QIPCRTR support")

    request = struct.pack("<BHHH", 0x00, transaction, message_id, 0)
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
    result, error = struct.unpack("<HH", value)
    return result, error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    operating = send_empty_request(args.node, args.port, 0x4301, 0x002D, args.timeout)
    result, error = parse_result(operating)
    mode_tlv = operating.get(0x01)
    if result or error or mode_tlv is None or len(mode_tlv) != 1:
        raise RuntimeError(f"operating-mode query failed: result={result} error={error}")
    mode = mode_tlv[0]
    print(f"operating_mode={OPERATING_MODE_NAMES.get(mode, 'unknown')}({mode})")

    state = send_empty_request(args.node, args.port, 0x4302, 0x007C, args.timeout)
    result, error = parse_result(state)
    print(f"device_state_qmi_result={QMI_RESULT_NAMES.get(result, result)} error={error}")
    if result or error:
        return 2

    init_tlv = state.get(0x10)
    fail_tlv = state.get(0x11)
    print(
        "device_init_state="
        + (str(struct.unpack("<I", init_tlv)[0]) if init_tlv and len(init_tlv) == 4 else "absent")
    )
    print(
        "device_fail_reason="
        + (str(struct.unpack("<I", fail_tlv)[0]) if fail_tlv and len(fail_tlv) == 4 else "absent")
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"probe_error={type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
