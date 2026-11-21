extends "res://tests/unit/test_case.gd"
const RecordScript := preload("res://scenes/RecordScript.gd")


func test_reads_the_record_script_option() -> void:
	expect(RecordScript.path(PackedStringArray(["--no-config", "--record-script=/tmp/demo/record.gd"])) == "/tmp/demo/record.gd",
		"the option's value is the script path")
	expect(RecordScript.path(PackedStringArray(["--no-config"])) == "", "no option means no script")
	expect(RecordScript.path(PackedStringArray(["--record-script"])) == "", "the bare flag has no path")
