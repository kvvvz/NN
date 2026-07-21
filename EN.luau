local player = game.Players.LocalPlayer
local uis = game:GetService("UserInputService")
local rs = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local ConfigurationFolder = ReplicatedStorage:WaitForChild("Configuration")
local ConfigModule = ConfigurationFolder:WaitForChild("FPVConfig")

local FPVConfig = require(ConfigModule)
type FPV = typeof(FPVConfig)
---------------------------------------------------------------------
-- SERVICES & REFERENCES
---------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("DroneRemotes")
local DroneCrashEvent = Remotes:WaitForChild("DroneCrash")
local KVN_Color = Lighting:WaitForChild("KVN_Color")
local Drone_Color = Lighting:WaitForChild("Drone_Color")

local tool = script.Parent
local cam = workspace.CurrentCamera
local playerGui = player:WaitForChild("PlayerGui")
local dronesFolder = workspace:WaitForChild("Drones")

---------------------------------------------------------------------
-- STATE VARIABLES
---------------------------------------------------------------------
local active, armed, isCrashed = false, false, false
local staticGui = nil 
local images = {}
local smoothYaw, smoothPitch, smoothRoll = 0, 0, 0
local flightTime = 0
local currentGlitchT = FPVConfig.FAR_TRANS
local originalFOV = 70 

local bFrame1, bFrame2, bText1, bText2
local lowBatteryText, armedText, timeLabel, usernameLabel
local crosshairDotImg, crosshairDotTxt
local blackout
local origB1Height, origB2Height, origB1Pos, origB2Pos
local batteryImageContainers = {}

local MAX_VOLTAGE_1 = 16.80
local CRITICAL_VOLTAGE_1 = 14.00 
local batteryCapacity1 = 1.0       
local displayVoltage1 = MAX_VOLTAGE_1

local MAX_VOLTAGE_2 = 8.40
local batteryCapacity2 = 1.0
local displayVoltage2 = MAX_VOLTAGE_2

local batteryUpdateTimer = 0
local updateInterval = 1.0 

local lowBatteryBlinkTimer = 0
local armedBlinkTimer = 0
local distortCycleTimer = 0

---------------------------------------------------------------------
-- HELPER FUNCTIONS
---------------------------------------------------------------------
local function setBatteryElementsVisible(visible)
	if not bFrame1 then return end
	bFrame1.Visible = visible
	bFrame2.Visible = visible
	bText1.Visible = visible
	bText2.Visible = visible

	for _, container in ipairs(batteryImageContainers) do
		container.Visible = visible
	end
end

local function refreshGuiReferences()
	staticGui = playerGui:WaitForChild("Static")

	batteryImageContainers = {}
	for _, child in ipairs(staticGui:GetChildren()) do
		if child.Name == "Battery image" then
			table.insert(batteryImageContainers, child)
		end
	end

	if batteryImageContainers[1] then
		bFrame1 = batteryImageContainers[1]:WaitForChild("BatteryFrame")
	else
		warn("First 'Battery image' instance not found!")
	end

	if batteryImageContainers[2] then
		bFrame2 = batteryImageContainers[2]:WaitForChild("BatteryFrame2")
	else
		warn("Second 'Battery image' instance not found!")
	end

	bText1 = staticGui:WaitForChild("Batterytext")
	bText2 = staticGui:WaitForChild("Batterytext2")
	lowBatteryText = staticGui:WaitForChild("LOW BATTERY")
	armedText = staticGui:WaitForChild("ARMED")
	timeLabel = staticGui:WaitForChild("TIME")
	usernameLabel = staticGui:WaitForChild("USERNAME")

	crosshairDotImg = nil
	crosshairDotTxt = nil

	for _, child in ipairs(staticGui:GetChildren()) do
		if child.Name == "Dot" then
			if child:IsA("ImageLabel") then
				crosshairDotImg = child
			elseif child:IsA("TextLabel") then
				crosshairDotTxt = child
			end
		end
	end

	if bFrame1 and bFrame2 then
		origB1Height = bFrame1.Size.Y.Offset
		origB2Height = bFrame2.Size.Y.Offset
		origB1Pos = bFrame1.Position
		origB2Pos = bFrame2.Position
	end

	if crosshairDotImg and crosshairDotTxt then
		crosshairDotImg.Visible = true
		crosshairDotTxt.Visible = false
	end

	blackout = staticGui:FindFirstChild("Blackout") or Instance.new("Frame", staticGui)
	if blackout.Name ~= "Blackout" then
		blackout.Name = "Blackout"; blackout.Size = UDim2.new(1, 0, 1, 0)
		blackout.BackgroundColor3 = Color3.new(0, 0, 0); blackout.BackgroundTransparency = 1
		blackout.ZIndex = 10000
	end

	images = {}
	for _, v in ipairs(staticGui:GetChildren()) do
		if v:IsA("ImageLabel") and string.find(v.Name:lower(), "static") then 
			table.insert(images, v) 
		end
	end
end

local function fade(target)
	if not blackout then return end
	local tween = TweenService:Create(blackout, TweenInfo.new(FPVConfig.FADE_SPEED, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {BackgroundTransparency = target})
	tween:Play()
	return tween
end

local function resetDroneColor()
	if Drone_Color then
		Drone_Color.Brightness = 0
		Drone_Color.Contrast = 0
	end
end

function cleanup()
	if blackout then fade(0).Completed:Wait() end
	active = false; armed = false; flightTime = 0; distortCycleTimer = 0
	if staticGui then staticGui.Enabled = false end
	cam.CameraType = Enum.CameraType.Custom
	cam.FieldOfView = originalFOV; uis.MouseBehavior = Enum.MouseBehavior.Default
	uis.MouseIconEnabled = true; Remotes.ToggleProps:FireServer(false)

	resetDroneColor()
	setBatteryElementsVisible(false)
	KVN_Color.Enabled = false
	task.wait(0.1); fade(1)
end

---------------------------------------------------------------------
-- EVENTS & LOOPS
---------------------------------------------------------------------
DroneCrashEvent.OnClientEvent:Connect(function()
	isCrashed = true; 
	resetDroneColor()
	if blackout then blackout.BackgroundTransparency = 0 end
	task.wait(0.1); active = false; 
	if staticGui then staticGui.Enabled = false end
	cam.CameraType = Enum.CameraType.Custom; cam.FieldOfView = originalFOV
	uis.MouseBehavior = Enum.MouseBehavior.Default; uis.MouseIconEnabled = true
	setBatteryElementsVisible(false) 
	KVN_Color.Enabled = false
	task.wait(0.5); fade(1)
end)

rs.RenderStepped:Connect(function(dt)
	if not active or isCrashed or not staticGui then return end
	local myDrone = dronesFolder:FindFirstChild(player.Name .. "_FPV")
	if not myDrone or not myDrone:FindFirstChild("Drone") then return end

	local droneRoot = myDrone.Drone
	cam.CFrame = (myDrone:FindFirstChild("Camera") or droneRoot).CFrame
	cam.FieldOfView = FPVConfig.LOCKED_FOV * FPVConfig.CAMERA_STRETCH_X 
	uis.MouseBehavior = Enum.MouseBehavior.LockCenter
	uis.MouseIconEnabled = false 

	flightTime = flightTime + dt

	-- Color_Drone Distortion Logic
	distortCycleTimer = distortCycleTimer + dt
	if distortCycleTimer >= FPVConfig.DISTORT_INTERVAL then
		distortCycleTimer = distortCycleTimer - FPVConfig.DISTORT_INTERVAL
	end

	local targetBrightness = 0
	local targetContrast = 0

	if distortCycleTimer < FPVConfig.DISTORT_PEAK_DURATION then
		local alpha = distortCycleTimer / FPVConfig.DISTORT_PEAK_DURATION
		targetBrightness = 0.2 * alpha
		targetContrast = 0.8 * alpha
	elseif distortCycleTimer < (FPVConfig.DISTORT_PEAK_DURATION + FPVConfig.DISTORT_FADE_DURATION) then
		local alpha = (distortCycleTimer - FPVConfig.DISTORT_PEAK_DURATION) / FPVConfig.DISTORT_FADE_DURATION
		targetBrightness = 0.2 * (1 - alpha)
		targetContrast = 0.8 * (1 - alpha)
	else
		targetBrightness = 0
		targetContrast = 0
	end

	if Drone_Color then
		Drone_Color.Brightness = targetBrightness
		Drone_Color.Contrast = targetContrast
	end

	local rayP = RaycastParams.new()
	rayP.FilterDescendantsInstances = {myDrone, player.Character}
	local hit = workspace:Raycast(droneRoot.Position, Vector3.new(0, -FPVConfig.RAY_DIST, 0), rayP)
	local targetT = hit and (FPVConfig.NEAR_TRANS + ((hit.Distance / FPVConfig.RAY_DIST) * (FPVConfig.FAR_TRANS - FPVConfig.NEAR_TRANS))) or FPVConfig.FAR_TRANS

	local isGlitching = (flightTime % FPVConfig.GLITCH_INTERVAL < FPVConfig.GLITCH_DURATION)
	local desiredT = isGlitching and FPVConfig.GLITCH_TRANS or targetT
	currentGlitchT = currentGlitchT + (desiredT - currentGlitchT) * FPVConfig.GLITCH_SMOOTHNESS

	-- Volnorez Proximity Calculation & Explosion System
	local closestJammerDist = math.huge
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj.Name == "volnorez" and obj:IsA("BasePart") then
			local distance = (droneRoot.Position - obj.Position).Magnitude
			if distance < closestJammerDist then
				closestJammerDist = distance
			end
		end
	end

	-- Trigger instant destruction if drone is closer than threshold
	if closestJammerDist <= FPVConfig.JAMMER_EXPLODE_DISTANCE then
		local DroneSelfDestruct = Remotes:FindFirstChild("DroneSelfDestruct")
		if DroneSelfDestruct then
			DroneSelfDestruct:FireServer()
			return
		end
	end

	-- Calculate Jammer Static Influence based on 10-stud structural increments
	local jammerStaticInfluence = 0
	if closestJammerDist <= FPVConfig.JAMMER_MAX_DISTANCE then
		local steppedDist = math.floor(closestJammerDist / 10) * 10
		local alpha = math.clamp((FPVConfig.JAMMER_MAX_DISTANCE - steppedDist) / (FPVConfig.JAMMER_MAX_DISTANCE - FPVConfig.JAMMER_EXPLODE_DISTANCE), 0, 1)
		jammerStaticInfluence = alpha * currentGlitchT
	end

	local finalStaticTransparency = math.clamp(currentGlitchT - jammerStaticInfluence, 0, 1)

	for _, img in ipairs(images) do 
		img.ImageTransparency = math.clamp(finalStaticTransparency + (math.random() * 0.04 - 0.02), 0, 1)
	end

	usernameLabel.Text = player.Name
	local minutes = math.floor(flightTime / 60)
	local seconds = math.floor(flightTime % 60)
	timeLabel.Text = string.format("%02d:%02d", minutes, seconds)

	local isLowBattery = (displayVoltage1 <= CRITICAL_VOLTAGE_1 and flightTime >= 1)

	if flightTime >= 1 then
		if bFrame1 and not bFrame1.Visible and not isLowBattery then
			setBatteryElementsVisible(true)
			bText1.Text = string.format("%.2fV", displayVoltage1)
			bText2.Text = string.format("%.2fV", displayVoltage2)
		end
	else
		setBatteryElementsVisible(false)
	end

	local thrustKeyCode = FPVConfig.ENABLE_NEW_KEYBINDS and Enum.KeyCode.LeftShift or Enum.KeyCode.LeftControl
	local keyboardThrust = uis:IsKeyDown(thrustKeyCode) and 1 or 0

	local gamepadThrust = 0
	local gamepadYaw = 0
	local gamepadPitch = 0
	local gamepadRoll = 0

	local connectedGamepads = uis:GetConnectedGamepads()
	if #connectedGamepads > 0 then
		local gamepadState = uis:GetGamepadState(connectedGamepads[1])
		for _, input in ipairs(gamepadState) do
			if input.KeyCode == Enum.KeyCode.Thumbstick1 then
				gamepadThrust = math.clamp(input.Position.Y, 0, 1)
				gamepadYaw = -input.Position.X * FPVConfig.ROT_SPEED
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
				gamepadPitch = input.Position.Y * FPVConfig.CONTROLLER_SENS
				gamepadRoll = -input.Position.X * FPVConfig.CONTROLLER_SENS
			end
		end
	end

	local finalThrustInput = math.max(keyboardThrust, gamepadThrust)
	local targetSag1 = 0

	if armed and finalThrustInput > 0 then
		batteryCapacity1 = math.max(0, batteryCapacity1 - (dt * 0.012 * finalThrustInput))
		targetSag1 = 1.65 
	else
		batteryCapacity1 = math.max(0, batteryCapacity1 - (dt * 0.002))
	end

	batteryCapacity2 = math.max(0, batteryCapacity2 - (dt * 0.0015))
	local baseVoltage1 = batteryCapacity1 * MAX_VOLTAGE_1
	local targetVoltage1 = math.max(0, baseVoltage1 - targetSag1)
	displayVoltage1 = displayVoltage1 + (targetVoltage1 - displayVoltage1) * 0.15
	local targetVoltage2 = batteryCapacity2 * MAX_VOLTAGE_2
	displayVoltage2 = displayVoltage2 + (targetVoltage2 - displayVoltage2) * 0.15

	if flightTime >= 1 and bFrame1 and bFrame2 then
		batteryUpdateTimer = batteryUpdateTimer + dt
		if batteryUpdateTimer >= updateInterval then
			batteryUpdateTimer = 0
			bText1.Text = string.format("%.2fV", displayVoltage1)
			bText2.Text = string.format("%.2fV", displayVoltage2)
			local fillRatio1 = math.clamp(displayVoltage1 / MAX_VOLTAGE_1, 0, 1)
			local fillRatio2 = math.clamp(displayVoltage2 / MAX_VOLTAGE_2, 0, 1)
			local newHeight1 = fillRatio1 * origB1Height
			local newHeight2 = fillRatio2 * origB2Height
			bFrame1.Size = UDim2.new(bFrame1.Size.X.Scale, bFrame1.Size.X.Offset, bFrame1.Size.Y.Scale, newHeight1)
			bFrame2.Size = UDim2.new(bFrame2.Size.X.Scale, bFrame2.Size.X.Offset, bFrame2.Size.Y.Scale, newHeight2)
			bFrame1.Position = UDim2.new(origB1Pos.X.Scale, origB1Pos.X.Offset, origB1Pos.Y.Scale, origB1Pos.Y.Offset + (origB1Height - newHeight1))
			bFrame2.Position = UDim2.new(origB2Pos.X.Scale, origB2Pos.X.Offset, origB2Pos.Y.Scale, origB2Pos.Y.Offset + (origB2Height - newHeight2))
		end
	end

	if isLowBattery then
		lowBatteryBlinkTimer = lowBatteryBlinkTimer + dt
		if lowBatteryBlinkTimer >= 1.5 then lowBatteryBlinkTimer = 0 end

		local showElements = (lowBatteryBlinkTimer < 0.75)
		lowBatteryText.Visible = showElements

		if FPVConfig.BLINK_ENTIRE_BATTERY_ON_LOW then
			setBatteryElementsVisible(showElements)
		end
	else
		lowBatteryText.Visible = false
	end

	if armed then
		armedBlinkTimer = armedBlinkTimer + dt
		if armedBlinkTimer >= 1.5 then armedBlinkTimer = 0 end
		armedText.Text = ">ARMED<"
		armedText.Visible = (armedBlinkTimer < 0.75)

		local delta = uis:GetMouseDelta()
		local keyboardYaw = uis:IsKeyDown(Enum.KeyCode.D) and -FPVConfig.ROT_SPEED or (uis:IsKeyDown(Enum.KeyCode.A) and FPVConfig.ROT_SPEED or 0)
		local totalYaw = keyboardYaw ~= 0 and keyboardYaw or (gamepadYaw ~= 0 and gamepadYaw or 0)
		local totalPitch = gamepadPitch ~= 0 and gamepadPitch or (-delta.Y * FPVConfig.MOUSE_SENS)
		local totalRoll = gamepadRoll ~= 0 and gamepadRoll or (-delta.X * FPVConfig.MOUSE_SENS)

		local weight = math.clamp(dt * 60, 0.1, 10)
		smoothYaw = smoothYaw + (totalYaw - smoothYaw) * (FPVConfig.YAW_SMOOTHING * weight)
		smoothPitch = smoothPitch + (totalPitch - smoothPitch) * (FPVConfig.MOUSE_SMOOTHING * weight)
		smoothRoll = smoothRoll + (totalRoll - smoothRoll) * (FPVConfig.MOUSE_SMOOTHING * weight)

		Remotes.UpdateDronePhysics:FireServer(FPVConfig.THRUST_FORCE * finalThrustInput, Vector3.new(smoothPitch, smoothYaw, smoothRoll), false, 1)
	else
		armedText.Text = ">UNARMED<"
		armedText.Visible = true
		armedBlinkTimer = 0
	end
end)

---------------------------------------------------------------------
-- INPUT CONTROLS
---------------------------------------------------------------------
tool.Activated:Connect(function()
	if active then 
		cleanup()
	else
		-- Find workspace.Drones.[Player.Name .. "_FPV"]
		local playerDrone = dronesFolder:FindFirstChild(player.Name .. "_FPV")
		if not playerDrone then return end

		-- Get the attachment templates from ReplicatedStorage
		local storageAttachments = ReplicatedStorage:FindFirstChild("DroneAttachments")
		local hasValidAttachment = false

		if storageAttachments then
			-- Map out all attachment model names inside ReplicatedStorage.DroneAttachments
			local validAttachmentNames = {}
			for _, item in ipairs(storageAttachments:GetChildren()) do
				if item:IsA("Model") then
					validAttachmentNames[item.Name] = true
				end
			end

			-- Check if the player's drone contains any model matching those names
			for _, child in ipairs(playerDrone:GetChildren()) do
				if child:IsA("Model") and validAttachmentNames[child.Name] then
					hasValidAttachment = true
					break
				end
			end
		else
			warn("ReplicatedStorage.DroneAttachments folder missing!")
		end

		-- Prevent entry if no matching model (e.g. OG-7) was found on the drone
		if not hasValidAttachment then
			warn("Cannot enter drone: Drone has no attachments matching ReplicatedStorage.DroneAttachments!")
			return
		end

		originalFOV = cam.FieldOfView 

		refreshGuiReferences()

		fade(0).Completed:Wait()
		active = true; flightTime = 0; batteryUpdateTimer = 0; distortCycleTimer = 0
		batteryCapacity1 = 1.0; displayVoltage1 = MAX_VOLTAGE_1
		batteryCapacity2 = 1.0; displayVoltage2 = MAX_VOLTAGE_2
		staticGui.Enabled = true
		KVN_Color.Enabled = true
		setBatteryElementsVisible(false) 
		cam.CameraType = Enum.CameraType.Scriptable; isCrashed = false
		task.wait(0.1); fade(1)
	end
end)

uis.InputBegan:Connect(function(i, g)
	if g then return end
	if active then
		if i.KeyCode == Enum.KeyCode.Y or i.KeyCode == Enum.KeyCode.ButtonA then 
			armed = not armed; Remotes.ToggleProps:FireServer(armed) 
		end
		if i.KeyCode == Enum.KeyCode.K and crosshairDotImg and crosshairDotTxt then
			local currentlyUsingImg = crosshairDotImg.Visible
			crosshairDotImg.Visible = not currentlyUsingImg
			crosshairDotTxt.Visible = currentlyUsingImg
		end
	end
end)

local DroneSelfDestruct = Remotes:WaitForChild("DroneSelfDestruct")
uis.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonB then
		DroneSelfDestruct:FireServer()
	end
end)