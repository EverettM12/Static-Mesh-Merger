static func merge_multiple_meshes(
	meshes_to_merge: Array[MeshInstance3D]
) -> ArrayMesh:
	var array_mesh = ArrayMesh.new()

	const NO_MATERIAL_KEY = "__mesh_merger_no_material__"
	var groups: Dictionary = {}

	for mesh_instance in meshes_to_merge:
		if not is_instance_valid(mesh_instance):
			continue

		if mesh_instance.mesh == null:
			continue

		var transform = mesh_instance.global_transform

		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			var material = mesh_instance.get_active_material(surface_index)

			if not groups.has(material):
				var surface_tool = SurfaceTool.new()
				surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[material] = surface_tool

			var surface_tool: SurfaceTool = groups[material]

			surface_tool.append_from(
				mesh_instance.mesh,
				surface_index,
				transform
			)

	for key in groups:
		var surface_tool: SurfaceTool = groups[key]

		if key is Material:
			surface_tool.set_material(key)

		surface_tool.commit(array_mesh)

	return array_mesh


static func set_owner_recursive(
	node: Node,
	owner: Node
) -> void:
	for child in node.get_children():
		child.owner = owner
		set_owner_recursive(child, owner)
