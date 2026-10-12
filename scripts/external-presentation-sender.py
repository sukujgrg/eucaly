#!/usr/bin/env python3
"""Reference same-Mac sender for eucaly.presentation.v1 (standard library only)."""
import argparse
import getpass
import json
import socket
import struct
import uuid

PROTOCOL = "eucaly.presentation.v1"
LIMIT = 65536


def identity():
    return str(uuid.uuid4()).upper()


def content(text, reference=None):
    components = [{"id": identity(), "role": "primary", "text": text}]
    if reference:
        components.append({"id": identity(), "role": "reference", "text": reference})
    return {"kind": "scripture", "components": components}


class Sender:
    def __init__(self, port, credential):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.send({"kind": "hello", "protocolVersion": PROTOCOL,
                   "credential": credential, "clientName": "Reference Scripture Sender"})
        self.welcome = self.receive_until(lambda reply: reply["kind"] == "welcome")
        self.lease = None
        self.revision = 0

    def send(self, value):
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if not 0 < len(payload) <= LIMIT:
            raise ValueError("Frame exceeds 64 KiB")
        self.socket.sendall(struct.pack(">I", len(payload)) + payload)

    def exact(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise ConnectionError("Receiver disconnected")
            data.extend(chunk)
        return bytes(data)

    def receive_until(self, predicate):
        while True:
            size = struct.unpack(">I", self.exact(4))[0]
            if not 0 < size <= LIMIT:
                raise ValueError("Invalid receiver frame")
            reply = json.loads(self.exact(size))
            if predicate(reply):
                return reply

    def present(self, current, next_content=None):
        action = identity()
        self.revision = 1
        message = {"kind": "present", "sourceID": identity(), "actionID": action,
                   "revision": self.revision, "current": current}
        if next_content is not None:
            message["next"] = next_content
        self.send(message)
        reply = self.receive_until(lambda item: item.get("actionID") == action)
        if reply["kind"] != "accepted":
            raise RuntimeError(reply.get("detail", "Present rejected"))
        self.lease = reply["lease"]
        return reply

    def state(self, current, lease=None):
        self.revision += 1
        self.send({"kind": "state", "lease": lease or self.lease,
                   "revision": self.revision, "current": current})

    def control(self, kind):
        action = identity()
        self.send({"kind": kind, "actionID": action, "lease": self.lease})
        return self.receive_until(lambda item: item.get("actionID") == action)

    def close(self):
        self.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=49871)
    parser.add_argument("--text", default="For God so loved the world…")
    parser.add_argument("--reference", default="John 3:16")
    parser.add_argument("--demo", action="store_true", help="Exercise burst, Hide, stale rejection, Clear, Release and reconnect")
    args = parser.parse_args()
    credential = getpass.getpass("Receiver credential (Settings > Receiver > Copy): ")
    sender = Sender(args.port, credential)
    try:
        print("Authenticated; profiles:", ", ".join(item["name"] for item in sender.welcome["profiles"]))
        print("Present accepted:", sender.present(content(args.text, args.reference))["actionID"])
        if args.demo:
            for index in range(1000):
                sender.state(content(f"Live update {index}"))
            sender.receive_until(lambda item: item.get("revision") == sender.revision)
            old_lease = sender.lease
            print("Hide:", sender.control("hide")["kind"])
            sender.state(content("Must be rejected"), lease=old_lease)
            print("Stale update:", sender.receive_until(lambda item: item.get("revision") == sender.revision)["kind"])
            sender.present(content(args.text, args.reference))
            input("Press Show Slides in eucaly, then press Return to test local takeover: ")
            sender.state(content("Must not replace local Current"))
            print("After local takeover:", sender.receive_until(lambda item: item.get("revision") == sender.revision)["kind"])
            sender.present(content(args.text, args.reference))
            print("Clear:", sender.control("clear")["kind"])
            sender.present(content(args.text, args.reference))
            print("Release:", sender.control("release")["kind"])
            sender.close()
            sender = Sender(args.port, credential)
            print("Reconnected for discovery only; no Present sent.")
        input("Press Return to disconnect: ")
    finally:
        sender.close()


if __name__ == "__main__":
    main()
