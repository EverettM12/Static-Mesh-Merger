@tool
extends EditorPlugin

const MeshMergerUtils = preload("res://addons/mergingmeshes/merge_utils.gd")
const MeshMergerExportPlugin = preload("res://addons/mergingmeshes/export_plugin.gd")

const MESHES_DIR = "res://meshes/"
const BACKUPS_DIR = "res://merge_backups/"

var export_plugin : EditorExportPlugin

var merge_button : Button

func _enter_tree() -> void:
	merge_button = Button.new()
	merge_button.text = "Merge Selected"
	merge_button.tooltip_text = "Merge selected MeshInstance3D nodes into one baked mesh (originals are backed up)."
	merge_button.pressed.connect(_on_merge_selected)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, merge_button)

	export_plugin = MeshMergerExportPlugin.new()
	add_export_plugin(export_plugin)

func _exit_tree() -> void:
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, merge_button)
	merge_button.queue_free()
	merge_button = null

	remove_export_plugin(export_plugin)
	export_plugin = null

func _on_merge_selected() -> void:
	var editor_selection = get_editor_interface().get_selection()
	var selected = editor_selection.get_selected_nodes()
	if selected.is_empty():
		push_warning("MeshMerger: select at least one node to merge.")
		return

	var edited_root = get_editor_interface().get_edited_scene_root()
	if edited_root == null:
		push_warning("MeshMerger: no scene is currently open.")
		return

	selected = _filter_top_level_selection(selected)

	var source_meshes : Array[MeshInstance3D] = []
	var nodes_to_delete : Array[Node] = []
	var target_parent : Node = null

	for node in selected:
		if node != edited_root and node.owner != edited_root:
			push_warning("MeshMerger: skipping '%s' — belongs to an instanced sub-scene." % node.name)
			continue

		if node == edited_root:
			for descendant in node.find_children("*", "MeshInstance3D", true, false):
				if descendant is MeshInstance3D and not source_meshes.has(descendant):
					source_meshes.append(descendant)
					nodes_to_delete.append(descendant)
			target_parent = edited_root
			continue

		if target_parent == null:
			target_parent = node.get_parent()
		if node is MeshInstance3D and not source_meshes.has(node):
			source_meshes.append(node)
		for descendant in node.find_children("*", "MeshInstance3D", true, false):
			if descendant is MeshInstance3D and not source_meshes.has(descendant):
				source_meshes.append(descendant)
		nodes_to_delete.append(node)

	if source_meshes.is_empty():
		push_warning("MeshMerger: no MeshInstance3D found in selection.")
		return
	if target_parent == null:
		target_parent = edited_root

	var dt = Time.get_datetime_dict_from_system()
	var timestamp = "%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var base_name = String(nodes_to_delete[0].name)

	var backup_root = Node3D.new()
	backup_root.name = "%s_backup" % base_name
	for node in nodes_to_delete:
		if node.get_parent() == null:
			continue
		var dup : Node = node.duplicate()
		if dup is Node3D and node is Node3D:
			dup.transform = node.global_transform
		backup_root.add_child(dup)
		dup.owner = backup_root
		MeshMergerUtils.set_owner_recursive(dup, backup_root)

	var backup_packed = PackedScene.new()
	var pack_err = backup_packed.pack(backup_root)
	backup_root.free()

	if pack_err != OK:
		push_error("MeshMerger: failed to pack backup scene (error %d) — aborting, nothing was changed." % pack_err)
		return

	DirAccess.make_dir_recursive_absolute(BACKUPS_DIR)
	var backup_path = "%s%s_%s.tscn" % [BACKUPS_DIR, base_name, timestamp]
	var backup_save_err = ResourceSaver.save(backup_packed, backup_path)
	if backup_save_err != OK:
		push_error("MeshMerger: failed to save backup scene (error %d) — aborting, nothing was changed." % backup_save_err)
		return
	print("MeshMerger: backup saved to ", backup_path)

	var merged_mesh = MeshMergerUtils.merge_multiple_meshes(source_meshes)
	DirAccess.make_dir_recursive_absolute(MESHES_DIR)
	var mesh_path = "%s%s_%s.res" % [MESHES_DIR, base_name, timestamp]
	var mesh_save_err = ResourceSaver.save(merged_mesh, mesh_path)
	if mesh_save_err != OK:
		push_error("MeshMerger: failed to save merged mesh (error %d) — aborting, nothing was changed." % mesh_save_err)
		return
	print("MeshMerger: merged mesh saved to ", mesh_path)

	for node in nodes_to_delete:
		if node.get_parent() == null:
			continue
		node.get_parent().remove_child(node)
		node.queue_free()

	var new_instance = MeshInstance3D.new()
	new_instance.name = "%s_merged" % base_name
	new_instance.mesh = load(mesh_path)
	target_parent.add_child(new_instance)
	new_instance.owner = edited_root
	new_instance.global_transform = Transform3D.IDENTITY

	editor_selection.clear()
	editor_selection.add_node(new_instance)

	print("MeshMerger: merged %d source meshes into '%s'." % [source_meshes.size(), new_instance.name])


func _filter_top_level_selection(nodes: Array[Node]) -> Array[Node]:
	var result : Array[Node] = []
	for node in nodes:
		var nested = false
		for other in nodes:
			if other != node and _is_descendant_of(node, other):
				nested = true
				break
		if not nested:
			result.append(node)
	return result


func _is_descendant_of(node: Node, maybe_ancestor: Node) -> bool:
	var p = node.get_parent()
	while p != null:
		if p == maybe_ancestor:
			return true
		p = p.get_parent()
	return false
