DataStore with Guarantees
=========================

This repository provides an interface to Roblox's DataStore which can be requested to guarantee certain properties:

`REQUEST_GUARANTEE_NOTHING` = 0
- Make a request as soon as possible and do not retry on error.

`REQUEST_GUARANTEE_ORDER` = 1
- All requests with this flag run in the same global order they were called.  Pending requests are queued.

`REQUEST_GUARANTEE_DELIVERY` = 2
- Retry indefinitely until the request succeeds.

### Combining flags
`REQUEST_GUARANTEE_ORDER + REQUEST_GUARANTEE_DELIVERY` = 3
- You can combine the flags to guarantee both order and delivery.

### How to use
The main interface is `DataStore.Request` (referred to below as `RequestBuilderClass`) which is a class for building datastore requests with type checking.  Request flags are accessed like `DataStore.RequestFlags.REQUEST_GUARANTEE_DELIVERY`

## Examples

Fetching the current balance for a currency module
```lua
local function FetchBalances(UserId)
	assert(type(UserId)=="number","IncrementCurrency failed: UserId is not a number")
	local Key=get_datastore_key(UserId)
	local Request=RequestBuilderClass()
	Request:SetDataStore(DATASTORE_NAME,DATASTORE_SCOPE)
	--Guarantee that currency updates happen in order, maybe the user just bought currency and the request is still in transit.
	--Do not guarantee delivery, we do not care what the balance is in 5 minutes
	--Simply try the request again later with another call to FetchBalances
	Request:SetFlags(REQUEST_GUARANTEE_ORDER)
	Request:SetQuery("GetAsync",Key)
	--Wait method takes no arguments and blocks execution, returning the reponse
	local success,Balances=Request:Wait()
	if success then
		if Balances==nil then
			Balances={}
		end
		CurrencyUpdated:Call(UserId,Balances)
	end
	return success,Balances
end
```

Adding an item to an inventory system
```lua
function InventoryClass:AddItem(ItemID)
	assert(type(ItemID)=="string","ItemID must be a string")
	--permanently add the item to the player's inventory
	local Request=RequestBuilderClass()
	Request:SetDataStore(DATASTORE_NAME,DATASTORE_SCOPE)
	--Updating the inventory depends on the previous contents of the inventory, so guarantee order
	--Technically you could add items in any order but this is an example...
	--Adding an item to a user's inventory should succeed even if it takes 5 minutes, so guarantee delivery
	Request:SetFlags(REQUEST_GUARANTEE_ORDER+REQUEST_GUARANTEE_DELIVERY)
	Request:SetQuery("UpdateAsync",self.Key,function(Inventory)
		if Inventory==nil then
			Inventory={}
		end
		local ExistingItemCount=Inventory[ItemID] or 0
		Inventory[ItemID]=ExistingItemCount+1
		return Inventory
	end)
	--Once method takes a callback function and does not block execution
	Request:Once(function(Success,Response)
		print("[Inventory] AddItem success=",Success,"response=",Response)
		if Success and Response then
			local ItemCount=Response[ItemID]
			if ItemCount then
				self.Data:SetKey(ItemID,ItemCount)
			else
				print("[Inventory] ItemCount did not exist: ",ItemID)
			end
			self.Updated:Call()
		end
	end)
end
```

#### License

<sup>
Licensed under either of <a href="LICENSE-APACHE">Apache License, Version
2.0</a> or <a href="LICENSE-MIT">MIT license</a> at your option.
</sup>

<br>

<sub>
Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this repository by you, as defined in the Apache-2.0 license, shall
be dual licensed as above, without any additional terms or conditions.
</sub>
