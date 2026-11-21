extends RefCounted
## Group identities and states, keeping individual pane titles in the tooltip.
static func agents(nodes: Array) -> Array:
 var groups := {}
 for node: Dictionary in nodes:
  var provider := str(node.get("provider", ""))
  var manifest: Dictionary = node.get("manifest", {}) if provider not in ["codex", "claude", "opencode", "pi"] else {}
  if (provider.is_empty() or provider == "shell") and manifest.is_empty(): continue
  var status := str(node.get("status", "unknown"))
  if status == "busy": status = "running"
  var key := provider + ":" + status + ":" + str(manifest.get("name", ""))
  if not groups.has(key): groups[key] = {"provider": provider, "manifest": manifest, "status": status, "count": 0, "titles": []}
  groups[key].count += 1
  groups[key].titles.append(str(node.get("title", "")))
 var keys := groups.keys()
 keys.sort()
 return keys.map(func(key): return groups[key])

## Aggregate pane samples without presenting unknown measurements as zero.
static func resources(samples: Array) -> Dictionary:
 var cpu := 0.0
 var memory := 0.0
 var cpus := 0
 var memories := 0
 for data: Dictionary in samples:
  if data.get("status", "starting") != "running": continue
  if data.get("cpu_valid", false): cpu += float(data.get("cpu_percent", 0)); cpus += 1
  if data.get("memory_current") != null and data.get("memory_valid", true): memory += float(data.memory_current); memories += 1
 var cpu_text := "—" if cpus == 0 else ("≥ " if cpus < samples.size() else "") + "%d%%" % roundi(cpu)
 var mib := memory / 1048576.0
 var memory_text := "—" if memories == 0 else ("≥ " if memories < samples.size() else "") + ("%.2f GiB" % (mib / 1024.0) if mib >= 1024 else "%.0f MiB" % mib)
 return {"cpu": cpu_text, "ram": memory_text}
