#!/usr/bin/env python3
"""Read-only Service Registry Locator query over AF_QIPCRTR.

This helper can only send message 0x21 (Get Domain List) to an explicitly
provided service-64 endpoint.  It prints the common result, advertised count,
database revision, and printable domain names from the returned list blob.
"""

import argparse
import socket
import struct
import sys
import time


SERVREG_GET_DOMAIN_LIST = 0x21
QMI_REQUEST = 0x00
QMI_RESPONSE = 0x02


def encode_request(transaction, service):
    name = service.encode("ascii")
    if not name or len(name) > 255:
        raise ValueError("service must contain 1..255 ASCII bytes")
    payload = struct.pack("<BH", 0x01, len(name)) + name
    return struct.pack(
        "<BHHH", QMI_REQUEST, transaction, SERVREG_GET_DOMAIN_LIST, len(payload)
    ) + payload


def parse_tlvs(payload):
    tlvs = {}
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < 3:
            raise ValueError("truncated TLV header")
        tlv_type, tlv_len = struct.unpack_from("<BH", payload, offset)
        offset += 3
        if len(payload) - offset < tlv_len:
            raise ValueError("truncated TLV value")
        if tlv_type in tlvs:
            raise ValueError(f"duplicate TLV 0x{tlv_type:02x}")
        tlvs[tlv_type] = payload[offset : offset + tlv_len]
        offset += tlv_len
    return tlvs


def send_query(node, port, transaction, service, timeout):
    family = getattr(socket, "AF_QIPCRTR", None)
    if family is None:
        raise RuntimeError("Python has no AF_QIPCRTR support")

    request = encode_request(transaction, service)
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
            flags, rx_transaction, message_id, payload_len = struct.unpack_from(
                "<BHHH", data, 0
            )
            if rx_transaction != transaction or message_id != SERVREG_GET_DOMAIN_LIST:
                continue
            if flags != QMI_RESPONSE:
                raise ValueError(f"unexpected response flags 0x{flags:02x}")
            if payload_len != len(data) - 7:
                raise ValueError("QMI payload length mismatch")
            return parse_tlvs(data[7:])


def u16_tlv(tlvs, tlv_type, label):
    value = tlvs.get(tlv_type)
    if value is None:
        return None
    if len(value) != 2:
        raise ValueError(f"{label} TLV has length {len(value)}, expected 2")
    return struct.unpack("<H", value)[0]


def parse_domain_list(blob):
    if not blob:
        return []
    count = blob[0]
    offset = 1
    domains = []
    for _index in range(count):
        if offset >= len(blob):
            raise ValueError("truncated domain name length")
        name_len = blob[offset]
        offset += 1
        if len(blob) - offset < name_len + 9:
            raise ValueError("truncated domain list entry")
        name = blob[offset : offset + name_len].decode("ascii")
        offset += name_len
        instance_id = struct.unpack_from("<I", blob, offset)[0]
        offset += 4
        service_data_valid = blob[offset]
        offset += 1
        service_data = struct.unpack_from("<I", blob, offset)[0]
        offset += 4
        domains.append((name, instance_id, service_data_valid, service_data))
    if offset != len(blob):
        raise ValueError(f"trailing domain-list bytes: {len(blob) - offset}")
    return domains


def self_test():
    expected = bytes.fromhex("00014321000e00010b00746d732f73657276726567")
    assert encode_request(0x4301, "tms/servreg") == expected
    sample = bytes.fromhex("0204000000000010020003001102000100")
    tlvs = parse_tlvs(sample)
    assert struct.unpack("<HH", tlvs[2]) == (0, 0)
    assert u16_tlv(tlvs, 0x10, "total_domains") == 3
    assert u16_tlv(tlvs, 0x11, "db_revision") == 1
    blob = bytes.fromhex(
        "01106d736d2f616473702f726f6f745f70644a0000000000000000"
    )
    assert parse_domain_list(blob) == [("msm/adsp/root_pd", 74, 0, 0)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--service", default="tms/servreg")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--raw", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    self_test()
    if args.self_test:
        print("self_test=pass")
        return 0

    tlvs = send_query(args.node, args.port, 0x4301, args.service, args.timeout)
    result_tlv = tlvs.get(0x02)
    if result_tlv is None or len(result_tlv) != 4:
        raise ValueError("missing QMI result TLV")
    result, error = struct.unpack("<HH", result_tlv)
    total = u16_tlv(tlvs, 0x10, "total_domains")
    revision = u16_tlv(tlvs, 0x11, "db_revision")
    blob = tlvs.get(0x12, b"")
    domains = parse_domain_list(blob)

    print(f"service={args.service}")
    print(f"qmi_result={result} error={error}")
    print(f"total_domains={total if total is not None else 'absent'}")
    print(f"db_revision={revision if revision is not None else 'absent'}")
    print(f"domain_list_present={int(0x12 in tlvs)} bytes={len(blob)}")
    print(f"decoded_domains={len(domains)}")
    for index, (name, instance_id, data_valid, data) in enumerate(domains):
        print(
            f"domain[{index}]={name} instance={instance_id} "
            f"service_data_valid={data_valid} service_data={data}"
        )
    if args.raw:
        print(f"domain_list_hex={blob.hex()}")
    return 0 if result == 0 and error == 0 else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"probe_error={type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
