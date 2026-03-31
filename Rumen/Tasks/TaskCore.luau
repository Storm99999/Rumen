--!native
--!optimize 2

type LightRecordType = {
	LightAttachment: Attachment,
	Light: PointLight,
	NumSamples: number,
	Color: Vector3,
	RayIndex: number,
	Position: Vector3,
}

type WorkerActorRecord = {
	Lights: { LightRecordType },
}

type RuntimeSettings = {
	SunVec: Vector3,
	MaxSamples: number,
	NeonBrightness: number,
	Brightness: number,
	GridSize: number,
	WhiteList: { Instance },
}

type ModuleType = {
	Invoke: (Self: ModuleType, MethodName: string, RecordData: WorkerActorRecord, SettingsData: RuntimeSettings) -> (),
}

local Module: ModuleType = {} :: ModuleType

local Workspace: Workspace = game:GetService("Workspace") :: Workspace
local Lighting: Lighting = game:GetService("Lighting") :: Lighting
local Terrain: Terrain = Workspace.Terrain :: Terrain

local Floor: (number) -> number = math.floor :: (number) -> number
local Ceil: (number) -> number = math.ceil :: (number) -> number
local Clamp: (number, number, number) -> number = math.clamp :: (number, number, number) -> number
local Random: (number) -> number = math.random :: (number) -> number
local Sqrt: (number) -> number = math.sqrt :: (number) -> number
local Pi: number = math.pi :: number
local Cos: (number) -> number = math.cos :: (number) -> number
local Sin: (number) -> number = math.sin :: (number) -> number

local Vec3: (number, number, number) -> vector = vector.create :: (number, number, number) -> vector
local Vector3Zero: vector = vector.zero :: vector
local Vector3One: vector = vector.one :: vector

local FromHSV: (number, number, number) -> Color3 = Color3.fromHSV :: (number, number, number) -> Color3
local NewColor: (number, number, number) -> Color3 = Color3.new :: (number, number, number) -> Color3

local TaskSynchronize: () -> () = task.synchronize :: () -> ()
local TableCreate: (number, any?) -> { any } = table.create :: (number, any?) -> { any }

local SunVec: vector = Vector3Zero :: vector
local MaxSamples: number = 0 :: number
local NeonBrightness: number = 0 :: number
local Brightness: number = 0 :: number
local GridSize: number = 0 :: number
local RayCount: number = 0 :: number
local SunBrightness: number = 0 :: number

local MaterialColors: { [Enum.Material]: Vector3 } = {} :: { [Enum.Material]: Vector3 }
local RayDirs: { Vector3 } = {} :: { Vector3 }
local BroadPhaseGrid: { [number]: { LightRecordType } } = {} :: { [number]: { LightRecordType } }
local LightRecordsList: { LightRecordType } = {} :: { LightRecordType }
local RayCastParamsObj: RaycastParams = RaycastParams.new() :: RaycastParams

local SunLength: number = 1024 :: number
local SurfaceCastDistance: number = 1024 :: number

local function GetSpatialHash(GridX: number, GridY: number, GridZ: number): number
	local OffsetX: number = (GridX + 100000) :: number
	local OffsetY: number = (GridY + 100000) :: number
	local OffsetZ: number = (GridZ + 100000) :: number

	return (OffsetX * 10000000000) + (OffsetY * 100000) + OffsetZ :: number
end

local function GetPosition(TargetLight: PointLight): vector
	local ParentInst: Instance? = TargetLight.Parent :: Instance?

	if ParentInst ~= nil then
		local ValidParent: Instance = ParentInst :: Instance

		if ValidParent:IsA("Attachment") then
			return (ValidParent :: Attachment).WorldPosition :: vector
		end

		if ValidParent:IsA("BasePart") then
			return (ValidParent :: BasePart).Position :: vector
		end
	end

	return Vector3Zero :: vector
end

local function WriteLightToBroadphase(TargetLight: LightRecordType, Pos: Vector3, Radius: number)
	local Square: number = (Radius * 1.44) :: number
	local MinX: number = (Pos.X - Square) :: number
	local MinY: number = (Pos.Y - Square) :: number
	local MinZ: number = (Pos.Z - Square) :: number
	local MaxX: number = (Pos.X + Square) :: number
	local MaxY: number = (Pos.Y + Square) :: number
	local MaxZ: number = (Pos.Z + Square) :: number

	local StartX: number = Floor(MinX / GridSize) :: number
	local StartY: number = Floor(MinY / GridSize) :: number
	local StartZ: number = Floor(MinZ / GridSize) :: number

	local EndX: number = (Ceil(MaxX / GridSize) - 1) :: number
	local EndY: number = (Ceil(MaxY / GridSize) - 1) :: number
	local EndZ: number = (Ceil(MaxZ / GridSize) - 1) :: number

	for X: number = StartX, EndX do
		for Y: number = StartY, EndY do
			for Z: number = StartZ, EndZ do
				local HashKey: number = GetSpatialHash(X, Y, Z) :: number
				local CellList: { LightRecordType }? = BroadPhaseGrid[HashKey] :: { LightRecordType }?

				if CellList == nil then
					CellList = {} :: { LightRecordType }
					BroadPhaseGrid[HashKey] = CellList :: { LightRecordType }
				end

				local NextIndex: number = (#CellList + 1) :: number
				CellList[NextIndex] = TargetLight :: LightRecordType
			end
		end
	end
end

local function GeneratePoints(SamplesCount: number): { Vector3 }
	local PointsList: { Vector3 } = TableCreate(SamplesCount) :: { Vector3 }
	local Sqrt5: number = Sqrt(5) :: number
	local Phi: number = (Pi * (3 - Sqrt5)) :: number

	local Denom: number = 1 :: number
	if SamplesCount > 1 then
		Denom = (SamplesCount - 1) :: number
	end

	for Index: number = 1, SamplesCount do
		local TVal: number = ((Index - 1) / Denom) :: number
		local YVal: number = (1 - (TVal * 2)) :: number
		local RadiusVal: number = Sqrt(1 - (YVal * YVal)) :: number
		local ThetaVal: number = (Phi * (Index - 1)) :: number

		local CosTheta: number = Cos(ThetaVal) :: number
		local SinTheta: number = Sin(ThetaVal) :: number

		PointsList[Index] = Vec3(CosTheta * RadiusVal, YVal, SinTheta * RadiusVal) :: Vector3
	end

	return PointsList :: { Vector3 }
end

local function TerrainDesat(SourceColor: Color3): Color3
	local Hue: number, Saturation: number, Value: number = SourceColor:ToHSV()
	return FromHSV(Hue, Saturation * 0.33, Value) :: Color3
end

local function RefreshRecordPositions()
	local Count: number = #LightRecordsList :: number

	for Index: number = 1, Count do
		local Record: LightRecordType = LightRecordsList[Index] :: LightRecordType
		Record.Position = GetPosition(Record.Light) :: vector
	end
end

local function Setup(Settings: RuntimeSettings, RecordData: WorkerActorRecord)
	SunVec = Settings.SunVec :: vector
	MaxSamples = Settings.MaxSamples :: number
	NeonBrightness = Settings.NeonBrightness :: number
	Brightness = Settings.Brightness :: number
	GridSize = Settings.GridSize :: number
	SunBrightness = Lighting.Brightness :: number

	RayDirs = GeneratePoints(MaxSamples) :: { Vector3 }
	RayCount = #RayDirs :: number

	TaskSynchronize()

	local TerrainMaterials: { Enum.Material } = {
		Enum.Material.Asphalt,
		Enum.Material.Basalt,
		Enum.Material.Brick,
		Enum.Material.Cobblestone,
		Enum.Material.Concrete,
		Enum.Material.CrackedLava,
		Enum.Material.Glacier,
		Enum.Material.Grass,
		Enum.Material.Ground,
		Enum.Material.Ice,
		Enum.Material.LeafyGrass,
		Enum.Material.Limestone,
		Enum.Material.Mud,
		Enum.Material.Pavement,
		Enum.Material.Rock,
		Enum.Material.Salt,
		Enum.Material.Sand,
		Enum.Material.Sandstone,
		Enum.Material.Slate,
		Enum.Material.Snow,
		Enum.Material.WoodPlanks,
	}

	local MatCount: number = #TerrainMaterials :: number

	for Index: number = 1, MatCount do
		local Mat: Enum.Material = TerrainMaterials[Index] :: Enum.Material
		local Col: Color3? = Terrain:GetMaterialColor(Mat) :: Color3?

		if Col ~= nil then
			local DesatCol: Color3 = TerrainDesat(Col :: Color3) :: Color3
			MaterialColors[Mat] = Vec3(DesatCol.R, DesatCol.G, DesatCol.B) :: Vector3
		end
	end

	local WaterCol: Color3 = Terrain.WaterColor :: Color3
	local DesatWaterCol: Color3 = TerrainDesat(WaterCol) :: Color3
	MaterialColors[Enum.Material.Water] = Vec3(DesatWaterCol.R, DesatWaterCol.G, DesatWaterCol.B) :: Vector3

	RayCastParamsObj = RaycastParams.new() :: RaycastParams
	RayCastParamsObj.FilterType = Enum.RaycastFilterType.Include :: Enum.RaycastFilterType
	RayCastParamsObj.FilterDescendantsInstances = Settings.WhiteList :: { Instance }

	BroadPhaseGrid = {} :: { [number]: { LightRecordType } }

	local Descendants: { Instance } = Workspace:GetDescendants() :: { Instance }
	local DescCount: number = #Descendants :: number

	for Index: number = 1, DescCount do
		local Value: Instance = Descendants[Index] :: Instance

		if Value:IsA("PointLight") then
			local Plight: PointLight = Value :: PointLight

			if Plight.Enabled and Plight.Parent ~= nil then
				local LightPos: Vector3 = GetPosition(Plight) :: vector
				local LightRange: number = Plight.Range :: number
				local LightRecord: LightRecordType = {
					LightAttachment = (Plight.Parent :: any) :: Attachment,
					Light = Plight :: PointLight,
					NumSamples = 0,
					Color = Vector3Zero :: Vector3,
					RayIndex = 1,
					Position = LightPos :: Vector3,
				} :: LightRecordType

				WriteLightToBroadphase(LightRecord, LightPos, LightRange)
			end
		end
	end

	LightRecordsList = RecordData.Lights :: { LightRecordType }

	local RecordCount: number = #LightRecordsList :: number
	for Index: number = 1, RecordCount do
		local RecordEntry: LightRecordType = LightRecordsList[Index] :: LightRecordType
		RecordEntry.NumSamples = 0 :: number
		RecordEntry.Color = Vector3Zero :: Vector3
		RecordEntry.RayIndex = 1 :: number
		RecordEntry.Position = GetPosition(RecordEntry.Light) :: vector
		RecordEntry.Light.Brightness = 0 :: number
	end
end

local function LDotN(LDir: Vector3, NDir: Vector3): number
	return Clamp((-LDir):Dot(NDir), 0, 1) :: number
end

local function PointFalloff(Dist: number, Total: number): number
	if Total <= 0 then
		return 0 :: number
	end

	return (1 - Clamp(Dist / Total, 0, 1)) :: number
end

local function RaycastThroughTransparency(
	StartPos: Vector3,
	Direction: Vector3,
	VecLength: number,
	Params: RaycastParams
): (boolean, RaycastResult?, Vector3)
	local TransparencyAccumulator: Vector3 = Vector3One :: Vector3
	local CurrentPos: Vector3 = StartPos :: Vector3
	local RemainingLength: number = VecLength :: number

	while RemainingLength > 0 do
		local Res: RaycastResult? = Workspace:Raycast(CurrentPos, Direction * RemainingLength, Params) :: RaycastResult?

		if Res == nil then
			return false, nil, TransparencyAccumulator
		end

		local ValidRes: RaycastResult = Res :: RaycastResult
		local HitInst: Instance = ValidRes.Instance :: Instance

		if HitInst == Terrain then
			return true, ValidRes, TransparencyAccumulator
		end

		if HitInst:IsA("BasePart") then
			local HitPart: BasePart = HitInst :: BasePart
			local PartTransparency: number = HitPart.Transparency :: number

			if PartTransparency > 0 then
				local CoveredDist: number = (ValidRes.Distance + 0.05) :: number
				CurrentPos += (Direction * CoveredDist) :: Vector3
				RemainingLength -= CoveredDist :: number

				if PartTransparency < 1 then
					local PartColor: Color3 = HitPart.Color :: Color3
					local ColorVec: Vector3 = Vec3(PartColor.R, PartColor.G, PartColor.B) :: Vector3
					local LerpedColor: Vector3 = ColorVec:Lerp(Vector3One, PartTransparency) :: Vector3
					TransparencyAccumulator *= LerpedColor :: Vector3
				end
			else
				return true, ValidRes, TransparencyAccumulator
			end
		else
			return true, ValidRes, TransparencyAccumulator
		end
	end

	return false, nil, TransparencyAccumulator
end

local function CheckDirectLightingForPoint(TargetPos: Vector3, Normal: Vector3, IgnoreLight: PointLight?): Vector3
	local Accumulator: Vector3 = Vector3Zero :: Vector3

	local HasHitSun: boolean, _, SunTrans: Vector3 =
		RaycastThroughTransparency(TargetPos, SunVec, SunLength, RayCastParamsObj)

	if not HasHitSun then
		local SunDot: number = LDotN(-SunVec, Normal) :: number
		local SunStrength: number = (SunDot * SunBrightness) :: number
		local SunColor: Vector3 = Vec3(SunStrength, SunStrength, SunStrength) :: Vector3
		Accumulator += (SunColor * SunTrans) :: Vector3
	end

	local GridX: number = Floor(TargetPos.X / GridSize) :: number
	local GridY: number = Floor(TargetPos.Y / GridSize) :: number
	local GridZ: number = Floor(TargetPos.Z / GridSize) :: number
	local PosHash: number = GetSpatialHash(GridX, GridY, GridZ) :: number

	local CellLights: { LightRecordType }? = BroadPhaseGrid[PosHash] :: { LightRecordType }?
	if CellLights ~= nil then
		local LightsList: { LightRecordType } = CellLights :: { LightRecordType }
		local LightCount: number = #LightsList :: number

		for Index: number = 1, LightCount do
			local CurrentLight: LightRecordType = LightsList[Index] :: LightRecordType
			if CurrentLight.Light ~= IgnoreLight then
				local LightPos: Vector3 = CurrentLight.Position :: Vector3
				local DiffVec: Vector3 = (LightPos - TargetPos) :: Vector3
				local VecMag: number = DiffVec.Magnitude :: number
				local LightRange: number = CurrentLight.Light.Range :: number

				if VecMag <= LightRange then
					local DirUnit: Vector3 = DiffVec.Unit :: Vector3
					local HasHitLight: boolean, _, LightTrans: Vector3 =
						RaycastThroughTransparency(TargetPos, DirUnit, VecMag, RayCastParamsObj)

					if not HasHitLight then
						local FalloffScale: number = PointFalloff(VecMag, LightRange) :: number
						local LightDot: number = LDotN(-DirUnit, Normal) :: number
						local CombinedScale: number = (FalloffScale * LightDot) :: number

						local LColor: Color3 = CurrentLight.Light.Color :: Color3
						local LColorVec: Vector3 = Vec3(LColor.R, LColor.G, LColor.B) :: Vector3
						local LBrightness: number = CurrentLight.Light.Brightness :: number
						local AddedColor: Vector3 = (LColorVec * (LBrightness * CombinedScale)) :: Vector3

						Accumulator += (AddedColor * LightTrans) :: Vector3
					end
				end
			end
		end
	end

	return Accumulator :: Vector3
end

local function GetNextRay(Record: LightRecordType): (boolean, Vector3, Vector3, Vector3, boolean)
	if RayCount <= 0 then
		return false, Vector3Zero, Vector3Zero, Vector3Zero, false
	end

	local RayPos: Vector3 = Record.Position :: Vector3
	local RayIndex: number = Record.RayIndex :: number
	local RayDir: Vector3 = RayDirs[RayIndex] :: Vector3

	local NextIndex: number = (RayIndex + 1) :: number
	if NextIndex > RayCount then
		NextIndex = 1 :: number
	end

	Record.RayIndex = NextIndex :: number

	local VecLength: number = SurfaceCastDistance :: number

	while VecLength > 0 do
		local Res: RaycastResult? = Workspace:Raycast(RayPos, RayDir * VecLength, RayCastParamsObj) :: RaycastResult?

		if Res == nil then
			return false, Vector3Zero, Vector3Zero, Vector3Zero, false
		end

		local ValidRes: RaycastResult = Res :: RaycastResult
		local HitInst: Instance = ValidRes.Instance :: Instance

		if HitInst == Terrain then
			local HitMaterial: Enum.Material = ValidRes.Material :: Enum.Material
			local HitColor: Vector3 = MaterialColors[HitMaterial] :: Vector3?
			if HitColor == nil then
				HitColor = Vector3One :: Vector3
			end

			return true, ValidRes.Position, ValidRes.Normal, HitColor, (HitMaterial == Enum.Material.Neon)
		end

		if HitInst:IsA("BasePart") then
			local HitPart: BasePart = HitInst :: BasePart
			local PartTransparency: number = HitPart.Transparency :: number

			if PartTransparency > 0 then
				local CoveredDist: number = (ValidRes.Distance + 0.05) :: number
				RayPos += (RayDir * CoveredDist) :: Vector3
				VecLength -= CoveredDist :: number
				continue
			end

			local HitColor: Vector3 = Vec3(HitPart.Color.R, HitPart.Color.G, HitPart.Color.B) :: Vector3
			local IsNeon: boolean = (HitPart.Material == Enum.Material.Neon) :: boolean

			return true, ValidRes.Position, ValidRes.Normal, HitColor, IsNeon
		end

		return false, Vector3Zero, Vector3Zero, Vector3Zero, false
	end

	return false, Vector3Zero, Vector3Zero, Vector3Zero, false
end

local function GetLightAtRay(
	HitPos: Vector3,
	HitNormal: Vector3,
	HitColor: Vector3,
	IsNeon: boolean,
	IgnoreLight: PointLight?
): Vector3
	local Contribution: Vector3 = Vector3Zero :: Vector3

	if IsNeon then
		Contribution += (HitColor * NeonBrightness) :: Vector3
	end

	local DirectLighting: Vector3 = CheckDirectLightingForPoint(HitPos, HitNormal, IgnoreLight) :: Vector3
	Contribution += (DirectLighting * HitColor) :: Vector3

	return Contribution :: Vector3
end

local function Gather()
	local Count: number = #LightRecordsList :: number

	for Index: number = 1, Count do
		local Record: LightRecordType = LightRecordsList[Index] :: LightRecordType
		local HasHit: boolean, HitPos: Vector3, HitNormal: Vector3, HitColor: Vector3, IsNeon: boolean =
			GetNextRay(Record)

		if HasHit then
			local NewContribution: Vector3 = GetLightAtRay(HitPos, HitNormal, HitColor, IsNeon, Record.Light) :: Vector3

			if NewContribution.X >= 0.01 or NewContribution.Y >= 0.01 or NewContribution.Z >= 0.01 then
				local CurrentSamples: number = Record.NumSamples :: number
				Record.NumSamples = (CurrentSamples + 1) :: number

				local PrevColor: Vector3 = Record.Color :: Vector3
				Record.Color = PrevColor + ((NewContribution - PrevColor) / Record.NumSamples) :: Vector3
			end
		end
	end
end

local function UpdateLight()
	TaskSynchronize()

	local Count: number = #LightRecordsList :: number

	for Index: number = 1, Count do
		local Record: LightRecordType = LightRecordsList[Index] :: LightRecordType
		local ColorVec: Vector3 = Record.Color :: Vector3
		local Mag: number = ColorVec.Magnitude :: number

		if Mag < 0.01 then
			Record.Light.Brightness = 0 :: number
		else
			local RgbVec: Vector3 = (ColorVec / Mag) :: Vector3
			Record.Light.Color = NewColor(RgbVec.X, RgbVec.Y, RgbVec.Z) :: Color3
			Record.Light.Brightness = (Mag * Brightness) :: number
		end
	end
end

local function Step()
	RefreshRecordPositions()
	Gather()
	UpdateLight()
end

function Module:Invoke(MethodName: string, RecordData: WorkerActorRecord, SettingsData: RuntimeSettings)
	if MethodName == "Setup" then
		Setup(SettingsData, RecordData)
	elseif MethodName == "Step" then
		Step()
	elseif MethodName == "Gather" then
		Gather()
	elseif MethodName == "UpdateLight" then
		UpdateLight()
	end
end

return Module :: ModuleType
