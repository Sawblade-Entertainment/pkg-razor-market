--!strict
--[[
	RazorMarket
	Centralized, fail-safe MarketplaceService handling.

	Design rules (from Roblox's official ProcessReceipt guidance):
	  * There is exactly ONE ProcessReceipt callback per experience. RazorMarket owns it.
	  * Only return PurchaseGranted once the grant has been durably handled.
	  * Any error / missing player / missing handler => NotProcessedYet, so Roblox retries
	    (on rejoin, or on any server the player is in).
	  * Receipts can be delivered more than once, even concurrently and on different servers.
	    Every PurchaseId is recorded in a DataStore ledger (idempotency) and locked in-memory.
	  * Handlers MUST yield until their grant is saved, and SHOULD be idempotent themselves
	    (receipt.PurchaseId is supplied for that) -- e.g. store the PurchaseId in the player's
	    profile in the same save as the granted item.
	  * Game passes are checked with retries and cached; PromptGamePassPurchaseFinished updates it.
	  * On BindToClose, the server waits for in-flight receipts to finish.
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	CurrencyType: Enum.CurrencyType,
}

-- Return true ONLY if the grant succeeded and is saved. Errors/false => retried later.
export type ProductHandler = (player: Player, receipt: Receipt) -> boolean
export type PassHandler = (player: Player, passId: number) -> ()

export type Config = {
	LedgerName: string?,
	MaxRetries: number?,
	RetryDelay: number?,
	Logger: ((level: string, message: string) -> ())?,
}

local RazorMarket = {}

local started = false
local ledgerName = "RazorMarket_PurchaseLedger_v1"
local maxRetries = 5
local retryDelay = 1
local logger: (string, string) -> () = function(level, message)
	if level == "error" then
		warn("[RazorMarket] " .. message)
	elseif level == "warn" then
		warn("[RazorMarket] " .. message)
	end
end

local ledger: DataStore? = nil
local productHandlers: { [number]: ProductHandler } = {}
local defaultProductHandler: ProductHandler? = nil
local passHandlers: { [number]: { PassHandler } } = {}
local passCache: { [number]: { [number]: boolean } } = {}
local inFlight: { [string]: boolean } = {}
local grantedThisServer: { [string]: boolean } = {}
local inFlightCount = 0

local function retry<T...>(label: string, fn: () -> T...): (boolean, any)
	local lastErr: any
	for attempt = 1, maxRetries do
		local results = table.pack(pcall(fn))
		if results[1] then
			return true, table.unpack(results, 2, results.n)
		end
		lastErr = results[2]
		logger("warn", `{label} failed (attempt {attempt}/{maxRetries}): {lastErr}`)
		if attempt < maxRetries then
			task.wait(retryDelay * 2 ^ (attempt - 1))
		end
	end
	return false, lastErr
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
	logger("error", `Could not open ledger DataStore: {store}`)
	return nil
end

local function ledgerKey(receipt: Receipt): string
	return `{receipt.PlayerId}_{receipt.PurchaseId}`
end

-- Returns (readOk, alreadyGranted)
local function isRecorded(receipt: Receipt): (boolean, boolean)
	local store = getLedger()
	if not store then
		return false, false
	end
	local ok, value = retry("Ledger read", function()
		return store:GetAsync(ledgerKey(receipt))
	end)
	if not ok then
		return false, false
	end
	return true, value ~= nil
end

local function record(receipt: Receipt): boolean
	local store = getLedger()
	if not store then
		return false
	end
	local ok = retry("Ledger write", function()
		store:UpdateAsync(ledgerKey(receipt), function(old)
			return old or { ProductId = receipt.ProductId, GrantedAt = os.time() }
		end)
	end)
	return ok
end

local function processReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local key = ledgerKey(receipt)

	if grantedThisServer[key] then
		-- Granted here earlier but ledger write failed; try to persist again.
		if record(receipt) then
			grantedThisServer[key] = nil
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return NOT_YET
	end

	if inFlight[key] then
		return NOT_YET -- concurrent duplicate; Roblox will retry
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
		local readOk, already = isRecorded(receipt)
		if not readOk then
			return
		end
		if already then
			decision = Enum.ProductPurchaseDecision.PurchaseGranted
			return
		end
		if player.Parent ~= Players then
			return
		end

		local handlerOk, granted = pcall(handler, player, receipt)
		if not handlerOk then
			logger("error", `Handler for product {receipt.ProductId} errored: {granted}`)
			return
		end
		if granted ~= true then
			return
		end

		if record(receipt) then
			decision = Enum.ProductPurchaseDecision.PurchaseGranted
		else
			-- Item was granted but not recorded: remember locally so we never re-grant here.
			grantedThisServer[key] = true
			logger("error", `Granted {key} but ledger write failed; will retry recording`)
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
	maxRetries = config.MaxRetries or maxRetries
	retryDelay = config.RetryDelay or retryDelay
	if config.Logger then
		logger = config.Logger
	end
end

--[=[ Register a grant handler for a developer product. Must return true once saved. ]=]
function RazorMarket.HandleProduct(productId: number, handler: ProductHandler)
	assert(productHandlers[productId] == nil, `Product {productId} already has a handler`)
	productHandlers[productId] = handler
end

--[=[ Fallback handler for products without a specific handler. ]=]
function RazorMarket.HandleDefaultProduct(handler: ProductHandler)
	defaultProductHandler = handler
end

--[=[ Called when a player owns (on join) or buys (in-game) a game pass. ]=]
function RazorMarket.HandleGamePass(passId: number, handler: PassHandler)
	local list = passHandlers[passId] or {}
	passHandlers[passId] = list
	table.insert(list, handler)
	if started then
		for _, player in Players:GetPlayers() do
			task.spawn(function()
				if RazorMarket.OwnsGamePass(player, passId) then
					pcall(handler, player, passId)
				end
			end)
		end
	end
end

local function firePass(player: Player, passId: number)
	for _, handler in passHandlers[passId] or {} do
		local ok, err = pcall(handler, player, passId)
		if not ok then
			logger("error", `Game pass {passId} handler errored: {err}`)
		end
	end
end

--[=[ Ownership check with retries + per-player cache. ]=]
function RazorMarket.OwnsGamePass(player: Player, passId: number): boolean
	local cache = passCache[player.UserId]
	if cache and cache[passId] ~= nil then
		return cache[passId]
	end
	local ok, owns = retry(`UserOwnsGamePassAsync({passId})`, function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		return false -- don't cache failures, next call retries
	end
	if player.Parent == Players then
		passCache[player.UserId] = passCache[player.UserId] or {}
		passCache[player.UserId][passId] = owns == true
	end
	return owns == true
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

local infoCache: { [string]: any } = {}
function RazorMarket.GetProductInfo(id: number, infoType: Enum.InfoType?): any?
	local t = infoType or Enum.InfoType.Product
	local key = `{t.Name}_{id}`
	if infoCache[key] then
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

	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		passCache[player.UserId] = passCache[player.UserId] or {}
		passCache[player.UserId][passId] = true
		firePass(player, passId)
	end)

	local function onPlayer(player: Player)
		for passId in passHandlers do
			task.spawn(function()
				if RazorMarket.OwnsGamePass(player, passId) then
					firePass(player, passId)
				end
			end)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		passCache[player.UserId] = nil
	end)

	game:BindToClose(function()
		local deadline = os.clock() + 25
		while inFlightCount > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

-- Exposed for tests only.
RazorMarket._processReceipt = processReceipt

return RazorMarket
