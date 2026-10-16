--!strict

local Model = require("../model")
local runner = require("./runner")
local test, eq = runner.test, runner.eq

local function porcelain(records: { { string } }): string
	local out = {}
	for _, record in records do
		for _, field in record do
			table.insert(out, field .. "\0")
		end
		table.insert(out, "\0")
	end
	return table.concat(out)
end

local MAIN = "C:/Users/dev/Documents/acme-api"
local LOGIN = "C:/Users/dev/wt/acme-api/APP-142"
local HOOKS = "C:/Users/dev/wt/acme-api/APP-157"

local function trees(): { Model.Tree }
	return {
		{ path = MAIN, branch = "main", detached = false, main = true },
		{ path = LOGIN, branch = "feat/APP-142-oauth-login", detached = false, main = false },
		{ path = HOOKS, branch = "fix/APP-157-retry-failed-webhooks", detached = false, main = false },
	}
end

local function input(over: { [string]: any }): Model.BoardInput
	local base: { [string]: any } = { trees = trees(), agents = {}, seen = {}, panes = {}, cwd = nil, windows = true }
	for k, v in over do
		base[k] = v
	end
	return base :: any
end

test("parseWorktrees keeps the main checkout first and drops bare and prunable entries", function()
	local list = Model.parseWorktrees(porcelain({
		{ "worktree " .. MAIN, "HEAD aaa", "branch refs/heads/main" },
		{
			"worktree C:/gone",
			"HEAD bbb",
			"branch refs/heads/old",
			"prunable gitdir file points to non-existent location",
		},
		{ "worktree " .. LOGIN, "HEAD ccc1234567", "detached" },
		{ "worktree C:/bare.git", "bare" },
	}))
	eq(#list, 2, "count")
	eq(list[1].path, MAIN, "first path")
	eq(list[1].branch, "main", "branch without refs/heads")
	eq(list[1].main, true, "first is main")
	eq(list[2].detached, true, "detached")
	eq(list[2].main, false, "second is not main")
	eq(Model.branch(list[2]).title, "detached @ ccc1234", "detached title uses short head")
end)

test("parseWorktrees accepts output without the trailing record terminator", function()
	local text = "worktree " .. MAIN .. "\0HEAD aaa\0branch refs/heads/main\0"
	eq(#Model.parseWorktrees(text), 1, "count")
end)

test("branch splits type, ticket key and summary", function()
	local b = Model.branch({
		path = LOGIN,
		branch = "feat/APP-142-oauth-login",
		detached = false,
		main = false,
	})
	eq(b.title, "APP-142", "title")
	eq(b.kind, "feat", "kind")
	eq(b.summary, "oauth login", "summary")
end)

test("branch keeps names without a key, or with a key in the middle, as they are", function()
	local plain = Model.branch({ path = MAIN, branch = "chore/upgrade-node-22", detached = false, main = false })
	eq(plain.title, "chore/upgrade-node-22", "no key")
	eq(plain.key, nil, "no key field")
	local nested = Model.branch({ path = MAIN, branch = "users/me/APP-1-x", detached = false, main = false })
	eq(nested.title, "users/me/APP-1-x", "multi-segment prefix")
	local bare = Model.branch({ path = MAIN, branch = "APP-12", detached = false, main = false })
	eq(bare.title, "APP-12", "bare key")
	eq(bare.kind, nil, "bare key has no kind")
	eq(bare.summary, nil, "bare key has no summary")
end)

test("owner picks the deepest worktree and compares Windows paths ignoring case and slashes", function()
	local list = trees()
	local nested = { path = MAIN .. "/.worktrees/x", branch = "x", detached = false, main = false }
	table.insert(list, nested)
	eq(Model.owner("c:\\users\\dev\\documents\\acme-api\\.worktrees\\x\\src", list, true), nested, "nested")
	eq(Model.owner("C:\\Users\\dev\\Documents\\acme-api\\src", list, true), list[1], "main")
	eq(Model.owner("C:/Users/dev/Documents/acme-api-old", list, true), nil, "prefix of another dir")
	eq(Model.owner("C:/Users/dev/Documents/ACME-API", list, false), nil, "case matters off Windows")
end)

test("displayPath shortens the home directory and deep paths", function()
	eq(Model.displayPath(LOGIN, true), "~/wt/acme-api/APP-142", "three parts kept")
	eq(
		Model.displayPath("C:/Users/dev/.paseo/worktrees/0wyhfz0w/quiet-otter", true),
		"~/.paseo/…/quiet-otter",
		"deep"
	)
	eq(Model.displayPath("/home/dev/src/app", false), "~/src/app", "linux home")
	eq(Model.displayPath("D:/repos/a/b/c/d", true), "D:/repos/…/d", "other drive")
end)

test("track keeps the time an agent entered its state and resets it on change", function()
	local agents = { { pane = 1, cwd = LOGIN, state = "working" } }
	local seen, changed = Model.track({}, agents, 1000)
	eq(changed, true, "new agent")
	eq(seen[1].since, 1000, "first sight")
	seen, changed = Model.track(seen, agents, 5000)
	eq(changed, false, "same state")
	eq(seen[1].since, 1000, "kept")
	seen, changed = Model.track(seen, { { pane = 1, cwd = LOGIN, state = "waiting_input" } }, 9000)
	eq(changed, true, "state change")
	eq(seen[1].since, 9000, "reset")
	seen, changed = Model.track(seen, {}, 9500)
	eq(changed, true, "agent gone")
	eq(seen[1], nil, "dropped")
end)

test("excerpt strips markdown, collapses whitespace and cuts on characters", function()
	eq(Model.excerpt("**Can** I run\n\n`npm run migrate`?", 80), "Can I run npm run migrate?", "cleaned")
	eq(Model.excerpt("before ```js\ncode\n``` after", 80), "before after", "code block removed")
	eq(Model.excerpt("café café café", 9), "café café…", "utf-8 cut")
	eq(Model.excerpt(nil, 10), "", "nil")
end)

test("board marks the current worktree, open tabs and the strongest agent state", function()
	local b = Model.board(input({
		cwd = LOGIN .. "/src",
		panes = { { pane = 10, cwd = HOOKS } },
		agents = {
			{ pane = 20, cwd = HOOKS, state = "idle" },
			{ pane = 21, cwd = HOOKS, state = "working" },
			{ pane = 22, cwd = "C:/Users/dev/Documents/other", state = "waiting_input" },
		},
		seen = { [21] = { state = "working", since = 42 } },
	}))
	eq(#b.rows, 3, "rows")
	eq(#b.waiting, 0, "agent in another repo is ignored")
	eq(b.rows[2].current, true, "login current")
	eq(b.rows[2].agent, nil, "no agent in login")
	eq(b.rows[3].open, true, "hooks open")
	eq(b.rows[3].agent, "working", "working beats idle")
	eq(b.rows[3].since, 42, "working since")
	eq(b.rows[1].open, false, "main not open")
end)

test("board moves worktrees with a waiting agent to the top, oldest wait first", function()
	local b = Model.board(input({
		agents = {
			{ pane = 30, cwd = HOOKS, state = "waiting_input", last_message = "B" },
			{ pane = 31, cwd = LOGIN, state = "waiting_input", last_message = "A" },
		},
		seen = { [30] = { state = "waiting_input", since = 900 }, [31] = { state = "waiting_input", since = 100 } },
	}))
	eq(#b.rows, 1, "only main left in the list")
	eq(#b.waiting, 2, "two waiting")
	eq(b.waiting[1].pane, 31, "oldest first")
	eq(b.waiting[1].branch.title, "APP-142", "title")
	eq(b.waiting[2].message, "B", "message")
end)

test("target prefers the last used pane of the worktree, else its first", function()
	local list = trees()
	local panes = { { pane = 1, cwd = LOGIN }, { pane = 2, cwd = LOGIN .. "/src" }, { pane = 3, cwd = MAIN } }
	eq(Model.target(panes, list, list[2], 2, true), 2, "last used")
	eq(Model.target(panes, list, list[2], 3, true), 1, "last used is elsewhere")
	eq(Model.target(panes, list, list[3], nil, true), nil, "no pane")
	eq(Model.target({ { pane = 4, cwd = LOGIN } }, list, list[1], nil, true), nil, "nested tree is not main")
end)

local function leaf(pane: number): Model.Split
	return { pane = pane }
end

test("edge picks the outermost pane of the chosen side, skipping the panel", function()
	local layout: Model.Split = {
		split = "right",
		ratio = 0.5,
		[1] = { split = "down", ratio = 0.5, [1] = leaf(1), [2] = leaf(2) },
		[2] = { split = "right", ratio = 0.5, [1] = leaf(3), [2] = leaf(4) },
	}
	eq(Model.edge(layout, "left"), 1, "left edge")
	eq(Model.edge(layout, "right"), 4, "right edge")
	eq(Model.edge(layout, "right", 4), 3, "right edge without the panel")
	eq(Model.edge(leaf(9), "right", 9), nil, "panel alone in the tab")
end)

test("edge does not reorder a vertical split", function()
	local stacked: Model.Split = { split = "down", ratio = 0.5, [1] = leaf(1), [2] = leaf(2) }
	eq(Model.edge(stacked, "right"), 1, "top pane first")
end)

test("share reads the panel's fraction from its own side of the root split", function()
	local left: Model.Split = { split = "right", ratio = 0.26, [1] = leaf(7), [2] = leaf(8) }
	local right: Model.Split = { split = "right", ratio = 0.74, [1] = leaf(8), [2] = leaf(7) }
	eq(Model.share(left, 7, "left"), 0.26, "left share")
	eq(Model.share(left, 7, "right"), nil, "panel is not on the right")
	eq(math.abs((Model.share(right, 7, "right") or 0) - 0.26) < 1e-9, true, "right share")
	eq(Model.share({ split = "down", ratio = 0.3, [1] = leaf(7), [2] = leaf(8) }, 7, "left"), nil, "vertical root")
end)

test("side defaults to left and inward points toward the content", function()
	eq(Model.side(nil), "left", "unset")
	eq(Model.side("right"), "right", "right")
	eq(Model.side("up"), "left", "invalid")
	eq(Model.inward("left"), "right", "left panel grows right")
	eq(Model.inward("right"), "left", "right panel grows left")
end)

runner.finish()
