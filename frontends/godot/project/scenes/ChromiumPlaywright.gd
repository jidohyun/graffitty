extends Node
## The shared session owner owns the lease, loopback endpoint and CDP routing.
## This adapter only binds workspace authorization/revocation to that owner.
var chromium: Node
var lease := ""
var opening := false
var generation := 0


func attach() -> Dictionary:
	if opening:
		return {"error": {"code": "chromium_busy", "message": "A Playwright attachment is opening"}}
	opening = true
	var started := generation
	var result: Dictionary = await chromium.request("chromium.attach")
	opening = false
	if result.get("result") is Dictionary:
		var issued := str(result.result.get("lease", ""))
		if started != generation or not is_inside_tree():
			chromium.request("chromium.detach", {"lease": issued})
			return {"error": {"code": "unauthorized", "message": "Attachment authority was revoked"}}
		lease = issued
	return result


func release() -> void:
	generation += 1
	var released := lease
	lease = ""
	if not released.is_empty() and is_instance_valid(chromium):
		chromium.request("chromium.detach", {"lease": released})


func _exit_tree() -> void:
	release()
