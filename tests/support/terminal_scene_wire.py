"""Current terminal scene/asset assembly for protocol tests and benchmarks."""
import json


class Scenes:
    def __init__(self):
        self.pending = {}
        self.text = {}
        self.graphics = {}
        self.assets = {}
        self.requested = set()

    @staticmethod
    def key(value):
        return json.dumps(value, sort_keys=True)

    def receive(self, header, payload, send):
        kind = header.get("type")
        if kind == "terminal":
            session, tx = header["session"], header["scene"]
            if tx["offset"] == 0:
                self.pending[session] = bytearray()
            data = self.pending[session]
            assert len(data) == tx["offset"]
            data.extend(payload)
            if not tx["commit"]:
                return
            assert len(data) == tx["total"]
            boundary = tx["total"] - tx["graphics_bytes"]
            if tx["snapshot"]:
                self.text[session] = bytearray()
            self.text.setdefault(session, bytearray()).extend(data[:boundary])
            if tx["graphics_bytes"]:
                graphics = json.loads(data[boundary:])
                self.graphics[session] = graphics
                for image in graphics["images"]:
                    key = (session, self.key(image["asset"]))
                    if key not in self.requested:
                        self.requested.add(key)
                        send(dict(type="terminal_asset_request", session=session, asset=image["asset"]))
            del self.pending[session]
        elif kind == "terminal_asset":
            asset = header["asset"]
            key = (header["session"], self.key(asset["asset"]))
            if asset["offset"] == 0:
                self.assets[key] = (asset, bytearray())
            first, data = self.assets[key]
            assert len(data) == asset["offset"] and first["total"] == asset["total"]
            data.extend(payload)
            assert len(data) <= asset["total"]

    def image(self, session, image_id):
        for image in self.graphics.get(session, {}).get("images", []):
            if image["id"] == image_id:
                asset = self.assets.get((session, self.key(image["asset"])))
                if asset and len(asset[1]) == asset[0]["total"]:
                    return asset
        return None
