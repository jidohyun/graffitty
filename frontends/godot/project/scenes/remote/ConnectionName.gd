extends RefCounted

static func display(settings: Dictionary) -> String:
	for field in ["name", "hostname"]:
		var value := str(settings.get(field, "")).strip_edges()
		if not value.is_empty(): return value
	# Until a server identifies itself, use the address's
	# host, without scheme, credentials, port or path. Preserve its spelling.
	var address := str(settings.get("url", ""))
	var authority := address.get_slice("://", 1).get_slice("/", 0).get_slice("?", 0).get_slice("#", 0)
	authority = authority.get_slice("@", authority.get_slice_count("@") - 1)
	if authority.begins_with("["):
		var end := authority.find("]")
		if end > 0: return authority.substr(1, end - 1)
	var host := authority.get_slice(":", 0)
	return host if not host.is_empty() else address

## Display only: keep paths/custom ports and IPv6 brackets; never change the
## canonical endpoint used by authentication or the credential store.
static func address(settings: Dictionary) -> String:
	var url := str(settings.get("url", ""))
	var text := url.trim_prefix("ws://").trim_prefix("wss://")
	var authority := text.get_slice("/", 0)
	var suffix := text.substr(authority.length())
	if authority.ends_with("]") or ":" not in authority:
		authority += ":443" if url.begins_with("wss://") else ":80"
	return authority + ("" if suffix == "/" else suffix)
