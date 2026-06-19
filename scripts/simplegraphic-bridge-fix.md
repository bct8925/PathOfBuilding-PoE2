# SimpleGraphic "keep-awake" patch — the long-term MCP bridge fix

> The patch now lives in a fork: **bct8925/PathOfBuilding-SimpleGraphic @ `feature/force-frames`**
> (upstream PR #103 was declined as out-of-scope). `scripts/build-simplegraphic.ps1`
> builds from that fork directly. For how to rebase the patch onto new upstream
> releases and rebuild/redeploy, see **`FORK.md`** in that fork. The sections below
> document the change itself.

## The problem (root cause)

The MCP bridge is pumped from PoB's Lua `OnFrame`. But SimpleGraphic's frame loop
**skips `OnFrame` entirely when PoB is idle and not the active window**, so the
bridge stops being serviced and tool calls time out.

The gate is in `ui_main.cpp`, `ui_main_c::Frame()` (master ~line 389):

```cpp
// Otherwise only runs frames if the mouse is on screen, there is an active coroutine, or there is an active subscript
else if (!sys->video->IsActive() && !sys->video->IsCursorOverWindow() && !hasActiveCoroutine && !hasSubscript) {
    sys->Sleep(100);
    return;
}
```

`IsActive()` is `glfwGetWindowAttrib(GLFW_FOCUSED)`. So when PoB is unfocused, the
cursor isn't over it, and nothing is animating, it sleeps 100 ms and returns
**without calling the Lua frame callback** — the bridge never pumps. (This is also
why it works for a moment right after an edit: the recalc coroutine is briefly
"active", keeping frames running.)

## The fix

Add a `forceFrames` flag that, when set, keeps `OnFrame` running regardless of
focus. Expose it to Lua as `SetForceFrames(bool)`, and have PoB turn it on while
the MCP bridge is enabled. Three small edits to SimpleGraphic + one already-made,
guarded call in PoB (`src/Modules/MCPBridge.lua`).

### Edit 1 — `ui_main.h` (declare the flag)

Add next to the other `ui_main_c` bools (after `bool hasActiveCoroutine = false;`,
~line 52):

```cpp
	bool	hasActiveCoroutine = false;
	bool	forceFrames = false;	// MCP bridge: keep running OnFrame while unfocused
```

### Edit 2 — `ui_main.cpp` (honour the flag in the idle gate, ~line 389)

```cpp
	else if (!forceFrames && !sys->video->IsActive() && !sys->video->IsCursorOverWindow() && !hasActiveCoroutine && !hasSubscript) {
		sys->Sleep(100);
		return;
	}
```

(only added `!forceFrames &&` at the front of the condition.)

### Edit 3 — `ui_api.cpp` (expose `SetForceFrames(bool)` to Lua)

Add the function alongside the other `l_*` handlers (e.g. near `l_SetWindowTitle`):

```cpp
// SetForceFrames(enable)
static int l_SetForceFrames(lua_State* L)
{
	ui_main_c* ui = GetUIPtr(L);
	int n = lua_gettop(L);
	ui->LAssert(L, n >= 1, "Usage: SetForceFrames(enable)");
	ui->forceFrames = lua_toboolean(L, 1) != 0;
	return 0;
}
```

Register it in the function-binding block (near `ADDFUNC(RenderInit);`, ~line 2264):

```cpp
	ADDFUNC(SetForceFrames);
```

### Edit 4 — PoB Lua (already done, and safe on the old DLL)

`src/Modules/MCPBridge.lua` calls `SetForceFrames(true)` when the bridge starts and
`SetForceFrames(false)` when it stops, **guarded** with `if SetForceFrames then`,
so it's a no-op on the current (unpatched) DLL and activates automatically once you
ship the rebuilt one.

## Build & deploy

1. `scripts\install-simplegraphic-buildtools.ps1`  (Git + VS 2022 C++ + CMake)
2. `scripts\build-simplegraphic.ps1`  (clones recursively; apply Edits 1–3 in the
   cloned `PoB-SimpleGraphic` before the build step, or let the script pause and
   patch then re-run)
3. Back up your PoB `SimpleGraphic.dll`, copy the freshly built one over it.

With this in place, the bridge responds with PoB unfocused **or** minimized, and
the server's auto-focus workaround (`mcp/src/bridge/focus.ts`) becomes unnecessary
— you can leave it or drop it.

## Tradeoff

While the bridge is enabled, PoB renders continuously even when unfocused/minimized
(higher idle CPU/GPU than stock). That only applies when you've turned the bridge
on, and it's the price of off-screen liveness. The flag is off whenever the bridge
is off, so normal PoB use is unchanged.
