@tool
extends EditorPlugin

const MeshMergerUtils = preload("res://addons/mergingmeshes/merge_utils.gd")
const MeshMergerExportPlugin = preload("res://addons/mergingmeshes/export_plugin.gd")

const MESHES_DIR = "res://meshes/"
const BACKUPS_DIR = "res://merge_backups/"

var export_plugin: EditorExportPlugin
var merge_button: Button
var collision_button: Button

var confirmation_dialog: ConfirmationDialog
var pending_selection: Array[Node] = []

func _enter_tree() -> void:
	merge_button = Button.new()
	merge_button.text = "Merge Selected"
	merge_button.tooltip_text = ("Merge selected meshes and preserve their existing collision " + "hierarchies under the merged mesh.")
	merge_button.pressed.connect(_on_merge_selected)

	add_control_to_container(
		EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU,
		merge_button
	)

	collision_button = Button.new()
	collision_button.text = "Create Collision"
	collision_button.tooltip_text = "Create StaticBody3D + CollisionShape3D for each selected MeshInstance3D."
	collision_button.pressed.connect(_on_create_collision_selected)

	add_control_to_container(
		EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU,
		collision_button
	)

	confirmation_dialog = ConfirmationDialog.new()
	confirmation_dialog.title = "Confirm Mesh Merge"
	confirmation_dialog.ok_button_text = "Merge"
	confirmation_dialog.cancel_button_text = "Cancel"
	confirmation_dialog.confirmed.connect(_on_merge_confirmation)

	add_child(confirmation_dialog)

	export_plugin = MeshMergerExportPlugin.new()
	add_export_plugin(export_plugin)

func _exit_tree() -> void:
	if merge_button:
		remove_control_from_container(
			EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU,
			merge_button
		)

		merge_button.queue_free()
		merge_button = null

	if collision_button:
		remove_control_from_container(
			EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU,
			collision_button
		)

		collision_button.queue_free()
		collision_button = null

	if export_plugin:
		remove_export_plugin(export_plugin)
		export_plugin = null

	if confirmation_dialog:
		confirmation_dialog.queue_free()
		confirmation_dialog = null

func _on_create_collision_selected() -> void:
	var editor_selection = get_editor_interface().get_selection()
	var selected_nodes = editor_selection.get_selected_nodes()
	var edited_root = get_editor_interface().get_edited_scene_root()

	if edited_root == null:
		push_warning(
			"MeshMerger: no scene is currently open."
		)
		return

	var meshes_to_process: Array[MeshInstance3D] = []

	for node in selected_nodes:
		if not node is MeshInstance3D:
			continue

		var mesh_instance = node as MeshInstance3D

		if not meshes_to_process.has(mesh_instance):
			meshes_to_process.append(mesh_instance)

	if meshes_to_process.is_empty():
		push_warning(
			"MeshMerger: select one or more MeshInstance3D nodes to create collision."
		)
		return

	var undo_redo = get_undo_redo()
	var meshes_created: Array[Array] = []
	var shape_cache: Dictionary = {}
	var skipped_existing := 0
	var skipped_invalid := 0
	var skipped_instanced := 0

	for mesh_instance in meshes_to_process:
		if not is_instance_valid(mesh_instance):
			skipped_invalid += 1
			continue

		if mesh_instance != edited_root and mesh_instance.owner != edited_root:
			push_warning(
				"MeshMerger: skipping '%s' — belongs to an instanced sub-scene."
				% mesh_instance.name
			)
			skipped_instanced += 1
			continue

		if mesh_instance.mesh == null:
			push_warning(
				"MeshMerger: skipping '%s' — no mesh resource is assigned."
				% mesh_instance.name
			)
			skipped_invalid += 1
			continue

		if _has_direct_static_body(mesh_instance):
			skipped_existing += 1
			continue

		var mesh_resource: Mesh = mesh_instance.mesh
		var collision_shape: Shape3D

		if shape_cache.has(mesh_resource):
			collision_shape = shape_cache[mesh_resource]
		else:
			collision_shape = mesh_resource.create_trimesh_shape()

			if collision_shape == null:
				push_warning(
					"MeshMerger: failed to create trimesh collision for '%s'."
					% mesh_instance.name
				)
				skipped_invalid += 1
				continue

			shape_cache[mesh_resource] = collision_shape

		var body = StaticBody3D.new()
		body.name = "StaticBody3D"

		var shape_node = CollisionShape3D.new()
		shape_node.name = "CollisionShape3D"
		shape_node.shape = collision_shape

		body.add_child(shape_node)

		meshes_created.append([
			mesh_instance,
			body
		])

	if meshes_created.is_empty():
		print(
			"MeshMerger: no collision shapes created. Existing: %d, invalid: %d, instanced: %d."
			% [
				skipped_existing,
				skipped_invalid,
				skipped_instanced
			]
		)
		return

	undo_redo.create_action(
		"Create Mesh Collision Shapes"
	)

	for pair in meshes_created:
		var mesh_instance: MeshInstance3D = pair[0]
		var body: StaticBody3D = pair[1]

		undo_redo.add_do_method(
			self,
			"_add_collision_body",
			mesh_instance,
			body,
			edited_root
		)
		undo_redo.add_undo_method(
			self,
			"_remove_collision_body",
			body
		)
		undo_redo.add_do_reference(body)

	undo_redo.commit_action()

	print(
		"MeshMerger: created collision for %d selected MeshInstance3D nodes."
		% meshes_created.size()
	)

	if skipped_existing > 0:
		print(
			"MeshMerger: skipped %d nodes that already have a StaticBody3D child."
			% skipped_existing
		)

	if skipped_invalid > 0:
		print(
			"MeshMerger: skipped %d invalid or meshless nodes."
			% skipped_invalid
		)

	if skipped_instanced > 0:
		print(
			"MeshMerger: skipped %d nodes belonging to instanced sub-scenes."
			% skipped_instanced
		)

func _add_collision_body(
	mesh_instance: MeshInstance3D,
	body: StaticBody3D,
	edited_root: Node
) -> void:
	if not is_instance_valid(mesh_instance):
		return

	if not is_instance_valid(body):
		return

	if body.get_parent() != null:
		return

	mesh_instance.add_child(body)
	body.owner = edited_root

	var shape_node = body.get_node_or_null("CollisionShape3D")

	if shape_node != null:
		shape_node.owner = edited_root

func _remove_collision_body(body: StaticBody3D) -> void:
	if not is_instance_valid(body):
		return

	var parent = body.get_parent()

	if parent != null:
		parent.remove_child(body)

func _has_direct_static_body(mesh_instance: MeshInstance3D) -> bool:
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			return true

	return false

func _on_merge_selected() -> void:
	var editor_selection = get_editor_interface().get_selection()
	var selected_nodes = editor_selection.get_selected_nodes()

	if selected_nodes.is_empty():
		push_warning(
			"MeshMerger: select at least one node to merge."
		)
		return

	var selected = _filter_top_level_selection(selected_nodes)

	if selected.is_empty():
		push_warning(
			"MeshMerger: no valid nodes selected."
		)
		return

	if selected.size() == 1 or selected.size() > 10:
		pending_selection.clear()

		for node in selected:
			pending_selection.append(node)

		if selected.size() == 1:
			confirmation_dialog.dialog_text = (
				"Are you sure you want to merge '%s'?\n"
				+ "This will replace the selected hierarchy with "
				+ "a merged mesh and preserved collision."
			) % selected[0].name
		else:
			confirmation_dialog.dialog_text = (
				"You have selected %d nodes.\n"
				+ "Are you sure you want to merge them?\n"
				+ "This will replace the selected hierarchies with "
				+ "a merged mesh and preserved collision."
			) % selected.size()

		confirmation_dialog.popup_centered()
		return

	_perform_merge(selected)

func _on_merge_confirmation() -> void:
	if pending_selection.is_empty():
		return

	var selected: Array[Node] = []

	for node in pending_selection:
		if is_instance_valid(node):
			selected.append(node)

	pending_selection.clear()

	if selected.is_empty():
		return

	_perform_merge(selected)

func _perform_merge(selected: Array[Node]) -> void:
	var edited_root = get_editor_interface().get_edited_scene_root()

	if edited_root == null:
		push_warning(
			"MeshMerger: no scene is currently open."
		)
		return

	var source_meshes: Array[MeshInstance3D] = []
	var collision_bodies: Array[StaticBody3D] = []
	var nodes_to_delete: Array[Node] = []

	var target_parent: Node = null

	for node in selected:
		if not is_instance_valid(node):
			continue

		if node != edited_root and node.owner != edited_root:
			push_warning(
				"MeshMerger: skipping '%s' — belongs to an instanced sub-scene."
				% node.name
			)
			continue

		if target_parent == null:
			if node == edited_root:
				target_parent = edited_root
			else:
				target_parent = node.get_parent()

		_collect_meshes(
			node,
			source_meshes
		)

		_collect_collision_bodies(
			node,
			collision_bodies
		)

		if node != edited_root:
			if not nodes_to_delete.has(node):
				nodes_to_delete.append(node)

	if source_meshes.is_empty():
		push_warning(
			"MeshMerger: no render MeshInstance3D nodes found in selection."
		)
		return

	if target_parent == null:
		target_parent = edited_root

	var base_name = _get_base_name(
		selected,
		edited_root
	)

	var timestamp = _get_timestamp()

	var backup_path = _create_backup(
		selected,
		base_name,
		timestamp,
		edited_root
	)

	if backup_path.is_empty():
		push_error(
			"MeshMerger: backup failed. Nothing was changed."
		)
		return

	print(
		"MeshMerger: backup saved to %s"
		% backup_path
	)

	var collision_container = Node3D.new()
	collision_container.name = "Collision"

	var preserved_collision_count = 0

	for body in collision_bodies:
		if not is_instance_valid(body):
			continue

		var duplicate_body = body.duplicate(
			Node.DUPLICATE_USE_INSTANTIATION
		)

		if duplicate_body == null:
			continue

		var original_global_transform = body.global_transform

		collision_container.add_child(duplicate_body)

		duplicate_body.global_transform = original_global_transform

		preserved_collision_count += 1

	if preserved_collision_count > 0:
		print(
			"MeshMerger: preserved %d StaticBody3D collision hierarchies."
			% preserved_collision_count
		)

	var merged_mesh = MeshMergerUtils.merge_multiple_meshes(
		source_meshes
	)

	if merged_mesh == null:
		collision_container.queue_free()

		push_error(
			"MeshMerger: failed to create merged mesh. Nothing was changed."
		)
		return

	if merged_mesh.get_surface_count() == 0:
		collision_container.queue_free()

		push_error(
			"MeshMerger: merged mesh contains no surfaces. Nothing was changed."
		)
		return

	DirAccess.make_dir_recursive_absolute(
		MESHES_DIR
	)

	var mesh_path = "%s%s_%s.res" % [
		MESHES_DIR,
		base_name,
		timestamp
	]

	var mesh_save_error = ResourceSaver.save(
		merged_mesh,
		mesh_path
	)

	if mesh_save_error != OK:
		collision_container.queue_free()

		push_error(
			"MeshMerger: failed to save merged mesh (error %d). Nothing was changed."
			% mesh_save_error
		)
		return

	print(
		"MeshMerger: merged mesh saved to %s"
		% mesh_path
	)

	nodes_to_delete.sort_custom(
		func(a: Node, b: Node) -> bool:
			return (
				a.get_path().get_name_count()
				>
				b.get_path().get_name_count()
			)
	)

	for node in nodes_to_delete:
		if not is_instance_valid(node):
			continue

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

	if preserved_collision_count > 0:
		new_instance.add_child(collision_container)
		collision_container.owner = edited_root

		MeshMergerUtils.set_owner_recursive(
			collision_container,
			edited_root
		)

		print(
			"MeshMerger: added preserved collision under '%s'."
			% new_instance.name
		)
	else:
		collision_container.queue_free()

		print(
			"MeshMerger: no collision hierarchy was found."
		)

	var editor_selection = get_editor_interface().get_selection()

	editor_selection.clear()
	editor_selection.add_node(new_instance)

	print(
		"MeshMerger: merged %d render meshes into '%s'."
		% [
			source_meshes.size(),
			new_instance.name
		]
	)

	print(
		"MeshMerger: collision data was preserved without modification."
	)

func _collect_meshes(root: Node, source_meshes: Array[MeshInstance3D]) -> void:

	if root is MeshInstance3D:
		var root_mesh = root as MeshInstance3D

		if not _is_under_static_body(root_mesh):
			if not source_meshes.has(root_mesh):
				source_meshes.append(root_mesh)


	for descendant in root.find_children(
		"*",
		"MeshInstance3D",
		true,
		false
	):
		if not descendant is MeshInstance3D:
			continue

		var mesh_instance = descendant as MeshInstance3D

		if _is_under_static_body(mesh_instance):
			continue

		if not source_meshes.has(mesh_instance):
			source_meshes.append(mesh_instance)

func _is_under_static_body(mesh_instance: MeshInstance3D) -> bool:
	var current = mesh_instance.get_parent()

	while current != null:
		if current is StaticBody3D:
			return true

		current = current.get_parent()

	return false

func _collect_collision_bodies(root: Node, collision_bodies: Array[StaticBody3D]) -> void:
	if root is StaticBody3D:
		var root_body = root as StaticBody3D

		if not _is_under_static_body_node(root_body):
			if not collision_bodies.has(root_body):
				collision_bodies.append(root_body)

	for descendant in root.find_children(
		"*",
		"StaticBody3D",
		true,
		false
	):
		if not descendant is StaticBody3D:
			continue

		var body = descendant as StaticBody3D

		if _is_under_static_body_node(body):
			continue

		if not collision_bodies.has(body):
			collision_bodies.append(body)

func _is_under_static_body_node(node: Node) -> bool:
	var current = node.get_parent()

	while current != null:
		if current is StaticBody3D:
			return true

		current = current.get_parent()

	return false

func _create_backup(selected: Array[Node], base_name: String, timestamp: String, edited_root: Node) -> String:
	var backup_root = Node3D.new()
	backup_root.name = "%s_backup" % base_name

	for node in selected:
		if not is_instance_valid(node):
			continue

		if node == edited_root:
			for child in node.get_children():
				var duplicate_child = child.duplicate()

				backup_root.add_child(duplicate_child)
				duplicate_child.owner = backup_root

				MeshMergerUtils.set_owner_recursive(
					duplicate_child,
					backup_root
				)

			continue

		var duplicate = node.duplicate()

		if duplicate == null:
			continue

		backup_root.add_child(duplicate)

		duplicate.owner = backup_root

		MeshMergerUtils.set_owner_recursive(
			duplicate,
			backup_root
		)

	var packed_scene = PackedScene.new()

	var pack_error = packed_scene.pack(
		backup_root
	)

	backup_root.free()

	if pack_error != OK:
		push_error(
			"MeshMerger: failed to pack backup scene (error %d)."
			% pack_error
		)
		return ""

	DirAccess.make_dir_recursive_absolute(
		BACKUPS_DIR
	)

	var backup_path = "%s%s_%s.tscn" % [
		BACKUPS_DIR,
		base_name,
		timestamp
	]

	var save_error = ResourceSaver.save(
		packed_scene,
		backup_path
	)

	if save_error != OK:
		push_error(
			"MeshMerger: failed to save backup scene (error %d)."
			% save_error
		)
		return ""

	return backup_path

func _get_base_name(selected: Array[Node], edited_root: Node) -> String:
	for node in selected:
		if node != edited_root:
			return String(node.name)

	return String(edited_root.name)

func _get_timestamp() -> String:
	var dt = Time.get_datetime_dict_from_system()

	return "%04d%02d%02d_%02d%02d%02d" % [
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second
	]

func _filter_top_level_selection(nodes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []

	for node in nodes:
		var nested = false

		for other in nodes:
			if other == node:
				continue

			if _is_descendant_of(
				node,
				other
			):
				nested = true
				break

		if not nested:
			result.append(node)

	return result

func _is_descendant_of(node: Node,maybe_ancestor: Node) -> bool:
	var parent = node.get_parent()

	while parent != null:
		if parent == maybe_ancestor:
			return true

		parent = parent.get_parent()

	return false
