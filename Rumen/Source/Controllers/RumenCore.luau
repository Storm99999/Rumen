--!native
--!optimize 2
--!strict

type FusionState<T> = {
	get: (Self: FusionState<T>) -> T,
	set: (Self: FusionState<T>, Value: T) -> (),
}

type SettingsType = {
	NumSamples: FusionState<number>,
	GridSize: FusionState<number>,
	Progress: FusionState<number>,
	ShowBoxes: FusionState<boolean>,
	ExecuteState: FusionState<string>,
	ShowProbes: FusionState<boolean>,
	Brightness: FusionState<number>,
	NeonBrightness: FusionState<number>,
	Probes: FusionState<number>,
	Root: Workspace,
	LightFolder: Folder?,
}

type IlluminationModule = {
	Run: (Self: IlluminationModule, Settings: SettingsType) -> (),
	UpdateShowProbes: (Self: IlluminationModule, TargetFolder: Folder, Visible: boolean) -> (),
	PlaceProbes: (Self: IlluminationModule, TargetFolder: Folder, Settings: SettingsType, Regions: { Instance }) -> (),
}

type WorkerLightRecord = {
	Light: PointLight?,
	LightAttachment: Attachment,
}

type WorkerActorRecord = {
	Event: BindableEvent,
	Lights: { WorkerLightRecord },
}

type RuntimeSettings = {
	MaxSamples: number,
	GridSize: number,
	Brightness: number,
	NeonBrightness: number,
	ShowProbes: boolean,
	LightFolder: Folder,
	WhiteList: { Instance },
	SunVec: Vector3,
}

type ModuleType = {
	Event: BindableEvent?,
	Running: boolean,
	AbortRequested: boolean,

	FindAABB: (Self: ModuleType, Target: Instance) -> (boolean, number, number, number, number, number, number),
	FindAABBS: (Self: ModuleType, Parts: { BasePart }) -> (boolean, number, number, number, number, number, number),
	Abort: (Self: ModuleType) -> (),
	Run: (Self: ModuleType, Settings: SettingsType) -> (),
	CountProbes: (Self: ModuleType, Regions: { BasePart }, GridSize: number) -> number,
	PlaceProbes: (Self: ModuleType, TargetFolder: Folder, Settings: SettingsType, Regions: { Instance }) -> number,
	BeginBake: (Self: ModuleType, Settings: RuntimeSettings, Progress: FusionState<number>?) -> (),
	UpdateShowProbes: (Self: ModuleType, TargetFolder: Folder, Visible: boolean) -> (),
	DoWork: (Self: ModuleType, SourceSettings: SettingsType) -> (),
	Cleanup: (Self: ModuleType) -> (),
}

local Module: ModuleType = {
	Event = nil :: BindableEvent?,
	Running = false :: boolean,
	AbortRequested = false :: boolean,
} :: ModuleType

local Workspace: Workspace = game:GetService("Workspace") :: Workspace
local Lighting: Lighting = game:GetService("Lighting") :: Lighting

local ScriptParent: Instance = script.Parent.Parent.Parent :: Instance
local PartsFolder: Instance = ScriptParent:WaitForChild("Dependencies"):FindFirstChild("Assets") :: Instance
local ActorsFolder: Instance = ScriptParent:WaitForChild("Tasks") :: Instance

local ProbeTemplate: Attachment = PartsFolder:WaitForChild("Source"):WaitForChild("Probe") :: Attachment
local LightRootTemplate: BasePart = PartsFolder:WaitForChild("LightRootPart") :: BasePart
local VisibleProbesRootTemplate: BasePart = PartsFolder:WaitForChild("VisibleProbesRootPart") :: BasePart
local ProbeBallTemplate: BasePart = PartsFolder:WaitForChild("ProbeBall") :: BasePart

local ModuleEvent: BindableEvent = script:WaitForChild("Event") :: BindableEvent
Module.Event = ModuleEvent :: BindableEvent

local TaskWait: (number?) -> number = task.wait :: (number?) -> number
local TaskSpawn: (any, ...any) -> thread = task.spawn :: (any, ...any) -> thread
local Floor: (number) -> number = math.floor :: (number) -> number
local Abs: (number) -> number = math.abs :: (number) -> number
local Huge: number = math.huge :: number
local Vec3: (number, number, number) -> vector = vector.create :: (number, number, number) -> vector
local Vector3Zero: vector = vector.zero :: vector
local Region3New: (Vector3, Vector3) -> Region3 = Region3.new :: (Vector3, Vector3) -> Region3
local TableCreate: (number, any?) -> { any } = table.create :: (number, any?) -> { any }

local function AlignDown(Value: number, Step: number): number
	return Floor(Value / Step) * Step :: number
end

local function GetSpatialHash(X: number, Y: number, Z: number, GridSize: number): number
	local GridIndexX: number = Floor(X / GridSize) :: number
	local GridIndexY: number = Floor(Y / GridSize) :: number
	local GridIndexZ: number = Floor(Z / GridSize) :: number
	local OffsetX: number = (GridIndexX + 100000) :: number
	local OffsetY: number = (GridIndexY + 100000) :: number
	local OffsetZ: number = (GridIndexZ + 100000) :: number

	return (OffsetX * 10000000000) + (OffsetY * 100000) + OffsetZ :: number
end

local function GetAABBFromCFrame(CFrameValue: CFrame, Size: Vector3): (number, number, number, number, number, number)
	local Position: Vector3 = CFrameValue.Position :: Vector3
	local HalfX: number = (Size.X * 0.5) :: number
	local HalfY: number = (Size.Y * 0.5) :: number
	local HalfZ: number = (Size.Z * 0.5) :: number

	local RightVector: Vector3 = CFrameValue.RightVector :: Vector3
	local UpVector: Vector3 = CFrameValue.UpVector :: Vector3
	local LookVector: Vector3 = CFrameValue.LookVector :: Vector3

	local Ex: number = (Abs(RightVector.X) * HalfX + Abs(UpVector.X) * HalfY + Abs(LookVector.X) * HalfZ) :: number
	local Ey: number = (Abs(RightVector.Y) * HalfX + Abs(UpVector.Y) * HalfY + Abs(LookVector.Y) * HalfZ) :: number
	local Ez: number = (Abs(RightVector.Z) * HalfX + Abs(UpVector.Z) * HalfY + Abs(LookVector.Z) * HalfZ) :: number

	return Position.X - Ex, Position.Y - Ey, Position.Z - Ez, Position.X + Ex, Position.Y + Ey, Position.Z + Ez
end

function Module:FindAABB(Target: Instance): (boolean, number, number, number, number, number, number)
	local IsModel: boolean = Target:IsA("Model") :: boolean

	if IsModel then
		local ModelTarget: Model = Target :: Model
		local ModelCFrame: CFrame, ModelSize: Vector3 = ModelTarget:GetBoundingBox()
		local MinX: number, MinY: number, MinZ: number, MaxX: number, MaxY: number, MaxZ: number =
			GetAABBFromCFrame(ModelCFrame, ModelSize)

		return true, MinX, MinY, MinZ, MaxX, MaxY, MaxZ
	end

	local IsBasePart: boolean = Target:IsA("BasePart") :: boolean

	if IsBasePart then
		local Part: BasePart = Target :: BasePart
		local MinX: number, MinY: number, MinZ: number, MaxX: number, MaxY: number, MaxZ: number =
			GetAABBFromCFrame(Part.CFrame, Part.Size)

		return true, MinX, MinY, MinZ, MaxX, MaxY, MaxZ
	end

	return false, 0, 0, 0, 0, 0, 0
end

function Module:FindAABBS(Parts: { BasePart }): (boolean, number, number, number, number, number, number)
	local MinX: number = Huge :: number
	local MinY: number = Huge :: number
	local MinZ: number = Huge :: number
	local MaxX: number = -Huge :: number
	local MaxY: number = -Huge :: number
	local MaxZ: number = -Huge :: number

	local HasAny: boolean = false :: boolean

	local Count: number = (#Parts) :: number

	for Index: number = 1, Count do
		local Part: BasePart = Parts[Index] :: BasePart
		local Success: boolean, BoundsMinX: number, BoundsMinY: number, BoundsMinZ: number, BoundsMaxX: number, BoundsMaxY: number, BoundsMaxZ: number =
			self:FindAABB(Part)

		if Success then
			HasAny = true :: boolean

			if BoundsMinX < MinX then
				MinX = BoundsMinX :: number
			end

			if BoundsMinY < MinY then
				MinY = BoundsMinY :: number
			end

			if BoundsMinZ < MinZ then
				MinZ = BoundsMinZ :: number
			end

			if BoundsMaxX > MaxX then
				MaxX = BoundsMaxX :: number
			end

			if BoundsMaxY > MaxY then
				MaxY = BoundsMaxY :: number
			end

			if BoundsMaxZ > MaxZ then
				MaxZ = BoundsMaxZ :: number
			end
		end
	end

	if not HasAny then
		return false, 0, 0, 0, 0, 0, 0
	end

	return true, MinX, MinY, MinZ, MaxX, MaxY, MaxZ
end

local function PointInsidePart(Point: Vector3, PartCFrame: CFrame, HalfSize: Vector3): boolean
	local LocalPoint: Vector3 = PartCFrame:PointToObjectSpace(Point) :: Vector3

	local OutsideX: boolean = (LocalPoint.X < -HalfSize.X or LocalPoint.X > HalfSize.X) :: boolean
	local OutsideY: boolean = (LocalPoint.Y < -HalfSize.Y or LocalPoint.Y > HalfSize.Y) :: boolean
	local OutsideZ: boolean = (LocalPoint.Z < -HalfSize.Z or LocalPoint.Z > HalfSize.Z) :: boolean

	return not (OutsideX or OutsideY or OutsideZ) :: boolean
end

local function TestTouch(Root: Workspace, Position: Vector3, Radius: number): boolean
	local Parts: { BasePart } = Root:GetPartBoundsInRadius(Position, Radius) :: { BasePart }
	local PartCount: number = #Parts :: number

	for Index: number = 1, PartCount do
		local Part: BasePart = Parts[Index] :: BasePart

		if Part.Transparency < 1 then
			return true
		end
	end

	local Offset: vector = Vec3(Radius, Radius, Radius) :: vector
	local Region: Region3 = Region3New(Position - Offset, Position + Offset) :: Region3
	Region = Region:ExpandToGrid(4) :: Region3

	local _: { [number]: { [number]: { [number]: Enum.Material } } }
	local Occupancy: { [number]: { [number]: { [number]: number } } }
	_, Occupancy = Root.Terrain:ReadVoxels(Region, 4)

	local SizeX: number = #Occupancy :: number

	for X: number = 1, SizeX do
		local YLayer: { [number]: { [number]: number } } = Occupancy[X] :: { [number]: { [number]: number } }
		local SizeY: number = #YLayer :: number

		for Y: number = 1, SizeY do
			local ZLayer: { [number]: number } = YLayer[Y] :: { [number]: number }
			local SizeZ: number = #ZLayer :: number

			for Z: number = 1, SizeZ do
				if ZLayer[Z] > 0.25 then
					return true
				end
			end
		end
	end

	return false
end

local function TestBuried(Root: Workspace, Position: Vector3): boolean
	local Parts: { BasePart } = Root:GetPartBoundsInRadius(Position, 1) :: { BasePart }
	local PartCount: number = (#Parts) :: number

	for Index: number = 1, PartCount do
		local Part: BasePart = Parts[Index] :: BasePart
		local IsBasePart: boolean = Part:IsA("BasePart") :: boolean
		local IsMeshPart: boolean = Part:IsA("MeshPart") :: boolean

		if IsBasePart and not IsMeshPart then
			local CastShadow: boolean = Part.CastShadow :: boolean
			local Transparency: number = Part.Transparency :: number

			if CastShadow and Transparency < 1 then
				return true
			end
		end
	end

	return false
end

local function Invoke(
	List: { WorkerActorRecord },
	Method: string,
	Settings: RuntimeSettings,
	Progress: FusionState<number>?
)
	local Count: number = (#List) :: number

	if Count == 0 then
		return
	end

	local Pending: number = Count :: number
	local Connection: RBXScriptConnection? = nil :: RBXScriptConnection?
	local SharedEvent: BindableEvent = Module.Event :: BindableEvent

	Connection = SharedEvent.Event:Connect(function()
		Pending -= 1 :: number

		if Progress ~= nil then
			local ProgressValue: number = (1 - (Pending / Count)) :: number
			Progress:set(ProgressValue)
		end

		if Pending <= 0 and Connection ~= nil then
			local ValidConnection: RBXScriptConnection = Connection :: RBXScriptConnection

			ValidConnection:Disconnect()
			Connection = nil :: RBXScriptConnection?
		end
	end) :: RBXScriptConnection

	for Index: number = 1, Count do
		local Record: WorkerActorRecord = List[Index] :: WorkerActorRecord
		Record.Event:Fire(Method, Record, Settings, SharedEvent)
	end

	while Pending > 0 do
		TaskWait()
	end

	if Connection ~= nil then
		local FinalConnection: RBXScriptConnection = Connection :: RBXScriptConnection
		local IsConnected: boolean = FinalConnection.Connected :: boolean

		if IsConnected then
			FinalConnection:Disconnect()
		end
	end
end

function Module:Abort()
	self.AbortRequested = true :: boolean
end

function Module:Run(Settings: SettingsType)
	local IsRunning: boolean = self.Running :: boolean
	if IsRunning then
		self:Abort()
		return
	end

	self:DoWork(Settings)
end

function Module:CountProbes(Regions: { BasePart }, GridSize: number): number
	local Counter: number = 0 :: number
	local OverlapMap: { [number]: boolean } = {} :: { [number]: boolean }
	local RegionCount: number = (#Regions) :: number

	for PartIndex: number = 1, RegionCount do
		local Part: BasePart = Regions[PartIndex] :: BasePart
		local Success: boolean, BoundsMinX: number, BoundsMinY: number, BoundsMinZ: number, BoundsMaxX: number, BoundsMaxY: number, BoundsMaxZ: number =
			self:FindAABB(Part)

		if Success then
			local PartCFrame: CFrame = Part.CFrame :: CFrame
			local HalfSize: Vector3 = (Part.Size * 0.5) :: Vector3

			local StartX: number = AlignDown(BoundsMinX, GridSize) :: number
			local StartY: number = AlignDown(BoundsMinY, GridSize) :: number
			local StartZ: number = AlignDown(BoundsMinZ, GridSize) :: number

			for X: number = StartX, BoundsMaxX, GridSize do
				for Y: number = StartY, BoundsMaxY, GridSize do
					for Z: number = StartZ, BoundsMaxZ, GridSize do
						local HashIndex: number = GetSpatialHash(X, Y, Z, GridSize) :: number
						local AlreadyCounted: boolean = OverlapMap[HashIndex] :: boolean

						if not AlreadyCounted then
							local Point: vector = Vec3(X, Y, Z) :: vector
							local Inside: boolean = PointInsidePart(Point, PartCFrame, HalfSize) :: boolean

							if Inside then
								OverlapMap[HashIndex] = true :: boolean
								Counter += 1 :: number
							end
						end
					end
				end
			end
		end
	end

	return Counter
end

function Module:PlaceProbes(TargetFolder: Folder, Settings: SettingsType, Regions: { Instance }): number
	local GridSize: number = Settings.GridSize:get() :: number
	local ProbeRange: number = (GridSize * 1.5) :: number
	local Root: Workspace = Settings.Root :: Workspace

	local LightRootInstance: Instance? = TargetFolder:FindFirstChild("LightRootPart") :: Instance?

	if LightRootInstance == nil or not LightRootInstance:IsA("BasePart") then
		local ClonedRoot: BasePart = LightRootTemplate:Clone() :: BasePart

		ClonedRoot.Parent = TargetFolder :: Folder
		ClonedRoot.Position = Vector3Zero :: vector
		LightRootInstance = ClonedRoot :: BasePart
	end

	local LightRootPart: BasePart = LightRootInstance :: BasePart
	local PlacingCount: number = 0 :: number
	local OverlapMap: { [number]: boolean } = {} :: { [number]: boolean }
	local RegionCount: number = (#Regions) :: number

	for RegionIndex: number = 1, RegionCount do
		local Region: Instance = Regions[RegionIndex] :: Instance
		local Success: boolean, BoundsMinX: number, BoundsMinY: number, BoundsMinZ: number, BoundsMaxX: number, BoundsMaxY: number, BoundsMaxZ: number =
			self:FindAABB(Region)

		if Success then
			local RegionCFrame: CFrame
			local RegionSize: Vector3

			local IsBasePart: boolean = Region:IsA("BasePart") :: boolean
			if IsBasePart then
				local Part: BasePart = Region :: BasePart

				RegionCFrame = Part.CFrame :: CFrame
				RegionSize = Part.Size :: Vector3
			else
				local Model: Model = Region :: Model
				local ModelCFrame: CFrame, ModelSize: Vector3 = Model:GetBoundingBox()

				RegionCFrame = ModelCFrame :: CFrame
				RegionSize = ModelSize :: Vector3
			end

			local HalfSize: Vector3 = (RegionSize * 0.5) :: Vector3
			local StartX: number = AlignDown(BoundsMinX, GridSize) :: number
			local StartY: number = AlignDown(BoundsMinY, GridSize) :: number
			local StartZ: number = AlignDown(BoundsMinZ, GridSize) :: number

			for X: number = StartX, BoundsMaxX, GridSize do
				for Y: number = StartY, BoundsMaxY, GridSize do
					for Z: number = StartZ, BoundsMaxZ, GridSize do
						local HashIndex: number = GetSpatialHash(X, Y, Z, GridSize) :: number
						local AlreadyPlaced: boolean = OverlapMap[HashIndex] :: boolean

						if AlreadyPlaced then
							continue
						end

						local Point: Vector3 = Vec3(X, Y, Z) :: vector
						local Inside: boolean = PointInsidePart(Point, RegionCFrame, HalfSize) :: boolean

						if not Inside then
							continue
						end

						local IsBuried: boolean = TestBuried(Root, Point) :: boolean

						if IsBuried then
							continue
						end

						local IsTouching: boolean = TestTouch(Root, Point, ProbeRange) :: boolean

						if not IsTouching then
							continue
						end

						local Probe: Attachment = ProbeTemplate:Clone() :: Attachment
						Probe.WorldPosition = Point :: Vector3
						Probe.Parent = LightRootPart :: BasePart

						local LightInstance: Instance? = Probe:FindFirstChild("Light") :: Instance?

						if LightInstance ~= nil then
							local IsPointLight: boolean = LightInstance:IsA("PointLight") :: boolean
							if IsPointLight then
								local Light: PointLight = LightInstance :: PointLight
								Light.Range = ProbeRange :: number
							end
						end

						OverlapMap[HashIndex] = true :: boolean
						PlacingCount += 1 :: number
					end
				end
			end
		end
	end

	return PlacingCount
end

function Module:BeginBake(Settings: RuntimeSettings, Progress: FusionState<number>?)
	local ActorChildren: { Instance } = ActorsFolder:GetChildren() :: { Instance }
	local ChildCount: number = (#ActorChildren) :: number
	local ActorList: { WorkerActorRecord } = TableCreate(ChildCount) :: { WorkerActorRecord }
	local ThreadCount: number = 0 :: number

	for Index: number = 1, ChildCount do
		local ActorInstance: Instance = ActorChildren[Index] :: Instance
		local IsActor: boolean = ActorInstance:IsA("Actor") :: boolean

		if IsActor then
			local Actor: Actor = ActorInstance :: Actor
			local EventInstance: Instance? = Actor:FindFirstChild("Event") :: Instance?

			if EventInstance ~= nil then
				local IsBindableEvent: boolean = EventInstance:IsA("BindableEvent") :: boolean

				if IsBindableEvent then
					local Event: BindableEvent = EventInstance :: BindableEvent

					ThreadCount += 1 :: number
					ActorList[ThreadCount] = {
						Event = Event :: BindableEvent,
						Lights = TableCreate(8) :: { WorkerLightRecord },
					} :: WorkerActorRecord
				end
			end
		end
	end

	if ThreadCount == 0 then
		return
	end

	local TargetFolder: Folder = Settings.LightFolder :: Folder
	local LightRootInstance: Instance? = TargetFolder:FindFirstChild("LightRootPart") :: Instance?

	if LightRootInstance == nil or not LightRootInstance:IsA("BasePart") then
		return
	end

	local LightRootPart: BasePart = LightRootInstance :: BasePart
	local LightChildren: { Instance } = LightRootPart:GetChildren() :: { Instance }
	local LightCount: number = #LightChildren :: number
	local ThreadIndex: number = 1 :: number

	for Index: number = 1, LightCount do
		local Child: Instance = LightChildren[Index] :: Instance
		local IsAttachment: boolean = Child:IsA("Attachment") :: boolean

		if IsAttachment then
			local ChildAttachment: Attachment = Child :: Attachment
			local Record: WorkerActorRecord = ActorList[ThreadIndex] :: WorkerActorRecord
			local LightsList: { WorkerLightRecord } = Record.Lights :: { WorkerLightRecord }
			local NextLightIndex: number = (#LightsList + 1) :: number

			local PointLightInstance: Instance? = ChildAttachment:FindFirstChild("Light") :: Instance?
			local Light: PointLight? = nil :: PointLight?

			if PointLightInstance ~= nil and PointLightInstance:IsA("PointLight") then
				Light = PointLightInstance :: PointLight
			end

			LightsList[NextLightIndex] = {
				Light = Light :: PointLight?,
				LightAttachment = ChildAttachment :: Attachment,
			} :: WorkerLightRecord

			ThreadIndex += 1 :: number

			if ThreadIndex > ThreadCount then
				ThreadIndex = 1 :: number
			end
		end
	end

	Invoke(ActorList, "Setup", Settings, Progress)

	if Progress ~= nil then
		Progress:set(0)
	end

	local MaxSamples: number = Settings.MaxSamples :: number

	for SampleIndex: number = 1, MaxSamples do
		if self.AbortRequested then
			break
		end

		Invoke(ActorList, "Step", Settings, nil)

		if Progress ~= nil then
			Progress:set(SampleIndex / MaxSamples)
		end
	end
end

function Module:UpdateShowProbes(TargetFolder: Folder, Visible: boolean)
	local RootInstance: Instance? = TargetFolder:FindFirstChild("VisibleProbesRootPart") :: Instance?

	if RootInstance == nil or not RootInstance:IsA("BasePart") then
		local ClonedRoot: BasePart = VisibleProbesRootTemplate:Clone() :: BasePart
		ClonedRoot.Parent = TargetFolder :: Folder
		ClonedRoot.Position = Vector3Zero :: Vector3
		RootInstance = ClonedRoot :: BasePart
	end

	local VisibleRoot: BasePart = RootInstance :: BasePart

	if not Visible then
		VisibleRoot:Destroy()
		return
	end

	VisibleRoot:ClearAllChildren()

	local LightRootInstance: Instance? = TargetFolder:FindFirstChild("LightRootPart") :: Instance?

	if LightRootInstance == nil or not LightRootInstance:IsA("BasePart") then
		local ClonedRoot: BasePart = LightRootTemplate:Clone() :: BasePart
		ClonedRoot.Parent = TargetFolder :: Folder
		ClonedRoot.Position = Vector3Zero :: Vector3
		LightRootInstance = ClonedRoot :: BasePart
	end

	local LightRootPart: BasePart = LightRootInstance :: BasePart
	local Children: { Instance } = LightRootPart:GetChildren() :: { Instance }
	local ChildCount: number = #Children :: number

	for Index: number = 1, ChildCount do
		local Child: Instance = Children[Index] :: Instance
		local IsAttachment: boolean = Child:IsA("Attachment") :: boolean

		if IsAttachment then
			local ChildAttachment: Attachment = Child :: Attachment
			local Ball: BasePart = ProbeBallTemplate:Clone() :: BasePart
			Ball.Position = ChildAttachment.WorldPosition :: Vector3
			Ball.Parent = VisibleRoot :: BasePart

			local LightInstance: Instance? = ChildAttachment:FindFirstChild("Light") :: Instance?

			if LightInstance ~= nil then
				local IsPointLight: boolean = LightInstance:IsA("PointLight") :: boolean

				if IsPointLight then
					local Light: PointLight = LightInstance :: PointLight
					Ball.Color = Light.Color :: Color3
				end
			end
		end
	end
end

local function BuildRuntimeSettings(SourceSettings: SettingsType): RuntimeSettings?
	local TargetLightFolder: Folder? = SourceSettings.LightFolder :: Folder?

	if TargetLightFolder == nil then
		return nil
	end

	local ValidLightFolder: Folder = TargetLightFolder :: Folder
	local CurrentMaxSamples: number = SourceSettings.NumSamples:get() :: number
	local CurrentGridSize: number = SourceSettings.GridSize:get() :: number
	local CurrentBrightness: number = (SourceSettings.Brightness:get() * 0.5) :: number
	local CurrentNeonBrightness: number = (SourceSettings.NeonBrightness:get() * 0.5) :: number
	local CurrentShowProbes: boolean = SourceSettings.ShowProbes:get() :: boolean
	local CurrentSunVec: Vector3 = Lighting:GetSunDirection() :: Vector3

	local WhiteListArray: { Instance } = { Workspace.Terrain :: Instance, Workspace :: Instance } :: { Instance }

	return {
		MaxSamples = CurrentMaxSamples :: number,
		GridSize = CurrentGridSize :: number,
		Brightness = CurrentBrightness :: number,
		NeonBrightness = CurrentNeonBrightness :: number,
		ShowProbes = CurrentShowProbes :: boolean,
		LightFolder = ValidLightFolder :: Folder,
		WhiteList = WhiteListArray :: { Instance },
		SunVec = CurrentSunVec :: Vector3,
	} :: RuntimeSettings
end

function Module:DoWork(SourceSettings: SettingsType)
	local GeneratedSettings: RuntimeSettings? = BuildRuntimeSettings(SourceSettings) :: RuntimeSettings?

	if GeneratedSettings == nil then
		self:Cleanup()

		return
	end

	local ValidRuntimeSettings: RuntimeSettings = GeneratedSettings :: RuntimeSettings
	SourceSettings.Progress:set(0)

	self.Running = true :: boolean
	self.AbortRequested = false :: boolean
	self.Event = ModuleEvent :: BindableEvent

	TaskSpawn(function()
		local StartTime: number = os.clock()

		self:BeginBake(ValidRuntimeSettings, SourceSettings.Progress)

		local EndTime: number = os.clock()
		local TotalTime: number = (EndTime - StartTime)

		print("[RumenCore] Total Time:", TotalTime, "seconds")

		SourceSettings.Progress:set(0)

		self:Cleanup()
	end)
end

function Module:Cleanup()
	self.AbortRequested = false :: boolean
	self.Running = false :: boolean
end

return Module :: ModuleType
