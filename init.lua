-- ===========================================================
-- VK-01 旋钮 × Claude / GPT(Codex) 审批
--   单击旋钮（F13）：批准“当前模式”里正在等待的那一条请求；
--                   没有待审批请求时什么都不做。
--   双击旋钮：      在 Claude 模式 和 GPT 模式 之间切换。
--   菜单栏显示当前模式；有待审批时显示红点并响一声。
-- ===========================================================

local ax = require("hs.axuielement")

local HOME      = os.getenv("HOME")
local LOG_FILE  = HOME .. "/anticater_debug/hs_log.txt"
local DUMP_FILE = HOME .. "/anticater_debug/hs_dump.txt"
local MODE_KEY  = "vk01.mode"

local DOUBLE_PRESS_WINDOW = 0.35   -- 两次按下间隔小于这个秒数算双击
hs.menuIcon(false)   -- 隐藏小锤子图标，只保留我们自己的菜单栏图标
hs.autoLaunch(true)  -- 开机自动启动 Hammerspoon（旋钮程序随之启动）
local POLL_SECONDS        = 2      -- 每隔几秒检查一次是否有待审批

-- 各模式要盯的桌面应用
local MODE_APPS = {
  claude = { "com.anthropic.claudefordesktop" },
  gpt    = { "com.openai.codex" },
  doubao = { "com.bot.pc.doubao" },
}
local MODE_NAME = { claude = "Claude", gpt = "GPT", doubao = "豆包" }
local MODE_ORDER = { "claude", "gpt", "doubao" }   -- 双击旋钮按这个顺序轮流切换

-- Claude 模式下额外检查的终端（终端里的 Claude Code）
local TERMINALS = { "com.apple.Terminal", "com.googlecode.iterm2" }

-- 只有标题“完全等于”下面这些词的按钮才会被按（数字越小越优先）。
-- “Always allow / 始终允许”之类不在列表里，所以永远不会被按。
local APPROVE_PRIORITY = {
  ["allow once"] = 1, ["允许一次"] = 1, ["仅允许一次"] = 1, ["approve once"] = 1,
  ["allow for this session"] = 1.5, ["本次会话允许"] = 1.5,
  ["approve"] = 2, ["批准"] = 2,
  ["allow"] = 3, ["允许"] = 3,
  ["run"] = 4, ["运行"] = 4,
  ["yes"] = 5, ["是"] = 5, ["确认"] = 5,
  ["confirm"] = 5, ["确定"] = 5,
  ["allow this time"] = 1, ["仅此一次"] = 1,
}

-- ---------- 工具函数 ----------
local function log(...)
  local parts = {}
  for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
  local line = os.date("%H:%M:%S ") .. table.concat(parts, " ")
  print(line)
  local f = io.open(LOG_FILE, "a")
  if f then f:write(line .. "\n"); f:close() end
end

local function normalize(t)
  if not t then return "" end
  t = t:gsub("[\r\n\t]", " ")
  t = t:gsub("\xC2\xA0", " ")      -- 不换行空格
  t = t:gsub("\xE2\x80\xAF", " ")  -- 窄不换行空格
  t = t:gsub("\xE2\x80\x8B", "")   -- 零宽空格
  t = t:gsub("%s+", " ")
  -- 去掉结尾的快捷键提示，例如 "Allow once ⌘⏎"、"批准 (Enter)"
  t = t:gsub("%s*%(.-%)%s*$", "")
  -- 逐个去掉结尾的快捷键符号（按完整字符比较，避免切坏中文的 UTF-8 字节）
  local glyphs = { "⌘", "⏎", "↩", "⇧", "⌥", "⌃", " " }
  local changed = true
  while changed do
    changed = false
    for _, g in ipairs(glyphs) do
      if #t >= #g and t:sub(-#g) == g then t = t:sub(1, -#g - 1); changed = true end
    end
  end
  t = t:gsub("^%s+", "")
  t = t:gsub("%s+$", "")
  -- 去掉结尾的数字快捷键提示，例如 "Allow once 2"、"Deny 1"
  t = t:gsub("%s+%d%d?$", "")
  return t:lower()
end

local enabledAX = {}
local function appElement(app)
  local el = ax.applicationElement(app)
  if el and not enabledAX[app:pid()] then
    -- Electron 应用（Claude、Codex）需要这个开关才会暴露完整的界面结构
    pcall(function() el:setAttributeValue("AXManualAccessibility", true) end)
    enabledAX[app:pid()] = true
  end
  return el
end

local function buttonTitle(el)
  local t = el:attributeValue("AXTitle")
  if not t or t == "" then t = el:attributeValue("AXDescription") end
  if not t or t == "" then
    local kids = el:attributeValue("AXChildren") or {}
    local parts = {}
    for _, k in ipairs(kids) do
      local v = k:attributeValue("AXValue") or k:attributeValue("AXTitle")
      if type(v) == "string" and v ~= "" then parts[#parts + 1] = v end
    end
    t = table.concat(parts, " ")
  end
  return t or ""
end

local function collectButtons(el, out, budget, depth)
  if budget.n <= 0 or depth > 60 then return end
  budget.n = budget.n - 1
  local role = el:attributeValue("AXRole")
  if role == "AXButton" then
    local enabled = el:attributeValue("AXEnabled")
    out[#out + 1] = { el = el, title = buttonTitle(el), enabled = (enabled ~= false) }
  end
  local kids = el:attributeValue("AXChildren") or {}
  for _, k in ipairs(kids) do collectButtons(k, out, budget, depth + 1) end
end

local function appButtons(bundleID)
  local app = hs.application.get(bundleID)
  if not app then return {} end
  local el = appElement(app)
  if not el then return {} end
  local out, budget = {}, { n = 8000 }
  for _, w in ipairs(el:attributeValue("AXWindows") or {}) do
    collectButtons(w, out, budget, 0)
  end
  return out
end

-- 在一组应用里找“唯一一个最优先”的批准按钮
local function findApproveButton(bundleIDs)
  local best, bestP, tie = nil, 99, false
  for _, bid in ipairs(bundleIDs) do
    for _, b in ipairs(appButtons(bid)) do
      local p = APPROVE_PRIORITY[normalize(b.title)]
      if p and b.enabled then
        if p < bestP then best, bestP, tie = b, p, false
        elseif p == bestP then tie = true end
      end
    end
  end
  if tie then return nil, "ambiguous" end
  return best
end

-- 终端里的 Claude Code：屏幕末尾出现“Do you want to …”且光标停在“1. Yes”上
local function findTextArea(el, depth)
  if depth > 12 then return nil end
  if el:attributeValue("AXRole") == "AXTextArea" then return el end
  for _, k in ipairs(el:attributeValue("AXChildren") or {}) do
    local r = findTextArea(k, depth + 1)
    if r then return r end
  end
end

local function terminalClaudePrompt()
  for _, bid in ipairs(TERMINALS) do
    local app = hs.application.get(bid)
    if app then
      local win = app:focusedWindow() or app:mainWindow()
      if win then
        local ta = findTextArea(ax.windowElement(win), 0)
        local text = ta and ta:attributeValue("AXValue")
        if type(text) == "string" then
          local tail = text:sub(-2500)
          if tail:find("Do you want to") and tail:find("❯%s*1%.%s*Yes") then
            return app
          end
        end
      end
    end
  end
end

-- 对按钮做一次“真实鼠标点击”（正中间）。
-- 安全检查：该位置最上层的窗口必须属于目标应用，否则不点，返回 false。
local function clickViaMouse(el, mode)
  local ok, frame = pcall(function() return el:attributeValue("AXFrame") end)
  if not ok or type(frame) ~= "table" or not frame.w or frame.w <= 0 or frame.h <= 0 then
    return false, "无有效位置"
  end
  local pt = { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
  for _, w in ipairs(hs.window.orderedWindows()) do
    local f = w:frame()
    if pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h then
      local app = w:application()
      local bid = app and app:bundleID()
      for _, want in ipairs(MODE_APPS[mode]) do
        if bid == want then
          hs.eventtap.leftClick(pt)
          return true, string.format("鼠标点击 (%.0f,%.0f)", pt.x, pt.y)
        end
      end
      return false, "按钮被其他窗口盖住: " .. tostring(bid)
    end
  end
  return false, "按钮不在任何可见窗口内"
end

-- 当前模式下有没有待审批；返回一个“执行批准”的函数
local function pendingApproval(mode)
  local btn, why = findApproveButton(MODE_APPS[mode])
  if btn then
    return function()
      local clicked, how = clickViaMouse(btn.el, mode)
      if not clicked then
        btn.el:performAction("AXPress")
        how = "辅助功能按下（" .. tostring(how) .. "）"
      end
      log("执行方式:", how)
    end, "按钮「" .. btn.title .. "」"
  end
  if why == "ambiguous" then return nil, "ambiguous" end
  if mode == "claude" then
    local term = terminalClaudePrompt()
    if term then
      return function() hs.eventtap.keyStroke({}, "return", 0, term) end, "终端 Claude Code"
    end
  end
  return nil
end

-- ---------- 模式 & 菜单栏 ----------
local mode = hs.settings.get(MODE_KEY) or "claude"
if not MODE_APPS[mode] then mode = "claude" end
local menubar = hs.menubar.new()
local lastPending = false

-- 菜单栏图标：读取已安装应用自己的图标，右下角叠一个状态色点
local DOT_COLORS = {
  claude = {
    idle    = { white = 0.62, alpha = 1 },                          -- 灰
    running = { red = 0.85, green = 0.47, blue = 0.34, alpha = 1 }, -- 橙
    pending = { red = 0.20, green = 0.85, blue = 0.30, alpha = 1 }, -- 绿
  },
  gpt = {
    idle    = { white = 0.62, alpha = 1 },                          -- 灰
    running = { red = 0.25, green = 0.55, blue = 1.00, alpha = 1 }, -- 蓝
    pending = { red = 0.20, green = 0.85, blue = 0.30, alpha = 1 }, -- 绿
  },
  doubao = {
    idle    = { white = 0.62, alpha = 1 },                          -- 灰
    running = { red = 0.65, green = 0.40, blue = 0.95, alpha = 1 }, -- 紫
    pending = { red = 0.20, green = 0.85, blue = 0.30, alpha = 1 }, -- 绿
  },
}
local iconCache = {}
local function stateIcon(m, state)
  local key = m .. "/" .. state
  if iconCache[key] then return iconCache[key] end
  local col = (DOT_COLORS[m] or DOT_COLORS.claude)[state] or DOT_COLORS.claude.idle
  local c = hs.canvas.new({ x = 0, y = 0, w = 22, h = 22 })
  local appImg = hs.image.imageFromAppBundle(MODE_APPS[m][1])
  if appImg then
    c[1] = { type = "image", image = appImg, frame = { x = 1, y = 1, w = 18, h = 18 } }
  else
    c[1] = { type = "circle", action = "fill", fillColor = { white = 0.8 },
             center = { x = 10, y = 10 }, radius = 8 }
  end
  c[2] = { type = "circle", action = "strokeAndFill", strokeColor = { white = 0.1, alpha = 1 }, strokeWidth = 1.5,
           fillColor = col, center = { x = 16.5, y = 16.5 }, radius = 4.5 }
  local img = c:imageFromCanvas()
  c:delete()
  iconCache[key] = img
  return img
end

local function refreshMenubar(state)
  state = state or "idle"
  menubar:setTitle("")
  menubar:setIcon(stateIcon(mode, state), false)   -- false：保留颜色，不当模板图
  menubar:setTooltip("旋钮：" .. MODE_NAME[mode] .. " 模式")
end

-- 切换模式时弹出对应应用自己的图标（读取已安装应用的图标，不是自绘）
local badgeCanvas, badgeTimer = nil, nil
local function showModeBadge(m)
  local ok, err = pcall(function()
    if badgeTimer then badgeTimer:stop(); badgeTimer = nil end
    if badgeCanvas then badgeCanvas:delete(); badgeCanvas = nil end
    local img = hs.image.imageFromAppBundle(MODE_APPS[m][1])
    if not img then error("读不到应用图标") end
    local scr = hs.screen.mainScreen():frame()
    local w, h = 220, 220
    local c = hs.canvas.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 2, w = w, h = h })
    c:level(hs.canvas.windowLevels.overlay)
    c[1] = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 28, yRadius = 28 },
             fillColor = { white = 0.1, alpha = 0.82 } }
    c[2] = { type = "image", image = img, frame = { x = 50, y = 28, w = 120, h = 120 } }
    c[3] = { type = "text", text = hs.styledtext.new(MODE_NAME[m],
             { font = { size = 26 }, color = { white = 1 }, paragraphStyle = { alignment = "center" } }),
             frame = { x = 0, y = 156, w = w, h = 40 } }
    c:show(0.1)
    badgeCanvas = c
    badgeTimer = hs.timer.doAfter(1.3, function()
      if badgeCanvas then badgeCanvas:delete(0.25); badgeCanvas = nil end
    end)
  end)
  if not ok then
    log("图标弹窗失败:", tostring(err))
    hs.alert.show("旋钮已切换到 " .. MODE_NAME[m] .. " 模式", 1.2)
  end
end

local function toggleMode()
  local idx = 1
  for i, m in ipairs(MODE_ORDER) do if m == mode then idx = i end end
  mode = MODE_ORDER[(idx % #MODE_ORDER) + 1]
  hs.settings.set(MODE_KEY, mode)
  showModeBadge(mode)
  log("切换模式 ->", mode)
  refreshMenubar("idle")
end

local approvingUntil = 0   -- 批准进行中到什么时刻为止（用时间戳，不会卡死）
keepTimers = keepTimers or {}   -- 保存定时器引用，避免被系统回收

local function approve()
  if hs.timer.secondsSinceEpoch() < approvingUntil then
    log("批准进行中，忽略这次单击")
    return
  end
  local act, what = pendingApproval(mode)
  if act then
    approvingUntil = hs.timer.secondsSinceEpoch() + 2.5
    local okAct, errAct = pcall(act)
    if not okAct then log("执行出错:", tostring(errAct)) end
    log("已批准（" .. MODE_NAME[mode] .. "）:", what)
    hs.alert.show("✓ 已批准（" .. MODE_NAME[mode] .. "）", 0.8)
    -- 网页界面里的按钮第一下常常只是“碰到”，没有真正点下去：
    -- 0.8 秒后如果同一个按钮还在，就自动再按一次（只重试一次）
    local firstWhat = what
    keepTimers.retry = hs.timer.doAfter(0.8, function()
      local ok, again, what2 = pcall(pendingApproval, mode)
      if ok and again and what2 == firstWhat then
        log("第一次没点下去，自动再按一次:", what2)
        local okAgain, errAgain = pcall(again)
        if not okAgain then log("再按出错:", tostring(errAgain)) end
      end
    end)
  elseif what == "ambiguous" then
    log("有多个待审批按钮，未操作")
    hs.alert.show("有多个待审批，请手动处理", 1.2)
  else
    log("单击：当前没有待审批，未操作")
    -- 诊断：列出看起来像审批的按钮及其原始字节，方便排查名字对不上的原因
    pcall(function()
      for _, bid in ipairs(MODE_APPS[mode]) do
        for _, b in ipairs(appButtons(bid)) do
          local low = b.title:lower()
          if low:find("allow") or low:find("deny") or low:find("approve")
             or b.title:find("允许") or b.title:find("拒绝") or b.title:find("批准") then
            local hex = b.title:gsub(".", function(c) return string.format("%02x", c:byte()) end)
            log("候选按钮:", b.title, "| 启用:", tostring(b.enabled),
                "| 规范化:", normalize(b.title), "| hex:", hex:sub(1, 160))
          end
        end
      end
    end)
  end
end

-- 调试：把当前模式应用里所有按钮的标题写进文件，方便校准
local function dumpButtons()
  local f = io.open(DUMP_FILE, "w")
  if not f then return end
  f:write(os.date() .. "  模式=" .. mode .. "\n")
  for _, bid in ipairs(MODE_APPS[mode]) do
    f:write("== " .. bid .. "\n")
    for _, b in ipairs(appButtons(bid)) do
      f:write(string.format("  [%s] %q -> %q\n", b.enabled and "on" or "off", b.title, normalize(b.title)))
    end
  end
  f:close()
  hs.alert.show("按钮列表已写入 anticater_debug/hs_dump.txt", 1.5)
end

-- 旋钮灯光：调用 vk01.py 通过 USB 设置“涟漪”模式 + 单色色表（状态变化时才写）
local PY = "/usr/bin/python3"
local VK = HOME .. "/anticater_debug/vk01.py"
local LED_COLORS = { pending = "00ff00", running = "d97757", idle = "default" }
-- 待审批：模式2（常亮绿）；工作中：模式5（闪烁RGB）；空闲：模式3（平时灭，按下闪多彩）
local LED_MODES  = { pending = "2", running = "5", idle = "3" }
local ledWanted, ledApplied, ledBusy, ledLastTry = nil, nil, false, 0
local ledLastOk = 0     -- 上一次成功写入灯效的时间；超过 60 秒会再写一次（旋钮重插/掉线后灯会自己恢复）

local LED_ENABLED = true
local function ledSync()
  if not LED_ENABLED then return end
  if ledBusy or not ledWanted then return end
  local stale = (ledWanted == ledApplied) and (os.time() - ledLastOk >= 60)
  if ledWanted == ledApplied and not stale then return end
  local gap = (ledWanted == "pending") and 1 or 3
  if os.time() - ledLastTry < gap then return end
  ledBusy, ledLastTry = true, os.time()
  local want = ledWanted
  local t = hs.task.new(PY, function(code, out, err)
    ledBusy = false
    if code == 0 then ledApplied = want; ledLastOk = os.time() else ledLastOk = os.time() - 45 end
    if code ~= 0 or want ~= ledApplied or not stale then log("灯效", want, "退出码", tostring(code)) end
    if ledWanted ~= ledApplied then ledSync() end
  end, (function()
    local c = LED_COLORS[want] or want
    local a = { VK, "led", LED_MODES[want] or "3" }
    if c ~= "default" then a[#a + 1] = c end   -- default：不带色号，用出厂多彩色表
    return a
  end)())
  if t then
    t:start()
    keepTimers.ledTimeout = hs.timer.doAfter(8, function() if t:isRunning() then t:terminate(); log("灯效脚本超时，已结束") end end)
  else ledBusy = false; log("灯光：无法启动 python3") end
end

local function setLedState(state)
  ledWanted = state
  ledSync()
end

local function setLight(hex)           -- 菜单手动测试用
  ledWanted, ledApplied = hex, nil
  ledSync()
end

menubar:setMenu(function()
  return {
    { title = "当前模式：" .. MODE_NAME[mode], disabled = true },
    { title = "-" },
    { title = "重新加载配置", fn = hs.reload },
    { title = "查看运行记录（控制台）", fn = function() hs.openConsole() end },
    { title = "打开偏好设置", fn = function() hs.openPreferences() end },
    { title = "退出旋钮程序", fn = function()
        local app = hs.application.get("org.hammerspoon.Hammerspoon")
        if app then app:kill() end
      end },
  }
end)

-- 调试：把最前面应用的界面结构导出到文件（用来研究选择卡）。快捷键 ⌃⌥⌘9
local function dumpTree(outName)
  local front = hs.application.frontmostApplication()
  if not front then return end
  local f = io.open(HOME .. "/anticater_debug/" .. (outName or "hs_tree.txt"), "w")
  if not f then return end
  f:write(os.date() .. "  应用=" .. tostring(front:bundleID()) .. "\n")
  local el = appElement(front)
  local budget = { n = 6000 }
  local function walk(e, depth)
    if budget.n <= 0 or depth > 40 then return end
    budget.n = budget.n - 1
    local role = e:attributeValue("AXRole") or ""
    local sub = e:attributeValue("AXSubrole") or ""
    local title = e:attributeValue("AXTitle") or ""
    local desc = e:attributeValue("AXDescription") or ""
    local val = e:attributeValue("AXValue")
    if type(val) ~= "string" then val = (val ~= nil) and tostring(val) or "" end
    local sel = e:attributeValue("AXSelected")
    local foc = e:attributeValue("AXFocused")
    if title ~= "" or desc ~= "" or val ~= "" or role == "AXRadioButton" or role == "AXCheckBox"
       or role == "AXButton" or role == "AXRadioGroup" or role == "AXList" then
      f:write(string.rep(" ", depth) .. string.format("%s|%s| t=%q d=%q v=%q sel=%s foc=%s\n",
        role, sub, title:sub(1, 80), desc:sub(1, 80), val:sub(1, 80), tostring(sel), tostring(foc)))
    end
    for _, k in ipairs(e:attributeValue("AXChildren") or {}) do walk(k, depth + 1) end
  end
  for _, w in ipairs(el:attributeValue("AXWindows") or {}) do walk(w, 0) end
  f:close()
end
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "9", function() pcall(dumpTree) end)

-- ---------- 选择卡：转旋钮上下选，按一下确认（仅 Claude 桌面版）----------
-- 选项在界面里是 AXCheckBox|AXToggleButton；转动靠拦截音量键实现
choiceCache, choiceIdx, choiceCanvas, choiceMulti = nil, 1, nil, false

local function hideChoiceHighlight()
  if choiceCanvas then choiceCanvas:delete(); choiceCanvas = nil end
end

local choiceCanvasKey = nil
local function showChoiceHighlight()
  if not choiceCache then hideChoiceHighlight(); choiceCanvasKey = nil; return end
  local e = choiceCache[choiceIdx]
  if not e then hideChoiceHighlight(); choiceCanvasKey = nil; return end
  local ok, f = pcall(function() return e:attributeValue("AXFrame") end)
  if not ok or type(f) ~= "table" or not f.w or f.w <= 0 then hideChoiceHighlight(); choiceCanvasKey = nil; return end
  local key = string.format("%d|%.0f|%.0f|%.0f|%.0f", choiceIdx, f.x, f.y, f.w, f.h)
  if choiceCanvas and key == choiceCanvasKey then return end   -- 位置没变，不重画（避免闪烁）
  hideChoiceHighlight()
  choiceCanvasKey = key
  local c = hs.canvas.new({ x = f.x - 3, y = f.y - 3, w = f.w + 6, h = f.h + 6 })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[1] = { type = "rectangle", action = "stroke", strokeColor = { red = 0.2, green = 0.9, blue = 0.35, alpha = 1 },
           strokeWidth = 3, roundedRectRadii = { xRadius = 10, yRadius = 10 } }
  c:show()
  choiceCanvas = c
end

-- 在 Claude 窗口里找所有选项（耗时较长，只在轮询里调用，不在按键回调里调用）
local function findChoiceOptions()
  if mode ~= "claude" and mode ~= "gpt" then return nil end   -- 豆包暂不支持选择卡
  local app = hs.application.get(MODE_APPS[mode][1])
  if not app then return nil end
  local el = appElement(app)
  if not el then return nil end
  if mode == "gpt" then
    -- Codex：选项是 AXRadioGroup 里的 AXRadioButton，下面有“跳过”“发送”按钮
    local radios, skips, groups, budget = {}, {}, {}, { n = 6000 }
    local function walk(e, depth)
      if budget.n <= 0 or depth > 60 then return end
      budget.n = budget.n - 1
      local role = e:attributeValue("AXRole")
      if role == "AXRadioButton" then radios[#radios + 1] = e
      elseif role == "AXButton" then
        local t = e:attributeValue("AXTitle")
        if type(t) == "string" and (t:find("^跳过") or t:find("^Skip")) then skips[#skips + 1] = e end
      end
      for _, k in ipairs(e:attributeValue("AXChildren") or {}) do walk(k, depth + 1) end
    end
    for _, w in ipairs(el:attributeValue("AXWindows") or {}) do walk(w, 0) end
    local function vis(e)
      local okF, f = pcall(function() return e:attributeValue("AXFrame") end)
      if okF and type(f) == "table" and f.w and f.w > 0 and f.h and f.h > 0 then return f end
    end
    local anchor
    for _, b in ipairs(skips) do local f = vis(b); if f then anchor = f end end
    if not anchor then return nil end
    local best, bestD
    for _, e in ipairs(radios) do
      local f = vis(e)
      if f and f.y < anchor.y then
        local d = anchor.y - f.y
        if not bestD or d < bestD then best, bestD = e, d end
      end
    end
    if not best then return nil end
    local par = best:attributeValue("AXParent")
    local mine = {}
    for _, e in ipairs(radios) do
      if vis(e) and e:attributeValue("AXParent") == par then mine[#mine + 1] = e end
    end
    if #mine >= 2 then return mine end
    return nil
  end
  local out, skips, submits, budget = {}, {}, {}, { n = 6000 }
  local function walk(e, depth)
    if budget.n <= 0 or depth > 60 then return end
    budget.n = budget.n - 1
    local role = e:attributeValue("AXRole")
    if role == "AXCheckBox" then
      -- 选项一定有标题；点赞/复制等小按钮标题为空（只有描述），不算
      local t = e:attributeValue("AXTitle")
      if type(t) == "string" and t ~= "" then out[#out + 1] = e end
    elseif role == "AXButton" then
      local t = e:attributeValue("AXTitle")
      if type(t) == "string" and (t:find("^Skip") or t:find("^跳过")) then skips[#skips + 1] = e end
      local d = e:attributeValue("AXDescription")
      if t == "Submit" or t == "提交" or d == "Submit" or d == "提交" then submits[#submits + 1] = e end
    end
    for _, k in ipairs(e:attributeValue("AXChildren") or {}) do walk(k, depth + 1) end
  end
  for _, w in ipairs(el:attributeValue("AXWindows") or {}) do walk(w, 0) end
  local function vis(e)
    local okF, f = pcall(function() return e:attributeValue("AXFrame") end)
    if okF and type(f) == "table" and f.w and f.w > 0 and f.h and f.h > 0 then return f end
  end
  -- 以“Skip”按钮为锚点：只认它上方最近的那组选项（点赞/复制等按钮不会被选中）
  local anchor
  for _, b in ipairs(skips) do
    local f = vis(b)
    if f then anchor = f end
  end
  if anchor then
    local best, bestD
    for _, e in ipairs(out) do
      local f = vis(e)
      if f and f.y < anchor.y then
        local d = anchor.y - f.y
        if not bestD or d < bestD then best, bestD = e, d end
      end
    end
    if not best then return nil end
    local par = best:attributeValue("AXParent")
    local mine = {}
    for _, e in ipairs(out) do
      if vis(e) and e:attributeValue("AXParent") == par then mine[#mine + 1] = e end
    end
    if #mine < 2 then return nil end
    -- 多选卡：选项是没有 ToggleButton 子角色的复选框，末尾追加“Submit”按钮作为最后一格
    local multi = (mine[1]:attributeValue("AXSubrole") ~= "AXToggleButton")
    if multi then
      local sub
      for _, b in ipairs(submits) do
        local f = vis(b)
        if f and f.y >= anchor.y - 5 then sub = b end
      end
      if not sub then return nil end
      mine[#mine + 1] = sub
      return mine, true
    end
    return mine, false
  end
  -- 没有 Skip 锚点就不认（避免误选点赞/复制等按钮）
  if true then return nil end
  if #out == 0 then return nil end
  local lastParent = out[#out]:attributeValue("AXParent")
  local mine = {}
  for _, e in ipairs(out) do
    local okF, f = pcall(function() return e:attributeValue("AXFrame") end)
    local visible = okF and type(f) == "table" and f.w and f.w > 0 and f.h and f.h > 0
    local sameParent = (e:attributeValue("AXParent") == lastParent)
    if visible and sameParent then mine[#mine + 1] = e end
  end
  if #mine >= 2 then return mine end
end

local function refreshChoices(force)
  local front = hs.application.frontmostApplication()
  local isFront = front and MODE_APPS[mode] and front:bundleID() == MODE_APPS[mode][1]
  if isFront and (force or (mode == "claude" and (awaitingNow or skipSeen)) or mode == "gpt") then
    local opts, multi = findChoiceOptions()
    if opts then
      choiceMulti = multi and true or false
      awaitingNow = true   -- Codex 的选择卡也算“等待回答”：灯变绿、拦截音量键
      local wasNil = (choiceCache == nil)
      choiceCache = opts
      if wasNil then log("选择卡出现，共", #opts, "项") end
      if wasNil then choiceIdx = 1 end
      if choiceIdx > #opts then choiceIdx = #opts end
      showChoiceHighlight()
      return
    end
  end
  if choiceCache then log("选择卡已消失") end
  choiceCache, choiceIdx = nil, 1
  hideChoiceHighlight()
end

local function moveChoice(delta)
  if not choiceCache then return end
  choiceIdx = ((choiceIdx - 1 + delta) % #choiceCache) + 1
  showChoiceHighlight()
  log("选择卡：移到第", choiceIdx, "项")
end

local function confirmChoice()
  local e = choiceCache and choiceCache[choiceIdx]
  if not e then return false end
  local okT, title = pcall(function() return e:attributeValue("AXTitle") end)
  local clicked, how = clickViaMouse(e, mode)
  if not clicked then
    pcall(function() e:performAction("AXPress") end)
    how = "辅助功能按下（" .. tostring(how) .. "）"
  end
  log("选择卡：确认第", choiceIdx, "项「" .. tostring(okT and title or "?") .. "」", how)
  hs.alert.show("✓ 已选择", 0.8)
  local target = e
  if choiceMulti and mode == "claude" then
    -- 多选卡：点选项 = 勾上/取消；点最后一格（Submit）= 提交。不做补救回车
    if choiceIdx >= #choiceCache then
      choiceCache, choiceIdx = nil, 1
      hideChoiceHighlight()
      log("多选卡：已点击 Submit 提交")
    else
      log("多选卡：切换第", choiceIdx, "项")
      keepTimers.multiRefresh = hs.timer.doAfter(0.5, function() pcall(refreshChoices) end)
    end
    return true
  end
  choiceCache, choiceIdx = nil, 1
  hideChoiceHighlight()
  if mode == "gpt" then
    -- Codex：点完选项还要点“发送”才提交；找不到按钮就发回车
    keepTimers.codexSend = hs.timer.doAfter(0.5, function()
      pcall(function()
        local app = hs.application.get(MODE_APPS.gpt[1])
        local root = app and appElement(app)
        local sendBtn
        local function walk(x, d)
          if sendBtn or d > 60 then return end
          if x:attributeValue("AXRole") == "AXButton" and x:attributeValue("AXTitle") == "发送" then
            local f = x:attributeValue("AXFrame")
            if type(f) == "table" and f.w and f.w > 0 then sendBtn = x; return end
          end
          for _, k in ipairs(x:attributeValue("AXChildren") or {}) do walk(k, d + 1) end
        end
        if root then for _, w in ipairs(root:attributeValue("AXWindows") or {}) do walk(w, 0) end end
        if sendBtn then
          local ok2, how2 = clickViaMouse(sendBtn, "gpt")
          log("Codex 选择卡：点击发送", tostring(ok2), tostring(how2))
        else
          hs.eventtap.keyStroke({}, "return", 0, app)
          log("Codex 选择卡：没找到发送按钮，发送回车")
        end
      end)
    end)
    return true
  end
  -- 补救：默认带焦点的选项，点一下只是“选中”，卡片不会提交。
  -- 0.9 秒后如果卡片还在：已选中就发回车提交；没选中就再按一次，仍不行再发回车
  keepTimers.confirmA = hs.timer.doAfter(0.9, function()
    local ok1 = pcall(function()
      if not findChoiceOptions() then return end        -- 卡片已经提交，结束
      local v = target:attributeValue("AXValue")
      if v == 1 or v == "1" or v == true then
        log("选择卡仍在且已选中，发送回车提交")
        hs.eventtap.keyStroke({}, "return", 0, hs.application.get(MODE_APPS.claude[1]))
      else
        log("选择卡仍在且未选中，再按一次")
        target:performAction("AXPress")
        keepTimers.confirmB = hs.timer.doAfter(0.9, function()
          pcall(function()
            if findChoiceOptions() then
              log("选择卡仍在，发送回车提交")
              hs.eventtap.keyStroke({}, "return", 0, hs.application.get(MODE_APPS.claude[1]))
            end
          end)
        end)
      end
    end)
    if not ok1 then log("补救步骤出错") end
  end)
  return true
end

-- 拦截音量键：只在有选择卡时生效，否则放行（照常调音量）
choiceTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(ev)
  local ok, res = pcall(function()
    local sk = ev:systemKey()
    if not sk or not sk.key then return false end
    if sk.key ~= "SOUND_UP" and sk.key ~= "SOUND_DOWN" then return false end
    if sk.down then log("音量键事件", sk.key, "| 选择卡缓存:", tostring(choiceCache and #choiceCache or "无"), "| awaiting:", tostring(awaitingNow), "|", (awaitingNow and choiceCache) and "已拦截" or "放行") end
    if not (awaitingNow and choiceCache) then return false end
    if sk.down then log("拦截音量键", sk.key); moveChoice(sk.key == "SOUND_UP" and 1 or -1) end
    return true   -- 拦截，不让系统调音量
  end)
  return ok and res or false
end)
choiceTap:start()

-- 绿框跟随：有选择卡时每 0.5 秒复查一次；卡片消失 / 应用不在最前面就立刻撤掉绿框
keepTimers.choiceWatch = hs.timer.doEvery(0.5, function()
  if not choiceCache then return end
  pcall(function()
    local front = hs.application.frontmostApplication()
    local want = MODE_APPS[mode] and MODE_APPS[mode][1]
    if not front or front:bundleID() ~= want then
      log("选择卡：应用不在最前面，撤掉绿框")
      choiceCache, choiceIdx = nil, 1
      hideChoiceHighlight()
      return
    end
    refreshChoices(true)
  end)
end)

-- ---------- 旋钮：F13 单击 / 双击 ----------
local pressCount, pressTimer = 0, nil
hs.hotkey.bind({}, "f13", function()
  pressCount = pressCount + 1
  if pressTimer then pressTimer:stop() end
  pressTimer = hs.timer.doAfter(DOUBLE_PRESS_WINDOW, function()
    local n = pressCount
    pressCount, pressTimer = 0, nil
    if n >= 2 then
      toggleMode()
    else
      local okp, act = pcall(pendingApproval, mode)
      if okp and act then approve()
      elseif choiceCache and awaitingNow then confirmChoice()
      else approve() end
    end
  end)
end)

-- ---------- 定时检查待审批（菜单栏红点 + 提示音） ----------
local lastTitles = ""
awaitingNow, awaitingDumped, skipSeen = false, false, false
runningNow = false
runningUntil = 0
RUNNING_TITLES = { ["stop response"] = true, ["stop generating"] = true, ["停止响应"] = true, ["停止生成"] = true, ["停止回答"] = true, ["停止"] = true, ["stop"] = true }
-- 判断“正在工作”的停止按钮：中英文界面都认（“Stop response”“停止回复”“停止生成”“停止”……）
function isRunningTitle(t)
  local n = normalize(t)
  if RUNNING_TITLES[n] then return true end
  -- 只认短标题（避免把以 "STOP SCROLLING…" 开头的长文本误当成停止按钮）
  if #n <= 30 and (n:find("^stop") or n:find("^停止")) then return true end
  return false
end
pollTimer = hs.timer.doEvery(POLL_SECONDS, function()
  -- 自测通道：choice.test 里写 down / up / press / volup / voldown
  pcall(function()
    local tf = HOME .. "/anticater_debug/choice.test"
    local fh = io.open(tf, "r")
    if fh then
      local cmd = (fh:read("*l") or ""):gsub("%s+", "")
      fh:close(); os.remove(tf)
      log("自测指令:", cmd, "| 选择卡缓存:", tostring(choiceCache and #choiceCache or "无"), "| awaiting:", tostring(awaitingNow))
      if cmd == "down" then moveChoice(1)
      elseif cmd == "up" then moveChoice(-1)
      elseif cmd == "press" then log("自测确认结果:", tostring(confirmChoice()))
      elseif cmd == "volup" then hs.eventtap.event.newSystemKeyEvent("SOUND_UP", true):post(); hs.eventtap.event.newSystemKeyEvent("SOUND_UP", false):post()
      elseif cmd == "voldown" then hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", true):post(); hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", false):post()
      end
    end
  end)
  -- 音量诊断：vol.diag 里写 list（列出可能抢音量键的程序）/ off（暂停本程序的音量拦截）/ on（恢复）
  pcall(function()
    local tf = HOME .. "/anticater_debug/vol.diag"
    local fh = io.open(tf, "r")
    if fh then
      local cmd = (fh:read("*l") or ""):gsub("%s+", "")
      fh:close(); os.remove(tf)
      if cmd == "off" then choiceTap:stop(); log("音量诊断：已暂停本程序的音量拦截")
      elseif cmd == "on" then choiceTap:start(); log("音量诊断：已恢复本程序的音量拦截")
      elseif cmd == "list" then
        local out = hs.execute("/bin/ps -axo pid,comm | /usr/bin/grep -i -E 'spotify|music|karabiner|bettertouch|raycast|logi|alfred|linearmouse|steermouse|mos|hammerspoon|rcd|NowPlaying|touchbar|yabai|skhd|hyper|sound|volume|audio|soundsource|eqmac|bartender|monitorcontrol|lunar|betterdisplay|MediaKey|mediaremote|chrome|safari|firefox|zoom|teams|discord|IINA|vlc|QuickTime|Podcasts|TV|Notion|Obsidian' | /usr/bin/grep -v grep")
        log("音量诊断：可能相关的进程 ->", (out or ""):gsub("\n", " ; "))
        log("音量诊断：choiceTap 运行中:", tostring(choiceTap:isEnabled()), "| 输出设备:", tostring(hs.audiodevice.defaultOutputDevice() and hs.audiodevice.defaultOutputDevice():name()), "| 音量:", tostring(hs.audiodevice.defaultOutputDevice() and hs.audiodevice.defaultOutputDevice():volume()), "| 静音:", tostring(hs.audiodevice.defaultOutputDevice() and hs.audiodevice.defaultOutputDevice():muted()))
      end
    end
  end)
  -- 信号文件：存在 dump.now 就导出一次界面结构，然后删除信号文件
  pcall(function()
    local sig = HOME .. "/anticater_debug/dump.now"
    local fh = io.open(sig, "r")
    if fh then fh:close(); os.remove(sig); dumpTree() end
  end)
  -- 自动识别：最前面的应用是 Claude / Codex 时，自动切到对应模式
  pcall(function()
    if hs.settings.get("vk01.auto") ~= false then
      local front = hs.application.frontmostApplication()
      local fb = front and front:bundleID()
      for m, ids in pairs(MODE_APPS) do
        for _, bid in ipairs(ids) do
          if fb == bid and m ~= mode then
            mode = m
            hs.settings.set(MODE_KEY, mode)
            log("自动切换模式 ->", mode, "（最前面应用:", fb .. ")")
            refreshMenubar("idle")
          end
        end
      end
    end
  end)
  -- 诊断：当前模式的应用里，按钮标题一旦变化就记进日志（找出审批按钮的真实名字）
  pcall(function()
    local seen = {}
    for _, bid in ipairs(MODE_APPS[mode]) do
      for _, b in ipairs(appButtons(bid)) do
        if b.title ~= "" then seen[#seen + 1] = b.title end
      end
    end
    table.sort(seen)
    awaitingNow = false
    skipSeen = false
    for _, t in ipairs(seen) do
      if t:find("^Skip") or t:find("^跳过") then skipSeen = true end
    end
    -- 注意：不再用侧边栏的 “Awaiting input/answer” 判断（它会把别的对话的等待也算进来，造成误报）。
    -- “等待回答”只由真实检测到的选择卡来决定（见 refreshChoices）。
    if awaitingNow and not awaitingDumped then
      awaitingDumped = true
    elseif not awaitingNow then
      awaitingDumped = false
    end
    pcall(refreshChoices)
    runningNow = false
    for _, t in ipairs(seen) do
      if isRunningTitle(t) then runningNow = true end
    end
    if runningNow then runningUntil = os.time() + 5 end
    local joined = table.concat(seen, " | ")
    if joined ~= lastTitles then
      lastTitles = joined
      log("按钮变化[" .. mode .. "] 共" .. #seen .. "个:", joined:sub(1, 700))
      pcall(function()
        local tf = io.open(HOME .. "/anticater_debug/hs_titles.txt", "a")
        if tf then tf:write(os.date("%H:%M:%S") .. " [" .. mode .. "] " .. joined .. "\n"); tf:close() end
      end)
    end
  end)
  local ok, act = pcall(pendingApproval, mode)
  local pending = (ok and act ~= nil) or awaitingNow   -- 选择卡（Claude 在等您回答）也算待处理
  if pending and not lastPending then
    local s = hs.sound.getByName("Glass"); if s then s:play() end
  end
  lastPending = pending
  local state = pending and "pending" or ((runningNow or os.time() < runningUntil) and "running" or "idle")
  refreshMenubar(state)
  setLedState(state)
end)

refreshMenubar("idle")
log("VK-01 配置已加载，当前模式:", mode, "| 辅助功能权限:", tostring(hs.accessibilityState()))
for m, ids in pairs(MODE_APPS) do
  for _, bid in ipairs(ids) do
    log("应用", bid, hs.application.get(bid) and "正在运行" or "未运行")
  end
end
hs.alert.show("VK-01 旋钮已就绪（" .. MODE_NAME[mode] .. " 模式）", 1.2)
