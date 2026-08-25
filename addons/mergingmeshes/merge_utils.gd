static func merge_multiple_meshes(meshes_to_merge: Array[MeshInstance3D]) -> ArrayMesh:
	var array_mesh = ArrayMesh.new()
	var groups : Dictionary = {}
	for mesh_instance in meshes_to_merge:
		if not mesh_instance.mesh:
			continue
		var transform: Transform3D = mesh_instance.global_transform
		for i in range(mesh_instance.mesh.get_surface_count()):
			var mat = mesh_instance.get_active_material(i)
			if not groups.has(mat):
				var st = SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups[mat] = st
			groups[mat].append_from(mesh_instance.mesh, i, transform)
	for mat in groups:
		var st : SurfaceTool = groups[mat]
		if mat != null:
			st.set_material(mat)
		st.commit(array_mesh)
	return array_mesh

static func set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		set_owner_recursive(child, owner)
