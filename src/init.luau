--!strict
--!native
--!optimize 2
--[[
	RazorMarket
	Centralized, fail-safe MarketplaceService handling.

	Design rules (from Roblox's official ProcessReceipt guidance):
	  * There is exactly ONE ProcessReceipt callback per experience. RazorMarket owns it.
	  * Only return PurchaseGranted once the grant has been durably handled.
	  * Any error / missing player / missing handler => NotProcessedYet, so Roblox retries
	    (on rejoin, or on any server the player is in).
	  * Receipts can be delivered more than once, even concurrently and on different servers.
	    Every PurchaseId is CLAIMED atomically in a DataStore ledger (single UpdateAsync) before
	    the handler runs, then marked GRANTED after. Claims expire so a dead server can't block
	    a purchase forever. An in-memory lock guards against concurrent delivery on one server.

	HARD REQUIREMENT FOR HANDLERS (the ledger alone cannot guarantee exactly-once):
	  * A ProductHandler MUST yield until the grant is saved, and MUST store receipt.PurchaseId
	    in the player's profile IN THE SAME SAVE as the granted item.
	  * Supply Config.IsAlreadyGranted so RazorMarket can consult that profile before running
	    the handler. This closes the "granted + saved, but ledger write failed, then server died"
	    window.
	  * Game pass handlers run on EVERY join (and on in-game purchase) and must be safe to repeat.

	Subscriptions (ProcessReceipt is NOT used for them):
	  * Status is queried with MarketplaceService:GetUserSubscriptionStatusAsync on join, and
	    kept fresh via Players.UserSubscriptionStatusChanged (fires on purchase, cancel, lapse).
	  * Subscription handlers receive the full status on EVERY join and on EVERY change, so
	    they can both grant AND revoke perks. They must be safe to repeat.
	  * Each change re-queries the status; a lookup that started before the change is discarded,
	    and handlers only ever see the newest status. Failed lookups are retried until they succeed.
	  * Do NOT persist subscription perks permanently; always derive them from current status.
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataModel = game -- like the services above, swapped for a fake by RazorMarket._useServices

export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	CurrencyType: Enum.CurrencyType,
}

export type SubscriptionStatus = {
	IsSubscribed: boolean,
	IsRenewing: boolean,
}

-- Return true ONLY if the grant succeeded and is saved. Errors/false => retried later.
export type ProductHandler = (player: Player, receipt: Receipt) -> boolean
export type PassHandler = (player: Player, passId: number) -> ()
-- Called on join and whenever the status changes. Check status.IsSubscribed to grant/revoke.
export type SubscriptionHandler = (player: Player, subscriptionId: string, status: SubscriptionStatus) -> ()
export type Logger = (level: string, message: string) -> ()

export type Config = {
	LedgerName: string?,
	-- Set false ONLY for Studio/testing without DataStore API access. Cross-server
	-- deduplication is then entirely up to IsAlreadyGranted + your handler.
	UseLedger: boolean?,
	-- Seconds before another server may take over a claim (default 60).
	ClaimTimeout: number?,
	MaxRetries: number?,
	RetryDelay: number?,
	-- Seconds BindToClose waits for in-flight receipts (default 20; must leave room for your saves).
	ShutdownWait: number?,
	-- Return true if this PurchaseId is already recorded in the player's saved profile.
	-- Errors are treated as "unknown" and the receipt is retried later.
	IsAlreadyGranted: ((player: Player, purchaseId: string) -> boolean)?,
	-- Errors thrown by the Logger are caught and the line is sent to warn() instead.
	Logger: Logger?,
}

type LedgerEntry = {
	Status: string, -- "claimed" | "granted" | "released"
	JobId: string?,
	At: number,
	ProductId: number?,
}

local RazorMarket = {}

local started = false
local ledgerName = "RazorMarket_PurchaseLedger_v1"
local useLedger = true
local claimTimeout = 60
local maxRetries = 5
local retryDelay = 1
local shutdownWait = 20
local isAlreadyGranted: ((Player, string) -> boolean)? = nil
local logger: Logger = function(level, message)
	if level == "error" or level == "warn" then
		warn("[RazorMarket] " .. message)
	end
end

local ledger: DataStore? = nil
local ledgerFailureLogged = false
local productHandlers: { [number]: ProductHandler } = {}
local defaultProductHandler: ProductHandler? = nil
local passHandlers: { [number]: { PassHandler } } = {}
local passCache: { [number]: { [number]: boolean } } = {}
local subscriptionHandlers: { [string]: { SubscriptionHandler } } = {}

-- A pending handler run for one player/subscription. A newer sync replaces it.
type SubscriptionSync = {
	Handlers: { SubscriptionHandler }?, -- nil = every registered handler
}

type SubscriptionEntry = {
	Status: SubscriptionStatus?,
	-- Bumped on every invalidation; a fetch that started under an older generation is discarded.
	Generation: number,
	-- Threads waiting on the in-flight fetch, or nil when nothing is being fetched.
	Waiting: { thread }?,
	Sync: SubscriptionSync?,
}

-- Per connected player; replaced on rejoin so lookups from an earlier session can't write into it.
local subscriptionState: { [number]: { [string]: SubscriptionEntry } } = {}
local MAX_RESYNC_DELAY = 60
local connectedUsers: { [number]: boolean } = {}
local inFlight: { [string]: boolean } = {}
local grantedThisServer: { [string]: boolean } = {}
local inFlightCount = 0

local function retry(label: string, fn: () -> any): (boolean, any)
	local lastErr: any
	for attempt = 1, maxRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		logger("warn", `{label} failed (attempt {attempt}/{maxRetries}): {lastErr}`)
		if attempt < maxRetries then
			task.wait(retryDelay * 2 ^ (attempt - 1))
		end
	end
	return false, lastErr
end

local function callHandler(label: string, handler: (...any) -> ...any, ...: any)
	local ok, err = pcall(handler, ...)
	if not ok then
		logger("error", `{label} handler errored: {err}`)
	end
end

local function noteLedgerFailure(err: any)
	if ledgerFailureLogged then
		return
	end
	ledgerFailureLogged = true
	local hint = ""
	if RunService:IsStudio() then
		hint = " (In Studio, enable 'Enable Studio Access to API Services' in Game Settings > Security,"
			.. " or call RazorMarket.Configure({ UseLedger = false }) for local testing.)"
	end
	logger("error", `Purchase ledger unavailable; receipts will be retried later. {err}{hint}`)
end

local function getLedger(): DataStore?
	if ledger then
		return ledger
	end
	local ok, store = pcall(DataStoreService.GetDataStore, DataStoreService, ledgerName)
	if ok then
		ledger = store
		return store
	end
	noteLedgerFailure(store)
	return nil
end

local function ledgerKey(receipt: Receipt): string
	return receipt.PurchaseId
end

-- Atomically claims the receipt. Returns one of:
--   "proceed" (we own the claim), "granted" (already granted anywhere),
--   "busy" (another live server owns it), "error" (ledger unavailable).
local function claim(receipt: Receipt): string
	if not useLedger then
		return "proceed"
	end
	local store = getLedger()
	if not store then
		return "error"
	end
	local outcome = "error"
	local ok, err = retry("Ledger claim", function()
		store:UpdateAsync(ledgerKey(receipt), function(old: LedgerEntry?)
			if old and old.Status == "granted" then
				outcome = "granted"
				return nil -- cancel update
			end
			if
				old
				and old.Status == "claimed"
				and old.JobId ~= DataModel.JobId
				and (os.time() - (old.At or 0)) < claimTimeout
			then
				outcome = "busy"
				return nil
			end
			outcome = "proceed"
			return {
				Status = "claimed",
				JobId = DataModel.JobId,
				At = os.time(),
				ProductId = receipt.ProductId,
			}
		end)
		return nil
	end)
	if not ok then
		noteLedgerFailure(err)
		return "error"
	end
	return outcome
end

local function writeStatus(receipt: Receipt, status: string): boolean
	if not useLedger then
		return true
	end
	local store = getLedger()
	if not store then
		return false
	end
	local ok, err = retry(`Ledger write ({status})`, function()
		store:UpdateAsync(ledgerKey(receipt), function(old: LedgerEntry?)
			if old and old.Status == "granted" then
				return nil -- never downgrade a granted record
			end
			if status == "released" and old and old.Status == "claimed" and old.JobId ~= DataModel.JobId then
				return nil -- our claim expired and another server took over; its claim stands
			end
			return {
				Status = status,
				JobId = DataModel.JobId,
				At = os.time(),
				ProductId = receipt.ProductId,
			}
		end)
		return nil
	end)
	if not ok then
		noteLedgerFailure(err)
	end
	return ok
end

local function processReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local key = ledgerKey(receipt)

	if grantedThisServer[key] then
		-- Granted here earlier but the ledger write failed; only retry the recording.
		if writeStatus(receipt, "granted") then
			grantedThisServer[key] = nil
			return GRANTED
		end
		return NOT_YET
	end

	if inFlight[key] then
		return NOT_YET -- concurrent duplicate on this server; Roblox will retry
	end

	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return NOT_YET -- retried when the player joins again
	end

	local handler = productHandlers[receipt.ProductId] or defaultProductHandler
	if not handler then
		logger("error", `No handler registered for product {receipt.ProductId}`)
		return NOT_YET
	end

	inFlight[key] = true
	inFlightCount += 1
	local decision = NOT_YET

	local ok, err = pcall(function()
		-- 1. Player's own profile is the source of truth if the game provides it.
		if isAlreadyGranted then
			local checkOk, already = pcall(isAlreadyGranted, player, receipt.PurchaseId)
			if not checkOk then
				logger("warn", `IsAlreadyGranted errored for {key}: {already}`)
				return
			end
			if already == true then
				writeStatus(receipt, "granted") -- best effort; profile already proves it
				decision = GRANTED
				return
			end
		end

		-- 2. Atomic cross-server claim.
		local outcome = claim(receipt)
		if outcome == "granted" then
			decision = GRANTED
			return
		elseif outcome ~= "proceed" then
			return -- busy / error => NotProcessedYet
		end

		if not connectedUsers[player.UserId] then
			writeStatus(receipt, "released")
			return
		end

		-- 3. Grant.
		local handlerOk, granted = pcall(handler, player, receipt)
		if not handlerOk then
			logger("error", `Handler for product {receipt.ProductId} errored: {granted}`)
			writeStatus(receipt, "released")
			return
		end
		if granted ~= true then
			writeStatus(receipt, "released")
			return
		end

		-- 4. Record.
		if writeStatus(receipt, "granted") then
			decision = GRANTED
		else
			grantedThisServer[key] = true
			logger("error", `Granted {key} but ledger write failed; will retry recording only`)
		end
	end)
	if not ok then
		logger("error", `ProcessReceipt internal error: {err}`)
	end

	inFlight[key] = nil
	inFlightCount -= 1
	return decision
end

--[=[ Configure before Start(). ]=]
function RazorMarket.Configure(config: Config)
	assert(not started, "RazorMarket.Configure must be called before Start")
	ledgerName = config.LedgerName or ledgerName
	if config.UseLedger ~= nil then
		useLedger = config.UseLedger
	end
	claimTimeout = config.ClaimTimeout or claimTimeout
	maxRetries = config.MaxRetries or maxRetries
	retryDelay = config.RetryDelay or retryDelay
	shutdownWait = config.ShutdownWait or shutdownWait
	isAlreadyGranted = config.IsAlreadyGranted or isAlreadyGranted
	if config.Logger then
		-- A throwing Logger must not escape into the pipeline (e.g. leave a receipt locked).
		local custom = config.Logger
		logger = function(level, message)
			local ok, err = pcall(custom, level, message)
			if not ok then
				warn(`[RazorMarket] Logger errored: {err} (while logging {level}: {message})`)
			end
		end
	end
end

--[=[
	Register a grant handler for a developer product.
	The handler MUST yield until the grant is saved, MUST save receipt.PurchaseId in the same
	save as the item, and return true only then. Returning false or erroring => retried later.
]=]
function RazorMarket.HandleProduct(productId: number, handler: ProductHandler)
	assert(productHandlers[productId] == nil, `Product {productId} already has a handler`)
	productHandlers[productId] = handler
end

--[=[ Fallback handler for products without a specific handler. Same rules as HandleProduct. ]=]
function RazorMarket.HandleDefaultProduct(handler: ProductHandler)
	defaultProductHandler = handler
end

--[=[
	Called when a player owns (on EVERY join) or buys (in-game) a game pass.
	Handlers must be safe to run repeatedly.
]=]
function RazorMarket.HandleGamePass(passId: number, handler: PassHandler)
	local list = passHandlers[passId] or {}
	passHandlers[passId] = list
	table.insert(list, handler)
	if started then
		for _, player in Players:GetPlayers() do
			task.spawn(function()
				if RazorMarket.OwnsGamePass(player, passId) then
					callHandler(`Game pass {passId}`, handler, player, passId)
				end
			end)
		end
	end
end

local function firePass(player: Player, passId: number)
	for _, handler in passHandlers[passId] or {} do
		callHandler(`Game pass {passId}`, handler, player, passId)
	end
end

--[=[ Ownership check with retries + per-player cache. Failures are not cached. ]=]
function RazorMarket.OwnsGamePass(player: Player, passId: number): boolean
	local cache = passCache[player.UserId]
	if cache and cache[passId] ~= nil then
		return cache[passId]
	end
	local ok, owns = retry(`UserOwnsGamePassAsync({passId})`, function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		return false -- don't cache failures; next call retries
	end
	-- Only cache for players still connected (checked AFTER the yield) to avoid leaks.
	if connectedUsers[player.UserId] then
		passCache[player.UserId] = passCache[player.UserId] or {}
		passCache[player.UserId][passId] = owns == true
	end
	return owns == true
end

--[=[
	Forget cached ownership so the next OwnsGamePass re-queries Roblox.
	Use after a pass may have been bought on the website mid-session. Omit passId to clear all.
]=]
function RazorMarket.InvalidatePass(player: Player, passId: number?)
	if passId == nil then
		passCache[player.UserId] = nil
	elseif passCache[player.UserId] then
		passCache[player.UserId][passId] = nil
	end
end

local function fetchSubscriptionStatus(player: Player, subscriptionId: string): SubscriptionStatus?
	local ok, result = retry(`GetUserSubscriptionStatusAsync({subscriptionId})`, function()
		return MarketplaceService:GetUserSubscriptionStatusAsync(player, subscriptionId)
	end)
	if not ok or type(result) ~= "table" then
		return nil
	end
	return {
		IsSubscribed = result.IsSubscribed == true,
		IsRenewing = result.IsRenewing == true,
	}
end

local function getSubscriptionEntry(userId: number, subscriptionId: string): SubscriptionEntry?
	local entries = subscriptionState[userId]
	if not entries then
		return nil
	end
	local entry = entries[subscriptionId]
	if not entry then
		entry = { Generation = 0 }
		entries[subscriptionId] = entry
	end
	return entry
end

local function isCurrentEntry(userId: number, subscriptionId: string, entry: SubscriptionEntry): boolean
	local entries = subscriptionState[userId]
	return entries ~= nil and entries[subscriptionId] == entry
end

--[=[
	Full subscription status with retries + per-player cache. Concurrent lookups share one request.
	Returns nil if Roblox could not be reached (failures are not cached). Returns a copy.
]=]
function RazorMarket.GetSubscriptionStatus(player: Player, subscriptionId: string): SubscriptionStatus?
	local entry = getSubscriptionEntry(player.UserId, subscriptionId)
	if not entry then
		-- Not tracked (left, or Start() not called yet): uncached lookup.
		return fetchSubscriptionStatus(player, subscriptionId)
	end
	while true do
		if entry.Status then
			return table.clone(entry.Status)
		end
		local status: SubscriptionStatus?
		local stale: boolean
		local waiting = entry.Waiting
		if waiting then
			table.insert(waiting, coroutine.running())
			status, stale = coroutine.yield()
		else
			local generation = entry.Generation
			local waiters: { thread } = {}
			entry.Waiting = waiters
			status = fetchSubscriptionStatus(player, subscriptionId)
			entry.Waiting = nil
			-- Invalidated while in flight: the answer may predate the change, so ask again.
			stale = entry.Generation ~= generation and isCurrentEntry(player.UserId, subscriptionId, entry)
			if status and not stale then
				entry.Status = status
			end
			for _, thread in waiters do
				task.spawn(thread, status, stale)
			end
		end
		if not stale then
			return if status then table.clone(status) else nil
		end
	end
end

--[=[ True if the player currently has an active subscription. Lookup failures => false. ]=]
function RazorMarket.IsSubscribed(player: Player, subscriptionId: string): boolean
	local status = RazorMarket.GetSubscriptionStatus(player, subscriptionId)
	return status ~= nil and status.IsSubscribed
end

--[=[
	Forget cached subscription status. Omit subscriptionId to clear all for the player.
	Lookups already in flight are re-run instead of caching a possibly outdated answer.
]=]
function RazorMarket.InvalidateSubscription(player: Player, subscriptionId: string?)
	for id, entry in subscriptionState[player.UserId] or {} do
		if subscriptionId == nil or id == subscriptionId then
			entry.Status = nil
			entry.Generation += 1
		end
	end
end

-- Fetches the status and runs handlers with it, retrying until it succeeds, the player leaves, or
-- a newer sync for the same subscription takes over (so an older status never lands after a newer
-- one). Passing `handler` limits the run to that one newly registered handler.
local function syncSubscription(player: Player, subscriptionId: string, handler: SubscriptionHandler?)
	local entry = getSubscriptionEntry(player.UserId, subscriptionId)
	if not entry then
		return
	end
	local active = entry.Sync
	if handler and active then
		-- A run is already pending; it picks this handler up.
		if active.Handlers then
			table.insert(active.Handlers, handler)
		end
		return
	end
	local sync: SubscriptionSync = { Handlers = if handler then { handler } else nil }
	entry.Sync = sync
	local function superseded(): boolean
		return entry.Sync ~= sync or not isCurrentEntry(player.UserId, subscriptionId, entry)
	end

	local delay = math.min(retryDelay * 2 ^ maxRetries, MAX_RESYNC_DELAY)
	while true do
		local status = RazorMarket.GetSubscriptionStatus(player, subscriptionId)
		if superseded() then
			return
		end
		if status then
			entry.Sync = nil
			for _, h in sync.Handlers or subscriptionHandlers[subscriptionId] or {} do
				callHandler(`Subscription {subscriptionId}`, h, player, subscriptionId, table.clone(status))
			end
			return
		end
		logger("warn", `Could not fetch subscription {subscriptionId} for {player.Name}; retrying in {delay}s`)
		task.wait(delay)
		if superseded() then
			return
		end
		delay = math.min(delay * 2, MAX_RESYNC_DELAY)
	end
end

--[=[
	Called with the current status on EVERY join and whenever it changes (purchase, cancel,
	expiry). Grant perks when status.IsSubscribed is true, revoke them when false.
	Handlers must be safe to run repeatedly. Failed lookups are retried until they succeed.
]=]
function RazorMarket.HandleSubscription(subscriptionId: string, handler: SubscriptionHandler)
	local list = subscriptionHandlers[subscriptionId] or {}
	subscriptionHandlers[subscriptionId] = list
	table.insert(list, handler)
	if started then
		for _, player in Players:GetPlayers() do
			task.spawn(syncSubscription, player, subscriptionId, handler)
		end
	end
end

function RazorMarket.PromptProduct(player: Player, productId: number)
	MarketplaceService:PromptProductPurchase(player, productId)
end

function RazorMarket.PromptGamePass(player: Player, passId: number)
	if RazorMarket.OwnsGamePass(player, passId) then
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, passId)
end

--[=[
	Prompts a subscription purchase unless the player is known to be subscribed. Doesn't yield:
	it only checks the cached status (filled on join for subscriptions with handlers).
]=]
function RazorMarket.PromptSubscription(player: Player, subscriptionId: string)
	local entries = subscriptionState[player.UserId]
	local entry = entries and entries[subscriptionId]
	if entry and entry.Status and entry.Status.IsSubscribed then
		return
	end
	MarketplaceService:PromptSubscriptionPurchase(player, subscriptionId)
end

local infoCache: { [string]: any } = {}
function RazorMarket.GetProductInfo(id: number, infoType: Enum.InfoType?): any?
	local t = infoType or Enum.InfoType.Product
	local key = `{t.Name}_{id}`
	if infoCache[key] ~= nil then
		return infoCache[key]
	end
	local ok, info = retry(`GetProductInfo({id})`, function()
		return MarketplaceService:GetProductInfo(id, t)
	end)
	if ok then
		infoCache[key] = info
		return info
	end
	return nil
end

--[=[ Starts RazorMarket. Call once, after registering handlers, on the server. ]=]
function RazorMarket.Start()
	assert(RunService:IsServer(), "RazorMarket must run on the server")
	if started then
		return
	end
	started = true

	if not useLedger then
		logger("warn", "UseLedger = false: cross-server purchase deduplication is DISABLED. Testing only.")
	end
	if not isAlreadyGranted then
		logger(
			"warn",
			"No IsAlreadyGranted configured. Your handlers must save receipt.PurchaseId with the player's data."
		)
	end

	-- Idempotent; also called from onPlayer since PlayerAdded connection order isn't guaranteed.
	local function track(player: Player)
		connectedUsers[player.UserId] = true
		subscriptionState[player.UserId] = subscriptionState[player.UserId] or {}
	end
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		connectedUsers[player.UserId] = nil
		passCache[player.UserId] = nil
		subscriptionState[player.UserId] = nil
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo: { [string]: any })
		return processReceipt(receiptInfo :: any)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		if connectedUsers[player.UserId] then
			passCache[player.UserId] = passCache[player.UserId] or {}
			passCache[player.UserId][passId] = true
		end
		firePass(player, passId)
	end)

	-- Fires on purchase, cancellation and expiry. The event carries no status, so re-query.
	Players.UserSubscriptionStatusChanged:Connect(function(player: Player, subscriptionId: string)
		RazorMarket.InvalidateSubscription(player, subscriptionId)
		if subscriptionHandlers[subscriptionId] then
			task.spawn(syncSubscription, player, subscriptionId)
		end
	end)

	local function onPlayer(player: Player)
		track(player)
		for passId in passHandlers do
			task.spawn(function()
				if RazorMarket.OwnsGamePass(player, passId) then
					firePass(player, passId)
				end
			end)
		end
		for subscriptionId in subscriptionHandlers do
			task.spawn(syncSubscription, player, subscriptionId)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end

	DataModel:BindToClose(function()
		local deadline = os.clock() + shutdownWait
		while inFlightCount > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
		if inFlightCount > 0 then
			logger("warn", `Shutting down with {inFlightCount} receipt(s) still in flight; they will be retried`)
		end
	end)
end

--[=[ Exposed for tests only. Runs the real ProcessReceipt pipeline on a fake receipt. ]=]
function RazorMarket._processReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	return processReceipt(receipt)
end

--[=[
	Exposed for tests only. Swaps Roblox services for fakes (DataStoreService, MarketplaceService,
	Players, RunService, DataModel); omitted ones stay real. Call before Start() on a fresh copy of
	the module (require a Clone()), since module state is never reset.
]=]
function RazorMarket._useServices(services: { [string]: any })
	assert(not started, "RazorMarket._useServices must be called before Start")
	DataStoreService = services.DataStoreService or DataStoreService
	MarketplaceService = services.MarketplaceService or MarketplaceService
	Players = services.Players or Players
	RunService = services.RunService or RunService
	DataModel = services.DataModel or DataModel
end

return RazorMarket
