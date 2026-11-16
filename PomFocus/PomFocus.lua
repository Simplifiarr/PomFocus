-- PomFocus for WoW: Forever (Mainline API, Interface 16001)
-- Timers end when ANY goal is hit first: minutes, quests turned in, tasks done.
-- A rotation is an editable list of named steps that repeats
-- (e.g. Work / chores -> Game time -> Work / chores -> Game time -> Rest).
--   /pf                      open / close setup (or click the tomato on the minimap)
--   /pf start <min> [quests] [tasks]     e.g. /pf start 25 5   (25 min OR 5 quests)
--   /pf rotation | done | skip | pause | resume | stop | status | test | reset

local ADDON = "PomFocus"
local DB
local s -- active session (nil when idle)

local DEFAULTS = {
  timers = {
    { name = "Quest sprint",  min = 25, quests = 5, tasks = 0, msg = "Time to do your chores!" },
    { name = "Home tasks",    min = 0,  quests = 0, tasks = 5, msg = "Home tasks complete!" },
    { name = "Work tasks",    min = 0,  quests = 0, tasks = 5, msg = "Work tasks complete!" },
    { name = "Office tasks",  min = 0,  quests = 0, tasks = 5, msg = "Office tasks complete!" },
  },
  rotation = {
    { name = "Work / chores",       min = 25, quests = 0, tasks = 0, msg = "Work block done - you earned some game time!" },
    { name = "Game time (WoW)",     min = 15, quests = 5, tasks = 0, msg = "Game time over - back to work!" },
    { name = "Work / chores",       min = 25, quests = 0, tasks = 0, msg = "Work block done - you earned some game time!" },
    { name = "Rest (away from PC)", min = 10, quests = 0, tasks = 0, msg = "Rest over - ready for the next round?" },
  },
}
local MAX_ROWS = 8

local function Print(msg) print("|cff33ff99Focus:|r " .. msg) end

local function CopyTable(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = CopyTable(v) end
  return c
end

local function FormatTime(sec)
  sec = math.max(0, math.ceil(sec))
  return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

local function Num(v) return tonumber(v) or 0 end

local function GoalText(d)
  local p = {}
  if Num(d.min) > 0 then p[#p + 1] = d.min .. " min" end
  if Num(d.quests) > 0 then p[#p + 1] = d.quests .. " quests" end
  if Num(d.tasks) > 0 then p[#p + 1] = d.tasks .. " tasks" end
  if #p == 0 then return "no goal set" end
  return table.concat(p, " or ")
end

local tmpl = BackdropTemplateMixin and "BackdropTemplate" or nil
local DIALOG_BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local TOOLTIP_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function MakeMovable(f, key)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if DB then DB[key] = { self:GetLeft(), self:GetTop() } end
  end)
end

local function RestorePos(f, key, default)
  f:ClearAllPoints()
  local p = DB and DB[key]
  if p and p[1] and p[2] then
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[1], p[2])
  else
    f:SetPoint(unpack(default))
  end
end

local function MakeEdit(parent, w, numeric)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(w, 20)
  e:SetAutoFocus(false)
  e:SetMaxLetters(numeric and 3 or 80)
  if numeric then e:SetNumeric(true) end
  e:SetScript("OnEnterPressed", e.ClearFocus)
  e:SetScript("OnEscapePressed", e.ClearFocus)
  return e
end

local function SmallButton(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

------------------------------------------------------------------------
-- HUD (status window)
------------------------------------------------------------------------
local hud = CreateFrame("Frame", "PomFocusFrame", UIParent, tmpl)
hud:SetSize(270, 116)
hud:SetBackdrop(TOOLTIP_BACKDROP)
hud:SetBackdropColor(0, 0, 0, 0.85)
MakeMovable(hud, "pos")
hud:Hide()

local hudTitle = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
hudTitle:SetPoint("TOP", hud, "TOP", 0, -9)
local hudValue = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
hudValue:SetPoint("TOP", hudTitle, "BOTTOM", 0, -3)
local hudSub = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hudSub:SetPoint("TOP", hudValue, "BOTTOM", 0, -2)

local bar = CreateFrame("StatusBar", nil, hud)
bar:SetSize(240, 8)
bar:SetPoint("TOP", hudSub, "BOTTOM", 0, -6)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 1)
bar:SetStatusBarColor(1, 0.82, 0)
local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

local btnPause = SmallButton(hud, "Pause", 56)
btnPause:SetPoint("BOTTOMLEFT", hud, "BOTTOMLEFT", 12, 9)
local btnDone = SmallButton(hud, "+1 task", 56)
btnDone:SetPoint("LEFT", btnPause, "RIGHT", 4, 0)
local btnStop = SmallButton(hud, "Stop", 46)
btnStop:SetPoint("LEFT", btnDone, "RIGHT", 4, 0)
local btnSetup = SmallButton(hud, "Setup", 52)
btnSetup:SetPoint("LEFT", btnStop, "RIGHT", 4, 0)

-- Minimap button (round tomato), draggable around the minimap edge
local launcher = CreateFrame("Button", "PomFocusMinimapButton", Minimap)
launcher:SetSize(31, 31)
launcher:SetFrameStrata("MEDIUM")
launcher:SetFrameLevel(8)
launcher:RegisterForClicks("LeftButtonUp")
launcher:RegisterForDrag("LeftButton")

local mmBg = launcher:CreateTexture(nil, "BACKGROUND")
mmBg:SetSize(20, 20)
mmBg:SetPoint("TOPLEFT", 7, -5)
mmBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

-- tomato drawn from masked circles (no icon file needed)
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local function Blob(layer, sub, w, h, x, y, r, g, b, a, round, rot)
  local t = launcher:CreateTexture(nil, layer, nil, sub)
  t:SetSize(w, h)
  t:SetPoint("CENTER", launcher, "CENTER", x, y)
  t:SetTexture("Interface\\Buttons\\WHITE8X8")
  t:SetVertexColor(r, g, b, a or 1)
  if round then pcall(t.SetMask, t, MASK) end
  if rot then t:SetRotation(rot) end
  return t
end
-- body: dark outline, red fruit (slightly wider than tall), highlight
Blob("ARTWORK", 0, 21, 19, 0, -2, 0.45, 0.03, 0.03, 1, true)
Blob("ARTWORK", 1, 19, 17, 0, -2, 0.9, 0.1, 0.08, 1, true)
Blob("ARTWORK", 2, 11, 7, 2, -6, 0.7, 0.05, 0.05, 0.6, true)   -- lower shade
Blob("OVERLAY", 0, 5, 4, -5, 1, 1, 0.75, 0.7, 0.85, true, 0.5) -- shine
-- green calyx: five small leaves fanned over the top, plus a brown stem
Blob("OVERLAY", 1, 8, 3, -4, 6, 0.15, 0.65, 0.15, 1, true, 0.5)
Blob("OVERLAY", 1, 8, 3, 4, 6, 0.15, 0.65, 0.15, 1, true, -0.5)
Blob("OVERLAY", 1, 8, 3, -2, 5, 0.25, 0.8, 0.25, 1, true, 0.2)
Blob("OVERLAY", 1, 8, 3, 2, 5, 0.25, 0.8, 0.25, 1, true, -0.2)
Blob("OVERLAY", 2, 2, 5, 0, 9, 0.35, 0.22, 0.08, 1, false)

local mmBorder = launcher:CreateTexture(nil, "OVERLAY", nil, 2)
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
launcher:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local function PlaceMinimapButton()
  local a = math.rad((DB and DB.mmAngle) or 215)
  local r = (Minimap:GetWidth() / 2) + 5
  launcher:ClearAllPoints()
  launcher:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end
launcher:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    DB.mmAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    PlaceMinimapButton()
  end)
end)
launcher:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
launcher:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("PomFocus")
  GameTooltip:AddLine("Click: open setup. Drag: move around the minimap.", 1, 1, 1)
  GameTooltip:Show()
end)
launcher:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function Remaining()
  if not s or not s.goalMin then return nil end
  if s.paused then return s.left end
  return s.endTime - GetTime()
end

local function RefreshHUD()
  if not s then hud:Hide() return end
  hud:Show()
  hudTitle:SetText(s.label .. (s.paused and " |cffff8800(paused)|r" or ""))

  local counts, frac = {}, 0
  local rem = Remaining()
  if rem then frac = math.max(frac, 1 - rem / (s.goalMin * 60)) end
  if s.goalQ then
    counts[#counts + 1] = "Quests " .. s.q .. "/" .. s.goalQ
    frac = math.max(frac, s.q / s.goalQ)
  end
  if s.goalT then
    counts[#counts + 1] = "Tasks " .. s.t .. "/" .. s.goalT
    frac = math.max(frac, s.t / s.goalT)
  end
  if rem then
    hudValue:SetText(FormatTime(rem))
    hudSub:SetText(table.concat(counts, "   "))
  else
    hudValue:SetText(counts[1] or "")
    hudSub:SetText(counts[2] or "")
  end
  local goals = (rem and 1 or 0) + #counts
  if goals > 1 then hudSub:SetText((hudSub:GetText() or "") .. (#counts > 0 and "   " or "") .. "|cff999999(first one wins)|r") end
  bar:SetValue(math.min(1, math.max(0, frac)))
  btnPause:SetShown(rem ~= nil)
  btnPause:SetText(s.paused and "Resume" or "Pause")
  btnDone:SetShown(s.goalT ~= nil)
end

------------------------------------------------------------------------
-- Visual alarm
------------------------------------------------------------------------
local flash = CreateFrame("Frame", "PomFocusFlash", UIParent)
flash:SetAllPoints(UIParent)
flash:SetFrameStrata("FULLSCREEN_DIALOG")
local flashTex = flash:CreateTexture(nil, "BACKGROUND")
flashTex:SetAllPoints()
flashTex:SetTexture("Interface\\FullScreenTextures\\LowHealth")
flashTex:SetVertexColor(1, 0.8, 0.1)
flashTex:SetBlendMode("ADD")
flash:Hide()

local alert = CreateFrame("Frame", "PomFocusAlert", UIParent, tmpl)
alert:SetSize(460, 180)
alert:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
alert:SetFrameStrata("FULLSCREEN_DIALOG")
alert:SetFrameLevel(50)
alert:SetBackdrop(DIALOG_BACKDROP)
alert:EnableMouse(true)
alert:Hide()
tinsert(UISpecialFrames, "PomFocusAlert")

local glow = alert:CreateTexture(nil, "BACKGROUND", nil, -8)
glow:SetPoint("TOPLEFT", alert, "TOPLEFT", -10, 10)
glow:SetPoint("BOTTOMRIGHT", alert, "BOTTOMRIGHT", 10, -10)
glow:SetColorTexture(1, 0.75, 0, 0.5)

local alertIcon = alert:CreateTexture(nil, "ARTWORK")
alertIcon:SetSize(56, 56)
alertIcon:SetPoint("TOPLEFT", alert, "TOPLEFT", 26, -28)
alertIcon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
local alertTitle = alert:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
alertTitle:SetPoint("TOPLEFT", alertIcon, "TOPRIGHT", 14, -2)
alertTitle:SetPoint("RIGHT", alert, "RIGHT", -26, 0)
alertTitle:SetJustifyH("LEFT")
local alertText = alert:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
alertText:SetPoint("TOPLEFT", alertTitle, "BOTTOMLEFT", 0, -6)
alertText:SetPoint("RIGHT", alert, "RIGHT", -26, 0)
alertText:SetJustifyH("LEFT")

local alertOk = CreateFrame("Button", nil, alert, "UIPanelButtonTemplate")
alertOk:SetSize(100, 26)
local alertNext = CreateFrame("Button", nil, alert, "UIPanelButtonTemplate")
alertNext:SetSize(230, 26)
local alertNextFn

local function DismissAlert()
  alert:Hide()
  flash:Hide()
end
alert:SetScript("OnHide", function() flash:Hide() end)
alertOk:SetText("Okay")
alertOk:SetScript("OnClick", DismissAlert)
alertNext:SetScript("OnClick", function()
  local fn = alertNextFn
  DismissAlert()
  if fn then fn() end
end)

local pulse, soundAcc, soundCount = 0, 0, 0
local function AlarmSound()
  pcall(PlaySound, (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960)
end
alert:SetScript("OnUpdate", function(_, el)
  pulse = pulse + el
  local a = 0.5 + 0.5 * math.sin(pulse * 6)
  glow:SetAlpha(0.25 + 0.75 * a)
  flash:SetAlpha(0.2 + 0.6 * a)
  if soundCount < 6 then
    soundAcc = soundAcc + el
    if soundAcc >= 2.5 then
      soundAcc = 0
      soundCount = soundCount + 1
      AlarmSound()
    end
  end
end)

local function ShowAlert(titleText, text, nextLabel, nextFn)
  alertTitle:SetText(titleText)
  alertText:SetText(text)
  alertNextFn = nextFn
  alertOk:ClearAllPoints()
  alertNext:ClearAllPoints()
  if nextLabel then
    alertNext:SetText(nextLabel)
    alertNext:SetPoint("BOTTOM", alert, "BOTTOM", -60, 22)
    alertOk:SetPoint("LEFT", alertNext, "RIGHT", 10, 0)
    alertOk:SetText("Not now")
    alertNext:Show()
  else
    alertOk:SetText("Okay")
    alertOk:SetPoint("BOTTOM", alert, "BOTTOM", 0, 22)
    alertNext:Hide()
  end
  pulse, soundAcc, soundCount = 0, 0, 1
  flash:Show()
  alert:Show()
  alert:Raise()
  AlarmSound()
  if FlashClientIcon then pcall(FlashClientIcon) end
end

------------------------------------------------------------------------
-- Session logic
------------------------------------------------------------------------
local function Begin(def, label, rotIndex)
  local m, q, t = Num(def.min), Num(def.quests), Num(def.tasks)
  if m <= 0 and q <= 0 and t <= 0 then
    Print("Set at least one goal (minutes, quests or tasks) above 0.")
    return
  end
  s = {
    label = label, message = def.msg or "", rot = rotIndex,
    goalMin = m > 0 and m or nil, goalQ = q > 0 and q or nil, goalT = t > 0 and t or nil,
    q = 0, t = 0,
  }
  if s.goalMin then s.endTime = GetTime() + m * 60 end
  DismissAlert()
  RefreshHUD()
  Print(label .. ": " .. GoalText(def) .. (GoalText(def):find(" or ") and " (whichever comes first)" or ""))
end

local function StartRotationStep(i)
  local list = DB.rotation
  if #list == 0 then Print("Add at least one step to the rotation first.") return end
  i = ((i - 1) % #list) + 1
  local d = list[i]
  Begin(d, d.name .. "  (step " .. i .. "/" .. #list .. ")", i)
end

local function Finish(reason)
  local done = s
  s = nil
  RefreshHUD()
  local list = DB.rotation
  local doneName = done.label:gsub("%s+%(step.*$", "")
  local text = (done.message ~= "") and done.message or "Time to do your chores / work!"
  if done.rot and #list > 0 then
    local nextI = (done.rot % #list) + 1
    local nd = list[nextI]
    ShowAlert(doneName .. " complete!", text .. "\n|cffaaaaaaNext: " .. nd.name .. " (" .. GoalText(nd) .. ")|r",
      "Start: " .. nd.name, function() StartRotationStep(nextI) end)
  else
    ShowAlert(doneName .. " complete!", text)
  end
  Print(doneName .. " complete (" .. reason .. "). " .. text)
end

local function CheckGoals()
  if not s then return end
  if s.goalQ and s.q >= s.goalQ then Finish("quests reached") return end
  if s.goalT and s.t >= s.goalT then Finish("tasks reached") return end
end

local function AddTask()
  if not s or not s.goalT then return end
  s.t = s.t + 1
  RefreshHUD()
  CheckGoals()
end

local function AddQuest()
  if not s or not s.goalQ then return end
  s.q = s.q + 1
  RefreshHUD()
  CheckGoals()
end

local function TogglePause()
  if not s or not s.goalMin then return end
  if s.paused then
    s.paused = nil
    s.endTime = GetTime() + s.left
  else
    s.paused = true
    s.left = s.endTime - GetTime()
  end
  RefreshHUD()
end

local function Stop()
  if s then Print("Session stopped.") end
  s = nil
  RefreshHUD()
end

local function Skip()
  if s and s.rot then
    StartRotationStep(s.rot + 1)
  end
end

btnPause:SetScript("OnClick", TogglePause)
btnDone:SetScript("OnClick", AddTask)
btnStop:SetScript("OnClick", Stop)

local acc = 0
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, el)
  if not s then return end
  if s.goalMin and not s.paused and Remaining() <= 0 then
    Finish("time up")
    return
  end
  acc = acc + el
  if acc >= 0.2 then acc = 0 RefreshHUD() end
end)

------------------------------------------------------------------------
-- Setup window
------------------------------------------------------------------------
local ROW_STEP = 32
local setup = CreateFrame("Frame", "PomFocusSetup", UIParent, tmpl)
setup:SetSize(650, 150 + 3 * ROW_STEP + 85)
setup:SetBackdrop(DIALOG_BACKDROP)
setup:SetFrameStrata("DIALOG")
MakeMovable(setup, "setupPos")
setup:Hide()
tinsert(UISpecialFrames, "PomFocusSetup")

local sTitle = setup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
sTitle:SetPoint("TOP", setup, "TOP", 0, -18)
sTitle:SetText("PomFocus Setup")
local closeX = CreateFrame("Button", nil, setup, "UIPanelCloseButton")
closeX:SetPoint("TOPRIGHT", setup, "TOPRIGHT", -6, -6)

local panels = {}
local currentTab

local COLS = { name = 30, min = 176, quests = 232, tasks = 288, msg = 344 }

local function BuildPanel(key, intro, startLabel, startFn, addLabel, newItem)
  local p = CreateFrame("Frame", nil, setup)
  p:SetAllPoints(setup)
  p:Hide()
  p.rows = {}

  local introFS = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  introFS:SetPoint("TOPLEFT", p, "TOPLEFT", 30, -82)
  introFS:SetPoint("RIGHT", p, "RIGHT", -30, 0)
  introFS:SetJustifyH("LEFT")
  introFS:SetText(intro)

  local function Header(text, x)
    local h = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", p, "TOPLEFT", x, -130)
    h:SetText(text)
  end
  Header("Name", COLS.name)
  Header("Minutes", COLS.min - 4)
  Header("Quests", COLS.quests)
  Header("Tasks", COLS.tasks)
  Header("Reminder message", COLS.msg)

  local function List() return DB[key] end

  function p.Refresh()
    local list = List()
    for i = 1, MAX_ROWS do
      local t, row = list[i], p.rows[i]
      if t then
        row.name:SetText(t.name or "")
        row.min:SetText(tostring(Num(t.min)))
        row.quests:SetText(tostring(Num(t.quests)))
        row.tasks:SetText(tostring(Num(t.tasks)))
        row.msg:SetText(t.msg or "")
        row.msg:SetCursorPosition(0)
        row:Show()
      else
        row:Hide()
      end
    end
    p.add:SetEnabled(#list < MAX_ROWS)
    -- size the window to the rows in use (no big empty gap)
    setup:SetHeight(150 + math.max(#list, 3) * ROW_STEP + 85)
  end

  for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, p)
    row:SetSize(600, 26)
    row:SetPoint("TOPLEFT", p, "TOPLEFT", 24, -150 - (i - 1) * ROW_STEP)
    local function At(w, numeric, x)
      local e = MakeEdit(row, w, numeric)
      e:SetPoint("LEFT", row, "LEFT", x - 24, 0)
      return e
    end
    row.name = At(140, false, COLS.name)
    row.name:SetScript("OnTextChanged", function(self, user)
      if user and List()[i] then List()[i].name = self:GetText() end
    end)
    local function NumBox(field, x)
      local e = At(40, true, x)
      e:SetScript("OnTextChanged", function(self, user)
        if user and List()[i] then List()[i][field] = tonumber(self:GetText()) or 0 end
      end)
      return e
    end
    row.min = NumBox("min", COLS.min)
    row.quests = NumBox("quests", COLS.quests)
    row.tasks = NumBox("tasks", COLS.tasks)
    row.msg = At(185, false, COLS.msg)
    row.msg:SetScript("OnTextChanged", function(self, user)
      if user and List()[i] then List()[i].msg = self:GetText() end
    end)
    row.start = SmallButton(row, "Start", 46)
    row.start:SetPoint("LEFT", row.msg, "RIGHT", 8, 0)
    row.start:SetScript("OnClick", function()
      if List()[i] then
        startFn(i)
        if s then setup:Hide() end
      end
    end)
    row.del = SmallButton(row, "X", 22)
    row.del:SetPoint("LEFT", row.start, "RIGHT", 3, 0)
    row.del:SetScript("OnClick", function()
      table.remove(List(), i)
      p.Refresh()
    end)
    p.rows[i] = row
  end

  p.add = SmallButton(p, addLabel, 110)
  p.add:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 30, 30)
  p.add:SetScript("OnClick", function()
    if #List() < MAX_ROWS then
      table.insert(List(), newItem())
      p.Refresh()
    end
  end)
  if startLabel then
    p.startAll = SmallButton(p, startLabel, 130)
    p.startAll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -30, 30)
    p.startAll:SetScript("OnClick", function()
      startFn(1)
      if s then setup:Hide() end
    end)
  end
  panels[key] = p
  return p
end

BuildPanel("timers",
  "Each timer ends when ANY goal is reached first. Leave a goal at 0 to ignore it.\nExample: 25 min + 5 quests = stop at 25 minutes or 5 quests, whichever comes first.",
  nil,
  function(i)
    local d = DB.timers[i]
    Begin(d, d.name ~= "" and d.name or "Timer")
  end,
  "+ Add timer",
  function() return { name = "New timer", min = 25, quests = 0, tasks = 0, msg = "" } end)

BuildPanel("rotation",
  "Steps run in order and loop. Name them whatever fits: work, chores, game time, real rest.\nWhen a step ends you get an alarm and a button to start the next one.",
  "Start rotation",
  function(i) StartRotationStep(i) end,
  "+ Add step",
  function() return { name = "New step", min = 15, quests = 0, tasks = 0, msg = "" } end)

-- Tabs
local tabs = {}
local function ShowTab(key)
  currentTab = key
  for k, p in pairs(panels) do p:SetShown(k == key) end
  for k, b in pairs(tabs) do b:SetEnabled(k ~= key) end
  panels[key].Refresh()
end
local function MakeTab(key, text, x)
  local b = SmallButton(setup, text, 130)
  b:SetPoint("TOPLEFT", setup, "TOPLEFT", x, -46)
  b:SetScript("OnClick", function() ShowTab(key) end)
  tabs[key] = b
end
MakeTab("timers", "Custom timers", 30)
MakeTab("rotation", "Rotation", 166)

local testBtn = SmallButton(setup, "Test alarm", 100)
testBtn:SetPoint("BOTTOM", setup, "BOTTOM", -50, 30)
testBtn:SetScript("OnClick", function()
  ShowAlert("Work / chores complete!", "This is what your alarm looks like.\n|cffaaaaaaNext: Game time (WoW) (15 min)|r",
    "Start: Game time (WoW)", function() end)
end)
local defBtn = SmallButton(setup, "Reset defaults", 110)
defBtn:SetPoint("LEFT", testBtn, "RIGHT", 8, 0)
defBtn:SetScript("OnClick", function()
  DB.timers = CopyTable(DEFAULTS.timers)
  DB.rotation = CopyTable(DEFAULTS.rotation)
  panels[currentTab or "timers"].Refresh()
end)

setup:SetScript("OnShow", function() ShowTab(currentTab or "timers") end)

btnSetup:SetScript("OnClick", function() setup:SetShown(not setup:IsShown()) end)
launcher:SetScript("OnClick", function() setup:SetShown(not setup:IsShown()) end)

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    PomFocusDB = PomFocusDB or {}
    DB = PomFocusDB
    DB.pomo = nil -- replaced by the editable rotation
    DB.timers = DB.timers or CopyTable(DEFAULTS.timers)
    DB.rotation = DB.rotation or CopyTable(DEFAULTS.rotation)
    -- migrate old single-goal timers (kind/amount) to min/quests/tasks
    for _, t in ipairs(DB.timers) do
      if t.kind then
        t.min = t.kind == "time" and Num(t.amount) or 0
        t.quests = t.kind == "quests" and Num(t.amount) or 0
        t.tasks = t.kind == "tasks" and Num(t.amount) or 0
        t.kind, t.amount = nil, nil
      end
    end
    RestorePos(hud, "pos", { "TOP", UIParent, "TOP", 0, -120 })
    RestorePos(setup, "setupPos", { "CENTER", UIParent, "CENTER", 0, 0 })
    PlaceMinimapButton()
    RefreshHUD()
    Print("PomFocus loaded. Click the tomato on the minimap or type /pf to set up.")
  elseif event == "QUEST_TURNED_IN" then
    AddQuest()
  end
end)

-- NOTE: "/focus" is a built-in WoW command (set focus target), so we use /pf
SLASH_POMFOCUS1 = "/pf"
SLASH_POMFOCUS2 = "/pomfocus"
SLASH_POMFOCUS3 = "/ft"
SLASH_POMFOCUS4 = "/pomodoro"
SlashCmdList["POMFOCUS"] = function(input)
  if not DB then return end
  input = input or ""
  local a, b, c, rest = input:match("^%s*start%s+(%d+)%s*(%d*)%s*(%d*)%s*(.*)$")
  if a then
    Begin({ min = tonumber(a), quests = tonumber(b), tasks = tonumber(c), msg = rest }, "Focus")
    return
  end
  local cmd = (input:match("^%s*(%S*)") or ""):lower()
  if cmd == "" or cmd == "setup" or cmd == "config" then
    setup:SetShown(not setup:IsShown())
  elseif cmd == "rotation" or cmd == "pomo" then StartRotationStep(1)
  elseif cmd == "skip" then Skip()
  elseif cmd == "stop" then Stop()
  elseif cmd == "pause" or cmd == "resume" then TogglePause()
  elseif cmd == "done" then AddTask()
  elseif cmd == "test" then ShowAlert("Work / chores complete!", "This is what your alarm looks like.")
  elseif cmd == "status" then
    if not s then Print("No session running.")
    else
      local r = Remaining()
      Print(s.label .. ": " .. (r and (FormatTime(r) .. " left. ") or "") ..
        (s.goalQ and ("Quests " .. s.q .. "/" .. s.goalQ .. ". ") or "") ..
        (s.goalT and ("Tasks " .. s.t .. "/" .. s.goalT .. ".") or ""))
    end
  elseif cmd == "reset" then
    DB.pos, DB.setupPos, DB.mmAngle = nil, nil, nil
    PlaceMinimapButton()
    RestorePos(hud, "pos", { "TOP", UIParent, "TOP", 0, -120 })
    RestorePos(setup, "setupPos", { "CENTER", UIParent, "CENTER", 0, 0 })
  else
    Print("/pf  - open setup")
    Print("/pf start <minutes> [quests] [tasks] [reminder]  (first goal reached wins)")
    Print("/pf rotation | skip | done | pause | resume | stop | status | test | reset")
  end
end
