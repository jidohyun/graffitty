extends SceneTree
const Pieces := preload('res://scenes/CellShatter.gd')
var failures := 0
func check(ok: bool, label: String):
 print('PASS ' if ok else 'FAIL ',label)
 if not ok:failures+=1
func _initialize():
 var letters: Array = []
 for x in 8:letters.append(Vector3i(x,0,1))
 check(Pieces.chunk_cells(letters)==[Vector3i(0,0,3),Vector3i(3,0,3),Vector3i(6,0,2)],'Eight letters become three short runs')
 var mixed: Array = [Vector3i(0,0,2),Vector3i(2,0,2),Vector3i(4,0,1),Vector3i(7,0,1),Vector3i(0,1,1)]
 check(Pieces.chunk_cells(mixed)==[Vector3i(0,0,4),Vector3i(4,0,1),Vector3i(7,0,1),Vector3i(0,1,1)],'Wide glyphs stay whole; spaces and rows split runs')
 var shuffled := letters.duplicate()
 shuffled.reverse()
 check(Pieces.chunk_cells(shuffled).size()==shuffled.size(),'Unexpected ordering stays safe without sorting')
 for width in [2,3,5,8]:
  var chunks: Array = Pieces.chunk_cells(mixed,width)
  var covered := {}
  for chunk in chunks:
   check(chunk.z<=width+1,'Chunk width respects budget without splitting wide glyphs')
   for x in range(chunk.x,chunk.x+chunk.z):
    var key := Vector2i(x,chunk.y)
    check(not covered.has(key),'No cell appears in two chunks')
    covered[key]=true
  var expected := {}
  for cell in mixed:
   for x in range(cell.x,cell.x+cell.z):expected[Vector2i(x,cell.y)]=true
  check(covered==expected,'Every original glyph cell is preserved exactly')
 print('SCATTER_CHUNKS failures=',failures)
 quit(1 if failures else 0)
