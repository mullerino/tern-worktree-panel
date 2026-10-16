--!strict

local Model = {}

export type Tree = {
	path: string,
	branch: string?,
	head: string?,
	detached: boolean,
	main: boolean,
}

export type Branch = {
	title: string,
	key: string?,
	kind: string?,
	summary: string?,
}

export type Agent = {
	pane: number,
	cwd: string,
	state: string,
	last_message: string?,
}

export type Seen = { [number]: { state: string, since: number } }

export type Pane = {
	pane: number,
	cwd: string?,
}

export type Row = {
	index: number,
	tree: Tree,
	branch: Branch,
	path: string,
	current: boolean,
	open: boolean,
	agent: string?,
	since: number?,
	merged: boolean,
	changed: number,
}

export type Waiting = {
	index: number,
	pane: number,
	branch: Branch,
	since: number,
	message: string,
}

export type Board = {
	rows: { Row },
	waiting: { Waiting },
}

export type BoardInput = {
	trees: { Tree },
	agents: { Agent },
	seen: Seen,
	panes: { Pane },
	cwd: string?,
	windows: boolean,
	status: { [string]: Status }?,
}

local WAITING = "waiting_input"
local WORKING = "working"
local IDLE = "idle"

export type Status = { merged: boolean, changed: number }

function Model.changes(porcelain: string): number
	local count = 0
	local skip = false
	for field in string.gmatch(porcelain, "([^\0]+)") do
		if skip then
			skip = false
		else
			count += 1
			local x = string.sub(field, 1, 1)
			skip = x == "R" or x == "C"
		end
	end
	return count
end

function Model.merged(counts: string, mergedTree: string?, baseTree: string?): boolean
	local behind, ahead = string.match(counts, "^%s*(%d+)%s+(%d+)")
	if not behind or not ahead then
		return false
	end
	if ahead == "0" then
		return behind ~= "0"
	end
	return mergedTree ~= nil and baseTree ~= nil and mergedTree ~= "" and mergedTree == baseTree
end

function Model.norm(path: string?, windows: boolean): string
	if path == nil or path == "" then
		return ""
	end
	local out = path
	if windows then
		out = string.lower((string.gsub(out, "\\", "/")))
	end
	out = string.gsub(out, "/+$", "")
	return out
end

function Model.native(path: string, windows: boolean): string
	if windows then
		return (string.gsub(path, "/", "\\"))
	end
	return path
end

function Model.inside(path: string?, dir: string?, windows: boolean): boolean
	local p, d = Model.norm(path, windows), Model.norm(dir, windows)
	if p == "" or d == "" then
		return false
	end
	return p == d or (string.sub(p, 1, #d) == d and string.sub(p, #d + 1, #d + 1) == "/")
end

function Model.parseWorktrees(text: string): { Tree }
	local trees: { Tree } = {}
	local current: { [string]: any }? = nil
	local function flush()
		if current and not current.bare and not current.prunable then
			table.insert(trees, {
				path = current.path,
				branch = current.branch,
				head = current.head,
				detached = current.detached == true,
				main = current.first == true,
			})
		end
		current = nil
	end
	local first = true
	for field in string.gmatch(text, "([^\0]*)\0") do
		if field == "" then
			flush()
		elseif string.sub(field, 1, 9) == "worktree " then
			flush()
			current = { path = string.sub(field, 10), first = first }
			first = false
		elseif current then
			local entry = current
			if string.sub(field, 1, 5) == "HEAD " then
				entry.head = string.sub(field, 6)
			elseif string.sub(field, 1, 7) == "branch " then
				entry.branch = string.match(field, "^branch refs/heads/(.+)$") or string.sub(field, 8)
			elseif field == "detached" then
				entry.detached = true
			elseif field == "bare" then
				entry.bare = true
			elseif field == "prunable" or string.sub(field, 1, 9) == "prunable " then
				entry.prunable = true
			end
		end
	end
	flush()
	return trees
end

function Model.branch(tree: Tree): Branch
	local name = tree.branch
	if not name then
		local head = tree.head and string.sub(tree.head, 1, 7) or "?"
		return { title = "detached @ " .. head }
	end
	local prefix, key, rest = string.match(name, "^(.-)([A-Z][A-Z0-9]*%-%d+)(.*)$")
	if not key then
		return { title = name }
	end
	local kind = prefix and string.match(prefix, "^([%w_]+)/$")
	if prefix ~= "" and not kind then
		return { title = name }
	end
	local summary = string.gsub(string.gsub(rest or "", "^[-_/]+", ""), "[-_]+", " ")
	return { title = key, key = key, kind = kind, summary = if summary == "" then nil else summary }
end

function Model.displayPath(path: string, windows: boolean): string
	local out = if windows then string.gsub(path, "\\", "/") else path
	local home = string.match(out, "^[A-Za-z]:/[Uu]sers/[^/]+")
		or string.match(out, "^/Users/[^/]+")
		or string.match(out, "^/home/[^/]+")
	local root = ""
	if home then
		root = "~"
		out = string.sub(out, #home + 1)
	end
	local parts = {}
	for part in string.gmatch(out, "[^/]+") do
		table.insert(parts, part)
	end
	if root == "" and string.sub(out, 1, 1) ~= "/" and #parts > 0 then
		root = table.remove(parts, 1) :: string
	end
	if #parts > 3 then
		parts = { parts[1], "…", parts[#parts] }
	end
	if #parts == 0 then
		return if root == "" then out else root
	end
	return root .. "/" .. table.concat(parts, "/")
end

export type Index = { { tree: Tree, dir: string } }

function Model.index(trees: { Tree }, windows: boolean): Index
	local out: Index = {}
	for _, tree in trees do
		table.insert(out, { tree = tree, dir = Model.norm(tree.path, windows) })
	end
	table.sort(out, function(a, b)
		return #a.dir > #b.dir
	end)
	return out
end

function Model.find(path: string?, index: Index, windows: boolean): Tree?
	local p = Model.norm(path, windows)
	if p == "" then
		return nil
	end
	for _, entry in index do
		local d = entry.dir
		if d ~= "" and (p == d or (string.sub(p, 1, #d) == d and string.sub(p, #d + 1, #d + 1) == "/")) then
			return entry.tree
		end
	end
	return nil
end

function Model.owner(path: string?, trees: { Tree }, windows: boolean): Tree?
	return Model.find(path, Model.index(trees, windows), windows)
end

function Model.track(seen: Seen, agents: { Agent }, now: number): (Seen, boolean)
	local next: Seen = {}
	local changed = false
	for _, agent in agents do
		local previous = seen[agent.pane]
		if previous and previous.state == agent.state then
			next[agent.pane] = previous
		else
			next[agent.pane] = { state = agent.state, since = now }
			changed = true
		end
	end
	for pane in seen do
		if not next[pane] then
			changed = true
		end
	end
	return next, changed
end

function Model.excerpt(message: string?, limit: number): string
	if not message then
		return ""
	end
	local text = string.gsub(message, "```.-```", " ")
	text = string.gsub(text, "[`*_#>]", "")
	text = string.gsub(text, "%s+", " ")
	text = string.gsub(text, "^ ", "")
	text = string.gsub(text, " $", "")
	if (utf8.len(text) or 0) > limit then
		local cut = utf8.offset(text, limit + 1)
		if cut and cut <= #text then
			text = string.gsub(string.sub(text, 1, cut - 1), " +$", "") .. "…"
		end
	end
	return text
end

function Model.target(panes: { Pane }, trees: { Tree }, tree: Tree, last: number?, windows: boolean): number?
	local index = Model.index(trees, windows)
	local first: number? = nil
	for _, pane in panes do
		if Model.find(pane.cwd, index, windows) == tree then
			if pane.pane == last then
				return pane.pane
			end
			first = first or pane.pane
		end
	end
	return first
end

local function rank(state: string): number
	if state == WAITING then
		return 3
	end
	if state == WORKING then
		return 2
	end
	if state == IDLE then
		return 1
	end
	return 0
end

function Model.board(input: BoardInput): Board
	local windows = input.windows
	local index = Model.index(input.trees, windows)
	local current = Model.find(input.cwd, index, windows)
	local open: { [Tree]: boolean } = {}
	for _, pane in input.panes do
		local tree = Model.find(pane.cwd, index, windows)
		if tree then
			open[tree] = true
		end
	end
	local strongest: { [Tree]: Agent } = {}
	local waitingByTree: { [Tree]: { Agent } } = {}
	for _, agent in input.agents do
		local tree = Model.find(agent.cwd, index, windows)
		if tree then
			local best = strongest[tree]
			if not best or rank(agent.state) > rank(best.state) then
				strongest[tree] = agent
			end
			if agent.state == WAITING then
				waitingByTree[tree] = waitingByTree[tree] or {}
				table.insert(waitingByTree[tree], agent)
			end
		end
	end
	local board: Board = { rows = {}, waiting = {} }
	for position, tree in input.trees do
		local branch = Model.branch(tree)
		local waiting = waitingByTree[tree]
		if waiting then
			for _, agent in waiting do
				local seen = input.seen[agent.pane]
				table.insert(board.waiting, {
					index = position,
					pane = agent.pane,
					branch = branch,
					since = if seen then seen.since else 0,
					message = agent.last_message or "",
				})
			end
		else
			local agent = strongest[tree]
			local seen = agent and input.seen[agent.pane]
			local status = input.status and input.status[Model.norm(tree.path, windows)]
			table.insert(board.rows, {
				index = position,
				tree = tree,
				branch = branch,
				path = Model.displayPath(tree.path, windows),
				current = tree == current,
				open = open[tree] == true,
				agent = agent and agent.state,
				since = seen and seen.since,
				merged = not tree.main and status ~= nil and status.merged,
				changed = if status then status.changed else 0,
			})
		end
	end
	table.sort(board.waiting, function(a, b)
		return a.since < b.since
	end)
	return board
end

export type Side = string

export type Split = { pane: number?, split: ("right" | "down")?, ratio: number?, [number]: Split }

function Model.side(value: any): Side
	return if value == "right" then "right" else "left"
end

function Model.edge(tree: Split?, side: Side, skip: number?): number?
	if not tree then
		return nil
	end
	if tree.pane then
		return if tree.pane == skip then nil else tree.pane
	end
	local near, far = tree[1], tree[2]
	if side == "right" and tree.split == "right" then
		near, far = tree[2], tree[1]
	end
	return Model.edge(near, side, skip) or Model.edge(far, side, skip)
end

function Model.share(root: Split?, pane: number, side: Side): number?
	if not root or root.split ~= "right" or not root.ratio then
		return nil
	end
	if side == "left" and root[1] and root[1].pane == pane then
		return root.ratio
	end
	if side == "right" and root[2] and root[2].pane == pane then
		return 1 - root.ratio
	end
	return nil
end

function Model.inward(side: Side): string
	return if side == "left" then "right" else "left"
end

return Model
