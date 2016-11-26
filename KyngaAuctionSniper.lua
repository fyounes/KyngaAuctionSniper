--[[

]]--

KyngaAuctionSniper = { }
local kas = KyngaAuctionSniper

KyngaAuctionSniperOptions = {
    -- TODO: Maybe profit should be as a percentage, with a hard max on spending
    MinAvailable =           100;   -- Measure liquidity - Minimum number of items being sold 
    MinAuctions =             10;   -- Measure liquidity - Minimum number of auctions, regardless of stack size
    MinPrice =            100000;   -- Minimum median price for a single item (discard junk)
    MaxBuyAmount =     250000000;   -- Maximum money willing to spend (per item id)
    MinProfit =          5000000;   -- Minimum profit
    AuctionsPerFrame =       500;   -- How many auctions to process per individual frame inside onUpdate (getAll only)
    AuctionDuration =         12;   -- Auction duration (H) to use for calculations
    LogLevel =            'TRACE';
}
local options = KyngaAuctionSniperOptions

local frame = CreateFrame("FRAME", "KyngaAuctionSniper")

local auctionHouseOpen = false
local queriedAuctionHouse = false


local lastUpdate = 0 -- Last Update time for onUpdate

-- AH Processing variables
local totalAuctions = -1 -- Total number of auctions in the current query
local currentPageSize = -1 -- Page size for the current query
local processedAuctions = 0 -- Auctions processed out of the current query
local getAllScan = false -- Is the current query a getAll?

-- Auction Storage
local auctionData = {}
local storedAuctions = 0
local storedItems = 0

------------------------------------------------------------------
-- Utility Functions
------------------------------------------------------------------
function KyngaAuctionSniper:Print(msg)
  if options.LogLevel == 'TRACE' or options.LogLevel == 'DEBUG' or options.LogLevel == 'INFO' then
    DEFAULT_CHAT_FRAME:AddMessage("[KAS] " .. tostring(msg), 0.8, 1.0, 0.25)
  end
end;

function KyngaAuctionSniper:Debug(msg)
  if options.LogLevel == 'TRACE' or options.LogLevel == 'DEBUG' then
    DEFAULT_CHAT_FRAME:AddMessage("[KAS D] " .. tostring(msg), 0.8, 1.0, 0.25)
  end
end;

function KyngaAuctionSniper:Trace(msg)
  if options.LogLevel == 'TRACE' then
    DEFAULT_CHAT_FRAME:AddMessage("[KAS T] " .. tostring(msg), 0.8, 1.0, 0.25)
  end
end;

function KyngaAuctionSniper:CalculateDepositCost(merchantPrice)
  return 0.15 * merchantPrice * (options.AuctionDuration / 12)
end

function KyngaAuctionSniper:CalculateAuctionFee(sellPrice)
  return 0.05 * sellPrice
end

function KyngaAuctionSniper:CalculateProfit(amountSpent, quantity, sellPrice, merchangPrice)
  local netPrice = sellPrice - kas:CalculateDepositCost(merchantPrice) - kas:CalculateAuctionFee(sellPrice)
  return quantity * netPrice - amountSpent
end

function KyngaAuctionSniper:pairsByKeys (t, f)
  local a = {}
  for n in pairs(t) do table.insert(a, n) end
  table.sort(a, f)
  local i = 0      -- iterator variable
  local iter = function ()   -- iterator function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end

-- Prints a table recursively
-- For Debugging purposes only... VERY verbose
function KyngaAuctionSniper:tprint ( tbl )
  if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      kas:tprint(v, indent+2)
    else
      print(formatting .. tostring(v))
    end
  end
end

------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------
frame:RegisterEvent('AUCTION_HOUSE_CLOSED')
frame:RegisterEvent('AUCTION_HOUSE_SHOW')
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

local function eventHandler(self, event, ...)
  if event == 'AUCTION_HOUSE_SHOW' then
    auctionHouseOpen = true
  elseif event == 'AUCTION_HOUSE_CLOSED' then
    auctionHouseOpen = false
  elseif event == 'AUCTION_ITEM_LIST_UPDATE' then
    kas:AHItemListUpdate(...)
  end
end
frame:SetScript("OnEvent", eventHandler)

local function onUpdate(self, elapsed)
  -- For getAll updates. Process data in chunks, otherwise the screen will freeze
  lastUpdate = lastUpdate + elapsed

  if lastUpdate > 0.1 then
    if getAllScan and totalAuctions > 0 and processedAuctions < totalAuctions then
      kas:ProcessAuctions(processedAuctions + 1, processedAuctions + options.AuctionsPerFrame)
    end
    lastUpdate = 0
  end
end
frame:SetScript("OnUpdate", onUpdate)

------------------------------------------------------------------
-- Item Data Storage/Processing
------------------------------------------------------------------

function KyngaAuctionSniper:DeleteStoredData ()
  for k,v in pairs(auctionData) do 
    auctionData[k]=nil
  end
  storedAuctions = 0
  storedItems = 0
  collectgarbage('collect')
end

function KyngaAuctionSniper:GetItem (itemId)
  if auctionData[itemId] == nil then
    auctionData[itemId] = {
        available = 0;
        numAuctions = 0;
        auctions = {};
    }
    storedItems = storedItems + 1
  end
  return auctionData[itemId]
end

function KyngaAuctionSniper:AddAuction (itemId, count, buyout)
  if buyout == nil then
    return
  end

  item = kas:GetItem(itemId)
  item.available = item.available + count
  item.numAuctions = item.numAuctions + 1
  storedAuctions = storedAuctions + 1
  
  if item.auctions[buyout] == nil then
    item.auctions[buyout] = count
  else
    item.auctions[buyout] = item.auctions[buyout] + count
  end
end

------------------------------------------------------------------
-- AH Interaction
------------------------------------------------------------------

function KyngaAuctionSniper:GetAuctionData (list, index)
  local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId = GetAuctionItemInfo(list, index)
  return itemId, count, ceil(buyout / count)
end

function KyngaAuctionSniper:AHItemListUpdate(...)
  local batch, total = GetNumAuctionItems('list')
  
  if total ~= totalAuctions then
    -- This is not reliable. The number of auctions can change while paging
    -- TODO need to figure this out. Doesn't seem to be correct based on what Auctionator is doing
    kas:Print('New Query')
    totalAuctions = total
    getAllScan = batch == total and total > 1000
    processedAuctions = 0
    kas:DeleteStoredData()
  end
  
  currentPageSize = batch
  kas:Trace('AHItemListUpdate - B: ' .. currentPageSize .. ' T: ' .. totalAuctions .. ' all? ' .. tostring(getAllScan))
  
  if not getAllScan then
    -- Not getAll, so process auctions now
    kas:ProcessAuctions(1, batch)
  end
end

function KyngaAuctionSniper:ProcessAuctions(from, to)
  kas:Trace('ProcessAuctions - ' .. from .. ' to ' .. to .. ' - Processed ' .. processedAuctions)
  for i = from, to do
    kas:AddAuction(kas:GetAuctionData('list', i))
    processedAuctions = processedAuctions + 1
    
    if processedAuctions % 1000 == 0 then
      kas:Print('Processed ' .. processedAuctions .. ' of ' .. totalAuctions)
    end
  end
  
  kas:PostProcessIfReady()
end

function KyngaAuctionSniper:PostProcessIfReady()
  -- If all the auction data queried is stored, run the calculations and clear any junk
  if processedAuctions == totalAuctions then
    kas:Print('Done! Stored ' .. storedAuctions .. ' auctions for ' .. storedItems .. ' items')
    -- kas:ProcessAuctionData()
  end
end

function KyngaAuctionSniper:ProcessAuctionData()
  kas:Trace('ProcessAuctionData')
  
  local counter
  local medianLoc
  
  for itemId, item in pairs(auctionData) do    
    if kas:IsLiquidEnough(item) then
      local sortedAuctions = kas:pairsByKeys(item.auctions)
      local medianPrice = kas:GetMedianPrice(sortedAuctions, floor(item.available / 2))
      
      if medianPrice < options.MinPrice then
        kas:Debug('Median price lower than minimum ' .. medianPrice)
      else
        kas:FindDeals(itemId, sortedAuctions)
      end
    end
  end
end

function KyngaAuctionSniper:FindDeals(itemId, sortedAuctions)
  local amountSpent = 0
  local quantity = 0
  local profit = 0
  local name, _, _, _, _, _, _, _, _, _, merchantPrice = GetItemInfo(itemId)
  
  for buyout, count in sortedAuctions do
    -- Calculate profit first. I need to know the 'next' price to figure out the auction fee... Useless the first time
    profit = kas:CalculateProfit(amountSpent, quantity, buyout, merchantPrice)
    if profit > options.MinProfit then
      kas:Print(name .. ' is a good target. You need to buy ' .. quantity .. ' at a max price of ' .. buyout .. ' to make ' .. profit)
      return
    end
    
    amountSpent = amountSpent + (count * buyout)
    quantity = quantity + count
      
    if amountSpent > options.MaxBuyAmount then
      kas:Debug(name .. ' is not good. Spent ' .. amountSpent .. ' so far (above threshold) - Expected Profit: ' .. profit)
      return
    end    
  end
end

function KyngaAuctionSniper:IsLiquidEnough(item)
  if options.MinAvailable > item.available or options.MinAuctions > item.numAuctions then
    kas:Debug('Not liquid enough. Available: ' .. item.available .. '. Auctions: ' .. item.numAuctions)
    return false
  end
  
  return true
end

function KyngaAuctionSniper:GetMedianPrice(sortedAuctions, location)
  local counter = 0
  
  for buyout, count in sortedAuctions do
    counter = counter + count
    if counter >= location then
      return buyout
    end
  end
  
  kas:Print('ERROR: No median price found?')
end