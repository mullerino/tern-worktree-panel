--!strict

local Model = require("./model")

local ui = tern.ui
local WINDOWS = tern.runtime.os == "windows"
local PLUGIN = tern.plugin.id
local TITLE = "Worktrees"
local ABOUT = "Lists the git worktrees of the focused repository and the omp agents running in each. "
	.. "Clicking a row focuses the last used pane of that worktree or opens a tab in it; ctrl+click opens Tern's Git view. "
	.. "Right-click a row for more: open a tab, open the Git view, copy the path, remove the worktree. "
	.. "A waiting agent's card focuses that agent; + creates a worktree on a new branch with tern-worktrees."
local PANEL_SHARE = 0.26
local POLL_MS = 3000
local SETTLE_MS = 150
local EXCERPT = 140
local BATCH = 3

type Panel = { pane: number, tab: number? }

type State = {
	enabled: boolean,
	adopted: boolean,
	cwd: string?,
	trees: { Model.Tree },
	loaded: boolean,
	failure: string?,
	loading: boolean,
	again: boolean,
	seen: Model.Seen,
	agents: { Model.Agent },
	polled: boolean,
	last: { [string]: number },
	board: Model.Board?,
	sig: string?,
	drawn: { [number]: string },
	placed: { [number]: number },
	content: { [number]: number },
	polling: boolean,
	queued: boolean,
	filling: boolean,
	status: { [string]: Model.Status },
	checking: boolean,
	recheck: boolean,
	removing: { [string]: boolean },
	creatable: boolean,
	cli: { string }?,
}

local state: State = {
	enabled = false,
	adopted = false,
	cwd = nil,
	trees = {},
	loaded = false,
	failure = nil,
	loading = false,
	again = false,
	seen = {},
	agents = {},
	polled = false,
	last = {},
	board = nil,
	sig = nil,
	drawn = {},
	placed = {},
	content = {},
	polling = false,
	queued = false,
	filling = false,
	status = {},
	checking = false,
	recheck = false,
	removing = {},
	creatable = false,
	cli = nil,
}

local function key(path: string): string
	return Model.norm(path, WINDOWS)
end

local function panels(cx: any): { Panel }
	local out: { Panel } = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == PLUGIN and canvas.title == TITLE and cx.session:pane(canvas.pane) then
			table.insert(out, { pane = canvas.pane, tab = cx.session:tab_of(canvas.pane) })
		end
	end
	return out
end

local function panelSet(cx: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for _, panel in panels(cx) do
		out[panel.pane] = true
	end
	for _, pane in state.placed do
		out[pane] = true
	end
	return out
end

local function shownTab(cx: any): number?
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function text(value: any): string?
	return if type(value) == "string" then value else nil
end

local function agents(cx: any): { Model.Agent }
	local out: { Model.Agent } = {}
	for _, agent in cx.agents:list() do
		local cwd = text(agent.cwd)
		if cwd then
			local message = text(agent.last_message)
			if not message or message == "" then
				local info = cx.session:pane(agent.pane)
				message = info and info.title
			end
			table.insert(out, { pane = agent.pane, cwd = cwd, state = agent.state, last_message = message })
		end
	end
	return out
end

local function panes(cx: any): { Model.Pane }
	local mine = panelSet(cx)
	local out: { Model.Pane } = {}
	for _, pane in cx.session:panes() do
		if not mine[pane.pane] and not pane.parked then
			table.insert(out, { pane = pane.pane, cwd = pane.cwd })
		end
	end
	return out
end

local function repoName(): string
	local main = state.trees[1]
	return if main then string.match(main.path, "([^/\\]+)[/\\]*$") or main.path else "—"
end

local function span(t: string, s: string?): any
	return ui.span(t, s)
end

local function keyed(name: string, node: any): any
	node.p = node.p or {}
	node.p.key = name
	return node
end

local function line(name: string, props: { [string]: any }, children: { any }): any
	props.key = name
	props.gap = props.gap or "sm"
	return ui.node("row", props, children)
end

local function fixed(node: any): any
	node.p = node.p or {}
	node.p.basis = "content"
	return node
end

local function grow(node: any): any
	node.p = node.p or {}
	node.p.grow = 1
	return node
end

local function role(name: string, node: any): any
	node.p = node.p or {}
	node.p.role = "wtp." .. name
	return node
end

local function cut(name: string, spans: { any }, how: string?): any
	return role(name, ui.node("text", { key = name, spans = spans, truncate = how or "end" }))
end

local function clamp(name: string, spans: { any }, count: number): any
	return role(name, ui.node("text", { key = name, spans = spans, lines = count }))
end

local function findCli(): { string }?
	local home = tern.getenv(if WINDOWS then "USERPROFILE" else "HOME")
	if not home or home == "" then
		return nil
	end
	local ok, argv = pcall(function(): { string }?
		if WINDOWS then
			local shim = home .. "\\.local\\bin\\tern-wt.cmd"
			if not tern.fs.exists(shim) then
				return nil
			end
			local script = string.match(tern.fs.read(shim, 4096), '"([^"]+%.ts)"')
			return if script then { "bun", script } else nil
		end
		local bin = home .. "/.local/bin/tern-wt"
		return if tern.fs.exists(bin) then { bin } else nil
	end)
	return if ok then argv else nil
end

local function header(creatable: boolean): any
	local count = if state.loaded then tostring(#state.trees) else ""
	local parts = {
		grow(cut("title", { span("Worktrees", "muted"), span(" · ", "dim"), span(repoName(), "strong") })),
		fixed(role("count", keyed("count", ui.text({ span(count, "num") })))),
	}
	if creatable then
		table.insert(
			parts,
			fixed(
				role(
					"new",
					ui.el("button", { key = "new", text = "+", title = "New worktree", actions = { click = "new" } })
				)
			)
		)
	end
	table.insert(
		parts,
		fixed(role("refresh", ui.el("button", { key = "refresh", text = "↻", actions = { click = "refresh" } })))
	)
	return role("header", line("header", { justify = "between", align = "center" }, parts))
end

local function elapsed(name: string, since: number?, now: number): any?
	if not since then
		return nil
	end
	return fixed(role("elapsed", ui.node("elapsed", { key = name, age = math.max(0, now - since) })))
end

local function waitingCard(item: Model.Waiting, now: number): any
	local where = if item.elsewhere then " · in " .. item.elsewhere else " · " .. item.branch.title
	local top = {
		fixed(role("dot", keyed("dot", ui.text({ span("◆", "warning") })))),
		grow(cut("waitTitle", { span("Waiting for you", "warning strong"), span(where, "muted") })),
	}
	local timer = elapsed("since", if item.since > 0 then item.since else nil, now)
	if timer then
		table.insert(top, timer)
	end
	local children = { line("top", { align = "center" }, top) }
	local message = Model.excerpt(item.message, EXCERPT)
	if message ~= "" then
		table.insert(children, clamp("message", { span(message, "muted") }, 3))
	end
	table.insert(
		children,
		role("reply", ui.el("button", { key = "go", text = "Reply →", actions = { click = "agent=" .. item.pane } }))
	)
	return role(
		"waiting",
		ui.node("col", { key = "wait" .. item.pane, gap = "xs", actions = { click = "agent=" .. item.pane } }, children)
	)
end

local function marker(item: Model.Row): any
	if item.agent == "working" then
		return fixed(
			role(
				"marker",
				ui.node("spinner", { key = "agent", style = "orbit", tone = "accent", aria = "Agent working" })
			)
		)
	end
	local glyph = if item.agent == "idle" then "○" else ""
	return fixed(role("marker", keyed("agent", ui.text({ span(glyph, "muted") }))))
end

local function row(item: Model.Row, now: number): any
	local title = { span(item.branch.title, "strong") }
	if item.branch.kind then
		table.insert(title, span(" " .. item.branch.kind, "muted"))
	end
	local head = { marker(item), grow(cut("name", title)) }
	if item.merged then
		table.insert(head, fixed(role("merged", keyed("merged", ui.text({ span("merged", nil) })))))
	end
	if not item.current and item.open then
		table.insert(head, fixed(role("go", keyed("action", ui.text({ span("Go", nil) })))))
	end
	local body = { line("head", { align = "center" }, head) }
	if item.branch.summary then
		table.insert(body, cut("summary", { span(item.branch.summary, nil) }))
	end
	local foot = { grow(cut("path", { span(item.path, nil) }, "start")) }
	if item.changed > 0 then
		table.insert(foot, fixed(role("changed", keyed("changed", ui.text({ span("±" .. item.changed, "num") })))))
	end
	local timer = if item.agent == "working" then elapsed("since", item.since, now) else nil
	if timer then
		table.insert(foot, timer)
	end
	table.insert(body, line("foot", { align = "center" }, foot))
	local i = tostring(item.index)
	local menu = { "open-tab", "git-view", "copy-path" }
	if not item.tree.main then
		table.insert(menu, "remove-worktree")
	end
	local node = ui.node("col", {
		key = "row" .. item.index,
		gap = "none",
		actions = { click = "go=" .. i, menu = menu },
	}, body)
	return role(if item.current then "current" else "row", node)
end

local function signature(board: Model.Board): string
	local parts = { tostring(#state.trees), state.failure or "", repoName(), tostring(state.creatable) }
	for _, w in board.waiting do
		table.insert(
			parts,
			string.format("w%d:%d:%s:%s:%s", w.index, w.pane, tostring(w.since), w.message, w.elsewhere or "")
		)
	end
	for _, r in board.rows do
		table.insert(
			parts,
			string.format(
				"r%d:%s:%s:%s:%s:%s:%d",
				r.index,
				tostring(r.current),
				tostring(r.open),
				r.agent or "",
				tostring(r.since),
				tostring(r.merged),
				r.changed
			)
		)
	end
	return table.concat(parts, "|")
end

local function view(board: Model.Board?, now: number): any
	local children = { header(state.creatable) }
	if state.failure then
		table.insert(children, role("note", keyed("failure", ui.text({ span(state.failure, "muted") }))))
	elseif not state.loaded or not board then
		table.insert(
			children,
			ui.node("spinner", { key = "loading", style = "dots", label = { span("Loading worktrees", "muted") } })
		)
	else
		local waiting = {}
		for _, item in board.waiting do
			table.insert(waiting, waitingCard(item, now))
		end
		if #waiting > 0 then
			table.insert(children, role("waitingList", ui.node("col", { key = "waiting", gap = "sm" }, waiting)))
		end
		local rows = {}
		for _, item in board.rows do
			table.insert(rows, row(item, now))
		end
		table.insert(children, role("list", ui.node("col", { key = "list", gap = "none" }, rows)))
	end
	return role("panel", ui.node("col", { key = "root", gap = "md" }, children))
end

local function listed(cx: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for _, canvas in cx.canvas:list() do
		out[canvas.pane] = true
	end
	return out
end

local redraw: () -> ()

local function compose(cx: any): (Model.Board?, string)
	state.cli = state.cli or findCli()
	state.creatable = state.cli ~= nil
	local board = if state.loaded
		then Model.board({
			trees = state.trees,
			agents = state.agents,
			seen = state.seen,
			panes = panes(cx),
			cwd = state.cwd,
			windows = WINDOWS,
			status = state.status,
		})
		else nil
	return board, if board then signature(board) else (state.failure or "loading") .. tostring(state.creatable)
end

local function paint(cx: any, queue: { number }, sig: string, board: Model.Board?)
	local ready = listed(cx)
	local now = tern.now()
	local view0 = nil
	local count = 0
	while #queue > 0 and count < BATCH do
		local pane = table.remove(queue, 1) :: number
		if ready[pane] and state.drawn[pane] ~= sig then
			view0 = view0 or view(board, now)
			cx.canvas:set(pane, { view = view0 })
			state.drawn[pane] = sig
			count += 1
		end
	end
	local waiting = false
	for _, panel in panels(cx) do
		if not ready[panel.pane] then
			waiting = true
		end
	end
	if #queue > 0 or waiting then
		tern.timer(if #queue > 0 then 0 else SETTLE_MS, function(next)
			if next then
				redraw()
			end
		end)
	end
end

local function draw(cx: any)
	if not state.enabled then
		return
	end
	local board, sig = compose(cx)
	state.board, state.sig = board, sig
	local shown = shownTab(cx)
	local queue: { number } = {}
	local rest: { number } = {}
	for _, panel in panels(cx) do
		if state.drawn[panel.pane] ~= sig then
			table.insert(if panel.tab == shown then queue else rest, panel.pane)
		end
	end
	for _, pane in rest do
		table.insert(queue, pane)
	end
	if #queue > 0 then
		paint(cx, queue, sig, board)
	end
end

redraw = function()
	if state.queued then
		return
	end
	state.queued = true
	tern.timer(0, function(cx)
		state.queued = false
		if cx then
			draw(cx)
		end
	end)
end

local function git(dir: string, args: { string }, env: { [string]: string }?, cb: (res: any) -> ())
	local argv = { "git", "--no-optional-locks", "-C", Model.native(dir, WINDOWS) }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local ok = pcall(tern.process.run, argv, { timeout_ms = 15000, env = env }, function(res, _cx)
		cb(res)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = "" })
	end
end

local function trimmed(text: string?): string?
	local out = text and string.match(text, "^%s*(.-)%s*$")
	return if out == "" then nil else out
end

local function check()
	if state.checking then
		state.recheck = true
		return
	end
	local main = state.trees[1]
	if not main then
		return
	end
	local todo: { Model.Tree } = {}
	for _, tree in state.trees do
		if not tree.main and not tree.detached then
			table.insert(todo, tree)
		end
	end
	state.checking = true
	local next: { [string]: Model.Status } = {}
	local scratch = tern.plugin.data .. "/scratch/" .. string.format("%d", tern.now())
	local function finish()
		pcall(tern.fs.remove, scratch)
		for path, status in next do
			state.status[path] = status
		end
		state.checking = false
		redraw()
		if state.recheck then
			state.recheck = false
			check()
		end
	end
	git(main.path, { "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD" }, nil, function(head)
		local base = if head.status == 0 then trimmed(head.stdout) else nil
		local args = { "rev-parse", "--path-format=absolute", "--git-common-dir" }
		if base then
			table.insert(args, base .. "^{tree}")
		end
		git(main.path, args, nil, function(info)
			local lines = string.split(info.stdout, "\n")
			local common = if info.status == 0 then trimmed(lines[1]) else nil
			local baseTree = if base and info.status == 0 then trimmed(lines[2]) else nil
			local env = nil
			if common and pcall(tern.fs.mkdir, scratch) then
				env = {
					GIT_OBJECT_DIRECTORY = Model.native(scratch, WINDOWS),
					GIT_ALTERNATE_OBJECT_DIRECTORIES = Model.native(common .. "/objects", WINDOWS),
				}
			end
			local function step(i: number)
				local tree = todo[i]
				if not tree then
					finish()
					return
				end
				git(tree.path, { "status", "--porcelain=v1", "-z", "--untracked-files=normal" }, nil, function(st)
					local status: Model.Status = { changed = 0, merged = false }
					if st.status == 0 then
						status.changed = Model.changes(st.stdout)
					end
					next[key(tree.path)] = status
					local branch = tree.branch
					if not base or not baseTree or not env or not branch then
						step(i + 1)
						return
					end
					git(
						tree.path,
						{ "rev-list", "--left-right", "--count", base .. "..." .. branch },
						nil,
						function(counts)
							local ahead = if counts.status == 0
								then string.match(counts.stdout, "^%s*%d+%s+(%d+)")
								else nil
							if not ahead or ahead == "0" then
								status.merged = counts.status == 0 and Model.merged(counts.stdout, nil, nil)
								step(i + 1)
								return
							end
							git(
								tree.path,
								{ "merge-tree", "--write-tree", "--no-messages", base, branch },
								env,
								function(merged)
									local out = if merged.status == 0 then trimmed(merged.stdout) else ""
									status.merged = Model.merged(counts.stdout, out, baseTree)
									step(i + 1)
								end
							)
						end
					)
				end)
			end
			step(1)
		end)
	end)
end

local function refresh()
	local dir = state.cwd
	if not dir then
		state.loaded, state.trees = true, {}
		state.failure = "Focus a terminal inside a git repository."
		redraw()
		return
	end
	if state.loading then
		state.again = true
		return
	end
	state.loading = true
	local argv =
		{ "git", "--no-optional-locks", "-C", Model.native(dir, WINDOWS), "worktree", "list", "--porcelain", "-z" }
	tern.process.run(argv, { timeout_ms = 10000 }, function(res, cx)
		state.loading = false
		if res.status == 0 then
			state.trees = Model.parseWorktrees(res.stdout)
			state.failure = if #state.trees == 0 then "No worktrees found." else nil
		else
			state.trees = {}
			state.failure = "Not a git repository: " .. Model.displayPath(dir, WINDOWS)
		end
		state.loaded = true
		if cx then
			draw(cx)
		end
		check()
		if state.again then
			state.again = false
			refresh()
		end
	end)
end

local function side(): Model.Side
	return Model.side(tern.kv.get("side"))
end

local function share(cx: any, tab: number, pane: number, at: Model.Side): number?
	local layout = cx.session:layout(tab)
	return Model.share(layout and layout.root, pane, at)
end

local function size(cx: any, tab: number, pane: number, at: Model.Side)
	local toward = Model.inward(at)
	local before = share(cx, tab, pane, at)
	if not before or math.abs(before - PANEL_SHARE) < 0.01 or not cx.layout:resize(pane, toward, 1) then
		return
	end
	local after = share(cx, tab, pane, at)
	cx.layout:resize(pane, toward, -1)
	if not after or after == before then
		return
	end
	local columns = 1 / math.abs(after - before)
	local step = math.floor((PANEL_SHARE - before) * columns + 0.5)
	if step ~= 0 then
		cx.layout:resize(pane, toward, step)
	end
end

local function settle(cx: any, pane: number, tab: number, at: Model.Side): boolean
	local layout = cx.session:layout(tab)
	if not layout then
		return false
	end
	if Model.edge(layout.root, at) ~= pane then
		local target = Model.edge(layout.root, at, pane)
		if not target then
			return false
		end
		cx.layout:move(pane, target, at, { focus = false })
	end
	size(cx, tab, pane, at)
	return true
end

local function others(cx: any, tab: number, mine: { [number]: boolean }): boolean
	local layout = cx.session:layout(tab)
	local function walk(tree: any): boolean
		if not tree then
			return false
		end
		if tree.pane then
			return not mine[tree.pane]
		end
		return walk(tree[1]) or walk(tree[2])
	end
	return layout ~= nil and walk(layout.root)
end

local function focusOf(cx: any, tab: number?): number?
	local layout = tab and cx.session:layout(tab)
	return layout and layout.focus
end

local function create(cx: any, tab: number, at: Model.Side): number?
	local shown = shownTab(cx)
	local keepShown = focusOf(cx, shown)
	local keepTarget = focusOf(cx, tab)
	local pane, err = cx.canvas:open({
		title = TITLE,
		about = ABOUT,
		view = view(state.board, tern.now()),
		how = "beside",
		focus = false,
	})
	if not pane then
		cx:toast("error", "The worktree panel did not open", tostring(err))
		return nil
	end
	state.placed[tab] = pane
	if cx.session:tab_of(pane) ~= tab then
		cx.layout:move_to_tab(pane, tab, { focus = false })
	end
	settle(cx, pane, tab, at)
	if keepTarget and keepTarget ~= pane then
		state.content[tab] = state.content[tab] or keepTarget
	end
	if tab ~= shown and keepTarget and focusOf(cx, tab) ~= keepTarget then
		cx.layout:focus(keepTarget)
	end
	if keepShown and cx.session:pane(keepShown) and cx.session:focused() ~= keepShown then
		cx.layout:focus(keepShown)
	end
	return pane
end

local function fill(cx: any)
	if not state.enabled or state.filling then
		return
	end
	state.filling = true
	local mine = panelSet(cx)
	local byTab: { [number]: number } = {}
	for _, panel in panels(cx) do
		if not panel.tab or byTab[panel.tab] then
			cx.layout:close(panel.pane)
			mine[panel.pane] = nil
		else
			byTab[panel.tab] = panel.pane
		end
	end
	for tab, pane in state.placed do
		if not byTab[tab] and cx.session:pane(pane) and cx.session:tab_of(pane) == tab then
			byTab[tab] = pane
		end
	end
	state.placed = byTab
	local shown = shownTab(cx)
	local missing: { number } = {}
	for _, tab in cx.session:tabs() do
		local own = byTab[tab.id]
		if own and not others(cx, tab.id, mine) then
			cx.layout:close(own)
			byTab[tab.id] = nil
			state.drawn[own] = nil
		elseif not own and others(cx, tab.id, mine) then
			if tab.id == shown then
				table.insert(missing, 1, tab.id)
			else
				table.insert(missing, tab.id)
			end
		end
	end
	local next = missing[1]
	if next then
		create(cx, next, side())
	end
	state.filling = false
	if #missing > 1 then
		tern.timer(SETTLE_MS, function(later)
			if later then
				fill(later)
			end
		end)
	end
	redraw()
end

local function remember(cx: any, paneId: number?): boolean
	if not paneId or panelSet(cx)[paneId] then
		return false
	end
	local info = cx.session:pane(paneId)
	local cwd = info and info.cwd
	if not cwd or cwd == "" then
		return false
	end
	local tree = Model.owner(cwd, state.trees, WINDOWS)
	if tree then
		state.last[key(tree.path)] = paneId
	end
	local moved = state.cwd == nil or not tree
	state.cwd = cwd
	return moved
end

local function alert(cx: any, panes: { number })
	local shown = shownTab(cx)
	for _, pane in panes do
		if cx.session:tab_of(pane) ~= shown then
			local agent: Model.Agent? = nil
			for _, a in state.agents do
				if a.pane == pane then
					agent = a
				end
			end
			if agent then
				local message = Model.excerpt(agent.last_message, EXCERPT)
				cx:toast(
					"info",
					"An agent is waiting for you in " .. Model.folder(agent.cwd, WINDOWS),
					if message ~= "" then message else nil
				)
			end
		end
	end
end

local function sync(cx: any): boolean
	local list = agents(cx)
	local before = state.seen
	local seen, changed = Model.track(before, list, tern.now())
	state.agents, state.seen = list, seen
	if changed then
		if state.polled then
			alert(cx, Model.newlyWaiting(before, seen))
		end
		tern.chrome.refresh()
	end
	return changed
end

local function poll(cx: any?)
	if not cx or not state.enabled then
		state.polling = false
		return
	end
	if sync(cx) or not state.polled then
		state.polled = true
		redraw()
	end
	tern.timer(POLL_MS, poll)
end

local function startPolling()
	if not state.polling then
		state.polling = true
		tern.timer(SETTLE_MS, poll)
	end
end

local function resync()
	tern.timer(0, function(cx)
		if cx and state.enabled and sync(cx) then
			redraw()
		end
	end)
end

local function schedule()
	tern.timer(0, function(cx)
		if cx then
			fill(cx)
		end
	end)
end

local function release(cx: any, tab: number, pane: number): boolean
	local mine = panelSet(cx)
	if not mine[pane] then
		return false
	end
	local back = state.content[tab]
	if not back or not cx.session:pane(back) or cx.session:tab_of(back) ~= tab then
		local layout = cx.session:layout(tab)
		back = layout and Model.edge(layout.root, Model.inward(side()), pane)
	end
	if back and not mine[back] then
		tern.timer(0, function(next)
			if not next or focusOf(next, tab) ~= pane or not next.session:pane(back) then
				return
			end
			local now = next.session:focused()
			next.layout:focus(back)
			if now and now ~= pane and next.session:pane(now) then
				next.layout:focus(now)
			end
		end)
	end
	return true
end

local function unstick(cx: any)
	for _, tab in cx.session:tabs() do
		local focus = focusOf(cx, tab.id)
		if focus then
			release(cx, tab.id, focus)
		end
	end
end

local function enable(cx: any)
	state.enabled = true
	tern.kv.set("enabled", true)
	remember(cx, cx.session:focused())
	state.loaded, state.failure, state.drawn = false, nil, {}
	schedule()
	unstick(cx)
	refresh()
	startPolling()
end

local function disable(cx: any)
	state.enabled = false
	tern.kv.set("enabled", false)
	for _, panel in panels(cx) do
		cx.layout:close(panel.pane)
	end
	state.placed, state.drawn = {}, {}
end

local function toggle(cx: any)
	if state.enabled then
		disable(cx)
	else
		enable(cx)
	end
end

local function goTo(cx: any, tree: Model.Tree)
	local target = Model.target(panes(cx), state.trees, tree, state.last[key(tree.path)], WINDOWS)
	if target then
		cx.layout:focus(target)
		return
	end
	if not cx.layout:new_tab({ cwd = Model.native(tree.path, WINDOWS) }) then
		cx:toast("error", "The tab did not open", Model.displayPath(tree.path, WINDOWS))
	end
end

local function openGit(cx: any, tree: Model.Tree)
	cx.git:open(Model.native(tree.path, WINDOWS), { how = "tab" }):next(function(_, err, next)
		if err and next then
			next:toast("error", "The Git view did not open", tostring(err))
		end
	end)
end

local function focusAgent(cx: any, pane: number)
	if cx.session:pane(pane) then
		cx.layout:focus(pane)
		return
	end
	cx:toast("info", "The agent is in another session", "Switch to that session to reply.")
end

local function held(mods: { string }?, name: string): boolean
	local list: { string } = mods or {}
	for _, mod in list do
		if mod == name then
			return true
		end
	end
	return false
end

local function openTab(cx: any, tree: Model.Tree)
	if not cx.layout:new_tab({ cwd = Model.native(tree.path, WINDOWS) }) then
		cx:toast("error", "The tab did not open", Model.displayPath(tree.path, WINDOWS))
	end
end

local function cliError(stdout: string, stderr: string): (string?, string)
	local ok, decoded = pcall(tern.json.decode, stdout)
	local err = ok and type(decoded) == "table" and decoded.error
	if type(err) == "table" then
		return err.code, tostring(err.message or err.code)
	end
	local text = if stderr ~= "" then stderr else stdout
	return nil, (string.match(text, "^%s*([^\n]+)") or "tern-wt failed")
end

local function runRemove(cx: any, tree: Model.Tree, force: boolean)
	local id = key(tree.path)
	if state.removing[id] then
		return
	end
	state.removing[id] = true
	local name = Model.branch(tree).title
	cx:toast("info", "Removing worktree " .. name .. "…")
	state.cli = state.cli or findCli()
	if not state.cli then
		state.removing[id] = nil
		cx:toast("error", "tern-wt was not found", "Install tern-worktrees to remove worktrees from the panel.")
		return
	end
	local argv = table.clone(state.cli)
	table.insert(argv, "remove")
	table.insert(argv, Model.native(tree.path, WINDOWS))
	if force then
		table.insert(argv, "--force")
	end
	local ok = pcall(tern.process.run, argv, { timeout_ms = 120000 }, function(res: any, next: any)
		state.removing[id] = nil
		refresh()
		if not next then
			return
		end
		if res.status == 0 then
			next:toast("success", "Removed worktree " .. name)
			return
		end
		local code, message = cliError(res.stdout, res.stderr)
		if code == "dirty_worktree" or code == "git_failed" then
			next:pick({
				placeholder = if code == "dirty_worktree"
					then name .. " has uncommitted work, not removed"
					else "Not removed: " .. message,
				icon = "trash",
				action = "choose",
				items = {
					{ id = "keep", label = "Keep the worktree", icon = "folder" },
					{ id = "force", label = "Force remove", detail = "discards uncommitted work", icon = "trash" },
				},
			}):next(function(item, _err, later)
				if item and item.id == "force" and later then
					runRemove(later, tree, true)
				end
			end)
		elseif code == "not_managed" then
			next:toast("info", "tern-worktrees does not manage this worktree", "It removes only worktrees it created.")
		else
			next:toast("error", "The worktree was not removed", message)
		end
	end)
	if not ok then
		state.removing[id] = nil
		cx:toast("error", "tern-wt did not run", "Install tern-worktrees to remove worktrees from the panel.")
	end
end

local function confirmRemove(cx: any, tree: Model.Tree)
	local status = state.status[key(tree.path)]
	local detail = if status and status.changed > 0
		then status.changed .. " uncommitted change" .. (if status.changed == 1 then "" else "s") .. ", removal stops"
		elseif status and status.merged then "merged and clean"
		else nil
	cx:pick({
		placeholder = "Remove " .. Model.displayPath(tree.path, WINDOWS) .. "?",
		icon = "trash",
		action = "choose",
		items = {
			{ id = "remove", label = "Remove worktree", detail = detail, icon = "trash" },
			{ id = "keep", label = "Keep it", icon = "folder" },
		},
	}):next(function(item, _err, next)
		if item and item.id == "remove" and next then
			runRemove(next, tree, false)
		end
	end)
end

local function createWorktree(cx: any, dir: string, branch: string)
	local cli = state.cli
	if not cli then
		cx:toast("error", "tern-wt was not found", "Install tern-worktrees to create worktrees from the panel.")
		return
	end
	local argv = table.clone(cli)
	for _, arg in { "create", "--repo", Model.native(dir, WINDOWS), "--new", "--branch=" .. branch } do
		table.insert(argv, arg)
	end
	cx:toast("info", "Creating worktree " .. branch .. "…")
	local ok = pcall(tern.process.run, argv, { timeout_ms = 180000 }, function(res: any, next: any)
		refresh()
		if not next then
			return
		end
		if res.status == 0 then
			local done, decoded = pcall(tern.json.decode, res.stdout)
			local path = if done and type(decoded) == "table" then decoded.path else nil
			next:toast("success", "Created worktree " .. branch, if type(path) == "string" then path else nil)
			return
		end
		local _, message = cliError(res.stdout, res.stderr)
		next:toast("error", "The worktree was not created", message)
	end)
	if not ok then
		cx:toast("error", "tern-wt did not run", table.concat(cli, " "))
	end
end

local function newWorktree(cx: any)
	local dir = state.cwd
	if not dir then
		cx:toast("info", "Focus a terminal inside a git repository first.")
		return
	end
	cx:prompt({ placeholder = "New branch for a worktree in " .. repoName(), icon = "branch", action = "create" })
		:next(function(text, _err, next)
			local branch = if type(text) == "string" then string.match(text, "^%s*(.-)%s*$") else nil
			if branch and branch ~= "" and next then
				createWorktree(next, dir, branch)
			end
		end)
end

local function adopt(cx: any)
	if state.adopted then
		return
	end
	state.adopted = true
	if tern.kv.get("enabled") == true or #panels(cx) > 0 then
		tern.timer(0, function(next)
			if next and not state.enabled then
				enable(next)
			end
		end)
	end
end

tern.command({
	id = "toggle",
	title = "Worktrees: show or hide the panel",
	icon = "branch",
	keys = { "alt+shift+e" },
	run = toggle,
})

tern.command({
	id = "waiting",
	title = "Worktrees: go to the agent waiting longest",
	icon = "branch",
	run = function(cx: any)
		local pane = Model.oldestWaiting(state.seen)
		if pane then
			focusAgent(cx, pane)
		else
			cx:toast("info", "No agent is waiting for you")
		end
	end,
})

tern.chrome.status(function(_pane: any): { any }?
	if not state.enabled then
		return nil
	end
	local _, count = Model.oldestWaiting(state.seen)
	if count == 0 then
		return nil
	end
	return {
		{
			text = count .. " waiting",
			icon = "branch",
			tone = "warn",
			command = "plugin." .. PLUGIN .. ".waiting",
		},
	}
end)

tern.command({
	id = "side",
	title = "Worktrees: move the panel to the other side",
	icon = "branch",
	run = function(cx: any)
		local next: Model.Side = if side() == "left" then "right" else "left"
		tern.kv.set("side", next)
		local shown = shownTab(cx)
		local list = panels(cx)
		table.sort(list, function(a, b)
			return a.tab == shown and b.tab ~= shown
		end)
		for _, panel in list do
			if panel.tab then
				settle(cx, panel.pane, panel.tab, next)
			end
		end
		cx:toast("info", if next == "right" then "Panel on the right" else "Panel on the left")
	end,
})

tern.on("canvas_action", function(ev: any, cx: any)
	if not panelSet(cx)[ev.pane] then
		return false
	end
	if ev.act == "refresh" then
		refresh()
	elseif ev.act == "new" then
		newWorktree(cx)
	elseif ev.act == "agent" then
		local pane = tonumber(ev.value)
		if pane then
			focusAgent(cx, pane)
		end
	elseif ev.act == "open-tab" or ev.act == "git-view" or ev.act == "copy-path" or ev.act == "remove-worktree" then
		local tree = state.trees[tonumber(ev.value) or tonumber(string.match(ev.node or "", "%.row(%d+)$")) or 0]
		if tree then
			if ev.act == "open-tab" then
				openTab(cx, tree)
			elseif ev.act == "git-view" then
				openGit(cx, tree)
			elseif ev.act == "copy-path" then
				cx:copy(Model.native(tree.path, WINDOWS))
				cx:toast("info", "Path copied", Model.displayPath(tree.path, WINDOWS))
			elseif not tree.main then
				confirmRemove(cx, tree)
			end
		end
	elseif ev.act == "go" then
		local tree = state.trees[tonumber(ev.value) or 0]
		if tree then
			if held(ev.mods, "ctrl") or held(ev.mods, "meta") then
				openGit(cx, tree)
			else
				goTo(cx, tree)
			end
		end
	end
	return true
end)

tern.on("focus", function(ev: any, cx: any)
	adopt(cx)
	if not state.enabled then
		return
	end
	if not state.placed[ev.tab] then
		schedule()
	end
	if release(cx, ev.tab, ev.pane) then
		return
	end
	state.content[ev.tab] = ev.pane
	if remember(cx, ev.pane) then
		refresh()
	else
		redraw()
	end
end)

tern.on("cwd", function(ev: any, cx: any)
	if not state.enabled then
		return
	end
	if ev.pane == cx.session:focused() and remember(cx, ev.pane) then
		refresh()
	else
		redraw()
	end
end)

tern.on("command_finished", function(ev: any, cx: any)
	if not state.enabled then
		return
	end
	local info = cx.session:pane(ev.pane)
	if info and Model.owner(info.cwd, state.trees, WINDOWS) then
		refresh()
	end
end)

tern.on("agent_finished", function(_ev: any, _cx: any)
	if state.enabled then
		resync()
	end
end)

for _, name in { "pane_created", "pane_closed", "tab_created", "tab_closed" } do
	tern.on(name, function(ev: any, cx: any)
		if not state.enabled or state.filling then
			return
		end
		if name == "pane_closed" then
			state.drawn[ev.pane] = nil
		end
		schedule()
		if name == "pane_created" or name == "pane_closed" then
			resync()
		end
		redraw()
	end)
end

tern.on("window_start", function(cx: any)
	adopt(cx)
end)
