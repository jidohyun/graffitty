extends RefCounted
## Packets: 4-byte magic, uint32 LE JSON-header length, small JSON metadata,
## then binary UTF-8 VT presentation or raw terminal input. No object
## decoding. Version 1 carries stable session IDs and session metadata.
##
## Network messages after login remain encrypted, with Chromium frame
## acknowledgements.
class Packet extends RefCounted:
	var header: Dictionary
	var header_json: String
	var payload: PackedByteArray

const VERSION := 1
const MAGIC := 0x32545247 # GRT2
const MAX_HEADER := 65536
const MAX_PACKET := 8388608


# Scene ownership releases native helpers before extension teardown.
static func _core() -> RefCounted:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_protocol_core"):
		owner.set_meta("graffitty_protocol_core", ClassDB.instantiate("RemoteClientCore"))
	return owner.get_meta("graffitty_protocol_core")

static func pack(header: Dictionary, payload: PackedByteArray) -> PackedByteArray:
	return _core().pack(JSON.stringify(header), payload)

static func unpack(packet: PackedByteArray) -> Packet:
	var wire: Dictionary = _core().unpack(packet)
	if wire.is_empty(): return null
	var decoded := Packet.new()
	decoded.header_json = wire.header_json
	decoded.header = wire.header
	decoded.payload = wire.payload
	return decoded
