--Generic object class constructor class
local setmetatable=setmetatable

local clone=table.clone

local Metatable={}

local function SetMetamethod(self,Name,f)
	self.Metamethods[Name]=f
end
Metatable.__newindex=SetMetamethod

local function DepthFirstConstructor(self,Instance,...)
	if self.Base then
		DepthFirstConstructor(self.Base,Instance,...)
	end
	self.Constructor(Instance,...)
end

local function Call(self,...)
	local Instance=setmetatable({},self.Metatable)
	DepthFirstConstructor(self,Instance,...)
	return Instance
end
Metatable.__call=Call

local function Thru(...)
	return ...
end

local function New(Base)
	local Metamethods
	if Base then
		Metamethods=clone(Base.Metamethods)
	else
		Metamethods={}
	end
	return setmetatable({
		Base=Base,
		Constructor=Thru,
		Metatable={__index=Metamethods},
		Metamethods=Metamethods,
	},Metatable)
end

return New