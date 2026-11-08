-- Test harness for RazorMarket (not part of the package).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RazorMarket = require(ReplicatedStorage:WaitForChild("RazorMarket"))

local TEST_PRODUCT = 0 -- replace with a real developer product id
local TEST_PASS = 0 -- replace with a real game pass id

local grantedIds = {}

RazorMarket.HandleProduct(TEST_PRODUCT, function(player, receipt)
	if grantedIds[receipt.PurchaseId] then
		return true -- idempotent
	end
	-- Grant + save the player's data here, yielding until saved.
	grantedIds[receipt.PurchaseId] = true
	print(`[Test] Granted product to {player.Name} ({receipt.PurchaseId})`)
	return true
end)

RazorMarket.HandleGamePass(TEST_PASS, function(player, passId)
	print(`[Test] {player.Name} owns pass {passId}`)
end)

RazorMarket.Start()
