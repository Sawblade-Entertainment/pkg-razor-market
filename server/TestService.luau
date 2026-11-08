-- Test harness for RazorMarket (not part of the package).
-- Runs the real ProcessReceipt pipeline against fake receipts and asserts exactly-once grants.
-- Requires DataStore API access (or set USE_LEDGER = false for pure local testing).
HttpService = use "HttpService"
Players = use "Players"
RazorMarket = use "razormarket"

local TEST_PRODUCT = 3729815949 -- replace with a real developer product id
local TEST_PASS = 2075908399 -- replace with a real game pass id
local USE_LEDGER = true

-- Stand-in for the player's saved profile. In a real game this is your DataStore profile,
-- and PurchaseId must be saved in the SAME write as the granted item.
local profiles: { [number]: { Purchases: { [string]: boolean }, Coins: number } } = {}
local grantCount: { [string]: number } = {}

local function getProfile(player: Player)
	profiles[player.UserId] = profiles[player.UserId] or { Purchases = {}, Coins = 0 }
	return profiles[player.UserId]
end

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
	print(`[Test] Granted product to {player.Name} ({receipt.PurchaseId})`)
	return true
end)

RazorMarket.HandleGamePass(TEST_PASS, function(player, passId)
	print(`[Test] {player.Name} owns pass {passId}`)
end)

RazorMarket.Start()

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

local function runTests(player: Player)
	local Granted = Enum.ProductPurchaseDecision.PurchaseGranted
	local NotYet = Enum.ProductPurchaseDecision.NotProcessedYet

	-- 1. First delivery grants.
	local id = "test_" .. HttpService:GenerateGUID(false)
	local d1 = RazorMarket._processReceipt(fakeReceipt(player, id))
	assert(d1 == Granted, `expected PurchaseGranted on first delivery, got {d1}`)
	assert(grantCount[id] == 1, "handler should have run exactly once")

	-- 2. Duplicate delivery is acknowledged WITHOUT re-granting.
	local d2 = RazorMarket._processReceipt(fakeReceipt(player, id))
	assert(d2 == Granted, `expected PurchaseGranted on duplicate, got {d2}`)
	assert(grantCount[id] == 1, "duplicate receipt re-ran the handler!")

	-- 3. Concurrent duplicate on the same server is deferred, not double-granted.
	local id2 = "test_" .. HttpService:GenerateGUID(false)
	local results = {}
	for i = 1, 2 do
		task.spawn(function()
			results[i] = RazorMarket._processReceipt(fakeReceipt(player, id2))
		end)
	end
	repeat
		task.wait(0.1)
	until results[1] ~= nil and results[2] ~= nil
	assert(grantCount[id2] == 1, "concurrent receipts double-granted!")
	assert(
		(results[1] == Granted and results[2] == NotYet) or (results[1] == NotYet and results[2] == Granted)
			or (results[1] == Granted and results[2] == Granted),
		"unexpected concurrent decisions"
	)

	-- 4. Unknown product => NotProcessedYet (no default handler registered).
	local bad = fakeReceipt(player, "test_" .. HttpService:GenerateGUID(false))
	bad.ProductId = -1
	assert(RazorMarket._processReceipt(bad) == NotYet, "unknown product must not be marked granted")

	print("[Test] All RazorMarket receipt tests passed for", player.Name)
end

local function onPlayer(player: Player)
	task.spawn(function()
		local ok, err = pcall(runTests, player)
		if not ok then
			warn("[Test] FAILED:", err)
		end
	end)
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end
