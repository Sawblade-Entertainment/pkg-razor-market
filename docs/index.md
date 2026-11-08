# RazorMarket

Centralized, fail-safe `MarketplaceService` handling for Roblox. RazorMarket is the **single owner** of `MarketplaceService.ProcessReceipt` for your experience and is built around one goal: **a purchase must never be lost or granted twice.**

- [Quick start](#quick-start)
- [How it guarantees purchases](#how-it-guarantees-purchases)
- [Handler requirements (read this)](#handler-requirements-read-this)
- [Configuration](#configuration)
- [API reference](#api-reference)
- [Game passes](#game-passes)
- [Studio and testing](#studio-and-testing)
- [Failure behavior](#failure-behavior)
- [Limitations](#limitations)

## Quick start

Run on the **server**, once, after registering all handlers.

```lua
local RazorMarket = require(path.to.RazorMarket)

RazorMarket.Configure({
	-- Strongly recommended: check the player's saved profile for this PurchaseId.
	IsAlreadyGranted = function(player, purchaseId)
		local profile = Profiles[player]
		return profile ~= nil and profile.Data.Purchases[purchaseId] == true
	end,
})

RazorMarket.HandleProduct(123456, function(player, receipt)
	local profile = Profiles[player]
	if not profile then
		return false -- retried later
	end

	-- Grant the item AND record the PurchaseId in the SAME save.
	profile.Data.Coins += 100
	profile.Data.Purchases[receipt.PurchaseId] = true

	local saved = SaveProfile(player) -- must yield until saved
	return saved -- true only once durably saved
end)

RazorMarket.HandleGamePass(987654, function(player, passId)
	grantVipPerks(player) -- must be safe to run on every join
end)

RazorMarket.Start()
```

Never set `MarketplaceService.ProcessReceipt` anywhere else. Roblox allows only one callback, and the last one assigned wins.

## How it guarantees purchases

| Concern | What RazorMarket does |
| --- | --- |
| Errors, missing player, missing handler, handler returns `false` | Returns `NotProcessedYet`; Roblox retries (on rejoin or on any server). |
| Same receipt delivered twice on one server | In-memory lock; the duplicate gets `NotProcessedYet` and is retried. |
| Same receipt delivered on two servers | Atomic **claim** in a DataStore ledger (a single `UpdateAsync`) before the handler runs. A second server sees the live claim and defers. |
| Server dies mid-grant | Claims expire after `ClaimTimeout` (default 60s) so another server can take over. |
| Granted, but ledger write failed | Remembered in memory; only the *recording* is retried, the handler is **not** run again on that server. |
| Granted and saved, ledger write failed, then the server died | `IsAlreadyGranted` checks the player's profile first, so the grant is not repeated. |
| Transient DataStore / Marketplace errors | Every Roblox call is retried with exponential backoff (default 5 attempts: 1s, 2s, 4s, 8s). |
| Server shutdown | `BindToClose` waits up to `ShutdownWait` seconds for in-flight receipts. |

### Receipt flow

1. Player must be in this server, and a handler must exist, otherwise `NotProcessedYet`.
2. If `IsAlreadyGranted` is configured and returns `true`, mark the ledger (best effort) and return `PurchaseGranted`. If it errors, return `NotProcessedYet`.
3. Atomically **claim** the ledger entry (`claimed`). Already `granted` returns `PurchaseGranted`. A live claim from another server returns `NotProcessedYet`. A ledger error returns `NotProcessedYet`.
4. Run your handler. Error or non-`true` result releases the claim and returns `NotProcessedYet`.
5. Mark the ledger `granted`, then return `PurchaseGranted`. A `granted` record is never downgraded.

Ledger entries are keyed `{PlayerId}_{PurchaseId}` in the DataStore `RazorMarket_PurchaseLedger_v1` and look like `{ Status, JobId, At, ProductId }` where `Status` is `claimed`, `granted` or `released`.

## Handler requirements (read this)

The ledger alone **cannot** guarantee exactly-once delivery. If a handler grants and saves, and then both the ledger write fails and the server dies, the ledger has no record. Your player data is the only other source of truth. So:

1. **Yield until the grant is saved.** Return `true` only after your data save has completed. Returning early can lose a purchase if the server shuts down before the save.
2. **Store `receipt.PurchaseId` in the player's profile in the same save as the item.**
3. **Provide `IsAlreadyGranted`** so RazorMarket can consult that profile before running the handler. `Start()` logs a warning if it is missing.
4. Return `false` (or error) to have the purchase retried. Never return `true` if the grant did not happen.
5. On shutdown your save shares the server's ~30s `BindToClose` budget with RazorMarket. Keep saves fast (`ShutdownWait` defaults to 20s).

## Configuration

Call `RazorMarket.Configure(config)` **before** `Start()`. All fields are optional.

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `LedgerName` | `string` | `"RazorMarket_PurchaseLedger_v1"` | DataStore name for the purchase ledger. |
| `UseLedger` | `boolean` | `true` | Set `false` **only** for Studio or testing without DataStore API access. Disables cross-server deduplication. |
| `ClaimTimeout` | `number` | `60` | Seconds before another server may take over a claim. |
| `MaxRetries` | `number` | `5` | Attempts per Roblox call. |
| `RetryDelay` | `number` | `1` | Base backoff in seconds (doubles each attempt). |
| `ShutdownWait` | `number` | `20` | Seconds `BindToClose` waits for in-flight receipts. |
| `IsAlreadyGranted` | `(player, purchaseId) -> boolean` | `nil` | Return `true` if the player's saved profile already records this purchase. Errors are treated as unknown and the receipt is retried. |
| `Logger` | `(level: string, message: string) -> ()` | prints `warn`/`error` via `warn` | Custom logging. Levels: `"warn"`, `"error"`. |

## API reference

### Types

```lua
export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	CurrencyType: Enum.CurrencyType,
}

export type ProductHandler = (player: Player, receipt: Receipt) -> boolean
export type PassHandler = (player: Player, passId: number) -> ()
```

### `RazorMarket.Configure(config)`
Sets options. Asserts if called after `Start()`.

### `RazorMarket.HandleProduct(productId, handler)`
Registers the grant handler for a developer product. One handler per product (asserts on duplicates). See [Handler requirements](#handler-requirements-read-this).

### `RazorMarket.HandleDefaultProduct(handler)`
Fallback handler for products with no specific handler. Same rules as `HandleProduct`. Without any handler, a purchase logs an error and returns `NotProcessedYet`.

### `RazorMarket.HandleGamePass(passId, handler)`
Registers a handler run when a player owns the pass on join, or buys it in-game. Multiple handlers per pass are allowed. Handlers must be safe to run repeatedly. If registered after `Start()`, it runs for players already in the server.

### `RazorMarket.OwnsGamePass(player, passId): boolean`
Ownership check with retries and a per-player cache. Failed checks return `false` and are **not** cached, so the next call retries.

### `RazorMarket.InvalidatePass(player, passId?)`
Clears cached ownership so the next `OwnsGamePass` re-queries Roblox. Omit `passId` to clear all of that player's passes. Use after a possible website purchase mid-session.

### `RazorMarket.PromptProduct(player, productId)`
Prompts a developer product purchase.

### `RazorMarket.PromptGamePass(player, passId)`
Prompts a game pass purchase, skipped if the player already owns it.

### `RazorMarket.GetProductInfo(id, infoType?): any?`
`MarketplaceService:GetProductInfo` with retries and caching. `infoType` defaults to `Enum.InfoType.Product`. Returns `nil` on failure (not cached).

### `RazorMarket.Start()`
Server only. Takes ownership of `ProcessReceipt`, wires game pass events and player tracking, and registers the `BindToClose` wait. Idempotent.

### `RazorMarket._processReceipt(receipt)`
Test hook that runs the real receipt pipeline on a fake receipt. Do not call it in production code.

## Game passes

- Ownership is checked on every join for each registered pass and cached per player.
- Buying a pass in-game updates the cache immediately and fires its handlers.
- A pass bought on the website mid-session stays cached until the player rejoins, or until you call `InvalidatePass`.
- Pass handlers run on **every** join, so make them idempotent.

## Studio and testing

With *Enable Studio Access to API Services* off, DataStore calls fail and receipts stay `NotProcessedYet`. RazorMarket logs one clear error explaining this. Either enable the setting in **Game Settings > Security**, or for local testing only:

```lua
RazorMarket.Configure({ UseLedger = false })
```

`Start()` warns loudly when the ledger is disabled. Never ship with it off.

The harness in `server/TestService.luau` runs fake receipts through `_processReceipt` and asserts that:

1. The first delivery grants.
2. A duplicate returns `PurchaseGranted` without re-granting.
3. Concurrent duplicates grant exactly once.
4. An unknown product returns `NotProcessedYet`.

Replace the placeholder product and pass IDs (`0`) with real ones before running it.

## Failure behavior

| Situation | Result |
| --- | --- |
| Player left the server | `NotProcessedYet`, retried when they rejoin |
| No handler for the product | Error logged, `NotProcessedYet` |
| Handler errors or returns non-`true` | Claim released, `NotProcessedYet` |
| `IsAlreadyGranted` errors | `NotProcessedYet` |
| Ledger unavailable | One error logged, `NotProcessedYet` |
| Another server holds a live claim | `NotProcessedYet` |
| Claim older than `ClaimTimeout` | Taken over by this server |
| Granted but ledger write fails | Only the recording is retried on this server |
| Shutdown with receipts in flight | Warning logged; Roblox retries them later |

## Limitations

- Subscriptions are not covered (`ProcessReceipt` is not used for them).
- Exactly-once across servers depends on your handler saving `PurchaseId` with the item. The library cannot do this for you.
- Handlers that take longer than `ClaimTimeout` may let another server take over the claim, so keep grants fast.
