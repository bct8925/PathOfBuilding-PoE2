-- tools/tree.lua — passive tree, ascendancy, jewel sockets, tree specs, class.
local S = require("tools.schema")

return function(ctx)
	ctx.register({
		name = "gui_search_passives",
		method = "searchPassives",
		description = "Search the live REGULAR passive tree to find node ids BEFORE allocating (so you "
			.. "don't guess). Ascendancy nodes are EXCLUDED — they have their own points and "
			.. "pathing; use gui_search_ascendancy for those. Matches `query` (case-insensitive) "
			.. "against each node's name and stat lines and returns matches with their id, name, "
			.. "stat lines, type, whether already allocated, `pathDist` — how many points from "
			.. "the CURRENT tree the node is (0 = already on the tree) — and `neighborCount`. For "
			.. "ALLOCATED nodes it also returns `dependentCount` (other nodes that would cascade-"
			.. "remove with it) and `isLeaf` (safe to refund alone). Results are nearest-first. "
			.. "Read-only. Use this to pick a node on your frontier to allocate, or a leaf to "
			.. "safely deallocate.",
		schema = S.obj({
			query = S.str("Text to match in node names/stats (e.g. 'maximum Life', 'Crit', a notable name)."),
			maxDist = S.num("Only return nodes within this many points of the current tree (the path cost to take them)."),
			includeAllocated = S.bool("Include nodes already allocated (default false)."),
			includeUnreachable = S.bool("Include nodes with no path to the current tree (default false; ignored when maxDist is set)."),
			limit = S.num("Max nodes to return (default 30, nearest-first)."),
		}),
	})

	ctx.register({
		name = "gui_set_passive",
		method = "setPassive",
		description = "Allocate or deallocate a REGULAR passive-tree node on the live build, then recalc and "
			.. "return refreshed stats plus `budget` (regular tree points used/total/remaining). "
			.. "Ascendancy nodes are REJECTED with a redirect — use gui_set_ascendancy (it has a "
			.. "separate 8-point budget). NOTE: allocating auto-allocates the SHORTEST PATH to the "
			.. "node (a distant node takes every node along the way); DEALLOCATING a connector "
			.. "cascades to every node that depends on it. Use `dryRun: true` to preview `changedNodes` "
			.. "WITHOUT applying, `maxPath` to cap an allocation, and `maxRemoved` to refuse a "
			.. "deallocation that would remove more than N nodes (gui_search_passives reports "
			.. "isLeaf/dependentCount to find a safe refund). The response's `changedNodes` lists "
			.. "exactly what changed.",
		schema = S.obj({
			nodeId = S.num("Regular passive tree node id (find one with gui_search_passives)."),
			alloc = S.bool("True to allocate (default), false to deallocate."),
			dryRun = S.bool("Preview the change (returns changedNodes) without applying it."),
			maxPath = S.num("Reject the allocation if reaching the node would path through more than this many points."),
			maxRemoved = S.num("Reject the deallocation if it would cascade-remove more than this many nodes."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "nodeId" }),
	})

	ctx.register({
		name = "gui_search_ascendancy",
		method = "searchAscendancy",
		description = "Search the live build's selected ASCENDANCY sub-tree to find node ids BEFORE "
			.. "allocating. This is the ascendancy counterpart to gui_search_passives — ascendancy "
			.. "nodes have a SEPARATE 8-point budget and their own pathing (within the ascendancy "
			.. "region only), so they're kept apart from the regular tree. Matches `query` "
			.. "(case-insensitive) against each node's name and stat lines and returns id, name, "
			.. "stat lines, type, whether already allocated, `pathDist`, and `neighborCount` (plus "
			.. "`dependentCount`/`isLeaf` for allocated nodes). The response also carries `budget` "
			.. "(ascendancy points used/total/remaining + a Trial caveat). Nearest-first, read-only. "
			.. "If no ascendancy is selected, returns an empty list with a note (set one via "
			.. "gui_set_class).",
		schema = S.obj({
			query = S.str("Text to match in node names/stats (e.g. a notable name, 'minion', 'Crit')."),
			maxDist = S.num("Only return nodes within this many ascendancy points of the current allocation."),
			includeAllocated = S.bool("Include nodes already allocated (default false)."),
			includeUnreachable = S.bool("Include nodes with no path to the current allocation (default false; ignored when maxDist is set)."),
			limit = S.num("Max nodes to return (default 30, nearest-first)."),
		}),
	})

	ctx.register({
		name = "gui_set_ascendancy",
		method = "setAscendancy",
		description = "Allocate or deallocate an ASCENDANCY node on the live build, then recalc and return "
			.. "refreshed stats plus `budget` (ascendancy points used/total/remaining). This is the "
			.. "ascendancy counterpart to gui_set_passive: ascendancy has its OWN flat 8-point "
			.. "budget, and some of those points require completing Trials that PoB can't see — heed "
			.. "`budget.ascendancyNote` before assuming 'remaining' points are spendable. Regular "
			.. "tree nodes (and other ascendancies' nodes) are REJECTED with a redirect. Mechanics "
			.. "match gui_set_passive: allocating takes the SHORTEST PATH within the ascendancy; "
			.. "deallocating a connector cascades. Use `dryRun`, `maxPath`, `maxRemoved` the same "
			.. "way; `changedNodes` lists exactly what changed.",
		schema = S.obj({
			nodeId = S.num("Ascendancy node id (find one with gui_search_ascendancy)."),
			alloc = S.bool("True to allocate (default), false to deallocate."),
			dryRun = S.bool("Preview the change (returns changedNodes) without applying it."),
			maxPath = S.num("Reject the allocation if reaching the node would path through more than this many ascendancy points."),
			maxRemoved = S.num("Reject the deallocation if it would cascade-remove more than this many nodes."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "nodeId" }),
	})

	ctx.register({
		name = "gui_get_jewel_sockets",
		method = "getJewelSockets",
		description = "List the live passive tree's jewel sockets BEFORE socketing (so you don't guess). "
			.. "Each socket reports its `nodeId` (the socket node), `socketName`, `location`, "
			.. "whether the node is `allocated` (a jewel ONLY takes effect at an allocated "
			.. "socket), `pathDist` (points to allocate an empty one), and its `occupant` "
			.. "(the jewel's itemId/name) or false if empty. Allocated sockets are listed first. "
			.. "Read-only. Use a socket's nodeId with gui_socket_jewel.",
		schema = S.obj({
			includeEmpty = S.bool("Include sockets with no jewel (default true)."),
			onlyAllocated = S.bool("Only return sockets whose node is allocated (i.e. usable now; default false)."),
		}),
	})

	ctx.register({
		name = "gui_set_class",
		method = "setClass",
		description = "Change the live build's character class and/or ascendancy, and optionally its "
			.. "level, then recalc. Class/ascendancy are given by name (e.g. class 'Witch', "
			.. "ascendancy 'Infernalist'). Changing class resets the ascendancy and the tree's "
			.. "class-dependent allocation, mirroring PoB's tree class switch.",
		schema = S.obj({
			className = S.str("Character class name (e.g. 'Witch', 'Ranger', 'Warrior')."),
			ascendancy = S.str("Ascendancy name for the class (e.g. 'Infernalist'); empty string clears it."),
			level = S.int("Character level (1-100); switches off auto-level."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}),
	})

	ctx.register({
		name = "gui_get_tree_specs",
		method = "getTreeSpecs",
		description = "List the live build's passive-tree SPECS and the tree VERSIONS the active tree "
			.. "can be converted to (so you switch/convert by real identifiers, not guesses). "
			.. "A build can hold several trees (specs) — each a class + allocation set on a "
			.. "specific tree version. Returns `specs` (index, title, treeVersion + display, "
			.. "isActive, class, allocatedNodeCount) — switch among them with gui_select_spec — "
			.. "and `availableVersions` (version + display + isLatest) — convert the active "
			.. "tree with gui_set_tree_version. Read-only.",
		schema = S.obj({}),
	})

	ctx.register({
		name = "gui_set_tree_version",
		method = "setTreeVersion",
		description = "Convert the live build's ACTIVE passive tree to a different tree version, then "
			.. "recalc. A version change can SILENTLY de-allocate passives that don't exist on "
			.. "the target tree — the response lists exactly which in `deallocatedNodes`. "
			.. "keepOld (default true) keeps the previous tree as a selectable alternate spec, "
			.. "so you can REVERT by calling gui_select_spec with the returned `previousSpec` "
			.. "index; keepOld=false replaces it in place and is NOT revertible that way. "
			.. "NOTE: gui_undo {scope:'tree'} does NOT revert a conversion (it undoes edits "
			.. "within a spec) — use gui_select_spec. Use gui_get_tree_specs to list versions.",
		schema = S.obj({
			version = S.str("Target tree version (e.g. '0_2', '0_5'); from gui_get_tree_specs availableVersions."),
			keepOld = S.bool("Keep the previous tree as an alternate spec for revert (default true)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "version" }),
	})

	ctx.register({
		name = "gui_select_spec",
		method = "selectSpec",
		description = "Switch the live build's ACTIVE passive tree among its existing specs (list them "
			.. "with gui_get_tree_specs), then recalc. This is also how you REVERT a "
			.. "gui_set_tree_version conversion that kept the old tree — switch back to the "
			.. "previous spec index. Syncs the GUI's version + spec selectors and jewel sockets.",
		schema = S.obj({
			spec = S.int("1-based spec index to make active (from gui_get_tree_specs)."),
			stats = S.arr(S.str(), "Stat keys to return after recalc."),
		}, { "spec" }),
	})
end
