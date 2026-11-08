RazorData = use "razordata"
S = RazorData.Serializer

-- Serializer round-trips
local sample = {
    v3 = Vector3.new(1, 2, 3), cf = CFrame.new(1, 2, 3) * CFrame.Angles(0, 1, 0),
    c3 = Color3.new(1, 0, 0.5), mat = Enum.Material.Neon, dt = DateTime.now(),
    ns = NumberSequence.new(0, 1), udim2 = UDim2.fromScale(0.5, 0.5),
    mixed = { [1] = "a", [5] = "b", key = true }, inf = math.huge,
}
local decoded = S.Decode(game:GetService("HttpService"):JSONDecode(
    game:GetService("HttpService"):JSONEncode(S.Encode(sample))))
assert(decoded.v3 == sample.v3, "Vector3")
assert(decoded.cf == sample.cf, "CFrame")
assert(decoded.mat == Enum.Material.Neon, "EnumItem")
assert(decoded.mixed[5] == "b" and decoded.mixed.key, "mixed table")
assert(decoded.inf == math.huge, "inf")

-- Migrations
local M = RazorData.Migrations.new({
    function(d) d.Coins = d.Gold or 0; d.Gold = nil end,
    function(d) d.Inventory = d.Inventory or {} end,
})
local migrated, v = M:Run({ Gold = 50 }, 0)
assert(v == 2 and migrated.Coins == 50 and migrated.Gold == nil, "migration")

-- Session lock (live DataStore)
local store = RazorData.new({ Name = "RazorDataTest", Template = { Coins = 0 }, LoadRetries = 1, RetryDelay = 0 })
local profile = assert(store:LoadProfile("test-key"))
profile.Data.Coins += 1
assert(profile:Save(), "save")
assert(profile:Release(), "release")
assert(not profile:IsActive(), "inactive after release")
print("[RazorData] all tests passed")