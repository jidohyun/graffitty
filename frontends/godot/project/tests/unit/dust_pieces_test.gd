extends "res://tests/unit/test_case.gd"
const Dust := preload("res://scenes/DustPieces.gd")
const Pieces := preload("res://scenes/CellShatter.gd")
class Grid extends Node:
 var cell_padding := 0.0
 var glyphs: Array = []
 func cell_glyphs() -> Array: return glyphs
 func get_cell_size() -> Vector2: return Vector2(8,16)

func test_every_letter_is_partitioned_and_shares_its_scatter_cohort() -> void:
 var term := Grid.new()
 for i in 100: term.glyphs.append({"col": i*2, "row": 0, "wide": true})
 var cells := Dust.cells(term, 192)
 expect(cells.size() == 100, "No glyph is dropped to satisfy a sparse particle budget")
 var x := PackedFloat32Array()
 for cell in cells: x.append(cell.x)
 var ranks := Pieces.release_ranks(x, 19)
 var dust := Dust.particles(term,Rect2(0,0,1600,16),cells,3200,ranks,0.0)
 var per_letter: int = dust.rects.size()/cells.size()
 var cohorts := [0,0,0]
 for i in cells.size():
  var area := 0.0
  for j in per_letter:
   var r: Rect2 = dust.rects[i*per_letter+j]
   area += r.get_area()
   expect(dust.ranks[i*per_letter+j] == ranks[i], "All fragments detach with their parent letter")
  expect(is_equal_approx(area,256.0), "Fragments cover a complete wide glyph without a dissolve overlay")
  cohorts[0 if ranks[i]<.2 else (1 if ranks[i]<.8 else 2)] += 1
 expect(cohorts == [20,60,20], "Exact original scatter cohort proportions")
 for i in cells.size():
  if ranks[i] < .2: expect(cells[i].x >= 99, "First cohort is biased to the occupied right half")
 expect(Dust.letters(cells, 0.3).size() == 30, "Exactly 30 percent of glyphs remain whole")
 expect(Dust.letters(cells, 0.3) == Dust.letters(cells, 0.3), "Both layers choose the identical stable random partition")
 var hybrid := Dust.particles(term,Rect2(0,0,1600,16),cells,3200,ranks,0.3)
 expect(hybrid.rects.size() == dust.rects.size() - 30*per_letter, "Hybrid removes complete flying glyphs from the particle layer")
 term.free()

func test_empty_text_and_effect_configuration() -> void:
 var term := Grid.new()
 expect(Dust.particles(term,Rect2(0,0,80,40),[],32768,PackedFloat32Array()).rects.is_empty(), "No fabricated cloud for empty text")
 term.free()
 var effects = preload("res://scenes/Effects.gd").new()
 expect(effects.scene.session_switch.effect == "fly_away_and_in", "Two-way flight is the session default")
 expect(effects.scene.tab_switch.effect == "push_pull", "Tabs default to zoom")
 expect(effects.scene.session_switch.dust_particles == 32768, "Actual glyph fragments have a suitable default budget")

func test_density_adjusts_whole_letters_without_losing_the_partition() -> void:
 var previous := 1.0
 for count in [0, 20, 60, 200, 600, 1200, 2400]:
  var ratio := Dust.flying_ratio(count)
  expect(ratio <= previous + 0.000001 and ratio >= 0.1 - 0.000001 and ratio <= 0.5 + 0.000001, "Density smoothly reduces the whole-letter share")
  previous = ratio
 expect(is_equal_approx(Dust.flying_ratio(20), 0.5), "Sparse text flies half its characters")
 expect(is_equal_approx(Dust.flying_ratio(1200), 0.1), "Dense text flies one tenth of its characters")
 expect(is_equal_approx(Dust.flying_ratio(5000), 0.1), "Very dense text keeps the configured lower endpoint")
 expect(is_equal_approx(Dust.flying_ratio(10, 0.8, 0.2, 400), 0.8), "Sparse endpoint is configurable")
 expect(is_equal_approx(Dust.flying_ratio(400, 0.8, 0.2, 400), 0.2), "Density scale and dense endpoint are configurable")
 var term := Grid.new()
 for i in 100: term.glyphs.append({"col": i, "row": 0})
 var cells := Dust.cells(term, 400)
 var ranks := PackedFloat32Array()
 ranks.resize(cells.size())
 for ratio in [0.0, 0.1, 0.5, 1.0]:
  var whole := Dust.letters(cells, ratio)
  var particles := Dust.particles(term, Rect2(0, 0, 800, 16), cells, 400, ranks, ratio)
  var areas := {}
  for rect: Rect2 in particles.rects:
   var column := floori(rect.position.x / 8.0)
   areas[column] = float(areas.get(column, 0.0)) + rect.get_area()
  expect(whole.size() == roundi(100 * ratio), "Flying layer uses the requested share")
  for cell in cells:
   expect(is_equal_approx(float(areas.get(cell.x, 0.0)), 0.0 if cell in whole else 128.0), "Each glyph is either complete dust or one whole letter, never both")
 term.free()

func test_flying_share_settings_validate_before_use() -> void:
 var effects = preload("res://scenes/Effects.gd").new()
 for key in ["fly_ratio_sparse", "fly_ratio_dense"]:
  effects.set_option("scene.session_switch", key, 0.25)
  expect(effects.scene.session_switch[key] == 0.25, "Valid ratio is accepted")
  effects.set_option("scene.session_switch", key, 1.1)
  expect(effects.scene.session_switch[key] == 0.25, "Invalid ratio preserves the last valid setting")
 effects.set_option("scene.session_switch", "fly_dense_count", 500)
 expect(effects.scene.session_switch.fly_dense_count == 500, "Density count is accepted")
 effects.set_option("scene.session_switch", "fly_dense_count", 0)
 expect(effects.scene.session_switch.fly_dense_count == 500, "Zero density is rejected")
