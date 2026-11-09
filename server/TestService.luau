-- Test harness for RazorMarket (not part of the package).
--
-- Unit suite (runs once on server start): every test gets a FRESH copy of the package wired to
-- in-memory fakes of MarketplaceService, DataStoreService, Players, RunService and the DataModel,
-- so every branch (outages, retries, races, other servers, shutdown) runs deterministically.
-- Needs no DataStore access and no real players.
--
-- Live suite (runs for each real player): exactly-once receipt checks against the REAL services.
-- Requires DataStore API access (or set USE_LEDGER = false for pure local testing).
HttpService = use "HttpService"
ReplicatedStorage = use "ReplicatedStorage"
RazorMarket = use "razormarket"

local TEST_PRODUCT = 3729815949 -- replace with a real developer product id
local TEST_PASS = 2075908399 -- replace with a real game pass id
local USE_LEDGER = true
-- Print every RazorMarket log line captured by the unit suite, not only those of failing tests.
local VERBOSE = false

local TAG = "[RazorMarket Test]"
local Granted = Enum.ProductPurchaseDecision.PurchaseGranted
local NotYet = Enum.ProductPurchaseDecision.NotProcessedYet

-- Ids used by the unit suite; the fakes accept anything.
local PRODUCT = 1001
local PASS = 2001
local OTHER_PASS = 2002
local SUB = "EXP-1"
local OTHER_SUB = "EXP-2"

local PackageModule = ReplicatedStorage:WaitForChild("packages"):WaitForChild("razormarket")

local unitSuiteDone = false

--------------------------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------------------------

local function describe(value: any): string
	if type(value) == "string" then
		return `"{value}"`
	end
	return tostring(value)
end

local function expect(condition: any, what: string)
	if not condition then
		error(what, 2)
	end
end

local function expectEqual(actual: any, expected: any, what: string)
	if actual ~= expected then
		error(`{what}: expected {describe(expected)}, got {describe(actual)}`, 2)
	end
end

local function expectError(fn: () -> (), fragment: string, what: string)
	local ok, err = pcall(fn)
	if ok then
		error(`{what}: expected an error containing {describe(fragment)}`, 2)
	end
	if not string.find(tostring(err), fragment, 1, true) then
		error(`{what}: expected an error containing {describe(fragment)}, got {describe(err)}`, 2)
	end
end

-- Yields until `condition` holds; fails the test after `timeout` seconds instead of hanging the suite.
local function waitFor(condition: () -> boolean, what: string, timeout: number?)
	local deadline = os.clock() + (timeout or 2)
	while not condition() do
		if os.clock() > deadline then
			error(`timed out waiting for {what}`, 2)
		end
		task.wait()
	end
end

--------------------------------------------------------------------------------------------------
-- Fakes
--------------------------------------------------------------------------------------------------

local function newSignal()
	local listeners: { (...any) -> () } = {}
	return {
		Connect = function(_, listener: (...any) -> ())
			table.insert(listeners, listener)
		end,
		Fire = function(_, ...)
			for _, listener in table.clone(listeners) do
				task.spawn(listener, ...)
			end
		end,
		Count = function(_): number
			return #listeners
		end,
	}
end

-- A switch a handler can block on, so tests can hold work "in flight".
local function newGate()
	local gate: any = { Open = false, Entered = 0 }
	function gate.Wait()
		gate.Entered += 1
		while not gate.Open do
			task.wait()
		end
	end
	return gate
end

-- One fake server: a fresh RazorMarket plus fakes it talks to. Options:
--   JobId, Ledger, Profiles  share Ledger/Profiles between harnesses to simulate several servers
--   IsStudio, IsServer       what the fake RunService reports (default true)
--   NoProfileCheck           don't configure IsAlreadyGranted
--   DefaultLogger            keep RazorMarket's own logger (output goes to the console, not Logs)
--   Config                   extra RazorMarket.Configure fields
local function newHarness(options: { [string]: any }?)
	local opts = options or {}
	local h: any = {
		RM = use(PackageModule:Clone()),
		JobId = opts.JobId or "server-A",
		Logs = {} :: { { Level: string, Message: string } },
		LogHook = nil :: ((string, string) -> ())?,
		Gates = {},

		-- DataStoreService
		Ledger = opts.Ledger or {},
		LedgerName = nil :: string?,
		GetDataStoreFails = false,
		BrokenDataStoreService = false,
		UpdateFailures = 0, -- the next N UpdateAsync calls throw
		UpdateCalls = 0,

		-- MarketplaceService
		Owned = {}, -- [`{userId}:{passId}`] = true
		OwnsFailures = 0,
		OwnsCalls = 0,
		Subscriptions = {}, -- [subscriptionId] = raw GetUserSubscriptionStatusAsync result
		SubFailures = 0,
		SubCalls = 0,
		HoldSubs = false, -- while true, subscription lookups stay in flight
		InfoFailures = 0,
		InfoCalls = 0,
		Prompts = {} :: { string },

		-- Game state
		Profiles = opts.Profiles or {},
		GrantCount = {},
		CloseCallbacks = {},
		IsStudio = opts.IsStudio ~= false,
		IsServer = opts.IsServer ~= false,
	}

	local function failIf(counter: string, api: string)
		if h[counter] > 0 then
			h[counter] -= 1
			error(`{api}: fake outage`)
		end
	end

	local dataStoreMethods = {
		GetDataStore = function(_, name: string)
			if h.GetDataStoreFails then
				error("DataStore API access is disabled (fake)")
			end
			h.LedgerName = name
			return {
				UpdateAsync = function(_, key: string, transform: (any) -> any)
					h.UpdateCalls += 1
					task.wait() -- yield like the real thing; the transform itself stays atomic
					failIf("UpdateFailures", "UpdateAsync")
					local new = transform(h.Ledger[key])
					if new ~= nil then
						h.Ledger[key] = new
					end
					return new
				end,
			}
		end,
	}
	-- While BrokenDataStoreService is set, merely touching the service throws, like an engine bug
	-- would: outside every retry, so only RazorMarket's last-resort pcall can contain it.
	h.DataStoreService = setmetatable({}, {
		__index = function(_, key: string)
			if h.BrokenDataStoreService then
				error("DataStoreService is broken (fake)")
			end
			return dataStoreMethods[key]
		end,
	})

	h.MarketplaceService = {
		ProcessReceipt = nil :: any,
		PromptGamePassPurchaseFinished = newSignal(),
		UserOwnsGamePassAsync = function(_, userId: number, passId: number)
			h.OwnsCalls += 1
			failIf("OwnsFailures", "UserOwnsGamePassAsync")
			return h.Owned[`{userId}:{passId}`] == true
		end,
		GetUserSubscriptionStatusAsync = function(_, _player, subscriptionId: string)
			h.SubCalls += 1
			-- Answer with the status as of the START of the request, like a slow web call.
			local result = h.Subscriptions[subscriptionId] or { IsSubscribed = false, IsRenewing = false }
			while h.HoldSubs do
				task.wait()
			end
			failIf("SubFailures", "GetUserSubscriptionStatusAsync")
			return result
		end,
		GetProductInfo = function(_, id: number, infoType: Enum.InfoType)
			h.InfoCalls += 1
			failIf("InfoFailures", "GetProductInfo")
			return { Id = id, InfoType = infoType.Name }
		end,
		PromptProductPurchase = function(_, player, id: number)
			table.insert(h.Prompts, `product:{player.UserId}:{id}`)
		end,
		PromptGamePassPurchase = function(_, player, id: number)
			table.insert(h.Prompts, `pass:{player.UserId}:{id}`)
		end,
		PromptSubscriptionPurchase = function(_, player, id: string)
			table.insert(h.Prompts, `subscription:{player.UserId}:{id}`)
		end,
	}

	local players: { any } = {}
	h.Players = {
		PlayerAdded = newSignal(),
		PlayerRemoving = newSignal(),
		UserSubscriptionStatusChanged = newSignal(),
		GetPlayers = function(_)
			return table.clone(players)
		end,
		GetPlayerByUserId = function(_, userId: number)
			for _, player in players do
				if player.UserId == userId then
					return player
				end
			end
			return nil
		end,
	}

	h.RM._useServices({
		DataStoreService = h.DataStoreService,
		MarketplaceService = h.MarketplaceService,
		Players = h.Players,
		RunService = {
			IsServer = function()
				return h.IsServer
			end,
			IsStudio = function()
				return h.IsStudio
			end,
		},
		DataModel = {
			JobId = h.JobId,
			BindToClose = function(_, callback: () -> ())
				table.insert(h.CloseCallbacks, callback)
			end,
		},
	})

	local config: { [string]: any } = { RetryDelay = 0, MaxRetries = 2 }
	if not opts.DefaultLogger then
		config.Logger = function(level: string, message: string)
			table.insert(h.Logs, { Level = level, Message = message })
			if h.LogHook then
				h.LogHook(level, message)
			end
		end
	end
	if not opts.NoProfileCheck then
		config.IsAlreadyGranted = function(player, purchaseId: string)
			return h:Profile(player).Purchases[purchaseId] == true
		end
	end
	for key, value in opts.Config or {} do
		config[key] = value
	end
	h.RM.Configure(config)

	-- A player that is already in the server (no PlayerAdded), e.g. present before Start().
	function h:AddPlayer(userId: number)
		local player = { UserId = userId, Name = `Fake{userId}` }
		table.insert(players, player)
		return player
	end

	function h:Join(userId: number)
		local player = self:AddPlayer(userId)
		self.Players.PlayerAdded:Fire(player)
		return player
	end

	-- PlayerRemoving fires while the player is still in the server, as in Roblox.
	function h:StartLeaving(player)
		self.Players.PlayerRemoving:Fire(player)
	end

	function h:Leave(player)
		self:StartLeaving(player)
		table.remove(players, table.find(players, player))
	end

	function h:Profile(player)
		self.Profiles[player.UserId] = self.Profiles[player.UserId] or { Purchases = {}, Coins = 0 }
		return self.Profiles[player.UserId]
	end

	-- The handler shape the package requires: idempotent, PurchaseId saved with the item.
	function h:Grant(player, receipt): boolean
		local profile = self:Profile(player)
		if profile.Purchases[receipt.PurchaseId] then
			return true
		end
		profile.Coins += 100
		profile.Purchases[receipt.PurchaseId] = true
		self.GrantCount[receipt.PurchaseId] = (self.GrantCount[receipt.PurchaseId] or 0) + 1
		return true
	end

	function h:HandleGranting(productId: number?)
		self.RM.HandleProduct(productId or PRODUCT, function(player, receipt)
			return self:Grant(player, receipt)
		end)
	end

	function h:Receipt(player, productId: number?)
		return {
			PurchaseId = "test_" .. HttpService:GenerateGUID(false),
			PlayerId = player.UserId,
			ProductId = productId or PRODUCT,
			PlaceIdWherePurchased = game.PlaceId,
			CurrencySpent = 0,
			CurrencyType = Enum.CurrencyType.Robux,
		}
	end

	function h:Process(receipt)
		return self.RM._processReceipt(receipt)
	end

	-- Runs ProcessReceipt in its own thread; read .Decision once it is non-nil.
	function h:ProcessAsync(receipt)
		local result = { Decision = nil :: Enum.ProductPurchaseDecision? }
		task.spawn(function()
			result.Decision = self:Process(receipt)
		end)
		return result
	end

	function h:Gate()
		local gate = newGate()
		table.insert(self.Gates, gate)
		return gate
	end

	function h:Logged(level: string, fragment: string): boolean
		for _, entry in self.Logs do
			if entry.Level == level and string.find(entry.Message, fragment, 1, true) then
				return true
			end
		end
		return false
	end

	function h:CountLogs(level: string): number
		local count = 0
		for _, entry in self.Logs do
			if entry.Level == level then
				count += 1
			end
		end
		return count
	end

	function h:ExpectLog(level: string, fragment: string)
		if not self:Logged(level, fragment) then
			error(`expected a {level} log containing {describe(fragment)} ({#self.Logs} lines captured)`, 2)
		end
	end

	-- Lets leftover threads finish so they can't leak into the next test.
	function h:Release()
		self.HoldSubs = false
		for _, gate in self.Gates do
			gate.Open = true
		end
	end

	return h
end

--------------------------------------------------------------------------------------------------
-- Test runner
--------------------------------------------------------------------------------------------------

type NewHarness = (options: { [string]: any }?) -> any
local tests: { { Name: string, Run: (new: NewHarness) -> () } } = {}

local function test(name: string, run: (new: NewHarness) -> ())
	table.insert(tests, { Name = name, Run = run })
end

local function runUnitSuite()
	print(`{TAG} Unit suite: {#tests} tests against fresh copies of {PackageModule:GetFullName()}`)
	local suiteStart = os.clock()
	local failures: { string } = {}

	for _, t in tests do
		local harnesses = {}
		local function new(options: { [string]: any }?)
			local h = newHarness(options)
			table.insert(harnesses, h)
			return h
		end

		local testStart = os.clock()
		local ok, err = pcall(t.Run, new)
		for _, h in harnesses do
			h:Release()
		end
		local ms = math.round((os.clock() - testStart) * 1000)

		if ok then
			print(`{TAG}   PASS  {t.Name} ({ms} ms)`)
		else
			table.insert(failures, t.Name)
			warn(`{TAG}   FAIL  {t.Name} ({ms} ms)\n{TAG}         {err}`)
		end
		if not ok or VERBOSE then
			for _, h in harnesses do
				for _, entry in h.Logs do
					print(`{TAG}         [{h.JobId}] {entry.Level}: {entry.Message}`)
				end
			end
		end
	end

	local seconds = string.format("%.2f", os.clock() - suiteStart)
	local summary = `Unit suite: {#tests - #failures}/{#tests} passed in {seconds} s`
	if #failures > 0 then
		local bullet = `\n{TAG}   - `
		warn(`{TAG} {summary}. Failed:{bullet}{table.concat(failures, bullet)}`)
	else
		print(`{TAG} {summary}`)
	end
end

--------------------------------------------------------------------------------------------------
-- Unit tests: setup
--------------------------------------------------------------------------------------------------

test("Start: refuses to run on the client", function(new)
	local h = new({ IsServer = false })
	expectError(h.RM.Start, "must run on the server", "Start on the client")
end)

test("Start: warns about a disabled ledger and a missing IsAlreadyGranted", function(new)
	local h = new({ NoProfileCheck = true, Config = { UseLedger = false } })
	h.RM.Start()
	h:ExpectLog("warn", "UseLedger = false")
	h:ExpectLog("warn", "No IsAlreadyGranted configured")
end)

test("Start: default logger writes warnings to the output", function(new)
	print(`{TAG}         (expected) the next two [RazorMarket] warnings come from this test`)
	local h = new({ DefaultLogger = true, NoProfileCheck = true, Config = { UseLedger = false } })
	h.RM.Start()
	expectEqual(#h.Logs, 0, "lines captured with the default logger")
end)

test("Start: a second call is a no-op", function(new)
	local h = new()
	h.RM.Start()
	local listeners = h.Players.PlayerAdded:Count()
	h.RM.Start()
	expectEqual(h.Players.PlayerAdded:Count(), listeners, "PlayerAdded listeners after second Start")
	expectEqual(#h.CloseCallbacks, 1, "BindToClose callbacks")
end)

test("Configure: rejected after Start", function(new)
	local h = new()
	h.RM.Start()
	expectError(function()
		h.RM.Configure({})
	end, "must be called before Start", "Configure after Start")
	expectError(function()
		h.RM._useServices({})
	end, "must be called before Start", "_useServices after Start")
end)

test("Configure: LedgerName names the ledger DataStore", function(new)
	local h = new({ Config = { LedgerName = "CustomLedger" } })
	h:HandleGranting()
	h.RM.Start()
	local player = h:Join(1)
	expectEqual(h:Process(h:Receipt(player)), Granted, "decision")
	expectEqual(h.LedgerName, "CustomLedger", "DataStore name")
end)

test("HandleProduct: a second handler for the same product errors", function(new)
	local h = new()
	h:HandleGranting()
	expectError(function()
		h:HandleGranting()
	end, `Product {PRODUCT} already has a handler`, "duplicate HandleProduct")
end)

--------------------------------------------------------------------------------------------------
-- Unit tests: receipts on one server
--------------------------------------------------------------------------------------------------

test("receipt: first delivery grants once and records 'granted'", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local player = h:Join(1)
	local receipt = h:Receipt(player)
	expectEqual(h:Process(receipt), Granted, "decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
	local entry = h.Ledger[receipt.PurchaseId]
	expectEqual(entry and entry.Status, "granted", "ledger status")
	expectEqual(entry.JobId, h.JobId, "ledger JobId")
	expectEqual(entry.ProductId, PRODUCT, "ledger ProductId")
	expectEqual(h:CountLogs("error"), 0, "errors logged")
end)

test("receipt: Roblox's ProcessReceipt callback runs the pipeline", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h.MarketplaceService.ProcessReceipt(receipt), Granted, "decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
end)

test("receipt: duplicate is acknowledged from the profile without re-granting", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	h:Process(receipt)
	local updates = h.UpdateCalls
	expectEqual(h:Process(receipt), Granted, "duplicate decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "granted", "ledger status (never downgraded)")
	expectEqual(h.UpdateCalls, updates + 1, "UpdateAsync calls on duplicate (best-effort record only)")
end)

test("receipt: duplicate is acknowledged from the ledger when there is no profile check", function(new)
	local h = new({ NoProfileCheck = true })
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	h:Process(receipt)
	expectEqual(h:Process(receipt), Granted, "duplicate decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
end)

test("receipt: concurrent duplicate on the same server is deferred", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	local first = h:ProcessAsync(receipt) -- yields inside the ledger claim
	expectEqual(h:Process(receipt), NotYet, "second (concurrent) decision")
	waitFor(function()
		return first.Decision ~= nil
	end, "first delivery")
	expectEqual(first.Decision, Granted, "first decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
end)

test("receipt: player not in the server is retried later", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt({ UserId = 999 })
	expectEqual(h:Process(receipt), NotYet, "decision")
	expectEqual(h.UpdateCalls, 0, "ledger touched")
end)

test("receipt: unknown product with no default handler is not granted", function(new)
	local h = new()
	h.RM.Start()
	expectEqual(h:Process(h:Receipt(h:Join(1), -1)), NotYet, "decision")
	h:ExpectLog("error", "No handler registered for product -1")
end)

test("receipt: HandleDefaultProduct catches unregistered products", function(new)
	local h = new()
	local seen
	h.RM.HandleDefaultProduct(function(player, receipt)
		seen = receipt.ProductId
		return h:Grant(player, receipt)
	end)
	h.RM.Start()
	expectEqual(h:Process(h:Receipt(h:Join(1), 4242)), Granted, "decision")
	expectEqual(seen, 4242, "product seen by the default handler")
end)

test("receipt: handler returning false releases the claim for a retry", function(new)
	local h = new()
	local ready = false
	h.RM.HandleProduct(PRODUCT, function(player, receipt)
		return ready and h:Grant(player, receipt)
	end)
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h:Process(receipt), NotYet, "decision while not ready")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "released", "ledger status")
	ready = true
	expectEqual(h:Process(receipt), Granted, "decision on retry")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
end)

test("receipt: handler error is logged and releases the claim", function(new)
	local h = new()
	h.RM.HandleProduct(PRODUCT, function()
		error("profile save failed")
	end)
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h:Process(receipt), NotYet, "decision")
	h:ExpectLog("error", `Handler for product {PRODUCT} errored`)
	h:ExpectLog("error", "profile save failed")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "released", "ledger status")
end)

test("receipt: IsAlreadyGranted error defers without running the handler", function(new)
	local h = new({
		Config = {
			IsAlreadyGranted = function()
				error("profile not loaded")
			end,
		},
	})
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h:Process(receipt), NotYet, "decision")
	h:ExpectLog("warn", "IsAlreadyGranted errored")
	expectEqual(h.GrantCount[receipt.PurchaseId], nil, "grants")
	expectEqual(h.UpdateCalls, 0, "ledger touched")
end)

test("receipt: purchase already in the profile is acknowledged and recorded", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local player = h:Join(1)
	local receipt = h:Receipt(player)
	h:Profile(player).Purchases[receipt.PurchaseId] = true -- saved, but the ledger write was lost
	expectEqual(h:Process(receipt), Granted, "decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], nil, "grants")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "granted", "ledger status")
end)

test("receipt: player who is leaving gets the claim released", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local player = h:Join(1)
	h:StartLeaving(player)
	local receipt = h:Receipt(player)
	expectEqual(h:Process(receipt), NotYet, "decision")
	expectEqual(h.GrantCount[receipt.PurchaseId], nil, "grants")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "released", "ledger status")
end)

test("receipt: failed 'granted' write only retries the recording", function(new)
	local h = new()
	h.RM.HandleProduct(PRODUCT, function(player, receipt)
		h.UpdateFailures = 2 -- every attempt of the following 'granted' write fails
		return h:Grant(player, receipt)
	end)
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h:Process(receipt), NotYet, "decision when the record fails")
	h:ExpectLog("error", "but ledger write failed")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "claimed", "ledger status")

	h.UpdateFailures = 2
	expectEqual(h:Process(receipt), NotYet, "decision when the record fails again")
	expectEqual(h:Process(receipt), Granted, "decision once the record succeeds")
	expectEqual(h.Ledger[receipt.PurchaseId].Status, "granted", "ledger status")
	expectEqual(h:Process(receipt), Granted, "decision after recovery")
	expectEqual(h.GrantCount[receipt.PurchaseId], 1, "grants")
end)

test("receipt: transient ledger error is retried within the same delivery", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	h.UpdateFailures = 1
	expectEqual(h:Process(h:Receipt(h:Join(1))), Granted, "decision")
	h:ExpectLog("warn", "Ledger claim failed (attempt 1/2)")
end)

test("receipt: unreachable ledger defers, logged once with a Studio hint", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	h.GetDataStoreFails = true
	local player = h:Join(1)
	local receipt = h:Receipt(player)
	expectEqual(h:Process(receipt), NotYet, "first decision")
	expectEqual(h:Process(h:Receipt(player)), NotYet, "second decision")
	expectEqual(h:CountLogs("error"), 1, "errors logged")
	h:ExpectLog("error", "Purchase ledger unavailable")
	h:ExpectLog("error", "Enable Studio Access to API Services")
	expectEqual(h.GrantCount[receipt.PurchaseId], nil, "grants")

	-- The ledger is fetched lazily, so it recovers once DataStores come back.
	h.GetDataStoreFails = false
	expectEqual(h:Process(receipt), Granted, "decision after recovery")
end)

test("receipt: ledger outage outside Studio has no Studio hint", function(new)
	local h = new({ IsStudio = false })
	h:HandleGranting()
	h.RM.Start()
	h.UpdateFailures = 2
	expectEqual(h:Process(h:Receipt(h:Join(1))), NotYet, "decision")
	h:ExpectLog("warn", "Ledger claim failed (attempt 2/2)")
	h:ExpectLog("error", "Purchase ledger unavailable")
	expect(not h:Logged("error", "Studio"), "Studio hint logged outside Studio")
end)

test("receipt: profile proves the grant even with no ledger", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	h.GetDataStoreFails = true
	local player = h:Join(1)
	local receipt = h:Receipt(player)
	h:Profile(player).Purchases[receipt.PurchaseId] = true
	expectEqual(h:Process(receipt), Granted, "decision")
end)

test("receipt: UseLedger = false never touches DataStores", function(new)
	local h = new({ Config = { UseLedger = false } })
	h:HandleGranting()
	h.RM.Start()
	h.GetDataStoreFails = true -- would turn any ledger access into an error log
	local receipt = h:Receipt(h:Join(1))
	expectEqual(h:Process(receipt), Granted, "decision")
	expectEqual(h.LedgerName, nil, "DataStore opened")
	expectEqual(h:CountLogs("error"), 0, "errors logged")
end)

test("receipt: internal errors are contained and the lock is released", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	h.BrokenDataStoreService = true
	expectEqual(h:Process(receipt), NotYet, "decision")
	h:ExpectLog("error", "ProcessReceipt internal error")
	h:ExpectLog("error", "DataStoreService is broken")
	h.BrokenDataStoreService = false
	expectEqual(h:Process(receipt), Granted, "decision once the service works")
end)

test("Logger: a throwing Logger can't break RazorMarket", function(new)
	print(`{TAG}         (expected) the next [RazorMarket] Logger errored warnings come from this test`)
	local h = new({ NoProfileCheck = true })
	h.LogHook = function()
		error("logger exploded")
	end
	h:HandleGranting()
	h.RM.Start() -- logs a warning (no IsAlreadyGranted); must still finish starting
	expect(h.MarketplaceService.ProcessReceipt, "Start stopped before wiring ProcessReceipt")

	-- The receipt lock is released even though logging the internal error throws.
	local player = h:Join(1)
	local receipt = h:Receipt(player)
	h.BrokenDataStoreService = true
	expectEqual(h:Process(receipt), NotYet, "decision while broken")
	h:ExpectLog("error", "ProcessReceipt internal error")
	h.BrokenDataStoreService = false
	expectEqual(h:Process(receipt), Granted, "decision once the service works")

	-- A failed lookup (whose retries log warnings) must not leave later lookups waiting forever.
	h.SubFailures = 2
	expectEqual(h.RM.GetSubscriptionStatus(player, SUB), nil, "status during an outage")
	local status
	task.spawn(function()
		status = h.RM.GetSubscriptionStatus(player, SUB)
	end)
	waitFor(function()
		return status ~= nil
	end, "the lookup after the outage")
end)

--------------------------------------------------------------------------------------------------
-- Unit tests: several servers sharing one ledger
--------------------------------------------------------------------------------------------------

test("servers: a live claim on another server defers delivery there", function(new)
	local ledger, profiles = {}, {}
	local a = new({ JobId = "server-A", Ledger = ledger, Profiles = profiles })
	local b = new({ JobId = "server-B", Ledger = ledger, Profiles = profiles, NoProfileCheck = true })
	local gate = a:Gate()
	a.RM.HandleProduct(PRODUCT, function(player, receipt)
		gate.Wait()
		return a:Grant(player, receipt)
	end)
	b:HandleGranting()
	a.RM.Start()
	b.RM.Start()
	local receipt = a:Receipt(a:Join(1))
	b:Join(1)

	local onA = a:ProcessAsync(receipt)
	waitFor(function()
		return gate.Entered > 0
	end, "server A's handler")
	expectEqual(ledger[receipt.PurchaseId].JobId, "server-A", "claim owner")
	expectEqual(b:Process(receipt), NotYet, "server B decision while A holds the claim")

	gate.Open = true
	waitFor(function()
		return onA.Decision ~= nil
	end, "server A's decision")
	expectEqual(onA.Decision, Granted, "server A decision")
	expectEqual(b:Process(receipt), Granted, "server B redelivery")
	expectEqual(a.GrantCount[receipt.PurchaseId], 1, "grants on A")
	expectEqual(b.GrantCount[receipt.PurchaseId], nil, "grants on B")
end)

test("servers: an expired claim from a dead server is taken over", function(new)
	local h = new({ Config = { ClaimTimeout = 5 } })
	h:HandleGranting()
	h.RM.Start()
	local player = h:Join(1)

	local fresh = h:Receipt(player)
	h.Ledger[fresh.PurchaseId] = { Status = "claimed", JobId = "dead", At = os.time() }
	expectEqual(h:Process(fresh), NotYet, "decision on a fresh foreign claim")

	local expired = h:Receipt(player)
	h.Ledger[expired.PurchaseId] = { Status = "claimed", JobId = "dead", At = os.time() - 10 }
	expectEqual(h:Process(expired), Granted, "decision on a claim older than ClaimTimeout")

	local undated = h:Receipt(player)
	h.Ledger[undated.PurchaseId] = { Status = "claimed", JobId = "dead" }
	expectEqual(h:Process(undated), Granted, "decision on a claim with no timestamp")
end)

test("servers: a late release never downgrades another server's grant", function(new)
	local ledger = {}
	local slow = new({ JobId = "server-A", Ledger = ledger })
	local fast = new({ JobId = "server-B", Ledger = ledger, Config = { ClaimTimeout = 0 } })
	local gate = slow:Gate()
	slow.RM.HandleProduct(PRODUCT, function()
		gate.Wait()
		return false -- e.g. its save failed after the claim expired
	end)
	fast:HandleGranting()
	slow.RM.Start()
	fast.RM.Start()
	local receipt = slow:Receipt(slow:Join(1))
	fast:Join(1)

	local onSlow = slow:ProcessAsync(receipt)
	waitFor(function()
		return gate.Entered > 0
	end, "slow server's handler")
	expectEqual(fast:Process(receipt), Granted, "fast server takes over the expired claim")
	gate.Open = true
	waitFor(function()
		return onSlow.Decision ~= nil
	end, "slow server's decision")
	expectEqual(ledger[receipt.PurchaseId].Status, "granted", "ledger status after the late release")
	expectEqual(ledger[receipt.PurchaseId].JobId, "server-B", "ledger owner")
end)

test("servers: a late release never frees another server's live claim", function(new)
	local ledger = {}
	local slow = new({ JobId = "server-A", Ledger = ledger })
	local fast = new({ JobId = "server-B", Ledger = ledger, Config = { ClaimTimeout = 0 } })
	local slowGate, fastGate = slow:Gate(), fast:Gate()
	slow.RM.HandleProduct(PRODUCT, function()
		slowGate.Wait()
		return false -- e.g. its save failed after the claim expired
	end)
	fast.RM.HandleProduct(PRODUCT, function(player, receipt)
		fastGate.Wait()
		return fast:Grant(player, receipt)
	end)
	slow.RM.Start()
	fast.RM.Start()
	local receipt = slow:Receipt(slow:Join(1))
	fast:Join(1)

	local onSlow = slow:ProcessAsync(receipt)
	waitFor(function()
		return slowGate.Entered > 0
	end, "slow server's handler")
	local onFast = fast:ProcessAsync(receipt) -- takes over the expired claim, then holds it
	waitFor(function()
		return fastGate.Entered > 0
	end, "fast server's handler")
	slowGate.Open = true
	waitFor(function()
		return onSlow.Decision ~= nil
	end, "slow server's decision")
	expectEqual(ledger[receipt.PurchaseId].Status, "claimed", "ledger status after the late release")
	expectEqual(ledger[receipt.PurchaseId].JobId, "server-B", "claim owner")

	fastGate.Open = true
	waitFor(function()
		return onFast.Decision ~= nil
	end, "fast server's decision")
	expectEqual(onFast.Decision, Granted, "fast server decision")
end)

test("servers: this server's own leftover claim is reused", function(new)
	local h = new()
	h:HandleGranting()
	h.RM.Start()
	local receipt = h:Receipt(h:Join(1))
	h.Ledger[receipt.PurchaseId] = { Status = "claimed", JobId = h.JobId, At = os.time() }
	expectEqual(h:Process(receipt), Granted, "decision")
end)

--------------------------------------------------------------------------------------------------
-- Unit tests: game passes
--------------------------------------------------------------------------------------------------

local function recorder()
	local calls: { any } = {}
	return calls, function(player, ...)
		table.insert(calls, { player.UserId, ... })
	end
end

test("pass: owned passes fire on join and for players present before Start", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleGamePass(PASS, handler)
	h.Owned[`1:{PASS}`] = true
	h.Owned[`2:{PASS}`] = true
	h:AddPlayer(1)
	h.RM.Start()
	h:Join(2)
	h:Join(3) -- doesn't own it
	waitFor(function()
		return #calls == 2
	end, "two pass handler calls")
	task.wait()
	expectEqual(#calls, 2, "pass handler calls")
end)

test("pass: HandleGamePass after Start checks players already in game", function(new)
	local h = new()
	h.RM.Start()
	h.Owned[`1:{PASS}`] = true
	h:Join(1)
	h:Join(2)
	local calls, handler = recorder()
	h.RM.HandleGamePass(PASS, handler)
	waitFor(function()
		return #calls == 1
	end, "pass handler call")
	expectEqual(calls[1][1], 1, "player")
	expectEqual(calls[1][2], PASS, "pass id")
end)

test("pass: a failing handler is logged and others still run", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleGamePass(PASS, function()
		error("boom")
	end)
	h.RM.HandleGamePass(PASS, handler)
	h.Owned[`1:{PASS}`] = true
	h.RM.Start()
	h:Join(1)
	waitFor(function()
		return #calls == 1
	end, "second handler")
	h:ExpectLog("error", `Game pass {PASS} handler errored`)
end)

test("pass: in-game purchase caches ownership and fires handlers", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleGamePass(PASS, handler)
	h.RM.Start()
	local player = h:Join(1)
	waitFor(function()
		return h.OwnsCalls == 1
	end, "join ownership check")
	local purchased = h.MarketplaceService.PromptGamePassPurchaseFinished

	purchased:Fire(player, PASS, false)
	expectEqual(#calls, 0, "handler calls after a cancelled prompt")

	purchased:Fire(player, PASS, true)
	expectEqual(#calls, 1, "handler calls after a purchase")
	expect(h.RM.OwnsGamePass(player, PASS), "owns after purchase")
	expectEqual(h.OwnsCalls, 1, "ownership lookups (purchase must be cached)")

	purchased:Fire(player, OTHER_PASS, true) -- no handlers registered for it
	expectEqual(#calls, 1, "handler calls for an unhandled pass")
end)

test("pass: purchase finishing after the player left fires but isn't cached", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleGamePass(PASS, handler)
	h.RM.Start()
	local player = h:Join(1)
	h:Leave(player)
	h.MarketplaceService.PromptGamePassPurchaseFinished:Fire(player, PASS, true)
	expectEqual(#calls, 1, "handler calls")
	local before = h.OwnsCalls
	h.RM.OwnsGamePass(player, PASS)
	expectEqual(h.OwnsCalls, before + 1, "ownership lookups (should not be cached)")
end)

test("pass: OwnsGamePass caches for connected players only", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.Owned[`1:{PASS}`] = true
	expect(h.RM.OwnsGamePass(player, PASS), "connected player owns")
	expect(h.RM.OwnsGamePass(player, PASS), "connected player owns (cached)")
	expectEqual(h.OwnsCalls, 1, "lookups for a connected player")

	local stranger = { UserId = 77, Name = "Stranger" }
	h.RM.OwnsGamePass(stranger, PASS)
	h.RM.OwnsGamePass(stranger, PASS)
	expectEqual(h.OwnsCalls, 3, "lookups for a player not in the server")
end)

test("pass: lookup failures return false and are retried next time", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.Owned[`1:{PASS}`] = true
	h.OwnsFailures = 3
	expectEqual(h.RM.OwnsGamePass(player, PASS), false, "owns during an outage")
	h:ExpectLog("warn", `UserOwnsGamePassAsync({PASS}) failed (attempt 2/2)`)
	expectEqual(h.RM.OwnsGamePass(player, PASS), true, "owns after a retry within the call")
	h:ExpectLog("warn", "(attempt 1/2)")
end)

test("pass: InvalidatePass forgets one pass or all of them", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.RM.OwnsGamePass(player, PASS)
	h.RM.OwnsGamePass(player, OTHER_PASS)
	expectEqual(h.OwnsCalls, 2, "initial lookups")

	h.RM.InvalidatePass(player, PASS)
	h.RM.OwnsGamePass(player, PASS)
	h.RM.OwnsGamePass(player, OTHER_PASS)
	expectEqual(h.OwnsCalls, 3, "lookups after invalidating one pass")

	h.RM.InvalidatePass(player)
	h.RM.OwnsGamePass(player, PASS)
	h.RM.OwnsGamePass(player, OTHER_PASS)
	expectEqual(h.OwnsCalls, 5, "lookups after invalidating all passes")

	h.RM.InvalidatePass({ UserId = 77 }, PASS) -- nothing cached: must not error
end)

test("pass: PromptGamePass skips players who own it", function(new)
	local h = new()
	h.RM.Start()
	h.Owned[`1:{PASS}`] = true
	h.RM.PromptGamePass(h:Join(1), PASS)
	h.RM.PromptGamePass(h:Join(2), PASS)
	expectEqual(table.concat(h.Prompts, ","), `pass:2:{PASS}`, "prompts")
end)

--------------------------------------------------------------------------------------------------
-- Unit tests: subscriptions
--------------------------------------------------------------------------------------------------

local SUBSCRIBED = { IsSubscribed = true, IsRenewing = true }

test("subscription: handlers get the status on join and for players present before Start", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.Subscriptions[SUB] = SUBSCRIBED
	h:AddPlayer(1)
	h.RM.Start()
	h:Join(2)
	waitFor(function()
		return #calls == 2
	end, "two subscription handler calls")
	expectEqual(calls[1][2], SUB, "subscription id")
	expectEqual(calls[1][3].IsSubscribed, true, "IsSubscribed")
	expectEqual(calls[1][3].IsRenewing, true, "IsRenewing")
end)

test("subscription: HandleSubscription after Start syncs players already in game", function(new)
	local h = new()
	h.RM.Start()
	h:Join(1)
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	waitFor(function()
		return #calls == 1
	end, "subscription handler call")
	expectEqual(calls[1][3].IsSubscribed, false, "IsSubscribed")
end)

test("subscription: a status change re-queries and fires with the new status", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.RM.Start()
	local player = h:Join(1)
	waitFor(function()
		return #calls == 1
	end, "join sync")
	expect(not h.RM.IsSubscribed(player, SUB), "subscribed before buying")

	h.Subscriptions[SUB] = SUBSCRIBED
	h.Players.UserSubscriptionStatusChanged:Fire(player, SUB)
	waitFor(function()
		return #calls == 2
	end, "change sync")
	expectEqual(calls[2][3].IsSubscribed, true, "IsSubscribed after the change")
	expect(h.RM.IsSubscribed(player, SUB), "subscribed after buying")
	expectEqual(h.SubCalls, 2, "status lookups")
end)

test("subscription: a change without handlers only clears the cache", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.RM.GetSubscriptionStatus(player, OTHER_SUB)
	h.Subscriptions[OTHER_SUB] = SUBSCRIBED
	h.Players.UserSubscriptionStatusChanged:Fire(player, OTHER_SUB)
	expectEqual(h.SubCalls, 1, "lookups right after the change (no handlers to sync)")
	expect(h.RM.IsSubscribed(player, OTHER_SUB), "subscribed on the next lookup")
	expectEqual(h.SubCalls, 2, "lookups")
end)

test("subscription: a change for a player who already left is ignored", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.RM.Start()
	local player = h:Join(1)
	waitFor(function()
		return #calls == 1
	end, "join sync")
	h:Leave(player)
	h.Players.UserSubscriptionStatusChanged:Fire(player, SUB)
	task.wait()
	expectEqual(#calls, 1, "handler calls")
	expectEqual(h.SubCalls, 1, "lookups")
end)

test("subscription: status is cached and callers get copies", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	local status = h.RM.GetSubscriptionStatus(player, SUB)
	status.IsSubscribed = true -- must not leak into the cache
	expectEqual(h.RM.GetSubscriptionStatus(player, SUB).IsSubscribed, false, "cached IsSubscribed")
	expectEqual(h.SubCalls, 1, "lookups")
end)

test("subscription: concurrent lookups share one request", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.Subscriptions[SUB] = SUBSCRIBED
	h.HoldSubs = true
	local results = {}
	for i = 1, 3 do
		task.spawn(function()
			results[i] = h.RM.GetSubscriptionStatus(player, SUB)
		end)
	end
	h.HoldSubs = false
	waitFor(function()
		return results[1] and results[2] and results[3]
	end, "three lookups")
	expectEqual(h.SubCalls, 1, "requests")
	expect(results[1] ~= results[2], "callers got the same table instead of copies")
	expectEqual(results[3].IsSubscribed, true, "IsSubscribed")
end)

test("subscription: a lookup started before a change is discarded", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.HoldSubs = true
	local results = {}
	for i = 1, 2 do
		task.spawn(function()
			results[i] = h.RM.GetSubscriptionStatus(player, SUB)
		end)
	end
	-- The in-flight request answers "not subscribed"; the player subscribes meanwhile.
	h.Subscriptions[SUB] = SUBSCRIBED
	h.RM.InvalidateSubscription(player, SUB)
	h.HoldSubs = false
	waitFor(function()
		return results[1] and results[2]
	end, "both lookups")
	expectEqual(results[1].IsSubscribed, true, "fetching caller sees the new status")
	expectEqual(results[2].IsSubscribed, true, "waiting caller sees the new status")
	expectEqual(h.SubCalls, 2, "requests (stale one re-run)")
end)

test("subscription: untracked players get uncached lookups", function(new)
	local h = new()
	local player = h:AddPlayer(1) -- Start() not called, so nobody is tracked
	h.RM.GetSubscriptionStatus(player, SUB)
	h.RM.GetSubscriptionStatus(player, SUB)
	expectEqual(h.SubCalls, 2, "lookups")
end)

test("subscription: failed or malformed lookups return nil", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.SubFailures = 2
	expectEqual(h.RM.GetSubscriptionStatus(player, SUB), nil, "status during an outage")
	h:ExpectLog("warn", `GetUserSubscriptionStatusAsync({SUB}) failed (attempt 2/2)`)
	h.SubFailures = 2
	expectEqual(h.RM.IsSubscribed(player, SUB), false, "IsSubscribed during an outage")
	h.Subscriptions[OTHER_SUB] = "not a table"
	expectEqual(h.RM.GetSubscriptionStatus(player, OTHER_SUB), nil, "status from a malformed response")
end)

test("subscription: a failed sync keeps retrying until it succeeds", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.RM.Start()
	h.SubFailures = 4 -- two whole lookups (MaxRetries = 2 each)
	h:Join(1)
	waitFor(function()
		return #calls == 1
	end, "handler call after the outage")
	h:ExpectLog("warn", `Could not fetch subscription {SUB} for Fake1; retrying in`)
	expectEqual(h.SubCalls, 5, "lookups")
end)

test("subscription: a retrying sync stops when the player leaves", function(new)
	local h = new({ Config = { RetryDelay = 0.05, MaxRetries = 1 } })
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.RM.Start()
	h.SubFailures = math.huge
	local player = h:Join(1)
	waitFor(function()
		return h:Logged("warn", "retrying in 0.1s")
	end, "first resync warning")
	h:Leave(player) -- during the 0.1 s wait
	h.SubFailures = 0
	local lookups = h.SubCalls
	task.wait(0.3)
	expectEqual(#calls, 0, "handler calls")
	expectEqual(h.SubCalls, lookups, "lookups after leaving")
end)

test("subscription: newest status wins when a change lands mid-sync", function(new)
	local h = new()
	local calls, handler = recorder()
	h.RM.HandleSubscription(SUB, handler)
	h.RM.Start()
	h.HoldSubs = true
	local player = h:Join(1) -- join sync is now in flight with the old status
	h.Subscriptions[SUB] = SUBSCRIBED
	h.Players.UserSubscriptionStatusChanged:Fire(player, SUB)
	h.HoldSubs = false
	waitFor(function()
		return #calls == 1
	end, "handler call")
	task.wait(0.1)
	expectEqual(#calls, 1, "handler calls (the outdated join sync must not fire)")
	expectEqual(calls[1][3].IsSubscribed, true, "IsSubscribed")
end)

test("subscription: handler added while a full sync is pending is run by it", function(new)
	local h = new()
	local first, firstHandler = recorder()
	local second, secondHandler = recorder()
	h.RM.HandleSubscription(SUB, firstHandler)
	h.RM.Start()
	h.HoldSubs = true
	h:Join(1)
	h.RM.HandleSubscription(SUB, secondHandler)
	h.HoldSubs = false
	waitFor(function()
		return #first == 1 and #second == 1
	end, "both handlers")
	task.wait(0.1)
	expectEqual(#first + #second, 2, "handler calls")
	expectEqual(h.SubCalls, 1, "lookups")
end)

test("subscription: handlers added while a handler-only sync is pending join it", function(new)
	local h = new()
	h.RM.Start()
	h:Join(1)
	local first, firstHandler = recorder()
	local second, secondHandler = recorder()
	h.HoldSubs = true
	h.RM.HandleSubscription(SUB, firstHandler)
	h.RM.HandleSubscription(SUB, secondHandler)
	h.HoldSubs = false
	waitFor(function()
		return #first == 1 and #second == 1
	end, "both handlers")
	task.wait(0.1)
	expectEqual(#first + #second, 2, "handler calls")
	expectEqual(h.SubCalls, 1, "lookups")
end)

test("subscription: a failing handler is logged", function(new)
	local h = new()
	h.RM.HandleSubscription(SUB, function()
		error("boom")
	end)
	h.RM.Start()
	h:Join(1)
	waitFor(function()
		return h:Logged("error", `Subscription {SUB} handler errored`)
	end, "handler error log")
end)

test("subscription: InvalidateSubscription forgets one or all", function(new)
	local h = new()
	h.RM.Start()
	local player = h:Join(1)
	h.RM.GetSubscriptionStatus(player, SUB)
	h.RM.GetSubscriptionStatus(player, OTHER_SUB)
	h.RM.InvalidateSubscription(player, SUB)
	h.RM.GetSubscriptionStatus(player, SUB)
	h.RM.GetSubscriptionStatus(player, OTHER_SUB)
	expectEqual(h.SubCalls, 3, "lookups after invalidating one")
	h.RM.InvalidateSubscription(player)
	h.RM.GetSubscriptionStatus(player, SUB)
	h.RM.GetSubscriptionStatus(player, OTHER_SUB)
	expectEqual(h.SubCalls, 5, "lookups after invalidating all")
end)

test("subscription: PromptSubscription skips known subscribers without yielding", function(new)
	local h = new()
	h.RM.Start()
	h.Subscriptions[SUB] = SUBSCRIBED
	local subscriber = h:Join(1)
	h.RM.GetSubscriptionStatus(subscriber, SUB)
	h.RM.PromptSubscription(subscriber, SUB) -- cached as subscribed: no prompt
	h.RM.PromptSubscription(subscriber, OTHER_SUB) -- unknown: prompt
	h.RM.PromptSubscription({ UserId = 77 }, SUB) -- untracked: prompt
	expectEqual(table.concat(h.Prompts, ","), `subscription:1:{OTHER_SUB},subscription:77:{SUB}`, "prompts")
	expectEqual(h.SubCalls, 1, "lookups (prompting must not query)")
end)

--------------------------------------------------------------------------------------------------
-- Unit tests: products, product info and shutdown
--------------------------------------------------------------------------------------------------

test("PromptProduct prompts the player", function(new)
	local h = new()
	h.RM.PromptProduct(h:AddPlayer(1), PRODUCT)
	expectEqual(table.concat(h.Prompts, ","), `product:1:{PRODUCT}`, "prompts")
end)

test("GetProductInfo: defaults to Product, caches per type, doesn't cache failures", function(new)
	local h = new()
	expectEqual(h.RM.GetProductInfo(PRODUCT).InfoType, "Product", "default info type")
	h.RM.GetProductInfo(PRODUCT)
	expectEqual(h.InfoCalls, 1, "lookups (cached)")
	expectEqual(h.RM.GetProductInfo(PRODUCT, Enum.InfoType.GamePass).InfoType, "GamePass", "explicit type")
	expectEqual(h.InfoCalls, 2, "lookups (cached per type)")

	h.InfoFailures = 2
	expectEqual(h.RM.GetProductInfo(PASS, Enum.InfoType.GamePass), nil, "info during an outage")
	h:ExpectLog("warn", `GetProductInfo({PASS}) failed (attempt 2/2)`)
	expect(h.RM.GetProductInfo(PASS, Enum.InfoType.GamePass), "info after the outage")
end)

test("shutdown: BindToClose waits for in-flight receipts", function(new)
	local h = new({ Config = { ShutdownWait = 2 } })
	local gate = h:Gate()
	h.RM.HandleProduct(PRODUCT, function(player, receipt)
		gate.Wait()
		return h:Grant(player, receipt)
	end)
	h.RM.Start()
	local close = h.CloseCallbacks[1]
	close() -- nothing in flight: returns at once

	local pending = h:ProcessAsync(h:Receipt(h:Join(1)))
	waitFor(function()
		return gate.Entered > 0
	end, "handler")
	local closed = false
	task.spawn(function()
		close()
		closed = true
	end)
	task.wait(0.1)
	expect(not closed, "BindToClose returned while a receipt was in flight")
	gate.Open = true
	waitFor(function()
		return closed
	end, "BindToClose to return")
	expectEqual(pending.Decision, Granted, "decision")
	expect(not h:Logged("warn", "Shutting down"), "shutdown warning logged")
end)

test("shutdown: BindToClose gives up after ShutdownWait", function(new)
	local h = new({ Config = { ShutdownWait = 0.1 } })
	local gate = h:Gate()
	h.RM.HandleProduct(PRODUCT, function()
		gate.Wait()
		return false
	end)
	h.RM.Start()
	h:ProcessAsync(h:Receipt(h:Join(1)))
	waitFor(function()
		return gate.Entered > 0
	end, "handler")
	h.CloseCallbacks[1]()
	h:ExpectLog("warn", "Shutting down with 1 receipt(s) still in flight")
end)

--------------------------------------------------------------------------------------------------
-- Live suite: the real package against the real services
--------------------------------------------------------------------------------------------------

-- Stand-in for the player's saved profile. In a real game this is your DataStore profile,
-- and PurchaseId must be saved in the SAME write as the granted item.
local profiles: { [number]: { Purchases: { [string]: boolean }, Coins: number } } = {}
local grantCount: { [string]: number } = {}

local function getProfile(player: Player)
	profiles[player.UserId] = profiles[player.UserId] or { Purchases = {}, Coins = 0 }
	return profiles[player.UserId]
end

local function fakeReceipt(player: Player, purchaseId: string)
	return {
		PurchaseId = purchaseId,
		PlayerId = player.UserId,
		ProductId = TEST_PRODUCT,
		PlaceIdWherePurchased = game.PlaceId,
		CurrencySpent = 0,
		CurrencyType = Enum.CurrencyType.Robux,
	}
end

local function runLiveSuite(player: Player)
	local step = "setup"
	local function check(name: string, fn: () -> ())
		step = name
		local started = os.clock()
		fn()
		print(`{TAG}   PASS  live: {name} ({math.round((os.clock() - started) * 1000)} ms)`)
	end

	print(`{TAG} Live suite for {player.Name} (UseLedger = {USE_LEDGER})`)
	local ok, err = pcall(function()
		check("first delivery grants", function()
			local id = "test_" .. HttpService:GenerateGUID(false)
			expectEqual(RazorMarket._processReceipt(fakeReceipt(player, id)), Granted, "decision")
			expectEqual(grantCount[id], 1, "grants")
		end)

		check("duplicate delivery is acknowledged without re-granting", function()
			local id = "test_" .. HttpService:GenerateGUID(false)
			RazorMarket._processReceipt(fakeReceipt(player, id))
			expectEqual(RazorMarket._processReceipt(fakeReceipt(player, id)), Granted, "duplicate decision")
			expectEqual(grantCount[id], 1, "grants")
		end)

		check("concurrent duplicate is deferred, not double-granted", function()
			local id = "test_" .. HttpService:GenerateGUID(false)
			local results = {}
			for i = 1, 2 do
				task.spawn(function()
					results[i] = RazorMarket._processReceipt(fakeReceipt(player, id))
				end)
			end
			waitFor(function()
				return results[1] ~= nil and results[2] ~= nil
			end, "both deliveries", 30)
			expectEqual(grantCount[id], 1, "grants")
			-- Without the ledger nothing yields, so both can finish in turn; with it, one is deferred.
			local granted = (results[1] == Granted and 1 or 0) + (results[2] == Granted and 1 or 0)
			expect(granted >= 1, `unexpected decisions: {results[1]}, {results[2]}`)
		end)

		check("unknown product is not granted", function()
			local bad = fakeReceipt(player, "test_" .. HttpService:GenerateGUID(false))
			bad.ProductId = -1
			expectEqual(RazorMarket._processReceipt(bad), NotYet, "decision")
		end)
	end)
	if ok then
		print(`{TAG} Live suite passed for {player.Name}`)
	else
		warn(`{TAG} Live suite FAILED for {player.Name} at "{step}": {err}`)
	end
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

function mod:init()
	RazorMarket.Configure({
		UseLedger = USE_LEDGER,
		IsAlreadyGranted = function(player, purchaseId)
			return getProfile(player).Purchases[purchaseId] == true
		end,
	})

	RazorMarket.HandleProduct(TEST_PRODUCT, function(player, receipt)
		local profile = getProfile(player)
		if profile.Purchases[receipt.PurchaseId] then
			return true -- idempotent
		end
		profile.Coins += 100
		profile.Purchases[receipt.PurchaseId] = true
		grantCount[receipt.PurchaseId] = (grantCount[receipt.PurchaseId] or 0) + 1
		-- Real game: yield here until the profile is saved, then return true.
		print(`{TAG} live: granted product to {player.Name} ({receipt.PurchaseId})`)
		return true
	end)

	RazorMarket.HandleGamePass(TEST_PASS, function(player, passId)
		print(`{TAG} live: {player.Name} owns pass {passId}`)
	end)

	RazorMarket.Start()
end

function mod:start()
	local ok, err = pcall(runUnitSuite)
	if not ok then
		warn(`{TAG} Unit suite crashed: {err}`)
	end
	unitSuiteDone = true
end

function mod:playerAdded(player: Player)
	while not unitSuiteDone do
		task.wait(0.1) -- keep the two suites' output apart
	end
	runLiveSuite(player)
end
