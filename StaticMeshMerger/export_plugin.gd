@tool
extends EditorExportPlugin

const EXCLUDED_PREFIX := "res://merge_backups/"

func _get_name() -> String:
	return "MeshMergerExportPlugin"

func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	if path.begins_with(EXCLUDED_PREFIX):
		skip()
