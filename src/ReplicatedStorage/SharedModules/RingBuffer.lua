local insert=table.insert
local remove=table.remove
local move=table.move

local ReplicatedStorage=game:GetService'ReplicatedStorage'

local Class=require(ReplicatedStorage.SharedModules.Class)

local RingBufferClass=Class()

function RingBufferClass:GetLength()
	return self.Length
end

function RingBufferClass:PeekFront()
	--this should always behave correctly even if Length==0
	return self.Buffer[self.FrontIndex]
end

function RingBufferClass:PopFront()
	local Length=self.Length
	if Length==0 then
		return nil
	end
	local Buffer=self.Buffer
	local FrontIndex=self.FrontIndex
	local value=Buffer[FrontIndex]
	--write changes
	Buffer[FrontIndex]=nil
	self.FrontIndex=FrontIndex+1
	self.Length=Length-1
	return value
end

function RingBufferClass:PushBack(value)
	local Buffer=self.Buffer
	local Length=self.Length
	if Length==self.Capacity then
		--double capacity
		local Capacity=self.Capacity
		local NewCapacity=2*Capacity
		local FrontIndex=self.FrontIndex
		local NewFrontIndex=FrontIndex+Capacity
		if self.BackIndex<FrontIndex then
			--move elements
			move(Buffer,FrontIndex,Capacity,NewFrontIndex,Buffer)
			--write nil values (from beyond the end of the buffer) to moved elements in order to assist gc by erasing strong references
			move(Buffer,NewCapacity+1,NewCapacity+(Capacity-FrontIndex)+1,FrontIndex,Buffer)
		end
		self.FrontIndex=NewFrontIndex
		self.Capacity=NewCapacity
	end
	--write value to back
	local NewBackIndex=self.BackIndex+1
	self.Buffer[NewBackIndex]=value
	self.BackIndex=NewBackIndex
	self.Length=Length+1
end

function RingBufferClass:Constructor()
	self.FrontIndex=1
	self.BackIndex=1
	self.Length=0
	self.Capacity=1
	self.Buffer={}
end

return RingBufferClass
