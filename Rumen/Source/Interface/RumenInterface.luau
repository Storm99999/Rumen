--!native
--!optimize 2

local Version: string = "V1.2"

type FusionState<T> = {
	get: (self: FusionState<T>) -> T,
	set: (self: FusionState<T>, Value: T) -> (),
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
	Run: (self: IlluminationModule, Settings: SettingsType) -> (),
	UpdateShowProbes: (self: IlluminationModule, Folder: Folder, Visible: boolean) -> (),
	PlaceProbes: (self: IlluminationModule, Folder: Folder, Settings: SettingsType, Regions: { Instance }) -> (),
}

local Plugin: Plugin = plugin
local WorkspaceService: Workspace = game:GetService("Workspace")
local ServerStorage: ServerStorage = game:GetService("ServerStorage")
local SelectionService: Selection = game:GetService("Selection")

local Components = script.Parent:WaitForChild("Components")
local Packages = script.Parent.Parent.Parent.Dependencies:WaitForChild("Modules")
local Fusion = require(Packages:WaitForChild("Fusion"))

local StudioComponents = Components:WaitForChild("StudioComponents")
local Slider: any = require(StudioComponents:WaitForChild("Slider"))
local Label: any = require(StudioComponents:WaitForChild("Label"))
local Background: any = require(StudioComponents:WaitForChild("Background"))
local Button: any = require(StudioComponents:WaitForChild("Button"))
local ProgressBar: any = require(StudioComponents:WaitForChild("ProgressBar"))
local Checkbox: any = require(StudioComponents:WaitForChild("Checkbox"))
local BoxBorder: any = require(StudioComponents:WaitForChild("BoxBorder"))

local RTGI: IlluminationModule = require(script.Parent.Parent.Controllers:WaitForChild("RumenCore")) :: any

local New = Fusion.New
local Children = Fusion.Children

local Toolbar = Plugin:CreateToolbar("Rumen T")
local ToolbarButton = Toolbar:CreateButton("Rumen T", "Open the widget", "rbxassetid://9924020683")
ToolbarButton.ClickableWhenViewportHidden = true

local Widget: DockWidgetPluginGui? = nil
local ExecuteButtonInstance: GuiButton? = nil
local ProgressBarInstance: GuiObject? = nil

local Settings: SettingsType = {
	NumSamples = Fusion.Value(128) :: any,
	GridSize = Fusion.Value(16) :: any,
	Progress = Fusion.Value(0) :: any,
	ShowBoxes = Fusion.Value(true) :: any,
	ExecuteState = Fusion.Value("Bake") :: any,
	ShowProbes = Fusion.Value(false) :: any,
	Brightness = Fusion.Value(1) :: any,
	NeonBrightness = Fusion.Value(1) :: any,
	Probes = Fusion.Value(0) :: any,
	Root = WorkspaceService,
	LightFolder = nil,
}

local function GetLightFolder(): Folder
	local Existing = WorkspaceService:FindFirstChild("RumenRTGI")

	if Existing ~= nil and Existing:IsA("Folder") then
		return Existing
	end

	local Folder = Instance.new("Folder")
	Folder.Name = "RumenRTGI"
	Folder.Parent = WorkspaceService

	return Folder
end

local function GetLightingRegionsFolder(): Folder
	local Existing = ServerStorage:FindFirstChild("LightingRegions")
	if Existing ~= nil and Existing:IsA("Folder") then
		return Existing
	end

	local WorkspaceExisting = WorkspaceService:FindFirstChild("LightingRegions")

	if WorkspaceExisting ~= nil and WorkspaceExisting:IsA("Folder") then
		return WorkspaceExisting
	end

	local Folder = Instance.new("Folder")
	Folder.Name = "LightingRegions"
	Folder.Parent = ServerStorage

	return Folder
end

local function UpdateShowProbes(Visible: boolean): ()
	local Folder = GetLightFolder()
	RTGI:UpdateShowProbes(Folder, Visible)
end

local function ClearProbes(): ()
	local LightFolder = GetLightFolder()

	for _, Descendant in LightFolder:GetDescendants() do
		if Descendant.Name == "Probe" then
			Descendant:Destroy()
		end
	end

	UpdateShowProbes(Settings.ShowProbes:get())
end

local function GetLightingRegions(): { Instance }
	local Folder = GetLightingRegionsFolder()
	local Regions: { Instance } = {}

	for _, Descendant in ipairs(Folder:GetDescendants()) do
		if Descendant:GetAttribute("LightingRegion") == true then
			table.insert(Regions, Descendant)
		end
	end

	return Regions
end

local function CreateProbes(): ()
	ClearProbes()

	local Regions = GetLightingRegions()

	RTGI:PlaceProbes(GetLightFolder(), Settings, Regions)
	UpdateShowProbes(Settings.ShowProbes:get())
end

local function ShowBoxes(): ()
	local Folder = GetLightingRegionsFolder()
	Folder.Parent = WorkspaceService
end

local function HideBoxes(): ()
	local Folder = GetLightingRegionsFolder()
	Folder.Parent = ServerStorage
end

local function CreateLightingRegion(): ()
	Settings.ShowBoxes:set(true)
	ShowBoxes()

	local Folder = GetLightingRegionsFolder()
	local Clone = script.Parent.Parent.Parent.Dependencies:WaitForChild("Assets"):WaitForChild("LightingRegion"):Clone()
	Clone.Parent = Folder
	SelectionService:Set({ Clone })
end

local function ExecuteBake(): ()
	Settings.LightFolder = GetLightFolder()
	RTGI:Run(Settings)
end

local function CreateGridSize(Parent: Instance, Top: number): number
	Label({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Fusion.Computed(function(): string
			return "GridSize: " .. tostring(Settings.GridSize:get()) .. " units"
		end),

		Parent = Parent,
	})

	Top += 22

	Slider({
		Step = 4,
		Min = 8,
		Max = 32,
		Value = Settings.GridSize,
		OnChange = function(NewValue: number)
			Settings.GridSize:set(NewValue)
		end,
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
	})
	Top += 22

	return Top
end

local function CreateNumSamples(Parent: Instance, Top: number): number
	Label({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Fusion.Computed(function(): string
			return "Samples: " .. tostring(Settings.NumSamples:get())
		end),
		Parent = Parent,
	})
	Top += 22

	Slider({
		Step = 16,
		Min = 16,
		Max = 2026,
		Value = Settings.NumSamples,
		OnChange = function(NewValue: number)
			Settings.NumSamples:set(NewValue)
		end,
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
	})
	Top += 22

	return Top
end

local function CreateBrightnessSlider(Parent: Instance, Top: number): number
	Label({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Fusion.Computed(function(): string
			return "Brightness: " .. tostring(Settings.Brightness:get())
		end),
		Parent = Parent,
	})
	Top += 22

	Slider({
		Step = 0.1,
		Min = 0,
		Max = 5,
		Value = Settings.Brightness,
		OnChange = function(NewValue: number)
			Settings.Brightness:set(NewValue)
		end,
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
	})
	Top += 22

	return Top
end

local function CreateNeonBrightnessSlider(Parent: Instance, Top: number): number
	Label({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Fusion.Computed(function(): string
			return "Neon Brightness: " .. tostring(Settings.NeonBrightness:get())
		end),
		Parent = Parent,
	})
	Top += 22

	Slider({
		Step = 0.25,
		Min = 0,
		Max = 3,
		Value = Settings.NeonBrightness,
		OnChange = function(NewValue: number)
			Settings.NeonBrightness:set(NewValue)
		end,
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
	})
	Top += 22

	return Top
end

local function CreateRunButton(Parent: Instance, Top: number): number
	ExecuteButtonInstance = Button({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = Fusion.Computed(function(): string
			return Settings.ExecuteState:get()
		end),
		Activated = ExecuteBake,
	})

	Top += 22
	return Top
end

local function CreateAddNewLightingRegionButton(Parent: Instance, Top: number): number
	Button({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = "Add New Lighting Region",
		Activated = CreateLightingRegion,
	})

	Top += 22
	return Top
end

local function CreateCreateProbesButton(Parent: Instance, Top: number): number
	Button({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = "Create Probes",
		Activated = CreateProbes,
	})

	Top += 22
	return Top
end

local function CreateClearProbesButton(Parent: Instance, Top: number): number
	Button({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = "Clear Probes",
		Activated = ClearProbes,
	})

	Top += 22
	return Top
end

local function CreateShowProbesButton(Parent: Instance, Top: number): number
	Checkbox({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = "Show Probes",
		Value = Settings.ShowProbes:get(),
		OnChange = function(NewValue: boolean)
			Settings.ShowProbes:set(NewValue)
			UpdateShowProbes(NewValue)
		end,
	})

	Top += 22
	return Top
end

local function CreateShowBoxes(Parent: Instance, Top: number): number
	Checkbox({
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Text = "Show Lighting Regions",
		Value = Settings.ShowBoxes:get(),
		OnChange = function(NewValue: boolean)
			Settings.ShowBoxes:set(NewValue)
			if NewValue then
				ShowBoxes()
			else
				HideBoxes()
			end
		end,
	})

	Top += 22
	return Top
end

local function CreateProgressBar(Parent: Instance, Top: number): number
	ProgressBarInstance = ProgressBar({
		Size = UDim2.new(1, -16, 0, 16),
		Position = UDim2.new(0, 8, 0, Top),
		Parent = Parent,
		Progress = Fusion.Computed(function(): number
			return Settings.Progress:get()
		end),
	})

	Top += 16
	return Top
end

local function CreateCredits(_: Instance, Top: number): number
	return Top
end

local function CreateFusionUi(WidgetInstance: DockWidgetPluginGui): ()
	local BackgroundFrame = Background({
		Parent = WidgetInstance,
		Position = UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
	})

	local BoxTop = 6
	local Top = BoxTop

	Top = CreateAddNewLightingRegionButton(BackgroundFrame, Top)
	Top += 2
	Top = CreateShowBoxes(BackgroundFrame, Top)
	Top += 2
	Top = CreateGridSize(BackgroundFrame, Top)
	Top += 2
	Top = CreateShowProbesButton(BackgroundFrame, Top)
	Top += 2
	Top = CreateCreateProbesButton(BackgroundFrame, Top)
	Top += 4
	Top = CreateClearProbesButton(BackgroundFrame, Top)
	Top += 2

	Background({
		Parent = BackgroundFrame,
		Position = UDim2.fromOffset(4, BoxTop - 2),
		Size = UDim2.new(1, -8, 0, Top - BoxTop + 4),
		BorderSizePixel = 1,
		ZIndex = 0,
	})

	Top += 10
	Top = CreateNumSamples(BackgroundFrame, Top)
	Top += 2
	Top = CreateBrightnessSlider(BackgroundFrame, Top)
	Top += 2
	Top = CreateNeonBrightnessSlider(BackgroundFrame, Top)
	Top += 2
	Top = CreateProgressBar(BackgroundFrame, Top)
	Top += 2
	Top = CreateRunButton(BackgroundFrame, Top)
	Top += 2
	Top = CreateCredits(BackgroundFrame, Top)
	Top += 2
end

local function SetEnabled(): ()
	UpdateShowProbes(Settings.ShowProbes:get())

	if Settings.ShowBoxes:get() == true then
		ShowBoxes()
	end
end

local function SetDisabled(): ()
	UpdateShowProbes(false)
	HideBoxes()
end

local function CreateWidget(): ()
	if Widget ~= nil then
		Widget.Enabled = not Widget.Enabled
		return
	end

	local WidgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, true, true, 200, 630, 200, 630)

	Widget = Plugin:CreateDockWidgetPluginGuiAsync("RumenEditorWidget" .. Version, WidgetInfo)
	Widget.Title = "Rumen Global Illumination"

	CreateFusionUi(Widget)

	Widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if Widget == nil then
			return
		end

		if Widget.Enabled == false then
			SetDisabled()
		else
			SetEnabled()
		end
	end)

	SetEnabled()
end

local function OnClicked(): ()
	CreateWidget()
end

ToolbarButton.Click:Connect(OnClicked)

return {}
