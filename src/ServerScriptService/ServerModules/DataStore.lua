local type=type
local warn=warn
local error=error
local pcall=pcall
local select=select
local unpack=unpack
local assert=assert

local band=bit32.band

local coyield=coroutine.yield
local cocreate=coroutine.create
local coresume=coroutine.resume
local corunning=coroutine.running

local ReplicatedStorage=game:GetService'ReplicatedStorage'
local Class=require(ReplicatedStorage.SharedModules.Class)
local RingBufferClass=require(ReplicatedStorage.SharedModules.RingBuffer)

local DataStoreService=game:GetService'DataStoreService'

--[[per key limit
Property 	Size Limit
Name 		50
Scope 		50
Key 		50
Data* 		4194303
--]]

--[[ backlog limit
/ Budget Type 				Start 	Base rate 	Per-player rate 	N Player Max (for N >= 0)
GetAsync 					100 	60 			40 					3 * (60 + N * 40)
{Set|Increment}Async 		100 	60 			40 					3 * (60 + N * 40)
GetSortedAsync 				10 		5 			2 					3 * (5 + N * 2)
{Set|Increment}SortedAsync	100 	30 			5 					3 * (30 + N * 5)
OnUpdate 					30 		30 			5 					1 * (30 + N * 5)
UpdateAsync 				100 	60 			40 					3 * (60 + N * 40)
--]]

local REQUEST_GUARANTEE_NOTHING=0
local REQUEST_GUARANTEE_ORDER=1
local REQUEST_GUARANTEE_DELIVERY=2

local RequestFlags={
	REQUEST_GUARANTEE_NOTHING=REQUEST_GUARANTEE_NOTHING,
	REQUEST_GUARANTEE_ORDER=REQUEST_GUARANTEE_ORDER,
	REQUEST_GUARANTEE_DELIVERY=REQUEST_GUARANTEE_DELIVERY,
}

--DataStoreRequestType
--This list informs how many independently ratelimited request lanes there are
local RequestTypes={
--Normal queries
	"GetAsync",
	"SetIncrementAsync",
	"UpdateAsync", -- note: read counts towards GetAsync budget, write counts towards SetIncrementAsync budget
	"GetSortedAsync",
	"SetIncrementSortedAsync",
	"OnUpdate", -- "OnUpdate only consumes budget when you connect it, not when triggered" ok
--Special queries (not implemented)
--	"ListAsync",
--	"GetVersionAsync",
--	"RemoveVersionAsync",
}
local NRequestTypes=#RequestTypes
local RequestTypeIdFromRequestType={}
for i=1,NRequestTypes do
	RequestTypeIdFromRequestType[RequestTypes[i]]=i
end
local RequestTypeEnumFromRequestType={}
for i=1,NRequestTypes do
	local RequestType=RequestTypes[i]
	RequestTypeEnumFromRequestType[RequestType]=Enum.DataStoreRequestType[RequestType]
end

--DataStore:GetRequestBudgetForRequestType
--guaranteed delivery requests are sent to a specific lane that checks the current budget and works through the queue
local RequestTypeIdFromFunctionName={
	GetAsync=				1,--GetAsync
	SetAsync=				2,--SetIncrementAsync
	IncrementAsync=			2,--SetIncrementAsync
	UpdateAsync=			3,--UpdateAsync
	GetSortedAsync=			4,--GetSortedAsync
	SetSortedAsync=			5,--SetIncrementSortedAsync
	IncrementSortedAsync=	5,--SetIncrementSortedAsync
	OnUpdate=				6,--OnUpdate
--	ListAsync=				7,--ListAsync
--	GetVersionAsync=		8,--GetVersionAsync
--	RemoveVersionAsync=		9,--RemoveVersionAsync
}
local RequestTypeEnumFromFunctionName={
	GetAsync=				Enum.DataStoreRequestType.GetAsync,
	SetAsync=				Enum.DataStoreRequestType.SetIncrementAsync,
	IncrementAsync=			Enum.DataStoreRequestType.SetIncrementAsync,
	UpdateAsync=			Enum.DataStoreRequestType.UpdateAsync,
	GetSortedAsync=			Enum.DataStoreRequestType.GetSortedAsync,
	SetSortedAsync=			Enum.DataStoreRequestType.SetIncrementSortedAsync,
	IncrementSortedAsync=	Enum.DataStoreRequestType.SetIncrementSortedAsync,
	OnUpdate=				Enum.DataStoreRequestType.OnUpdate,
--	ListAsync=				Enum.DataStoreRequestType.ListAsync,
--	GetVersionAsync=		Enum.DataStoreRequestType.GetVersionAsync,
--	RemoveVersionAsync=		Enum.DataStoreRequestType.RemoveVersionAsync,
}

--convert to and from int
local RequestFunctionNames={
	"GetAsync",
	"SetAsync",
	"IncrementAsync",
	"UpdateAsync",
	"GetSortedAsync",
	"SetSortedAsync",
	"IncrementSortedAsync",
	"OnUpdate",
--	"ListAsync",
--	"GetVersionAsync",
--	"RemoveVersionAsync",
}
local FunctionIdFromFunctionName={}
for i=1,#RequestFunctionNames do
	FunctionIdFromFunctionName[RequestFunctionNames[i]]=i
end

--guarantee order means that the request is processed through a global queue in a specific lane
--guarantee delivery means that the request will retry indefinitely, otherwise it will try once and return an error.

--If a request asks for guaranteed order, it will be placed at the back of the global queue even if guaranteed delivery is not flagged

local global_ordered_request_queue=RingBufferClass()
local delivery_request_queue_lanes={}
for i=1,NRequestTypes do
	delivery_request_queue_lanes[i]=RingBufferClass()
end

local function resumeWarnErr(...)
	local NoErr,ErrMsg=coresume(...)
	if not NoErr then
		warn("DataStore error:",ErrMsg)
	end
end

local function GetLane(request)
	local flags=request.Flags
	if band(flags,REQUEST_GUARANTEE_ORDER)~=0 then
		return global_ordered_request_queue
	elseif band(flags,REQUEST_GUARANTEE_DELIVERY)~=0 then
		--request.FunctionName is supposed to be validated at this point
		return delivery_request_queue_lanes[RequestTypeIdFromFunctionName[request.FunctionName]]
	end
	--requests with empty flags are attempted immediately and then dropped, no lane interaction
	return nil
end

local function VarArgDoRequest(attempt_inline,request,status,...)
	if not status then
		warn("DataStore request failed:",request.StoreName,request.StoreScope,request.FunctionName,"\nError:",...)
		--if REQUEST_GUARANTEE_DELIVERY bit is set, push the request into a lane
		if band(request.Flags,REQUEST_GUARANTEE_DELIVERY)~=0 then
			local lane=GetLane(request)
			if lane then
				lane:PushBack(request)
				--inline failed, request must be delayed
				return false
			else
				--this is an error because requests with REQUEST_GUARANTEE_DELIVERY should always return a lane
				error("Could not get lane for request")
			end
		end
	end
	local Thread=request.Thread
	if Thread then
		resumeWarnErr(Thread,status,...)
	else
		return attempt_inline,status,...
	end
end

--returns inline_success,status,...
local function DoRequest(attempt_inline,request)
	local data_store=DataStoreService:GetDataStore(request.StoreName,request.StoreScope)
	return VarArgDoRequest(attempt_inline,request,pcall(data_store[request.FunctionName],data_store,unpack(request.Args,1,request.NArgs)))
end

--returns inline_success,status,...
local function RunDoRequest(attempt_inline,request)
	if attempt_inline then
		return DoRequest(attempt_inline,request)
	else
		resumeWarnErr(cocreate(DoRequest),attempt_inline,request)
		return false
	end
end

local function BudgetCheck(function_name)
	return 0<DataStoreService:GetRequestBudgetForRequestType(RequestTypeEnumFromFunctionName[function_name])
end
--returns inline_success,status,...
local function ProcessRequest(attempt_inline,request)
	--if lane is empty, try immediately
	local lane=GetLane(request)
	if lane then
		--if there is no requests ahead of this one, try it immediately
		if lane:GetLength()==0 then
			if BudgetCheck(request.FunctionName) then
				return RunDoRequest(attempt_inline,request)
			else
				return false
			end
		else
			lane:PushBack(request)
			return false
		end
	else
		if BudgetCheck(request.FunctionName) then
			return RunDoRequest(attempt_inline,request)
		else
			return false
		end
	end
end

local function VarArgBlockingRequest(request,inline_success,...)
	if inline_success then
		return ...
	else
		request.Thread=corunning()
		return coyield()
	end
end
local function VarArgCallbackRequest(request,Thread,inline_success,...)
	if inline_success then
		--unreachable
		resumeWarnErr(Thread,...)
	else
		request.Thread=Thread
	end
end

local RequestBuilderClass=Class()
function RequestBuilderClass:GetDataStore()
	assert(type(self.StoreName)=="string","GetDataStore failed: Request.StoreName is not a string")
	assert(type(self.StoreScope)=="string","GetDataStore failed: Request.StoreScope is not a string")
	return self.StoreName,self.StoreScope
end
function RequestBuilderClass:SetDataStore(store_name,store_scope)
	assert(self.StoreName==nil,"SetDataStore failed: Attempt to double-set Request.StoreName")
	assert(self.StoreScope==nil,"SetDataStore failed: Attempt to double-set Request.StoreScope")
	assert(type(store_name)=="string","SetDataStore failed: Value is not a string")
	assert(type(store_scope)=="string","SetDataStore failed: Value is not a string")
	self.StoreName=store_name
	self.StoreScope=store_scope
end
function RequestBuilderClass:GetFlags()
	assert(type(self.Flags)=="number","GetDataStore failed: Request.Flags is not a number")
	return self.Flags
end
function RequestBuilderClass:SetFlags(request_flags)
	assert(self.Flags==nil,"SetDataStore failed: Attempt to double-set Request.Flags")
	assert(type(request_flags)=="number","SetDataStore failed: Value is not a number")
	self.Flags=request_flags
end
function RequestBuilderClass:GetQuery()
	assert(type(self.FunctionName)=="string","GetQuery failed: Request.FunctionName is not a string")
	assert(type(self.Args)=="table","GetQuery failed: Request.Args is not a table")
	assert(type(self.NArgs)=="number","GetQuery failed: Request.NArgs is not a number")
	return self.FunctionName,self.Args,self.NArgs
end
function RequestBuilderClass:SetQuery(request_fn_name,...)
	assert(self.FunctionName==nil,"SetQuery failed: Attempt to double-set Request.FunctionName")
	assert(FunctionIdFromFunctionName[request_fn_name]~=nil,"SetQuery failed: Invalid FunctionName")
	self.FunctionName=request_fn_name
	--not going to bother with argument validation, you better pray you got your arguments right
	self.Args={...}
	--this is necessary because lua tables can have holes, #t cannot be trusted if some arguments are nil
	self.NArgs=select("#",...)
end
local function build_request(RequestBuilder)
	local request={}
	request.StoreName,request.StoreScope=RequestBuilder:GetDataStore()
	request.Flags=RequestBuilder:GetFlags()
	request.FunctionName,request.Args,request.NArgs=RequestBuilder:GetQuery()
	return request
end
function RequestBuilderClass:Wait()
	local request=build_request(self)
	return VarArgBlockingRequest(request,ProcessRequest(true,request))
end
function RequestBuilderClass:Once(callback)
	local request=build_request(self)
	return VarArgCallbackRequest(request,cocreate(callback),ProcessRequest(false,request))
end

local function ProcessLane(attempt_inline,lane)
	while true do
		local front_request=lane:PeekFront()
		if front_request then
			if BudgetCheck(front_request.FunctionName) then
				RunDoRequest(attempt_inline,lane:PopFront())
			else
				break
			end
		else
			break
		end
	end
end

--check global_ordered_request_queue forever
local wait=task.wait
task.spawn(function()
	while true do
		--this has to be processed in this contrived way instead of using RunService.Stepped
		--so that it is guaranteed to process each request to completion
		local success,err=pcall(ProcessLane,true,global_ordered_request_queue)
		if not success then
			warn("ProcessLane (ordered) Error:",err)
		end
		wait()
	end
end)
--check delivery_request_queue_lanes forever
for lane=1,NRequestTypes do
	local delivery_request_queue_lane=delivery_request_queue_lanes[lane]
	task.spawn(function()
		while true do
			--requests in these queues will necessarily not care about order
			local success,err=pcall(ProcessLane,false,delivery_request_queue_lane)
			if not success then
				warn("ProcessLane (delivery) Error:",err)
			end
			wait()
		end
	end)
end

return {
	RequestFlags=RequestFlags,
	Request=RequestBuilderClass,
}
