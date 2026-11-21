extends "res://tests/unit/test_case.gd"
const Search := preload("res://scenes/TabListSearch.gd")

func items() -> Array:
	return [
		{"id": 40, "title": "Backend", "panes": [{"key": "%7", "title": "API server", "ordinal": 1}, {"key": "%9", "title": "Database migration", "ordinal": 2}]},
		{"id": 10, "title": "Docs", "panes": [{"key": "%3", "title": "Chromium preview", "ordinal": 1}]},
	]

func test_search_groups_panes_under_their_original_tab() -> void:
	var model := Search.new()
	var rows := model.filter(items(), "dtbsmgr")
	expect(rows.size() == 2, "A fuzzy pane match includes its tab and matching pane only")
	if rows.size() != 2: return
	expect(rows[0].id == 40 and rows[0].kind == "tab", "The owning tab remains visible")
	expect(rows[1].pane_key == "%9" and rows[1].pane_ordinal == 2, "The matched pane keeps its stable identity and ordinal")
	var matched := ""
	for index in rows[1].match_indices: matched += str(rows[1].title)[index].to_lower()
	expect(matched == "dtbsmgr", "Highlight the same nonconsecutive characters that produced the fuzzy match")
	expect(not rows[0].has("match_indices"), "An owning tab does not claim its child's match")
	expect(model.preferred == "pane:%9", "Enter can focus the actual pane that matched")
	rows = model.filter(items(), "docs")
	expect(rows.size() == 1 and rows[0].ordinal == 2 and rows[0].id == 10, "A filtered tab keeps its original number")

func test_clearing_search_removes_pane_rows_and_unmatched_input_is_empty() -> void:
	var model := Search.new()
	model.filter(items(), "preview")
	var rows := model.filter(items(), "")
	expect(rows.size() == 2 and rows.all(func(row): return row.kind == "tab"), "Pane details exist only during search")
	expect(rows[0].id == 40 and rows[1].id == 10, "Clearing preserves workspace order rather than ID order")
	expect(model.filter(items(), "zzzzzzzzzz").is_empty(), "No match does not fall back to all tabs")

func test_search_keeps_typo_matches_and_highlights_the_actual_characters() -> void:
	var model := Search.new()
	var tabs := [
		{"id": 8, "title": "HTTP request · a visual explanation", "panes": [
			{"key": "%8", "title": "Explain an HTTP request with a diagram in graffitty chromium.", "ordinal": 1},
			{"key": "%10", "title": "HTTP request · a visual explanation", "ordinal": 2}]},
		{"id": 11, "title": "Task list", "panes": [
			{"key": "%11", "title": "Use graffitty chromium to run the button test", "ordinal": 1},
			{"key": "%12", "title": "Use graffitty chromium to run the E2E test", "ordinal": 2}]},
	]
	var rows := model.filter(tabs, "HTTP")
	expect(rows.size() > 3 and rows[0].id == 8,
		"Exact HTTP matches rank first while typo-tolerant pane matches remain available")
	var partial_matches := 0
	for row in rows:
		if not row.has("match_indices"): continue
		var matched := ""
		for index in row.match_indices:
			expect(index >= 0 and index < str(row.title).length(), "Highlights refer to characters in the displayed title")
			matched += str(row.title)[index].to_upper()
		if row.id == 8:
			expect(matched == "HTTP", "Exact matches highlight the entire query")
		elif row.kind == "pane":
			partial_matches += 1
			expect(not matched.is_empty() and matched != "HTTP", "Typo matches highlight only the characters actually matched")
	expect(partial_matches > 0, "Typo tolerance includes titles missing a query character")

func test_refresh_uses_updated_titles_and_unicode_without_stale_matches() -> void:
	var model := Search.new()
	var tabs := items()
	model.filter(tabs, "Database")
	tabs[0].panes[1].title = "데이터 로그"
	var rows := model.filter(tabs, "데이터")
	expect(rows.size() == 2 and rows[1].pane_key == "%9", "Unicode pane titles use the same ranker")
	expect(rows[1].match_indices == PackedInt32Array([0, 1, 2]), "Highlight indices are Unicode characters, not UTF-8 bytes")
	tabs[0].panes.remove_at(1)
	expect(model.filter(tabs, "데이터").is_empty(), "Closing a pane removes its search candidate")

func test_default_shortcut_uses_v_and_can_be_remapped() -> void:
	var settings := preload("res://graffitty/config.gd").PrefixSettings.new()
	expect(settings.bindings.get(KEY_V) == "ShowAllTabs", "V opens the down-arrow menu")
	settings.bindings.erase(KEY_V)
	settings.bindings[KEY_G] = "ShowAllTabs"
	expect(settings.validate().is_empty(), "The tab summary action is remappable")
