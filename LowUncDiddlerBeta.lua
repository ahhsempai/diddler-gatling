local function notify(title, text, duration)
	duration = duration or 5
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = duration,
		})
	end)
end

local checks = {
	{ name = "getgenv", fn = function() return type(getgenv) == "function" end },
	{ name = "RemoteEvent", fn = function() local ok = pcall(function() local re = Instance.new("RemoteEvent"); re:Destroy() end) return ok end },
}

for _, check in ipairs(checks) do
	local ok = pcall(check.fn)
	if not ok then
		notify("Gatling: Not Loaded", "Executor missing: " .. check.name, 8)
		error("[Gatling] Check failed: " .. check.name)
		return
	end
end

local UserInputService = game:GetService("UserInputService")
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local Network = ReplicatedStorage:WaitForChild("Network", 10)
local GatlingNetwork = Network and Network:WaitForChild("GatlingGun", 10)

local RE_Reload       = GatlingNetwork and GatlingNetwork:WaitForChild("RE:Reload", 10)
local RE_Fire         = GatlingNetwork and GatlingNetwork:WaitForChild("RE:Fire", 10)
local URE_AimPos      = GatlingNetwork and GatlingNetwork:WaitForChild("URE:ReplicateAimPosition", 10)
local RemoteFunction  = ReplicatedStorage:WaitForChild("RemoteFunction", 10)

if not RE_Reload or not RE_Fire or not RemoteFunction then
	notify("Not found remotes... may be sure that gatling is on the ground", 10)
	error("[Gatling] Remotes not found")
	return
end

getgenv().gatlingcooldown = 0.15
getgenv().multiplytimes = 1
getgenv().auto_fire = false
getgenv().fps_mode = false
getgenv().targetMode = 1
getgenv().showChams = true
getgenv().towerRange = 50

local original_multiply = getgenv().multiplytimes
local original_cooldown = getgenv().gatlingcooldown

local myTowers = {}
local npcsFolder = Workspace:WaitForChild("NPCs")
local enemyToRep = {}

local isPlayerMoving = false
local fireResumeDelay = 0
local lastCharPos = nil

local function checkMoving()
	local char = player.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local pos = hrp.Position
	if lastCharPos then
		local delta = (pos - lastCharPos).Magnitude
		lastCharPos = pos
		return delta > 0.15
	end
	lastCharPos = pos
	return false
end

local smoothAimTarget = nil
local smoothAimPos = nil
local AIM_LERP_SPEED = 16

RunService.Heartbeat:Connect(function(dt)
	if getgenv().fps_mode and smoothAimTarget and URE_AimPos then
		local rootPart = smoothAimTarget and smoothAimTarget.Parent and getEnemyRoot(smoothAimTarget)
		if rootPart then
			local basePos = rootPart.Position
			local desiredPos = Vector3.new(basePos.X, basePos.Y + 0.5, basePos.Z)

			if smoothAimPos == nil then
				smoothAimPos = desiredPos
			else
				local alpha = math.min(1, dt * AIM_LERP_SPEED)
				smoothAimPos = smoothAimPos:Lerp(desiredPos, alpha)
			end

			pcall(function()
				URE_AimPos:FireServer(
					Vector3.new(smoothAimPos.X, smoothAimPos.Y, smoothAimPos.Z)
				)
			end)
		end
	elseif not getgenv().fps_mode then
		smoothAimPos = nil
		smoothAimTarget = nil
	end
end)

local function safeGet(instance, key)
	local attr = instance:GetAttribute(key)
	if attr ~= nil then return attr end
	local valueObj = instance:FindFirstChild(key)
	if valueObj and (valueObj:IsA("BoolValue") or valueObj:IsA("IntValue") or valueObj:IsA("NumberValue") or valueObj:IsA("StringValue")) then
		return valueObj.Value
	end
	return nil
end

local function updateEnemyMapping()
	enemyToRep = {}
	for _, model in ipairs(npcsFolder:GetChildren()) do
		if model:IsA("Model") then
			local rootPointer = model:FindFirstChild("RootPointer")
			if rootPointer and rootPointer.Value then
				local folder = rootPointer.Value
				if safeGet(folder, "FakeUnit") == false and safeGet(folder, "Type") == "Enemies" then
					enemyToRep[model] = folder
				end
			end
		end
	end
end

npcsFolder.ChildAdded:Connect(updateEnemyMapping)
npcsFolder.ChildRemoved:Connect(updateEnemyMapping)
updateEnemyMapping()

function getEnemyRoot(model)
	return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Hitbox") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function getEnemyHP(enemy)
	local folder = enemyToRep[enemy]
	if folder then return safeGet(folder, "Health") or 0 end
	return 0
end

local function hasLeadModifier(enemy)
	local folder = enemyToRep[enemy]
	if folder then
		local modifiers = folder:FindFirstChild("Modifiers")
		if modifiers then return safeGet(modifiers, "5") == true end
	end
	return false
end

local function canHitLead(towerReplicator)
	local modifiers = towerReplicator:FindFirstChild("Modifiers")
	if modifiers then return safeGet(modifiers, "5") == true end
	return false
end

local function getTowerPosition(towerData)
	local towerFolder = towerData.tower
	local model = towerFolder:FindFirstChildWhichIsA("Model")
	if model and model.PrimaryPart then
		return model.PrimaryPart.Position
	end
	if model then
		local bp = model:FindFirstChildWhichIsA("BasePart")
		if bp then return bp.Position end
	end
	local bp = towerFolder:FindFirstChildWhichIsA("BasePart")
	if bp then return bp.Position end
	local attrPos = towerData.replicator:GetAttribute("Position")
	if attrPos then return attrPos end
	return nil
end

local function getTowerDamage(towerReplicator)
	local damage = safeGet(towerReplicator, "Damage") or 25
	local buff = safeGet(towerReplicator, "DamageBuff") or 0
	return damage * (1 + buff / 100)
end

local function findAllMyTowers()
	myTowers = {}
	for _, towerFolder in ipairs(Workspace.Towers:GetChildren()) do
		local replicator = towerFolder:FindFirstChild("TowerReplicator")
		if replicator and safeGet(replicator, "Name") == "Gatling Gun" and
		   (safeGet(replicator, "OwnerId") == player.UserId or safeGet(replicator, "OwnerName") == player.Name) then
			table.insert(myTowers, {tower = towerFolder, replicator = replicator})
		end
	end
end

findAllMyTowers()

Workspace.Towers.ChildAdded:Connect(function(child)
	task.wait(0.3)
	findAllMyTowers()
end)

function toggleFPS(enabled)
	for _, towerData in ipairs(myTowers) do
		local tower = towerData.tower
		local args = {
			"Troops",
			"Abilities",
			"Activate",
			{
				Troop = tower,
				Name = "FPS",
				Data = { enabled = enabled }
			}
		}
		pcall(function()
			RemoteFunction:InvokeServer(unpack(args))
		end)
		task.wait(0.08)
	end
	getgenv().fps_mode = enabled
	if not enabled then
		smoothAimPos = nil
		smoothAimTarget = nil
	end
end

local function getServerTime()
	local success, timeNow = pcall(function() return Workspace:GetServerTimeNow() end)
	return success and timeNow or os.clock()
end

local cachedSync = Workspace:GetAttribute("Sync") or 3355
Workspace:GetAttributeChangedSignal("Sync"):Connect(function()
	cachedSync = Workspace:GetAttribute("Sync") or cachedSync
end)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DiddlerGatling"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local mainFrame = Instance.new("Frame")
mainFrame.Size = isMobile and UDim2.new(0, 270, 0, 342) or UDim2.new(0, 240, 0, 432)
mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mainFrame.BackgroundColor3 = Color3.fromRGB(12, 8, 22)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = mainFrame

local borderFrame = Instance.new("Frame")
borderFrame.Size = isMobile and UDim2.new(0, 276, 0, 348) or UDim2.new(0, 246, 0, 438)
borderFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
borderFrame.AnchorPoint = Vector2.new(0.5, 0.5)
borderFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
borderFrame.BackgroundTransparency = 0
borderFrame.BorderSizePixel = 0
borderFrame.ZIndex = 0
borderFrame.Parent = screenGui

local borderCorner = Instance.new("UICorner")
borderCorner.CornerRadius = UDim.new(0, 16)
borderCorner.Parent = borderFrame

local borderGrad = Instance.new("UIGradient")
borderGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(6, 0, 14)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(130, 50, 240)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 110, 255)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(90, 30, 180)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 0, 14)),
})
borderGrad.Rotation = 0
borderGrad.Parent = borderFrame

spawn(function()
	local rot = 0
	while borderFrame and borderFrame.Parent do
		rot = (rot + 1.2) % 360
		borderGrad.Rotation = rot
		borderFrame.Position = mainFrame.Position
		task.wait(0.03)
	end
end)

RunService.RenderStepped:Connect(function()
	if borderFrame and borderFrame.Parent and mainFrame and mainFrame.Parent then
		borderFrame.Position = mainFrame.Position
	end
end)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 48)
titleBar.BackgroundColor3 = Color3.fromRGB(20, 10, 40)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 14)
titleCorner.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -10, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "DIDDLER GATLING"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextScaled = true
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

local yPos = 62

local function makeRow(parent, yOffset, labelText)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -20, 0, 38)
	row.Position = UDim2.new(0, 10, 0, yOffset)
	row.BackgroundColor3 = Color3.fromRGB(22, 14, 42)
	row.BorderSizePixel = 0
	row.Parent = parent
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 8)
	rc.Parent = row
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.65, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = labelText
	lbl.TextColor3 = Color3.fromRGB(210, 200, 230)
	lbl.TextSize = 13
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Position = UDim2.new(0, 12, 0, 0)
	lbl.Parent = row
	return row
end

local function makeToggle(parent, row, defaultOn)
	local state = defaultOn
	local toggleBg = Instance.new("Frame")
	toggleBg.Size = UDim2.new(0, 42, 0, 22)
	toggleBg.Position = UDim2.new(1, -52, 0.5, -11)
	toggleBg.BackgroundColor3 = state and Color3.fromRGB(120, 60, 220) or Color3.fromRGB(50, 40, 70)
	toggleBg.BorderSizePixel = 0
	toggleBg.Parent = row
	local tbc = Instance.new("UICorner")
	tbc.CornerRadius = UDim.new(1, 0)
	tbc.Parent = toggleBg
	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 16, 0, 16)
	knob.Position = state and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.Parent = toggleBg
	local kc = Instance.new("UICorner")
	kc.CornerRadius = UDim.new(1, 0)
	kc.Parent = knob
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Parent = row

	local function setToggle(val)
		state = val
		TweenService:Create(toggleBg, TweenInfo.new(0.15), {BackgroundColor3 = state and Color3.fromRGB(140, 70, 240) or Color3.fromRGB(50, 40, 70)}):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {Position = state and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)}):Play()
	end
	return btn, setToggle, function() return state end
end

local function makeInputRow(parent, yOffset, labelText, defaultVal)
	local row = makeRow(parent, yOffset, labelText)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0, 60, 0, 24)
	box.Position = UDim2.new(1, -72, 0.5, -12)
	box.BackgroundColor3 = Color3.fromRGB(30, 20, 55)
	box.BorderSizePixel = 0
	box.Text = tostring(defaultVal)
	box.TextColor3 = Color3.fromRGB(200, 180, 255)
	box.TextSize = 13
	box.Font = Enum.Font.GothamBold
	box.Parent = row
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = box
	return row, box
end

local dragging = false
local dragStart, startPos
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = mainFrame.Position
	end
end)
titleBar.InputChanged:Connect(function(input)
	if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) and dragging then
		local delta = input.Position - dragStart
		mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)
titleBar.InputEnded:Connect(function() dragging = false end)

local autoRow = makeRow(mainFrame, yPos, "Auto Fire")
local autoBtn, setAutoToggle, _ = makeToggle(mainFrame, autoRow, false)
autoBtn.MouseButton1Click:Connect(function()
	getgenv().auto_fire = not getgenv().auto_fire
	setAutoToggle(getgenv().auto_fire)
	if getgenv().auto_fire and not getgenv().fps_mode then toggleFPS(true) end
end)
yPos = yPos + 46

local _, multiBox = makeInputRow(mainFrame, yPos, "Multiply Times", getgenv().multiplytimes)
multiBox.FocusLost:Connect(function()
	local num = tonumber(multiBox.Text)
	if num and num > 0 and num <= 100 then getgenv().multiplytimes = num end
end)
yPos = yPos + 46

local _, coolBox = makeInputRow(mainFrame, yPos, "Cooldown", getgenv().gatlingcooldown)
coolBox.FocusLost:Connect(function()
	local num = tonumber(coolBox.Text)
	if num and num >= 0 then getgenv().gatlingcooldown = num end
end)
yPos = yPos + 46

local _, towerRangeBox = makeInputRow(mainFrame, yPos, "Tower Range (studs)", getgenv().towerRange)
towerRangeBox.FocusLost:Connect(function()
	local num = tonumber(towerRangeBox.Text)
	if num then
		getgenv().towerRange = math.clamp(num, 10, 9999)
		towerRangeBox.Text = tostring(getgenv().towerRange)
	end
end)
yPos = yPos + 46

local targetRow = makeRow(mainFrame, yPos, "Target Mode")
local targetValLabel = Instance.new("TextLabel")
targetValLabel.Size = UDim2.new(0, 80, 1, 0)
targetValLabel.Position = UDim2.new(1, -90, 0, 0)
targetValLabel.BackgroundTransparency = 1
targetValLabel.Text = "Farthest"
targetValLabel.TextColor3 = Color3.fromRGB(180, 140, 255)
targetValLabel.TextSize = 12
targetValLabel.Font = Enum.Font.GothamBold
targetValLabel.TextXAlignment = Enum.TextXAlignment.Right
targetValLabel.Parent = targetRow

local modeNames = {"Farthest", "First", "Strongest", "SmartAmmo"}
local targetBtn = Instance.new("TextButton")
targetBtn.Size = UDim2.new(1, 0, 1, 0)
targetBtn.BackgroundTransparency = 1
targetBtn.Text = ""
targetBtn.Parent = targetRow
targetBtn.MouseButton1Click:Connect(function()
	local old = getgenv().targetMode
	getgenv().targetMode = (getgenv().targetMode % 4) + 1
	targetValLabel.Text = modeNames[getgenv().targetMode]
	if old == 4 and getgenv().targetMode ~= 4 then
		getgenv().multiplytimes = original_multiply
		getgenv().gatlingcooldown = original_cooldown
	elseif getgenv().targetMode == 4 then
		original_multiply = getgenv().multiplytimes
		original_cooldown = getgenv().gatlingcooldown
	end
end)
yPos = yPos + 46

local chamsRow = makeRow(mainFrame, yPos, "Show Targets")
local chamsBtn, setChamsToggle, _ = makeToggle(mainFrame, chamsRow, true)
chamsBtn.MouseButton1Click:Connect(function()
	getgenv().showChams = not getgenv().showChams
	setChamsToggle(getgenv().showChams)
end)
yPos = yPos + 54

local syncBtn = Instance.new("TextButton")
syncBtn.Size = UDim2.new(1, -20, 0, 38)
syncBtn.Position = UDim2.new(0, 10, 0, yPos)
syncBtn.BackgroundColor3 = Color3.fromRGB(100, 45, 200)
syncBtn.Text = "Sync All Gatling Guns"
syncBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
syncBtn.TextSize = 13
syncBtn.Font = Enum.Font.GothamBold
syncBtn.Parent = mainFrame
local syncCorner = Instance.new("UICorner")
syncCorner.CornerRadius = UDim.new(0, 8)
syncCorner.Parent = syncBtn
syncBtn.MouseButton1Click:Connect(function()
	toggleFPS(true)
	syncBtn.Text = "Ѓ7Ѕ7 Synced!"
	task.wait(1.2)
	syncBtn.Text = "Sync All Gatling Guns"
end)
yPos = yPos + 48

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 24)
statusLabel.Position = UDim2.new(0, 10, 0, yPos)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Gooning to towers..."
statusLabel.TextColor3 = Color3.fromRGB(160, 100, 255)
statusLabel.TextSize = 11
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = mainFrame

if isMobile then
	local fpsMobileBtn = Instance.new("TextButton")
	fpsMobileBtn.Size = UDim2.new(1, -20, 0, 42)
	fpsMobileBtn.Position = UDim2.new(0, 10, 0, yPos + 30)
	fpsMobileBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 160)
	fpsMobileBtn.Text = "Toggle FPS Mode"
	fpsMobileBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	fpsMobileBtn.TextSize = 13
	fpsMobileBtn.Font = Enum.Font.GothamBold
	fpsMobileBtn.Parent = mainFrame
	local fpsCorner = Instance.new("UICorner")
	fpsCorner.CornerRadius = UDim.new(0, 8)
	fpsCorner.Parent = fpsMobileBtn
	fpsMobileBtn.MouseButton1Click:Connect(function()
		getgenv().fps_mode = not getgenv().fps_mode
		toggleFPS(getgenv().fps_mode)
		getgenv().auto_fire = getgenv().fps_mode
		setAutoToggle(getgenv().auto_fire)
		fpsMobileBtn.Text = getgenv().fps_mode and "FPS: ON" or "FPS: OFF"
	end)
end

if not isMobile then
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.Y then
			getgenv().fps_mode = not getgenv().fps_mode
			toggleFPS(getgenv().fps_mode)
			getgenv().auto_fire = getgenv().fps_mode
			setAutoToggle(getgenv().auto_fire)
		end
	end)
end

local currentTarget = nil
local currentHighlight = nil
local noTargetTime = 0
local pendingResumeDelay = 0

spawn(function()
	while true do
		findAllMyTowers()
		updateEnemyMapping()

		if #myTowers == 0 then task.wait(0.5) continue end

		for _, towerData in ipairs(myTowers) do
			local towerReplicator = towerData.replicator
			local ammo      = safeGet(towerReplicator, "Ammo") or 0
			local reloading = safeGet(towerReplicator, "Reloading") or false
			local canLead   = canHitLead(towerReplicator)

			if isPlayerMoving then
				if fireResumeDelay > 0 then
					pendingResumeDelay = fireResumeDelay
					fireResumeDelay = 0
				end
				task.wait(0.05)
				continue
			end

			if pendingResumeDelay > 0 then
				task.wait(pendingResumeDelay)
				pendingResumeDelay = 0
			end

			if getgenv().auto_fire and getgenv().fps_mode then
				local towerPos = getTowerPosition(towerData)
				local rangeLimit = tonumber(getgenv().towerRange) or 150

				local targets = npcsFolder:GetChildren()
				local enemies = {}

				for _, model in ipairs(targets) do
					if model:IsA("Model") and model.Name ~= "Blue" and model.Name ~= "Red" then
						local rootPart = getEnemyRoot(model)
						if rootPart then
							local hp = getEnemyHP(model)
							local isLead = hasLeadModifier(model)
							if hp > 0 and (not isLead or canLead) then
								local inRange = true
								if towerPos then
									local dist = (rootPart.Position - towerPos).Magnitude
									inRange = dist <= rangeLimit
								end

								if inRange then
									local prog = 0
									local folder = enemyToRep[model]
									if folder then prog = safeGet(folder, "PathDistance") or 0 end
									local distToTower = towerPos and (rootPart.Position - towerPos).Magnitude or 0
									table.insert(enemies, {model = model, rootPart = rootPart, progress = prog, hp = hp, distToTower = distToTower})
								end
							end
						end
					end
				end

				local target = nil
				if getgenv().targetMode == 1 then
					table.sort(enemies, function(a, b) return a.distToTower > b.distToTower end)
					target = enemies[1] and enemies[1].model
				elseif getgenv().targetMode == 2 then
					table.sort(enemies, function(a, b) return a.progress > b.progress end)
					target = enemies[1] and enemies[1].model
				elseif getgenv().targetMode == 3 then
					table.sort(enemies, function(a, b) return a.hp > b.hp end)
					target = enemies[1] and enemies[1].model
				elseif getgenv().targetMode == 4 then
					table.sort(enemies, function(a, b) return a.progress > b.progress end)
					local towerDmg = getTowerDamage(towerReplicator)
					local totalHp = 0
					local maxAmmo = safeGet(towerReplicator, "MaxAmmo") or 100
					for i = 1, math.min(3, #enemies) do
						totalHp = totalHp + enemies[i].hp
					end
					local needed = math.ceil(totalHp / towerDmg)
					getgenv().multiplytimes = needed > (maxAmmo * 2) and maxAmmo or math.min(needed + 3, maxAmmo)
					getgenv().gatlingcooldown = 0
					target = enemies[1] and enemies[1].model
				end

				smoothAimTarget = target

				if target ~= currentTarget then
					if currentHighlight then currentHighlight:Destroy() end
					currentTarget = target
					if currentTarget and getgenv().showChams then
						currentHighlight = Instance.new("Highlight")
						currentHighlight.Parent = currentTarget
						currentHighlight.FillColor = Color3.new(52, 0, 25)
						currentHighlight.OutlineColor = Color3.new(1, 0, 1)
						currentHighlight.FillTransparency = 0.7
						currentHighlight.OutlineTransparency = 0
					end
				end

				if #enemies > 0 then
					noTargetTime = 0
					local rootPart = currentTarget and getEnemyRoot(currentTarget)
					local hp = currentTarget and getEnemyHP(currentTarget) or 0

					if ammo == 0 and not reloading then
						pcall(function() RE_Reload:FireServer() end)
						task.wait(2.6)
					elseif rootPart and ammo > 0 and not reloading and hp > 0 then
						local basePos = rootPart.Position
						--  origin + lookVector * dist
						local attrPos = towerData.replicator:GetAttribute("Position")
						local origin = attrPos or towerPos or basePos
						local targetPos = Vector3.new(basePos.X, basePos.Y, basePos.Z)
						local lookVector = (targetPos - origin).Unit
						local dist = (targetPos - origin).Magnitude
						local firePos = origin + lookVector * dist

						for i = 1, getgenv().multiplytimes do
							pcall(function()
								RE_Fire:FireServer(
									Vector3.new(firePos.X, firePos.Y, firePos.Z),
									cachedSync,
									getServerTime() + (i - 1) * 0.001
								)
							end)
						end
						task.wait(getgenv().gatlingcooldown)
					end
				else
					noTargetTime = noTargetTime + 0.1
					if noTargetTime >= 5 then
						pcall(function() RE_Reload:FireServer() end)
						noTargetTime = 0
					end
				end
			end
		end
		task.wait(0.001)
	end
end)

print("Diddler Gatling LOADED")
notify("Gatling Loaded", 5)
