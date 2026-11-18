--[[
    RUBO CHAT - BROOKHAVEN COMPATIBLE V2
    Based on Delta Global Chat Stable
    Firebase: community-chat-6daa7

    V4: compact mobile layout, locked premium effects, chat bubbles, Studio preview tab (contact: Discord sirrubo)

    Key fixes applied:
    - Robust GUI parenting (gethui → CoreGui → PlayerGui) + duplicate prevention + ResetOnSpawn = false
    - Mobile-friendly sizing + better drag handling
    - Safe Firebase request wrapper with timeout, status checks, rate limiting, null/JSON validation
    - Duplicate message prevention strengthened + ordering fixed
    - Custom in-GUI RUBO system notifications (no ChatMakeSystemMessage dependency)
    - Profile / likes / decorations / floating emoji cleanup + RenderStepped limited
    - DM sync + error handling improved
    - Promo system kept (7 min global + 2 min system) + enable/disable flag
    - Connection cleanup on close, reduced polling when not needed
    - Security notes: client-side "admin" is decorative only – real likes/unlocks must be validated server-side
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)

-- ===================== STYLE (bold font + helpers) =====================
local FONT = Enum.Font.GothamBold
local FONT_HEAVY = Enum.Font.GothamBlack

local function fit(obj, maxSize, minSize)
    obj.TextScaled = true
    local c = Instance.new("UITextSizeConstraint")
    c.MaxTextSize = maxSize or 16
    c.MinTextSize = minSize or 9
    c.Parent = obj
end

local function seq(...)
    local cols = {...}
    local n = #cols
    local pts = {}
    for i, c in ipairs(cols) do
        pts[#pts + 1] = ColorSequenceKeypoint.new((i - 1) / n, c)
    end
    pts[#pts + 1] = ColorSequenceKeypoint.new(1, cols[1])
    return ColorSequence.new(pts)
end

local function scrollToBottom(sf)
    task.spawn(function()
        RunService.Heartbeat:Wait()
        RunService.Heartbeat:Wait()
        if sf and sf.Parent then
            sf.CanvasPosition = Vector2.new(0, math.max(0, sf.AbsoluteCanvasSize.Y))
        end
    end)
end

local PF = {}   -- shared UI/FX references (kept in a table to save local slots)
local R = {size = 92, x = 22, y = 26}
R.cx = R.x + R.size / 2
R.cy = R.y + R.size / 2

-- phone / small screen => compact layout (narrower window, denser chat)
PF.compact = false
do
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    PF.compact = (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) or vp.X < 760
end
if PF.compact then
    PF.K = {title = 38, tab = 32, msgPad = 6, listPad = 4, scrollPad = 4, av = 28, head = 34,
        nameS = 15, subS = 11, txtS = 15, input = 42, nameH = 20, rw = 52, rh = 24, btn = 28, tabS = 13}
else
    PF.K = {title = 48, tab = 38, msgPad = 10, listPad = 8, scrollPad = 8, av = 38, head = 40,
        nameS = 16, subS = 12, txtS = 16, input = 48, nameH = 22, rw = 60, rh = 26, btn = 30, tabS = 15}
end

-- ===================== CONFIG =====================
local FIREBASE_URL = "https://community-chat-6daa7-default-rtdb.asia-southeast1.firebasedatabase.app"
local POLL_TIME = 1.5
local MAX_MSG = 45
local MAX_TEXT = 180
local MAX_BIO = 140
local OWNER_NAME = "world_ruler07"
local OWNER_LIKES = 10000000
local TYPING_TTL = 4
local PROMO_TIME = 420          -- 7 minutes
local SYSTEM_PROMO_TIME = 120   -- 2 minutes
local RATE_LIMIT_MS = 350

local ENABLE_GLOBAL_PROMO = true
local ENABLE_SYSTEM_PROMO = true

local PROMO_LINES = {
    "I AM USING RUBO CHAT ♥️",
    "🔥 RUBO CHAT ON TOP",
    "✨ Join the vibe — RUBO CHAT",
    "💜 Live on RUBO CHAT",
    "🚀 RUBO CHAT is the future",
    "💎 Using RUBO CHAT rn",
    "🌍 Global vibes only — RUBO CHAT",
    "⭐ RUBO CHAT elite status",
}

local RUBO_SYSTEM_MESSAGES = {
    "🔥 I AM USING RUBO CHAT!",
    "👑 RUBO ON TOP!",
    "🚀 POWERED BY RUBO!",
    "💎 RUBO CHAT IS THE FUTURE!",
    "⚡ JOIN THE RUBO COMMUNITY!",
    "🔥 ONLY RUBO VIBES!",
    "👑 RUBO NEVER STOPS!",
    "💬 EXPERIENCE RUBO CHAT!"
}

local EFFECTS = {
    {id = "Hearts",   emojis = {"❤️", "💖", "💕", "💗"},  mode = "float",    tint = Color3.fromRGB(255, 70, 130),  rate = 0.16,
        desc = "Soft hearts float up your card with a gentle sway."},
    {id = "Stars",    emojis = {"⭐", "✨", "🌟", "💫"},  mode = "twinkle",  tint = Color3.fromRGB(255, 215, 90),  rate = 0.12, shooting = true,
        desc = "Twinkling stars appear and fade, with an occasional shooting star."},
    {id = "Fire",     emojis = {"🔥", "✨", "💥"},        mode = "ember",    tint = Color3.fromRGB(255, 85, 20),   rate = 0.07,
        desc = "Embers and flames rise from the bottom of the card."},
    {id = "Unicorn",  emojis = {"🦄", "✨", "💖", "🌈"},  mode = "wave",     tint = Color3.fromRGB(255, 130, 230), rate = 0.14, rainbow = true,
        desc = "A rainbow wash with waving unicorn magic."},
    {id = "Sparkles", emojis = {"✨", "💎", "🌟"},        mode = "twinkle",  tint = Color3.fromRGB(255, 235, 150), rate = 0.09,
        desc = "Glittering gems and sparkles pop all around."},
    {id = "Galaxy",   emojis = {"🌌", "🪐", "✨", "🌙"},  mode = "orbit",    tint = Color3.fromRGB(110, 80, 255),  rate = 0.35,
        desc = "Planets and stars drift in wide orbits across the card."},
    {id = "Cool",     emojis = {"😎", "❄️", "💙", "⚡"},  mode = "snow",     tint = Color3.fromRGB(90, 190, 255),  rate = 0.22,
        desc = "Cool snowfall in icy blue."},
    {id = "Money",    emojis = {"💰", "💵", "🤑", "✨"},  mode = "rain",     tint = Color3.fromRGB(70, 220, 120),  rate = 0.16,
        desc = "It's raining cash."},
    {id = "Party",    emojis = {"🎉", "🎊", "🥳", "🎈"},  mode = "confetti", tint = Color3.fromRGB(255, 170, 60),  rate = 0.30,
        desc = "Confetti cannons and party poppers."},
    {id = "Skull",    emojis = {"💀", "🖤", "☠️", "🔥"},  mode = "ghost",    tint = Color3.fromRGB(190, 40, 60),   rate = 0.35,
        desc = "Ghostly skulls drift up out of the dark."},
    {id = "Love",     emojis = {"💘", "💝", "😍", "💞"},  mode = "swirl",    tint = Color3.fromRGB(255, 90, 160),  rate = 0.12,
        desc = "Hearts spiral outward from your avatar."},
    {id = "None",     emojis = {},                         mode = "none",     tint = Color3.fromRGB(255, 140, 40),  rate = 1,
        desc = "No effect. Clean and simple."},

    -- ===== PREMIUM (locked: owner unlocks) =====
    {id = "Lightning", locked = true, emojis = {"⚡", "🌩️", "💥"}, mode = "lightning", tint = Color3.fromRGB(80, 120, 255), rate = 1.3,
        desc = "Real lightning bolts strike across the card with a screen flash."},
    {id = "Matrix",    locked = true, emojis = {"0", "1", "7", "A", "Z", "#", "$", "%"}, mode = "matrix", tint = Color3.fromRGB(0, 255, 110), rate = 0.07,
        desc = "Green digital rain falls in glowing columns."},
    {id = "Aurora",    locked = true, emojis = {"✨", "💫", "🌌"}, mode = "aurora", tint = Color3.fromRGB(80, 255, 200), rate = 0.5, aurora = true,
        desc = "Colour-shifting northern lights ribbons sweep over the card."},
    {id = "BlackHole", locked = true, emojis = {"🌀", "☄️", "✨", "🪐"}, mode = "implode", tint = Color3.fromRGB(120, 40, 200), rate = 0.16,
        desc = "Everything spirals into a black hole at your avatar."},
    {id = "Sakura",    locked = true, emojis = {"🌸", "🌺", "🍃"}, mode = "sakura", tint = Color3.fromRGB(255, 150, 190), rate = 0.14,
        desc = "Cherry blossom petals flutter down in the wind."},
    {id = "Phoenix",   locked = true, emojis = {"🔥", "🦅", "✨", "🌅"}, mode = "phoenix", tint = Color3.fromRGB(255, 120, 30), rate = 0.12,
        desc = "A phoenix soars across the card trailing flames."},
    {id = "Glitch",    locked = true, emojis = {"👾", "💻", "📡", "⚠️"}, mode = "glitch", tint = Color3.fromRGB(0, 255, 220), rate = 0.22,
        desc = "Corrupted pixels, jittering icons and RGB glitch bars."},
    {id = "Nova",      locked = true, emojis = {"⭐", "💫", "✨", "🌟"}, mode = "nova", tint = Color3.fromRGB(255, 210, 90), rate = 1.4,
        desc = "A supernova pulse: shockwave ring plus a radial star explosion."},
}

-- Frames: animated gradient ring + pulsing halos + orbiting emojis + particle emitters
local DECORATIONS = {
    {id = "None", name = "None", color = Color3.fromRGB(255, 140, 40),
        grad = seq(Color3.fromRGB(255, 140, 40), Color3.fromRGB(255, 196, 110)),
        spin = 0.15, halo = 0, pulse = 1, orbit = {},
        desc = "A clean orange ring."},

    {id = "Gold", name = "Gold Frame", locked = true, color = Color3.fromRGB(255, 215, 0),
        grad = seq(Color3.fromRGB(255, 244, 170), Color3.fromRGB(255, 196, 40), Color3.fromRGB(160, 100, 0), Color3.fromRGB(255, 222, 90)),
        spin = 0.5, halo = 2, pulse = 1.4,
        orbit = {
            {e = "✨", r = 54, speed = 1.1, size = 15},
            {e = "✨", r = 54, speed = 1.1, size = 15, phase = math.pi},
            {e = "⭐", r = 58, speed = -0.7, size = 14, phase = 1.5},
        },
        emit = {emojis = {"✨"}, rate = 0.35, mode = "glint"},
        desc = "Spinning gold ring, pulsing halos and orbiting sparkles."},

    {id = "Neon", name = "Neon Frame", locked = true, color = Color3.fromRGB(0, 255, 200),
        grad = seq(Color3.fromRGB(0, 255, 200), Color3.fromRGB(0, 120, 255), Color3.fromRGB(200, 0, 255), Color3.fromRGB(0, 255, 200)),
        spin = 1.1, halo = 3, pulse = 3, flicker = true,
        orbit = {
            {e = "⚡", r = 55, speed = 2.2, size = 16},
            {e = "⚡", r = 55, speed = 2.2, size = 16, phase = math.pi},
        },
        desc = "Flickering cyan/magenta neon with fast orbiting bolts."},

    {id = "Diamond", name = "Diamond Frame", locked = true, color = Color3.fromRGB(185, 242, 255),
        grad = seq(Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 225, 255), Color3.fromRGB(210, 245, 255), Color3.fromRGB(120, 200, 255)),
        spin = 0.8, halo = 2, pulse = 2,
        orbit = {
            {e = "💎", r = 56, speed = 0.8, size = 17},
            {e = "✨", r = 56, speed = 0.8, size = 14, phase = 2.1},
            {e = "✨", r = 56, speed = 0.8, size = 14, phase = 4.2},
        },
        emit = {emojis = {"✨", "💎"}, rate = 0.22, mode = "glint"},
        desc = "Icy diamond shimmer with glints popping on the ring."},

    {id = "Royal", name = "Royal Frame", locked = true, color = Color3.fromRGB(180, 40, 255),
        grad = seq(Color3.fromRGB(190, 60, 255), Color3.fromRGB(255, 215, 80), Color3.fromRGB(110, 20, 200), Color3.fromRGB(255, 215, 80)),
        spin = 0.6, halo = 2, pulse = 1.6, crown = true,
        orbit = {
            {e = "✨", r = 55, speed = 0.6, size = 15},
            {e = "🔮", r = 55, speed = 0.6, size = 15, phase = math.pi},
        },
        emit = {emojis = {"✨"}, rate = 0.4, mode = "glint"},
        desc = "Purple and gold with a floating crown."},

    {id = "FireFrame", name = "Fire Frame", locked = true, color = Color3.fromRGB(255, 80, 20),
        grad = seq(Color3.fromRGB(255, 230, 80), Color3.fromRGB(255, 120, 20), Color3.fromRGB(220, 30, 10), Color3.fromRGB(255, 150, 30)),
        spin = 1.6, halo = 3, pulse = 5, flicker = true,
        orbit = {},
        emit = {emojis = {"🔥"}, rate = 0.09, mode = "ring_ember"},
        desc = "A burning ring that throws flames upward."},

    {id = "GalaxyFrame", name = "Galaxy Frame", locked = true, color = Color3.fromRGB(120, 60, 255),
        grad = seq(Color3.fromRGB(100, 60, 255), Color3.fromRGB(40, 200, 255), Color3.fromRGB(190, 80, 255), Color3.fromRGB(20, 20, 90)),
        spin = 0.45, halo = 3, pulse = 1.2,
        orbit = {
            {e = "🪐", r = 60, speed = 0.5, size = 22, ry = 0.5},
            {e = "⭐", r = 54, speed = -0.9, size = 14, phase = 1},
            {e = "🌙", r = 56, speed = 0.7, size = 16, phase = 3.6},
        },
        emit = {emojis = {"✨"}, rate = 0.2, mode = "glint"},
        desc = "Deep space colours, a ringed planet and a moon in orbit."},

    {id = "UnicornFrame", name = "Unicorn Frame", locked = true, color = Color3.fromRGB(255, 120, 220),
        grad = seq(Color3.fromRGB(255, 80, 80), Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 240, 80), Color3.fromRGB(80, 230, 120),
            Color3.fromRGB(80, 190, 255), Color3.fromRGB(150, 110, 255), Color3.fromRGB(255, 110, 220)),
        spin = 1.3, halo = 3, pulse = 2.2,
        orbit = {
            {e = "🦄", r = 58, speed = 0.6, size = 22},
            {e = "🌈", r = 52, speed = -0.8, size = 17, phase = 2},
            {e = "✨", r = 56, speed = 1.4, size = 14, phase = 4},
        },
        emit = {emojis = {"✨", "💖"}, rate = 0.18, mode = "glint"},
        desc = "Full rainbow ring with an orbiting unicorn."},
}

-- Chat bubbles
local BUBBLES = {
    {id = "Default", name = "Default", bg = Color3.fromRGB(34, 17, 12), text = Color3.fromRGB(248, 243, 238),
        desc = "The classic RUBO chat bubble."},
    {id = "Ocean", name = "Ocean", icon = "🌊", bg = Color3.fromRGB(10, 38, 70), stroke = Color3.fromRGB(70, 160, 255),
        text = Color3.fromRGB(222, 242, 255), desc = "Deep blue bubble with a cool ocean outline."},
    {id = "Sunset", name = "Sunset", icon = "🌇",
        grad = seq(Color3.fromRGB(90, 30, 70), Color3.fromRGB(130, 55, 40), Color3.fromRGB(90, 30, 70)), spin = 20,
        stroke = Color3.fromRGB(255, 140, 90), text = Color3.fromRGB(255, 236, 225),
        desc = "Warm purple-to-orange sunset gradient that slowly drifts."},
    {id = "Mint", name = "Mint", icon = "🍃", bg = Color3.fromRGB(12, 44, 34), stroke = Color3.fromRGB(80, 230, 170),
        text = Color3.fromRGB(225, 255, 242), desc = "Fresh mint green bubble."},

    {id = "Neon", name = "Neon", locked = true, icon = "⚡", bg = Color3.fromRGB(8, 10, 22),
        strokeGrad = seq(Color3.fromRGB(0, 255, 220), Color3.fromRGB(255, 0, 200), Color3.fromRGB(0, 255, 220)), flow = 140, strokeW = 2.2,
        text = Color3.fromRGB(190, 255, 250), desc = "Dark bubble with a flowing cyan/magenta neon border."},
    {id = "Gold", name = "Gold", locked = true, icon = "👑",
        grad = seq(Color3.fromRGB(70, 48, 6), Color3.fromRGB(150, 108, 22), Color3.fromRGB(70, 48, 6)), spin = 40,
        strokeGrad = seq(Color3.fromRGB(255, 244, 170), Color3.fromRGB(255, 196, 40), Color3.fromRGB(160, 100, 0)), flow = 80, strokeW = 2,
        text = Color3.fromRGB(255, 244, 205), desc = "Shimmering gold bubble with a rotating golden border."},
    {id = "Fire", name = "Fire", locked = true, icon = "🔥",
        grad = seq(Color3.fromRGB(60, 8, 4), Color3.fromRGB(160, 44, 10), Color3.fromRGB(60, 8, 4)), spin = 120,
        strokeGrad = seq(Color3.fromRGB(255, 230, 80), Color3.fromRGB(255, 90, 20), Color3.fromRGB(220, 30, 10), Color3.fromRGB(255, 150, 30)), flow = 220, strokeW = 2.2,
        text = Color3.fromRGB(255, 236, 215), desc = "A bubble that burns: flickering ember background and fast flame border."},
    {id = "Galaxy", name = "Galaxy", locked = true, icon = "🌌",
        grad = seq(Color3.fromRGB(16, 10, 48), Color3.fromRGB(56, 22, 110), Color3.fromRGB(10, 40, 90)), spin = 30,
        strokeGrad = seq(Color3.fromRGB(150, 100, 255), Color3.fromRGB(60, 210, 255), Color3.fromRGB(150, 100, 255)), flow = 60, strokeW = 2,
        text = Color3.fromRGB(232, 226, 255), desc = "Deep space gradient with a slow cosmic border."},
    {id = "Rainbow", name = "Rainbow", locked = true, icon = "🌈", bg = Color3.fromRGB(22, 14, 24),
        strokeGrad = seq(Color3.fromRGB(255, 80, 80), Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 240, 80), Color3.fromRGB(80, 230, 120),
            Color3.fromRGB(80, 190, 255), Color3.fromRGB(150, 110, 255), Color3.fromRGB(255, 110, 220)), flow = 160, strokeW = 2.4,
        text = Color3.fromRGB(255, 246, 250), desc = "A fast-spinning rainbow border."},
    {id = "Ice", name = "Ice", locked = true, icon = "❄️",
        grad = seq(Color3.fromRGB(210, 238, 255), Color3.fromRGB(150, 205, 245), Color3.fromRGB(210, 238, 255)), spin = 25,
        stroke = Color3.fromRGB(255, 255, 255), strokeW = 2, text = Color3.fromRGB(10, 34, 58),
        desc = "Frosty light bubble with dark text."},
}

PF.animGrads = {}
PF.bubbleById = function(id)
    for _, b in ipairs(BUBBLES) do
        if b.id == id then return b end
    end
    return BUBBLES[1]
end

-- styles a message bubble frame; returns the background transparency to use (nil = default look)
PF.applyBubble = function(f, id, txt, nameBtn)
    local b = PF.bubbleById(id)
    if b.id == "Default" then return nil end
    local function register(g, speed)
        local list = PF.animGrads
        list[#list + 1] = {g = g, speed = speed}
        if #list > 30 then table.remove(list, 1) end
    end
    if b.grad then
        f.BackgroundColor3 = Color3.new(1, 1, 1)
        local g = Instance.new("UIGradient")
        g.Color = b.grad
        g.Rotation = 45
        g.Parent = f
        if b.spin then register(g, b.spin) end
    else
        f.BackgroundColor3 = b.bg or f.BackgroundColor3
    end
    if b.stroke or b.strokeGrad then
        local st = f:FindFirstChildOfClass("UIStroke")
        if not st then
            st = Instance.new("UIStroke")
            st.Parent = f
        end
        st.Thickness = b.strokeW or 1.5
        st.Transparency = 0
        if b.strokeGrad then
            st.Color = Color3.new(1, 1, 1)
            local g2 = Instance.new("UIGradient")
            g2.Color = b.strokeGrad
            g2.Parent = st
            register(g2, b.flow or 90)
        else
            st.Color = b.stroke
        end
    end
    if txt and b.text then txt.TextColor3 = b.text end
    if nameBtn and b.icon and b.icon ~= "" then nameBtn.Text = b.icon .. " " .. nameBtn.Text end
    return b.alpha or 0
end

-- ===================== SAFE HTTP =====================
local httpRequest = (syn and syn.request) or http_request or (http and http.request) or request

local lastRequestTime = 0
local function safeRequest(method, url, body)
    if not httpRequest then
        return nil, 0, "no_http"
    end

    local now = tick()
    if now - lastRequestTime < (RATE_LIMIT_MS / 1000) then
        task.wait((RATE_LIMIT_MS / 1000) - (now - lastRequestTime))
    end
    lastRequestTime = tick()

    local payload = {
        Url = url,
        Method = method,
        Headers = {["Content-Type"] = "application/json"},
    }
    if body ~= nil then
        payload.Body = type(body) == "string" and body or HttpService:JSONEncode(body)
    end

    local resultBody, statusCode = nil, 0
    local ok, res = pcall(function()
        return httpRequest(payload)
    end)

    if ok and res then
        resultBody = res.Body
        statusCode = res.StatusCode or res.Status or 0
    end

    return resultBody, statusCode
end

local function safeJSON(body)
    if not body or body == "" or body == "null" then
        return nil
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if ok and type(data) == "table" and not data.error then
        return data
    end
    return nil
end

-- ===================== HELPERS =====================
local function isOwner(...)
    for i = 1, select("#", ...) do
        local n = select(i, ...)
        if type(n) == "string" and string.lower(n) == OWNER_NAME then
            return true
        end
    end
    return false
end

local function formatNumber(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local k
    while true do
        s, k = s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

local function headshot(userId)
    return "https://www.roblox.com/headshot-thumbnail/image?userId=" .. tostring(userId) .. "&width=150&height=150&format=png"
end

local function effectById(id)
    for _, e in ipairs(EFFECTS) do
        if e.id == id then return e end
    end
    return EFFECTS[1]
end

local function decorById(id)
    for _, d in ipairs(DECORATIONS) do
        if d.id == id then return d end
    end
    return DECORATIONS[1]
end

local function makeDMKey(id1, id2)
    id1, id2 = tonumber(id1) or 0, tonumber(id2) or 0
    if id1 < id2 then
        return tostring(id1) .. "_" .. tostring(id2)
    end
    return tostring(id2) .. "_" .. tostring(id1)
end

local function sanitizeText(text, maxLen)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > maxLen then
        text = text:sub(1, maxLen)
    end
    return text
end

-- ===================== GUI PARENT (Brookhaven safe) =====================
local function getGUIParent()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    if ok and hui then
        return hui
    end
    local ok2, cg = pcall(function()
        return CoreGui
    end)
    if ok2 and cg then
        return cg
    end
    return PlayerGui
end

local function destroyOldGUI()
    local parents = {PlayerGui}
    pcall(function()
        if CoreGui then table.insert(parents, CoreGui) end
    end)
    pcall(function()
        local h = gethui and gethui()
        if h then table.insert(parents, h) end
    end)
    for _, parent in ipairs(parents) do
        local old = parent:FindFirstChild("RUBOChatV2")
        if old then
            old:Destroy()
        end
    end
end
destroyOldGUI()

-- ===================== STATE =====================
local state = {
    lastTime = 0,
    sending = false,
    currentTab = "Chat",
    viewingUserId = LocalPlayer.UserId,
    myProfile = nil,
    viewingProfile = nil,
    likedCache = {},
    viewingEffect = "Hearts",
    editEffect = "Hearts",
    editDecor = "None",
    viewingDecor = "None",
    unlockedDecor = {None = true},
    nameHint = LocalPlayer.Name,
    ownerUserId = nil,
    order = 0,
    replyTo = nil,
    lastTypingPush = 0,
    promoIndex = 1,
    promoSending = false,
    dmTargetId = nil,
    dmLastTime = 0,
    dmOrder = 0,
    seenMessages = {},
    connections = {},
    isAlive = true,
}

local function track(conn)
    if conn then
        table.insert(state.connections, conn)
    end
end

local function cleanup()
    state.isAlive = false
    for _, c in ipairs(state.connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.connections)
end

-- ===================== UI CREATION =====================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RUBOChatV2"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 100
ScreenGui.Parent = getGUIParent()

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Size = PF.compact and UDim2.new(0.55, 0, 0.94, 0) or UDim2.new(0.48, 0, 0.84, 0)
Main.Position = UDim2.new(0.5, 0, 0.5, 0)
Main.BackgroundColor3 = Color3.fromRGB(14, 7, 5)
Main.BorderSizePixel = 0
Main.Active = true
Main.ClipsDescendants = true
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 18)

do
    local sc = Instance.new("UISizeConstraint")
    sc.MinSize = PF.compact and Vector2.new(280, 300) or Vector2.new(300, 360)
    sc.MaxSize = PF.compact and Vector2.new(400, 760) or Vector2.new(640, 820)
    sc.Parent = Main
    PF.sizeC = sc
end

local mainGrad = Instance.new("UIGradient")
mainGrad.Color = ColorSequence.new(Color3.fromRGB(34, 15, 9), Color3.fromRGB(6, 3, 2))
mainGrad.Rotation = 90
mainGrad.Parent = Main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.new(1, 1, 1)
mainStroke.Thickness = 2.5
mainStroke.Parent = Main

-- animated flowing border
PF.mainStrokeGrad = Instance.new("UIGradient")
PF.mainStrokeGrad.Color = seq(Color3.fromRGB(255, 120, 40), Color3.fromRGB(255, 200, 80), Color3.fromRGB(190, 80, 255), Color3.fromRGB(255, 120, 40))
PF.mainStrokeGrad.Parent = mainStroke

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, PF.K.title)
TitleBar.BackgroundTransparency = 1
TitleBar.Parent = Main

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -(PF.K.btn * 2 + 34), 1, 0)
Title.Position = UDim2.new(0, 14, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "RUBO Chat"
Title.TextColor3 = Color3.fromRGB(255, 244, 235)
Title.Font = FONT_HEAVY
Title.TextSize = PF.compact and 19 or 22
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextTruncate = Enum.TextTruncate.AtEnd
Title.Parent = TitleBar

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, PF.K.btn + 4, 0, PF.K.btn)
CloseBtn.Position = UDim2.new(1, -(PF.K.btn + 10), 0, (PF.K.title - PF.K.btn) / 2)
CloseBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 36)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.new(1, 1, 1)
CloseBtn.Font = FONT_HEAVY
CloseBtn.TextSize = 16
CloseBtn.Parent = TitleBar
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 8)

-- window size toggle (+ / -)
do
    local mode = "normal"
    local SizeBtn = Instance.new("TextButton")
    SizeBtn.Size = UDim2.new(0, PF.K.btn + 4, 0, PF.K.btn)
    SizeBtn.Position = UDim2.new(1, -(PF.K.btn * 2 + 18), 0, (PF.K.title - PF.K.btn) / 2)
    SizeBtn.BackgroundColor3 = Color3.fromRGB(70, 42, 34)
    SizeBtn.Text = "+"
    SizeBtn.TextColor3 = Color3.new(1, 1, 1)
    SizeBtn.Font = FONT_HEAVY
    SizeBtn.TextSize = 20
    SizeBtn.Parent = TitleBar
    Instance.new("UICorner", SizeBtn).CornerRadius = UDim.new(0, 8)

    local function targetSize()
        if PF.compact then
            if mode == "big" then
                PF.sizeC.MaxSize = Vector2.new(560, 760)
                return UDim2.new(0.8, 0, 0.96, 0)
            end
            PF.sizeC.MaxSize = Vector2.new(400, 760)
            return UDim2.new(0.55, 0, 0.94, 0)
        end
        if mode == "big" then return UDim2.new(0.64, 0, 0.94, 0) end
        return UDim2.new(0.48, 0, 0.84, 0)
    end
    Main.Size = targetSize()

    SizeBtn.MouseButton1Click:Connect(function()
        if mode == "big" then mode = "normal" else mode = "big" end
        SizeBtn.Text = (mode == "big") and "-" or "+"
        TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size = targetSize()}):Play()
    end)
end

-- Better drag (works on mobile + desktop, follows finger even outside title bar)
do
    local dragging = false
    local dragStart, startPos
    local function isPointer(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
    end
    track(TitleBar.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging = true
            dragStart = input.Position
            startPos = Main.Position
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then
            dragging = false
        end
    end))
end

-- Tabs
local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -16, 0, PF.K.tab)
TabBar.Position = UDim2.new(0, 8, 0, PF.K.title + 2)
TabBar.BackgroundColor3 = Color3.fromRGB(22, 11, 8)
TabBar.BorderSizePixel = 0
TabBar.Parent = Main
Instance.new("UICorner", TabBar).CornerRadius = UDim.new(0, 10)

local tabButtons = {}
local isOwnerPlayer = isOwner(LocalPlayer.Name)

-- is a locked effect / frame / bubble unlocked for this player? (owner has everything)
PF.isUnlocked = function(kind, item)
    if not item or not item.locked then return true end
    if isOwner(LocalPlayer.Name) then return true end
    local key = item.id
    if kind == "effect" then
        key = "fx_" .. item.id
    elseif kind == "bubble" then
        key = "bb_" .. item.id
    end
    return state.unlockedDecor[key] == true
end

local function createTabs()
    for _, b in pairs(tabButtons) do
        if b and b.Parent then b:Destroy() end
    end
    tabButtons = {}

    local list = {"Chat", "Leaderboard", "Profile", "Studio", "DM"}
    if isOwnerPlayer then
        table.insert(list, "Admin")
    end

    local total = #list
    for i, name in ipairs(list) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / total, -4, 1, -6)
        btn.Position = UDim2.new((i - 1) / total, 2, 0, 3)
        btn.BackgroundColor3 = Color3.fromRGB(22, 11, 8)
        btn.Text = (PF.compact and name == "Leaderboard") and "Top" or name
        btn.TextColor3 = Color3.fromRGB(190, 170, 160)
        btn.Font = FONT
        btn.TextSize = PF.K.tabS
        btn.AutoButtonColor = false
        btn.Parent = TabBar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
        fit(btn, PF.K.tabS, 8)
        tabButtons[name] = btn
    end
end
createTabs()

local Content = Instance.new("Frame")
Content.Size = UDim2.new(1, -16, 1, -(PF.K.title + PF.K.tab + 6 + 30))
Content.Position = UDim2.new(0, 8, 0, PF.K.title + PF.K.tab + 6)
Content.BackgroundTransparency = 1
Content.Parent = Main

-- ========== CHAT PAGE ==========
local ChatPage = Instance.new("Frame")
ChatPage.Size = UDim2.new(1, 0, 1, 0)
ChatPage.BackgroundTransparency = 1
ChatPage.Parent = Content

local ChatScroll = Instance.new("ScrollingFrame")
ChatScroll.Size = UDim2.new(1, 0, 1, -(PF.K.input + 6))
ChatScroll.BackgroundColor3 = Color3.fromRGB(9, 4, 3)
ChatScroll.BorderSizePixel = 0
ChatScroll.ScrollBarThickness = PF.compact and 3 or 4
ChatScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 140, 50)
ChatScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
ChatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
ChatScroll.ScrollingDirection = Enum.ScrollingDirection.Y
ChatScroll.Parent = ChatPage
Instance.new("UICorner", ChatScroll).CornerRadius = UDim.new(0, 12)

do
    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, PF.K.listPad)
    list.Parent = ChatScroll

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, PF.K.scrollPad)
    pad.PaddingLeft = UDim.new(0, PF.K.scrollPad)
    pad.PaddingRight = UDim.new(0, PF.K.scrollPad)
    pad.PaddingBottom = UDim.new(0, PF.K.scrollPad)
    pad.Parent = ChatScroll
end

-- Footer stack (typing label + reply bar + input) -> never overlaps the messages
local Footer = Instance.new("Frame")
Footer.AnchorPoint = Vector2.new(0, 1)
Footer.Position = UDim2.new(0, 0, 1, 0)
Footer.Size = UDim2.new(1, 0, 0, 0)
Footer.AutomaticSize = Enum.AutomaticSize.Y
Footer.BackgroundTransparency = 1
Footer.Parent = ChatPage

do
    local fl = Instance.new("UIListLayout")
    fl.SortOrder = Enum.SortOrder.LayoutOrder
    fl.Padding = UDim.new(0, 3)
    fl.Parent = Footer
end

local TypingLabel = Instance.new("TextLabel")
TypingLabel.Size = UDim2.new(1, -8, 0, 18)
TypingLabel.BackgroundTransparency = 1
TypingLabel.Text = ""
TypingLabel.TextColor3 = Color3.fromRGB(200, 182, 172)
TypingLabel.Font = FONT
TypingLabel.TextSize = PF.compact and 12 or 14
TypingLabel.TextXAlignment = Enum.TextXAlignment.Left
TypingLabel.Visible = false
TypingLabel.LayoutOrder = 1
TypingLabel.Parent = Footer

local ReplyBar = Instance.new("Frame")
ReplyBar.Size = UDim2.new(1, 0, 0, PF.compact and 28 or 34)
ReplyBar.BackgroundColor3 = Color3.fromRGB(36, 18, 14)
ReplyBar.BorderSizePixel = 0
ReplyBar.Visible = false
ReplyBar.LayoutOrder = 2
ReplyBar.Parent = Footer
Instance.new("UICorner", ReplyBar).CornerRadius = UDim.new(0, 8)

local ReplyInfo = Instance.new("TextLabel")
ReplyInfo.Size = UDim2.new(1, -46, 1, 0)
ReplyInfo.Position = UDim2.new(0, 10, 0, 0)
ReplyInfo.BackgroundTransparency = 1
ReplyInfo.Text = "Replying..."
ReplyInfo.TextColor3 = Color3.fromRGB(255, 196, 130)
ReplyInfo.Font = FONT
ReplyInfo.TextSize = PF.compact and 12 or 14
ReplyInfo.TextXAlignment = Enum.TextXAlignment.Left
ReplyInfo.TextTruncate = Enum.TextTruncate.AtEnd
ReplyInfo.Parent = ReplyBar

local ReplyCancel = Instance.new("TextButton")
ReplyCancel.Size = UDim2.new(0, 30, 0, 22)
ReplyCancel.Position = UDim2.new(1, -36, 0.5, -11)
ReplyCancel.BackgroundColor3 = Color3.fromRGB(90, 44, 34)
ReplyCancel.Text = "X"
ReplyCancel.TextColor3 = Color3.new(1, 1, 1)
ReplyCancel.Font = FONT
ReplyCancel.TextSize = 14
ReplyCancel.Parent = ReplyBar
Instance.new("UICorner", ReplyCancel).CornerRadius = UDim.new(0, 6)

local InputBar = Instance.new("Frame")
InputBar.Size = UDim2.new(1, 0, 0, PF.K.input)
InputBar.BackgroundColor3 = Color3.fromRGB(26, 13, 10)
InputBar.BorderSizePixel = 0
InputBar.LayoutOrder = 3
InputBar.Parent = Footer
Instance.new("UICorner", InputBar).CornerRadius = UDim.new(0, 12)
do
    local st = Instance.new("UIStroke")
    st.Color = Color3.fromRGB(255, 140, 50)
    st.Transparency = 0.6
    st.Thickness = 1
    st.Parent = InputBar
end

local MsgBox = Instance.new("TextBox")
MsgBox.Size = UDim2.new(1, -(PF.compact and 76 or 88), 1, -8)
MsgBox.Position = UDim2.new(0, 10, 0, 4)
MsgBox.BackgroundTransparency = 1
MsgBox.PlaceholderText = "Type a message..."
MsgBox.Text = ""
MsgBox.TextColor3 = Color3.fromRGB(250, 245, 240)
MsgBox.PlaceholderColor3 = Color3.fromRGB(150, 130, 120)
MsgBox.Font = FONT
MsgBox.TextSize = PF.K.txtS
MsgBox.ClearTextOnFocus = false
MsgBox.TextXAlignment = Enum.TextXAlignment.Left
MsgBox.Parent = InputBar

local SendBtn = Instance.new("TextButton")
SendBtn.Size = UDim2.new(0, PF.compact and 58 or 68, 0, PF.compact and 30 or 36)
SendBtn.Position = UDim2.new(1, -(PF.compact and 64 or 76), 0.5, -(PF.compact and 15 or 18))
SendBtn.BackgroundColor3 = Color3.new(1, 1, 1)
SendBtn.Text = "Send"
SendBtn.TextColor3 = Color3.new(1, 1, 1)
SendBtn.Font = FONT_HEAVY
SendBtn.TextSize = PF.compact and 14 or 16
SendBtn.Parent = InputBar
Instance.new("UICorner", SendBtn).CornerRadius = UDim.new(0, 10)
do
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(Color3.fromRGB(168, 85, 247), Color3.fromRGB(236, 72, 153))
    g.Rotation = 20
    g.Parent = SendBtn
end

-- Custom RUBO System Notification: pushes the chat down instead of covering it
local showSystemNotif
do
    local notifOffset = 0
    local notifToken = 0

    local SystemNotif = Instance.new("Frame")
    SystemNotif.Size = UDim2.new(1, 0, 0, 36)
    SystemNotif.Position = UDim2.new(0, 0, 0, 0)
    SystemNotif.BackgroundColor3 = Color3.fromRGB(0, 44, 38)
    SystemNotif.BorderSizePixel = 0
    SystemNotif.Visible = false
    SystemNotif.ZIndex = 5
    SystemNotif.Parent = ChatPage
    Instance.new("UICorner", SystemNotif).CornerRadius = UDim.new(0, 10)
    local nst = Instance.new("UIStroke")
    nst.Color = Color3.fromRGB(0, 255, 170)
    nst.Transparency = 0.4
    nst.Thickness = 1.2
    nst.Parent = SystemNotif

    local SystemNotifText = Instance.new("TextLabel")
    SystemNotifText.Size = UDim2.new(1, -20, 1, 0)
    SystemNotifText.Position = UDim2.new(0, 10, 0, 0)
    SystemNotifText.BackgroundTransparency = 1
    SystemNotifText.Text = ""
    SystemNotifText.TextColor3 = Color3.fromRGB(0, 255, 170)
    SystemNotifText.Font = FONT_HEAVY
    SystemNotifText.TextSize = 15
    SystemNotifText.TextXAlignment = Enum.TextXAlignment.Left
    SystemNotifText.ZIndex = 6
    SystemNotifText.Parent = SystemNotif
    fit(SystemNotifText, 15, 10)

    local function relayoutChat()
        local footerH = Footer.AbsoluteSize.Y
        ChatScroll.Position = UDim2.new(0, 0, 0, notifOffset)
        ChatScroll.Size = UDim2.new(1, 0, 1, -(footerH + 5 + notifOffset))
    end
    track(Footer:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutChat))
    task.defer(relayoutChat)

    showSystemNotif = function(msg)
        if not state.isAlive then return end
        notifToken = notifToken + 1
        local mine = notifToken
        SystemNotifText.Text = msg
        SystemNotif.Visible = true
        notifOffset = 42
        relayoutChat()
        task.delay(4.5, function()
            if mine ~= notifToken then return end
            if SystemNotif and SystemNotif.Parent then
                SystemNotif.Visible = false
                notifOffset = 0
                relayoutChat()
            end
        end)
    end
end

-- ========== LEADERBOARD ==========
local LBPage = Instance.new("Frame")
LBPage.Size = UDim2.new(1, 0, 1, 0)
LBPage.BackgroundTransparency = 1
LBPage.Visible = false
LBPage.Parent = Content

local LBScroll = Instance.new("ScrollingFrame")
LBScroll.Size = UDim2.new(1, 0, 1, 0)
LBScroll.BackgroundColor3 = Color3.fromRGB(8, 4, 3)
LBScroll.BorderSizePixel = 0
LBScroll.ScrollBarThickness = 3
LBScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 140, 50)
LBScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
LBScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
LBScroll.Parent = LBPage
Instance.new("UICorner", LBScroll).CornerRadius = UDim.new(0, 10)

local LBList = Instance.new("UIListLayout")
LBList.SortOrder = Enum.SortOrder.LayoutOrder
LBList.Padding = UDim.new(0, 8)
LBList.Parent = LBScroll

local LBPad = Instance.new("UIPadding")
LBPad.PaddingTop = UDim.new(0, 6)
LBPad.PaddingLeft = UDim.new(0, 6)
LBPad.PaddingRight = UDim.new(0, 6)
LBPad.Parent = LBScroll

-- ========== PROFILE ==========
local ProfilePage = Instance.new("ScrollingFrame")
ProfilePage.Size = UDim2.new(1, 0, 1, 0)
ProfilePage.BackgroundTransparency = 1
ProfilePage.BorderSizePixel = 0
ProfilePage.ScrollBarThickness = 4
ProfilePage.ScrollBarImageColor3 = Color3.fromRGB(255, 140, 50)
ProfilePage.CanvasSize = UDim2.new(0, 0, 0, 700)
ProfilePage.Visible = false
ProfilePage.Parent = Content

local ProfileCard = Instance.new("Frame")
ProfileCard.Size = UDim2.new(1, -8, 0, 700)
ProfileCard.BackgroundColor3 = Color3.fromRGB(22, 10, 6)
ProfileCard.BorderSizePixel = 0
ProfileCard.ClipsDescendants = true
ProfileCard.Parent = ProfilePage
Instance.new("UICorner", ProfileCard).CornerRadius = UDim.new(0, 14)

-- A "stage" = animated avatar ring + halos + orbiters + effect layers. Used by the Profile card AND the Studio preview.
PF.buildStage = function(card, cxs, cxo, cy)
    local S = {card = card, cxs = cxs, cxo = cxo, cy = cy, size = R.size, orbiters = {},
        decor = DECORATIONS[1], effectId = "Hearts"}
    local pos = UDim2.new(cxs, cxo, 0, cy)

    -- animated ambient colour wash (colour follows the selected effect)
    local amb = Instance.new("Frame")
    amb.Size = UDim2.new(1, 0, 1, 0)
    amb.BackgroundColor3 = Color3.new(1, 1, 1)
    amb.BorderSizePixel = 0
    amb.ZIndex = 1
    amb.Parent = card
    Instance.new("UICorner", amb).CornerRadius = UDim.new(0, 14)
    local ag = Instance.new("UIGradient")
    ag.Rotation = 90
    ag.Color = ColorSequence.new(Color3.fromRGB(255, 140, 40))
    ag.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0.94),
        NumberSequenceKeypoint.new(1, 0.7),
    })
    ag.Parent = amb
    S.ambient, S.ambientGrad = amb, ag

    -- layer BEHIND the avatar (orbiters pass behind it, shockwaves)
    local back = Instance.new("Frame")
    back.Size = UDim2.new(1, 0, 1, 0)
    back.BackgroundTransparency = 1
    back.Active = false
    back.ZIndex = 2
    back.Parent = card
    S.back = back

    -- pulsing glow halos
    S.halos = {}
    for i = 1, 3 do
        local size = R.size + 4 + i * 7
        local h = Instance.new("Frame")
        h.AnchorPoint = Vector2.new(0.5, 0.5)
        h.Position = pos
        h.Size = UDim2.fromOffset(size, size)
        h.BackgroundTransparency = 1
        h.BorderSizePixel = 0
        h.ZIndex = 2
        h.Visible = false
        h.Parent = card
        Instance.new("UICorner", h).CornerRadius = UDim.new(1, 0)
        local st = Instance.new("UIStroke")
        st.Color = Color3.new(1, 1, 1)
        st.Thickness = 2
        st.Transparency = 0.6
        st.Parent = h
        local g = Instance.new("UIGradient")
        g.Parent = st
        S.halos[i] = {frame = h, stroke = st, grad = g}
    end

    local emoji = Instance.new("Frame")
    emoji.Size = UDim2.new(1, 0, 1, 0)
    emoji.BackgroundTransparency = 1
    emoji.Active = false
    emoji.ZIndex = 6
    emoji.Parent = card
    S.emoji = emoji

    local flash = Instance.new("Frame")
    flash.Size = UDim2.new(1, 0, 1, 0)
    flash.BackgroundColor3 = Color3.new(1, 1, 1)
    flash.BackgroundTransparency = 1
    flash.BorderSizePixel = 0
    flash.Active = false
    flash.ZIndex = 10
    flash.Parent = card
    Instance.new("UICorner", flash).CornerRadius = UDim.new(0, 14)
    S.flash = flash

    local ring = Instance.new("Frame")
    ring.AnchorPoint = Vector2.new(0.5, 0.5)
    ring.Size = UDim2.fromOffset(R.size, R.size)
    ring.Position = pos
    ring.BackgroundColor3 = Color3.fromRGB(30, 14, 10)
    ring.BorderSizePixel = 0
    ring.ZIndex = 3
    ring.Parent = card
    Instance.new("UICorner", ring).CornerRadius = UDim.new(1, 0)
    local rs = Instance.new("UIStroke")
    rs.Color = Color3.new(1, 1, 1)
    rs.Thickness = 4
    rs.Parent = ring
    local rg = Instance.new("UIGradient")
    rg.Color = seq(Color3.fromRGB(255, 140, 40), Color3.fromRGB(255, 196, 110))
    rg.Parent = rs
    S.ring, S.ringStroke, S.ringGrad = ring, rs, rg

    local av = Instance.new("ImageButton")
    av.AnchorPoint = Vector2.new(0.5, 0.5)
    av.Size = UDim2.fromOffset(R.size - 14, R.size - 14)
    av.Position = pos
    av.BackgroundColor3 = Color3.fromRGB(40, 22, 18)
    av.BorderSizePixel = 0
    av.AutoButtonColor = false
    av.ZIndex = 4
    av.Image = headshot(LocalPlayer.UserId)
    av.Parent = card
    Instance.new("UICorner", av).CornerRadius = UDim.new(1, 0)
    local avs = Instance.new("UIScale")
    avs.Parent = av
    S.avatar, S.avatarScale = av, avs

    local crown = Instance.new("TextLabel")
    crown.AnchorPoint = Vector2.new(0.5, 0.5)
    crown.Size = UDim2.fromOffset(30, 26)
    crown.Position = UDim2.new(cxs, cxo, 0, cy - R.size / 2 - 6)
    crown.BackgroundTransparency = 1
    crown.Text = "👑"
    crown.TextSize = 22
    crown.ZIndex = 8
    crown.Visible = false
    crown.Parent = card
    S.crown = crown

    S.center = function()
        return card.AbsoluteSize.X * cxs + cxo, cy
    end
    return S
end

do
    local cardGrad = Instance.new("UIGradient")
    cardGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(48, 18, 10)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(18, 8, 6)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 3, 2)),
    })
    cardGrad.Rotation = 90
    cardGrad.Parent = ProfileCard
end

PF.s1 = PF.buildStage(ProfileCard, 0, R.cx, R.cy)
local Avatar = PF.s1.avatar

-- stats (likes / effect) - tidy boxes, no overlap
local LikesNum, LikesCap, EffectStat, EffectCap
do
    local row = Instance.new("Frame")
    row.Position = UDim2.new(0, 150, 0, 32)
    row.Size = UDim2.new(1, -164, 0, 68)
    row.BackgroundTransparency = 1
    row.ZIndex = 4
    row.Parent = ProfileCard

    local function statBox(xs, xo, numSize)
        local box = Instance.new("Frame")
        box.Size = UDim2.new(0.5, -4, 1, 0)
        box.Position = UDim2.new(xs, xo, 0, 0)
        box.BackgroundColor3 = Color3.fromRGB(38, 18, 12)
        box.BackgroundTransparency = 0.25
        box.BorderSizePixel = 0
        box.ZIndex = 4
        box.Parent = row
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 12)
        local st = Instance.new("UIStroke")
        st.Color = Color3.fromRGB(255, 140, 50)
        st.Transparency = 0.7
        st.Thickness = 1
        st.Parent = box

        local num = Instance.new("TextLabel")
        num.Size = UDim2.new(1, -10, 0, 36)
        num.Position = UDim2.new(0, 5, 0, 6)
        num.BackgroundTransparency = 1
        num.TextColor3 = Color3.fromRGB(255, 246, 238)
        num.Font = FONT_HEAVY
        num.TextSize = numSize
        num.ZIndex = 4
        num.Parent = box
        fit(num, numSize, 11)

        local cap = Instance.new("TextLabel")
        cap.Size = UDim2.new(1, -10, 0, 20)
        cap.Position = UDim2.new(0, 5, 0, 42)
        cap.BackgroundTransparency = 1
        cap.TextColor3 = Color3.fromRGB(200, 182, 172)
        cap.Font = FONT
        cap.TextSize = 14
        cap.ZIndex = 4
        cap.Parent = box
        fit(cap, 14, 9)
        return num, cap
    end

    LikesNum, LikesCap = statBox(0, 0, 26)
    EffectStat, EffectCap = statBox(0.5, 4, 20)
    LikesNum.Text = "0"
    LikesCap.Text = "Likes"
    EffectStat.Text = "Hearts"
    EffectCap.Text = "Effect"
end

local UnicornMark = Instance.new("TextLabel")
UnicornMark.Size = UDim2.fromOffset(26, 26)
UnicornMark.Position = UDim2.fromOffset(16, 146)
UnicornMark.BackgroundTransparency = 1
UnicornMark.Text = "🦄"
UnicornMark.TextSize = 20
UnicornMark.Visible = false
UnicornMark.ZIndex = 4
UnicornMark.Parent = ProfileCard

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.fromOffset(76, 26)
TitleLabel.Position = UDim2.fromOffset(44, 146)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "OWNER"
TitleLabel.TextColor3 = Color3.fromRGB(255, 170, 60)
TitleLabel.Font = FONT_HEAVY
TitleLabel.TextSize = 16
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Visible = false
TitleLabel.ZIndex = 4
TitleLabel.Parent = ProfileCard

local NameLabel = Instance.new("TextLabel")
NameLabel.Size = UDim2.new(1, -32, 0, 26)
NameLabel.Position = UDim2.new(0, 16, 0, 146)
NameLabel.BackgroundTransparency = 1
NameLabel.Text = LocalPlayer.Name
NameLabel.TextColor3 = Color3.fromRGB(250, 245, 240)
NameLabel.Font = FONT_HEAVY
NameLabel.TextSize = 20
NameLabel.TextXAlignment = Enum.TextXAlignment.Left
NameLabel.TextTruncate = Enum.TextTruncate.AtEnd
NameLabel.ZIndex = 4
NameLabel.Parent = ProfileCard

local HandleLabel = Instance.new("TextLabel")
HandleLabel.Size = UDim2.new(1, -32, 0, 20)
HandleLabel.Position = UDim2.new(0, 16, 0, 174)
HandleLabel.BackgroundTransparency = 1
HandleLabel.Text = "@" .. LocalPlayer.Name
HandleLabel.TextColor3 = Color3.fromRGB(185, 165, 155)
HandleLabel.Font = FONT
HandleLabel.TextSize = 15
HandleLabel.TextXAlignment = Enum.TextXAlignment.Left
HandleLabel.TextTruncate = Enum.TextTruncate.AtEnd
HandleLabel.ZIndex = 4
HandleLabel.Parent = ProfileCard

do
    local div = Instance.new("Frame")
    div.Size = UDim2.new(1, -32, 0, 2)
    div.Position = UDim2.new(0, 16, 0, 200)
    div.BackgroundColor3 = Color3.fromRGB(140, 80, 44)
    div.BackgroundTransparency = 0.5
    div.BorderSizePixel = 0
    div.ZIndex = 4
    div.Parent = ProfileCard
end

local BioLabel = Instance.new("TextLabel")
BioLabel.Size = UDim2.new(1, -32, 0, 64)
BioLabel.Position = UDim2.new(0, 16, 0, 212)
BioLabel.BackgroundTransparency = 1
BioLabel.Text = "No bio yet"
BioLabel.TextColor3 = Color3.fromRGB(228, 214, 204)
BioLabel.Font = FONT
BioLabel.TextSize = 16
BioLabel.TextWrapped = true
BioLabel.TextXAlignment = Enum.TextXAlignment.Left
BioLabel.TextYAlignment = Enum.TextYAlignment.Top
BioLabel.TextTruncate = Enum.TextTruncate.AtEnd
BioLabel.ZIndex = 4
BioLabel.Parent = ProfileCard

local LikeBtn = Instance.new("TextButton")
LikeBtn.Size = UDim2.new(1, -32, 0, 46)
LikeBtn.Position = UDim2.new(0, 16, 0, 288)
LikeBtn.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
LikeBtn.Text = "Like"
LikeBtn.TextColor3 = Color3.new(1, 1, 1)
LikeBtn.Font = FONT_HEAVY
LikeBtn.TextSize = 18
LikeBtn.ZIndex = 5
LikeBtn.Parent = ProfileCard
Instance.new("UICorner", LikeBtn).CornerRadius = UDim.new(0, 12)

-- Edit section (row heights are computed from the item counts -> grids can never overlap each other)
local EditHolder = Instance.new("Frame")
EditHolder.Size = UDim2.new(1, -32, 0, 700)
EditHolder.Position = UDim2.new(0, 16, 0, 212)
EditHolder.BackgroundTransparency = 1
EditHolder.Visible = false
EditHolder.ZIndex = 5
EditHolder.Parent = ProfileCard

local BioBox, SaveBtn
local effectButtons = {}
local decorButtons = {}
local bubbleButtons = {}
do
    local total = 0
    local order = 0
    local function nextOrder()
        order = order + 1
        return order
    end
    local function reserve(h)
        total = total + h + 6
    end

    local lay = Instance.new("UIListLayout")
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Padding = UDim.new(0, 6)
    lay.Parent = EditHolder

    local function hint(text)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 18)
        l.BackgroundTransparency = 1
        l.Text = text
        l.TextColor3 = Color3.fromRGB(205, 186, 176)
        l.Font = FONT
        l.TextSize = 14
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.LayoutOrder = nextOrder()
        l.Parent = EditHolder
        reserve(18)
    end

    local function gridRow(cols, count, store, list, labelOf)
        local rows = math.ceil(count / cols)
        local h = rows * 30 + (rows - 1) * 6
        local holder = Instance.new("Frame")
        holder.Size = UDim2.new(1, 0, 0, h)
        holder.BackgroundTransparency = 1
        holder.LayoutOrder = nextOrder()
        holder.Parent = EditHolder
        local g = Instance.new("UIGridLayout")
        g.CellSize = UDim2.new(1 / cols, -(cols - 1) * 6 / cols, 0, 30)
        g.CellPadding = UDim2.new(0, 6, 0, 6)
        g.SortOrder = Enum.SortOrder.LayoutOrder
        g.Parent = holder
        for i, it in ipairs(list) do
            local btn = Instance.new("TextButton")
            btn.BackgroundColor3 = Color3.fromRGB(30, 15, 11)
            btn.Text = labelOf(it)
            btn.TextColor3 = Color3.fromRGB(205, 186, 176)
            btn.Font = FONT
            btn.TextSize = 14
            btn.LayoutOrder = i
            btn.Parent = holder
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
            fit(btn, 14, 9)
            store[it.id] = btn
        end
        reserve(h)
    end

    hint("Your bio")

    BioBox = Instance.new("TextBox")
    BioBox.Size = UDim2.new(1, 0, 0, 40)
    BioBox.BackgroundColor3 = Color3.fromRGB(18, 9, 7)
    BioBox.Text = ""
    BioBox.PlaceholderText = "Write your bio"
    BioBox.TextColor3 = Color3.fromRGB(250, 245, 240)
    BioBox.PlaceholderColor3 = Color3.fromRGB(150, 130, 120)
    BioBox.Font = FONT
    BioBox.TextSize = 16
    BioBox.ClearTextOnFocus = false
    BioBox.TextXAlignment = Enum.TextXAlignment.Left
    BioBox.LayoutOrder = nextOrder()
    BioBox.Parent = EditHolder
    Instance.new("UICorner", BioBox).CornerRadius = UDim.new(0, 8)
    local bp = Instance.new("UIPadding")
    bp.PaddingLeft = UDim.new(0, 10)
    bp.PaddingRight = UDim.new(0, 10)
    bp.Parent = BioBox
    reserve(40)

    hint("Profile effect  (🔒 = locked, preview in Studio)")
    gridRow(3, #EFFECTS, effectButtons, EFFECTS, function(e) return e.id end)

    hint("Profile Frame (High Level)")
    gridRow(2, #DECORATIONS, decorButtons, DECORATIONS, function(d)
        return (d.id ~= "None") and ("🔒 " .. d.name) or d.name
    end)

    hint("Chat bubble")
    gridRow(2, #BUBBLES, bubbleButtons, BUBBLES, function(b) return b.name end)

    SaveBtn = Instance.new("TextButton")
    SaveBtn.Size = UDim2.new(1, 0, 0, 44)
    SaveBtn.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
    SaveBtn.Text = "Save"
    SaveBtn.TextColor3 = Color3.new(1, 1, 1)
    SaveBtn.Font = FONT_HEAVY
    SaveBtn.TextSize = 17
    SaveBtn.LayoutOrder = nextOrder()
    SaveBtn.Parent = EditHolder
    Instance.new("UICorner", SaveBtn).CornerRadius = UDim.new(0, 12)
    reserve(44)

    EditHolder.Size = UDim2.new(1, -32, 0, total)
end

PF.highlightBubbles = function()
    for id, btn in pairs(bubbleButtons) do
        local b = PF.bubbleById(id)
        local on = id == (state.editBubble or "Default")
        local unlocked = PF.isUnlocked("bubble", b)
        btn.Text = (unlocked and "" or "🔒 ") .. b.name
        if on then
            btn.BackgroundColor3 = Color3.fromRGB(255, 132, 40)
            btn.TextColor3 = Color3.new(1, 1, 1)
        else
            btn.BackgroundColor3 = unlocked and Color3.fromRGB(30, 15, 11) or Color3.fromRGB(40, 20, 18)
            btn.TextColor3 = unlocked and (b.stroke or Color3.fromRGB(205, 186, 176)):Lerp(Color3.new(1, 1, 1), 0.35) or Color3.fromRGB(120, 100, 90)
        end
    end
end

-- ========== DM PAGE ==========
local DMPage = Instance.new("Frame")
DMPage.Size = UDim2.new(1, 0, 1, 0)
DMPage.BackgroundTransparency = 1
DMPage.Visible = false
DMPage.Parent = Content

local DMListFrame = Instance.new("Frame")
DMListFrame.Size = UDim2.new(0.38, 0, 1, 0)
DMListFrame.BackgroundColor3 = Color3.fromRGB(8, 4, 3)
DMListFrame.BorderSizePixel = 0
DMListFrame.Parent = DMPage
Instance.new("UICorner", DMListFrame).CornerRadius = UDim.new(0, 10)

local DMListTitle = Instance.new("TextLabel")
DMListTitle.Size = UDim2.new(1, -8, 0, 26)
DMListTitle.Position = UDim2.new(0, 6, 0, 4)
DMListTitle.BackgroundTransparency = 1
DMListTitle.Text = "Liked You"
DMListTitle.TextColor3 = Color3.fromRGB(255, 180, 100)
DMListTitle.Font = FONT
DMListTitle.TextSize = 15
DMListTitle.TextXAlignment = Enum.TextXAlignment.Left
DMListTitle.Parent = DMListFrame

local DMScroll = Instance.new("ScrollingFrame")
DMScroll.Size = UDim2.new(1, -6, 1, -34)
DMScroll.Position = UDim2.new(0, 3, 0, 30)
DMScroll.BackgroundTransparency = 1
DMScroll.BorderSizePixel = 0
DMScroll.ScrollBarThickness = 3
DMScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
DMScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
DMScroll.Parent = DMListFrame

local DMListLayout = Instance.new("UIListLayout")
DMListLayout.SortOrder = Enum.SortOrder.LayoutOrder
DMListLayout.Padding = UDim.new(0, 4)
DMListLayout.Parent = DMScroll

local DMChatFrame = Instance.new("Frame")
DMChatFrame.Size = UDim2.new(0.60, 0, 1, 0)
DMChatFrame.Position = UDim2.new(0.40, 0, 0, 0)
DMChatFrame.BackgroundColor3 = Color3.fromRGB(8, 4, 3)
DMChatFrame.BorderSizePixel = 0
DMChatFrame.Parent = DMPage
Instance.new("UICorner", DMChatFrame).CornerRadius = UDim.new(0, 10)

local DMChatTitle = Instance.new("TextLabel")
DMChatTitle.Size = UDim2.new(1, -8, 0, 26)
DMChatTitle.Position = UDim2.new(0, 6, 0, 4)
DMChatTitle.BackgroundTransparency = 1
DMChatTitle.Text = "Select someone"
DMChatTitle.TextColor3 = Color3.fromRGB(245, 240, 235)
DMChatTitle.Font = FONT
DMChatTitle.TextSize = 15
DMChatTitle.TextXAlignment = Enum.TextXAlignment.Left
DMChatTitle.TextTruncate = Enum.TextTruncate.AtEnd
DMChatTitle.Parent = DMChatFrame

local DMMsgScroll = Instance.new("ScrollingFrame")
DMMsgScroll.Size = UDim2.new(1, -6, 1, -74)
DMMsgScroll.Position = UDim2.new(0, 3, 0, 30)
DMMsgScroll.BackgroundTransparency = 1
DMMsgScroll.BorderSizePixel = 0
DMMsgScroll.ScrollBarThickness = 3
DMMsgScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
DMMsgScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
DMMsgScroll.Parent = DMChatFrame

local DMMsgList = Instance.new("UIListLayout")
DMMsgList.SortOrder = Enum.SortOrder.LayoutOrder
DMMsgList.Padding = UDim.new(0, 5)
DMMsgList.Parent = DMMsgScroll

local DMInputBar = Instance.new("Frame")
DMInputBar.Size = UDim2.new(1, -6, 0, 36)
DMInputBar.Position = UDim2.new(0, 3, 1, -40)
DMInputBar.BackgroundColor3 = Color3.fromRGB(24, 12, 10)
DMInputBar.BorderSizePixel = 0
DMInputBar.Parent = DMChatFrame
Instance.new("UICorner", DMInputBar).CornerRadius = UDim.new(0, 6)

local DMMsgBox = Instance.new("TextBox")
DMMsgBox.Size = UDim2.new(1, -64, 1, -4)
DMMsgBox.Position = UDim2.new(0, 6, 0, 2)
DMMsgBox.BackgroundTransparency = 1
DMMsgBox.PlaceholderText = "Message..."
DMMsgBox.Text = ""
DMMsgBox.TextColor3 = Color3.fromRGB(245, 240, 235)
DMMsgBox.PlaceholderColor3 = Color3.fromRGB(140, 120, 110)
DMMsgBox.Font = FONT
DMMsgBox.TextSize = 15
DMMsgBox.ClearTextOnFocus = false
DMMsgBox.Parent = DMInputBar

local DMSendBtn = Instance.new("TextButton")
DMSendBtn.Size = UDim2.new(0, 50, 0, 26)
DMSendBtn.Position = UDim2.new(1, -54, 0, 5)
DMSendBtn.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
DMSendBtn.Text = "Send"
DMSendBtn.TextColor3 = Color3.new(1, 1, 1)
DMSendBtn.Font = FONT
DMSendBtn.TextSize = 14
DMSendBtn.Parent = DMInputBar
Instance.new("UICorner", DMSendBtn).CornerRadius = UDim.new(0, 5)

-- ========== ADMIN PAGE ==========
local AdminPage = Instance.new("Frame")
AdminPage.Size = UDim2.new(1, 0, 1, 0)
AdminPage.BackgroundTransparency = 1
AdminPage.Visible = false
AdminPage.Parent = Content

local AdminCard = Instance.new("ScrollingFrame")
AdminCard.Size = UDim2.new(1, 0, 1, 0)
AdminCard.BackgroundColor3 = Color3.fromRGB(18, 8, 6)
AdminCard.BorderSizePixel = 0
AdminCard.ScrollBarThickness = 3
AdminCard.CanvasSize = UDim2.new(0, 0, 0, 670)
AdminCard.Parent = AdminPage
Instance.new("UICorner", AdminCard).CornerRadius = UDim.new(0, 10)

local AdminTitle = Instance.new("TextLabel")
AdminTitle.Size = UDim2.new(1, -16, 0, 28)
AdminTitle.Position = UDim2.new(0, 10, 0, 8)
AdminTitle.BackgroundTransparency = 1
AdminTitle.Text = "👑 Owner Admin Panel"
AdminTitle.TextColor3 = Color3.fromRGB(255, 196, 80)
AdminTitle.Font = FONT
AdminTitle.TextSize = 17
AdminTitle.TextXAlignment = Enum.TextXAlignment.Left
AdminTitle.Parent = AdminCard

local AdminHint = Instance.new("TextLabel")
AdminHint.Size = UDim2.new(1, -20, 0, 36)
AdminHint.Position = UDim2.new(0, 10, 0, 38)
AdminHint.BackgroundTransparency = 1
AdminHint.Text = "Target UserId or Username.\nClient-side only – real validation needs a server."
AdminHint.TextColor3 = Color3.fromRGB(180, 160, 150)
AdminHint.Font = FONT
AdminHint.TextSize = 13
AdminHint.TextWrapped = true
AdminHint.TextXAlignment = Enum.TextXAlignment.Left
AdminHint.Parent = AdminCard

local TargetBox = Instance.new("TextBox")
TargetBox.Size = UDim2.new(1, -20, 0, 34)
TargetBox.Position = UDim2.new(0, 10, 0, 82)
TargetBox.BackgroundColor3 = Color3.fromRGB(16, 8, 6)
TargetBox.PlaceholderText = "UserId or Username"
TargetBox.Text = ""
TargetBox.TextColor3 = Color3.fromRGB(245, 240, 235)
TargetBox.PlaceholderColor3 = Color3.fromRGB(140, 120, 110)
TargetBox.Font = FONT
TargetBox.TextSize = 15
TargetBox.ClearTextOnFocus = false
TargetBox.Parent = AdminCard
Instance.new("UICorner", TargetBox).CornerRadius = UDim.new(0, 6)

local LikesGiveBox = Instance.new("TextBox")
LikesGiveBox.Size = UDim2.new(0.48, -8, 0, 34)
LikesGiveBox.Position = UDim2.new(0, 10, 0, 126)
LikesGiveBox.BackgroundColor3 = Color3.fromRGB(16, 8, 6)
LikesGiveBox.PlaceholderText = "Likes to add"
LikesGiveBox.Text = ""
LikesGiveBox.TextColor3 = Color3.fromRGB(245, 240, 235)
LikesGiveBox.PlaceholderColor3 = Color3.fromRGB(140, 120, 110)
LikesGiveBox.Font = FONT
LikesGiveBox.TextSize = 15
LikesGiveBox.ClearTextOnFocus = false
LikesGiveBox.Parent = AdminCard
Instance.new("UICorner", LikesGiveBox).CornerRadius = UDim.new(0, 6)

local GiveLikesBtn = Instance.new("TextButton")
GiveLikesBtn.Size = UDim2.new(0.48, -8, 0, 34)
GiveLikesBtn.Position = UDim2.new(0.52, 0, 0, 126)
GiveLikesBtn.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
GiveLikesBtn.Text = "Give Likes"
GiveLikesBtn.TextColor3 = Color3.new(1, 1, 1)
GiveLikesBtn.Font = FONT
GiveLikesBtn.TextSize = 15
GiveLikesBtn.Parent = AdminCard
Instance.new("UICorner", GiveLikesBtn).CornerRadius = UDim.new(0, 6)

local DecorGiveLabel = Instance.new("TextLabel")
DecorGiveLabel.Size = UDim2.new(1, -20, 0, 20)
DecorGiveLabel.Position = UDim2.new(0, 10, 0, 170)
DecorGiveLabel.BackgroundTransparency = 1
DecorGiveLabel.Text = "Unlock Decoration for target:"
DecorGiveLabel.TextColor3 = Color3.fromRGB(200, 180, 160)
DecorGiveLabel.Font = FONT
DecorGiveLabel.TextSize = 14
DecorGiveLabel.TextXAlignment = Enum.TextXAlignment.Left
DecorGiveLabel.Parent = AdminCard

local AdminDecorRow = Instance.new("Frame")
AdminDecorRow.Size = UDim2.new(1, -20, 0, 130)
AdminDecorRow.Position = UDim2.new(0, 10, 0, 196)
AdminDecorRow.BackgroundTransparency = 1
AdminDecorRow.Parent = AdminCard

local adminDecorGrid = Instance.new("UIGridLayout")
adminDecorGrid.CellSize = UDim2.new(0.48, -4, 0, 28)
adminDecorGrid.CellPadding = UDim2.new(0, 5, 0, 5)
adminDecorGrid.Parent = AdminDecorRow

for _, d in ipairs(DECORATIONS) do
    if d.id ~= "None" then
        local btn = Instance.new("TextButton")
        btn.BackgroundColor3 = Color3.fromRGB(40, 20, 18)
        btn.Text = "Unlock " .. d.name
        btn.TextColor3 = Color3.fromRGB(220, 200, 180)
        btn.Font = FONT
        btn.TextSize = 13
        btn.Name = "Unlock_" .. d.id
        fit(btn, 14, 9)
        btn.Parent = AdminDecorRow
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    end
end

local AdminStatus = Instance.new("TextLabel")
AdminStatus.Size = UDim2.new(1, -20, 0, 20)
AdminStatus.Position = UDim2.new(0, 10, 0, 628)
AdminStatus.BackgroundTransparency = 1
AdminStatus.Text = "Ready (client-side only)"
AdminStatus.TextColor3 = Color3.fromRGB(140, 190, 130)
AdminStatus.Font = FONT
AdminStatus.TextSize = 14
AdminStatus.TextXAlignment = Enum.TextXAlignment.Left
AdminStatus.Parent = AdminCard

-- Status
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -24, 0, 18)
StatusLabel.Position = UDim2.new(0, 12, 1, -(PF.compact and 22 or 26))
StatusLabel.BackgroundTransparency = 1
StatusLabel.Text = "Ready"
StatusLabel.TextColor3 = Color3.fromRGB(140, 190, 130)
StatusLabel.Font = FONT
StatusLabel.TextSize = 13
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.Parent = Main

print("[RUBO Chat V2] GUI Created | Parent: " .. tostring(ScreenGui.Parent))

-- ===================== FUNCTIONS =====================
local setTab, loadProfile, loadLeaderboard, loadDMList, loadDMConversation
local burst, applyDecoration, applyEffectTheme, clearParticles, resizeProfileCard

-- ===================== VISUAL ENGINE (effects + animated frames, works on any "stage") =====================
do
    local particles = {}
    local MAX_PARTICLES = 76
    local clock = 0
    local spawnTimer = 0
    local emitTimer = 0
    local A = nil   -- active stage
    local CONFETTI = {
        Color3.fromRGB(255, 90, 90), Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 220, 140),
        Color3.fromRGB(90, 170, 255), Color3.fromRGB(200, 110, 255),
    }
    local GLITCH = {Color3.fromRGB(0, 255, 230), Color3.fromRGB(255, 0, 200), Color3.fromRGB(255, 60, 60)}

    local function rnd(a, b)
        return a + math.random() * (b - a)
    end
    local function dims(S)
        local w, h = S.emoji.AbsoluteSize.X, S.emoji.AbsoluteSize.Y
        if w < 100 then w = 380 end
        if h < 100 then h = 300 end
        return w, h
    end

    local function makeEmoji(text, size, parent)
        local e = Instance.new("TextLabel")
        e.AnchorPoint = Vector2.new(0.5, 0.5)
        e.Size = UDim2.fromOffset(size + 12, size + 12)
        e.BackgroundTransparency = 1
        e.Text = text
        e.TextSize = size
        e.Font = FONT
        e.TextColor3 = Color3.new(1, 1, 1)
        e.ZIndex = 7
        e.Parent = parent
        local sc = Instance.new("UIScale")
        sc.Parent = e
        return e, sc
    end

    local function addParticle(S, p)
        if #particles >= MAX_PARTICLES then return end
        p.stage = S
        p.life = p.life or 2
        p.age = 0
        if p.rot == nil then p.rot = p.color and math.random(0, 360) or 0 end
        p.x0 = p.x0 or p.x
        p.y0 = p.y0 or p.y
        p.vx = p.vx or 0
        p.vy = p.vy or 60
        p.grav = p.grav or 0
        p.spin = p.spin or 0
        p.freq = p.freq or 2
        p.amp = p.amp or 10
        p.phase = p.phase or 0
        p.fadeIn = p.fadeIn or 0.15
        p.fadeOut = p.fadeOut or 0.35
        p.maxAlpha = p.maxAlpha or 1
        p.baseScale = p.baseScale or 1

        if p.color then
            local f = Instance.new("Frame")
            f.AnchorPoint = Vector2.new(0.5, 0.5)
            f.Size = UDim2.fromOffset(p.w or 6, p.h or 10)
            f.BackgroundColor3 = p.color
            f.BackgroundTransparency = 1
            f.BorderSizePixel = 0
            f.ZIndex = 7
            f.Parent = S.emoji
            if p.round then
                Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
            end
            local sc = Instance.new("UIScale")
            sc.Scale = 0.1
            sc.Parent = f
            p.label, p.scale, p.isFrame = f, sc, true
        else
            p.label, p.scale = makeEmoji(p.text, p.size or math.random(16, 24), S.emoji)
            if p.textColor then p.label.TextColor3 = p.textColor end
            if p.font then p.label.Font = p.font end
            p.label.TextTransparency = 1
            p.scale.Scale = 0.1
        end
        p.label.Position = UDim2.fromOffset(p.x, p.y)
        particles[#particles + 1] = p
    end

    local function stepParticle(p, dt)
        p.age = p.age + dt
        local t = p.age / p.life
        if t >= 1 then return false end
        local m = p.mode

        if m == "float" then
            p.y = p.y - p.vy * dt
            p.x = p.x0 + (p.drift or 0) * p.age + math.sin(p.age * p.freq + p.phase) * p.amp
            p.rot = math.sin(p.age * p.freq + p.phase) * 18
        elseif m == "rain" then
            p.y = p.y + p.vy * dt
            p.x = p.x0 + (p.drift or 0) * p.age + math.sin(p.age * p.freq + p.phase) * p.amp
            p.rot = p.rot + p.spin * dt
        elseif m == "ember" then
            p.vy = p.vy * (1 - 0.35 * dt)
            p.y = p.y - p.vy * dt
            p.x = p.x0 + math.sin(p.age * p.freq + p.phase) * p.amp * (0.5 + t)
            p.rot = math.sin(p.age * 9 + p.phase) * 14
        elseif m == "twinkle" then
            p.rot = p.rot + p.spin * dt
        elseif m == "orbit" then
            p.angle = p.angle + p.angVel * dt
            p.x = p.cx + math.cos(p.angle) * p.rx
            p.y = p.cy + math.sin(p.angle) * p.ry
        elseif m == "swirl" then
            p.angle = p.angle + p.angVel * dt
            p.radius = p.radius + p.speed * dt
            p.x = p.cx + math.cos(p.angle) * p.radius
            p.y = p.cy + math.sin(p.angle) * p.radius * 0.85
        elseif m == "burst" or m == "confetti" then
            p.vy = p.vy + p.grav * dt
            p.vx = p.vx * (1 - (p.drag or 0.6) * dt)
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.rot = p.rot + p.spin * dt
        elseif m == "ghost" then
            p.y = p.y - p.vy * dt
            p.x = p.x0 + math.sin(p.age * p.freq + p.phase) * p.amp
        elseif m == "shoot" then
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
        elseif m == "implode" then
            local k = 1 - t
            p.angle = p.angle + p.angVel * dt * (1 + 3 * t)
            local rr = p.r0 * k * k
            p.x = p.cx + math.cos(p.angle) * rr
            p.y = p.cy + math.sin(p.angle) * rr * 0.8
            p.rot = p.rot + 180 * dt
        elseif m == "arc" then
            p.x = p.x0 + (p.x1 - p.x0) * t
            p.y = p.y0 + (p.y1 - p.y0) * t - math.sin(math.pi * t) * p.arcH
            p.rot = ((p.x1 > p.x0) and 1 or -1) * (10 + math.sin(p.age * 9) * 12)
        elseif m == "glitch" then
            p.x = p.x0 + rnd(-6, 6)
            p.y = p.y0 + rnd(-4, 4)
        end

        local alpha = 1
        if t < p.fadeIn then
            alpha = t / p.fadeIn
        elseif t > 1 - p.fadeOut then
            alpha = (1 - t) / p.fadeOut
        end
        local tr = 1 - math.clamp(alpha, 0, 1) * p.maxAlpha
        if m == "glitch" and math.random() < 0.25 then tr = 1 end

        local sc = p.baseScale
        if m == "twinkle" then
            sc = p.baseScale * math.sin(math.pi * t)
        elseif m == "ember" then
            sc = p.baseScale * (1 - 0.6 * t)
        elseif m == "implode" then
            sc = p.baseScale * (1 - 0.75 * t)
        elseif p.noPop then
            sc = p.baseScale
        else
            sc = p.baseScale * (0.35 + 0.65 * math.min(1, t / 0.2))
        end

        p.label.Position = UDim2.fromOffset(p.x, p.y)
        p.label.Rotation = p.rot
        p.scale.Scale = math.max(0.05, sc)
        if p.isFrame then
            p.label.BackgroundTransparency = tr
        else
            p.label.TextTransparency = tr
        end
        return true
    end

    local function shockwave(S)
        local c = Instance.new("Frame")
        c.AnchorPoint = Vector2.new(0.5, 0.5)
        c.Position = UDim2.new(S.cxs, S.cxo, 0, S.cy)
        c.Size = UDim2.fromOffset(R.size, R.size)
        c.BackgroundTransparency = 1
        c.ZIndex = 2
        c.Parent = S.back
        Instance.new("UICorner", c).CornerRadius = UDim.new(1, 0)
        local st = Instance.new("UIStroke")
        st.Color = S.decor.color
        st.Thickness = 4
        st.Parent = c
        local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(c, info, {Size = UDim2.fromOffset(R.size + 130, R.size + 130)}):Play()
        local tw = TweenService:Create(st, info, {Transparency = 1, Thickness = 1})
        tw.Completed:Connect(function()
            if c then c:Destroy() end
        end)
        tw:Play()
    end

    -- a real zig-zag lightning bolt (rotated thin frames) + full-card flash
    local function spawnBolt(S)
        local w, h = dims(S)
        local x = rnd(0.15, 0.85) * w
        local y = 0
        local segs = 7
        local endY = h * rnd(0.55, 0.85)
        for _ = 1, segs do
            local nx = x + rnd(-38, 38)
            local ny = y + endY / segs
            local dx, dy = nx - x, ny - y
            local len = math.sqrt(dx * dx + dy * dy)
            local f = Instance.new("Frame")
            f.AnchorPoint = Vector2.new(0.5, 0.5)
            f.Position = UDim2.fromOffset((x + nx) / 2, (y + ny) / 2)
            f.Size = UDim2.fromOffset(len + 3, 3)
            f.Rotation = math.deg(math.atan2(dy, dx))
            f.BackgroundColor3 = Color3.fromRGB(215, 232, 255)
            f.BorderSizePixel = 0
            f.ZIndex = 9
            f.Parent = S.emoji
            local st = Instance.new("UIStroke")
            st.Color = Color3.fromRGB(90, 140, 255)
            st.Thickness = 3
            st.Transparency = 0.3
            st.Parent = f
            TweenService:Create(f, TweenInfo.new(0.35), {BackgroundTransparency = 1}):Play()
            TweenService:Create(st, TweenInfo.new(0.35), {Transparency = 1}):Play()
            task.delay(0.4, function()
                if f then f:Destroy() end
            end)
            x, y = nx, ny
        end
        S.flash.BackgroundTransparency = 0.72
        TweenService:Create(S.flash, TweenInfo.new(0.4), {BackgroundTransparency = 1}):Play()
        addParticle(S, {mode = "twinkle", text = "⚡", x = x, y = y, spin = 0, life = 0.7, size = 26})
    end

    local function spawnEffectParticle(S, pack)
        local emojis = pack.emojis
        if not emojis or #emojis == 0 then return end
        local w, h = dims(S)
        local cx, cy = S.center()
        local text = emojis[math.random(1, #emojis)]
        local m = pack.mode

        if m == "float" or m == "wave" then
            local life = rnd(2.4, 3.6)
            local x0 = rnd(0.06, 0.94) * w
            addParticle(S, {mode = "float", text = text, x0 = x0, x = x0, y = h + 10,
                vy = (h + 30) / life,
                freq = (m == "wave") and rnd(2.5, 4) or rnd(1.4, 2.6),
                amp = (m == "wave") and rnd(18, 34) or rnd(8, 20),
                phase = rnd(0, 6.28), life = life, size = math.random(16, 26)})
        elseif m == "twinkle" then
            addParticle(S, {mode = "twinkle", text = text, x = rnd(0.05, 0.95) * w, y = rnd(0.04, 0.9) * h,
                spin = rnd(-70, 70), life = rnd(1.2, 2.2), size = math.random(14, 24)})
            if pack.shooting and math.random() < 0.2 then
                addParticle(S, {mode = "shoot", text = "💫", x = w * rnd(0.6, 1.0), y = -10,
                    vx = -rnd(200, 300), vy = rnd(120, 200), life = 1.1, size = 22,
                    fadeIn = 0.1, fadeOut = 0.4})
            end
        elseif m == "ember" then
            local x0 = rnd(0.04, 0.96) * w
            addParticle(S, {mode = "ember", text = text, x0 = x0, x = x0, y = h + 6,
                vy = rnd(110, 200), freq = rnd(3, 6), amp = rnd(6, 16), phase = rnd(0, 6.28),
                life = rnd(1.5, 2.6), size = math.random(16, 28)})
        elseif m == "snow" or m == "rain" then
            local vy = (m == "snow") and rnd(55, 90) or rnd(100, 170)
            local x0 = rnd(0.04, 0.96) * w
            addParticle(S, {mode = "rain", text = text, x0 = x0, x = x0, y = -12, vy = vy,
                freq = rnd(1, 2.5), amp = (m == "snow") and rnd(10, 22) or rnd(3, 8),
                phase = rnd(0, 6.28), spin = rnd(-100, 100), life = (h + 30) / vy,
                size = math.random(16, 24), fadeIn = 0.05, fadeOut = 0.12})
        elseif m == "confetti" then
            local sx = rnd(0.15, 0.85) * w
            for _ = 1, 3 do
                addParticle(S, {mode = "confetti", color = CONFETTI[math.random(1, #CONFETTI)],
                    x = sx, y = -6, vx = rnd(-110, 110), vy = rnd(40, 140), grav = 200,
                    spin = rnd(-300, 300), life = rnd(2, 3), fadeIn = 0.05, fadeOut = 0.25})
            end
            addParticle(S, {mode = "confetti", text = text, x = sx, y = -6, vx = rnd(-90, 90), vy = rnd(40, 120),
                grav = 200, spin = rnd(-200, 200), life = rnd(2, 3), size = math.random(18, 26)})
        elseif m == "ghost" then
            local x0 = rnd(0.08, 0.92) * w
            addParticle(S, {mode = "ghost", text = text, x0 = x0, x = x0, y = rnd(0.5, 1.0) * h,
                vy = rnd(18, 38), freq = rnd(0.8, 1.6), amp = rnd(10, 24), phase = rnd(0, 6.28),
                life = rnd(3, 4.5), size = math.random(22, 32), maxAlpha = 0.75, fadeIn = 0.3, fadeOut = 0.4})
        elseif m == "orbit" then
            local dir = (math.random() < 0.5) and 1 or -1
            local rx = rnd(0.28, 0.46) * w
            addParticle(S, {mode = "orbit", text = text, cx = w * 0.5, cy = rnd(70, 150), rx = rx,
                ry = rx * rnd(0.18, 0.35), angle = rnd(0, 6.28), angVel = dir * rnd(0.7, 1.5),
                x = w * 0.5, y = 100, life = rnd(3.5, 5.5), size = math.random(16, 26),
                fadeIn = 0.2, fadeOut = 0.25})
            if math.random() < 0.5 then
                addParticle(S, {mode = "twinkle", text = "✨", x = rnd(0.05, 0.95) * w, y = rnd(0.05, 0.9) * h,
                    spin = rnd(-60, 60), life = rnd(1.2, 2.2), size = math.random(12, 18)})
            end
        elseif m == "swirl" then
            local dir = (math.random() < 0.5) and 1 or -1
            addParticle(S, {mode = "swirl", text = text, cx = cx, cy = cy, angle = rnd(0, 6.28),
                angVel = dir * rnd(1.3, 2.4), radius = 24, speed = rnd(28, 46), x = cx, y = cy,
                life = rnd(2.4, 3.4), size = math.random(16, 22), fadeIn = 0.15, fadeOut = 0.4})

        -- ===== premium modes =====
        elseif m == "lightning" then
            spawnBolt(S)
        elseif m == "matrix" then
            local x0 = rnd(0.03, 0.97) * w
            local vy = rnd(150, 240)
            local life = (h + 90) / vy
            for k = 0, 3 do
                addParticle(S, {mode = "rain", text = emojis[math.random(1, #emojis)],
                    textColor = (k == 0) and Color3.fromRGB(215, 255, 225) or Color3.fromRGB(0, 255, 110),
                    font = Enum.Font.Code, x0 = x0, x = x0, y = -12 - k * 16, vy = vy, amp = 0, freq = 1,
                    spin = 0, life = life, size = 16, maxAlpha = 1 - k * 0.22, fadeIn = 0.02, fadeOut = 0.05, noPop = true})
            end
        elseif m == "aurora" then
            addParticle(S, {mode = "shoot", color = Color3.fromHSV(rnd(0.35, 0.8), 0.7, 1), w = rnd(120, 220), h = rnd(10, 22),
                round = true, noPop = true, x = -rnd(0, 40), y = rnd(0.05, 0.55) * h, vx = rnd(30, 60), vy = rnd(-6, 6),
                rot = rnd(-14, 14), life = rnd(4, 6), maxAlpha = 0.28, fadeIn = 0.35, fadeOut = 0.4})
            if math.random() < 0.6 then
                addParticle(S, {mode = "twinkle", text = text, x = rnd(0.05, 0.95) * w, y = rnd(0.05, 0.7) * h,
                    spin = rnd(-40, 40), life = rnd(1.4, 2.4), size = math.random(14, 22)})
            end
        elseif m == "implode" then
            local dir = (math.random() < 0.5) and 1 or -1
            addParticle(S, {mode = "implode", text = text, cx = cx, cy = cy, angle = rnd(0, 6.28),
                angVel = dir * rnd(1.2, 2.2), r0 = rnd(90, 170), x = cx, y = cy,
                life = rnd(2.2, 3.2), size = math.random(16, 24), fadeIn = 0.2, fadeOut = 0.25})
        elseif m == "sakura" then
            local vy = rnd(45, 80)
            local x0 = rnd(0.2, 1.15) * w
            addParticle(S, {mode = "rain", text = text, x0 = x0, x = x0, y = -12, vy = vy, drift = -rnd(25, 55),
                freq = rnd(1.5, 3), amp = rnd(14, 28), phase = rnd(0, 6.28), spin = rnd(-140, 140),
                life = (h + 30) / vy, size = math.random(16, 24), fadeIn = 0.05, fadeOut = 0.1})
        elseif m == "phoenix" then
            if math.random() < 0.22 then
                local fromLeft = math.random() < 0.5
                local xa = fromLeft and -20 or (w + 20)
                local xb = fromLeft and (w + 20) or -20
                local ya = rnd(0.55, 0.85) * h
                addParticle(S, {mode = "arc", text = "🦅", x0 = xa, x = xa, y0 = ya, y = ya, x1 = xb,
                    y1 = rnd(0.1, 0.3) * h, arcH = rnd(30, 70), life = rnd(2.2, 3), size = 30,
                    fadeIn = 0.1, fadeOut = 0.2})
            else
                local x0 = rnd(0.04, 0.96) * w
                addParticle(S, {mode = "ember", text = text, x0 = x0, x = x0, y = h + 6,
                    vy = rnd(130, 230), freq = rnd(3, 6), amp = rnd(8, 20), phase = rnd(0, 6.28),
                    life = rnd(1.6, 2.8), size = math.random(20, 32)})
            end
        elseif m == "glitch" then
            local gx, gy = rnd(0.05, 0.95) * w, rnd(0.05, 0.9) * h
            addParticle(S, {mode = "glitch", text = text, x0 = gx, x = gx, y0 = gy, y = gy,
                life = rnd(0.5, 1.2), size = math.random(18, 28), fadeIn = 0.05, fadeOut = 0.1})
            for _ = 1, 2 do
                local bx, by = rnd(0, 1) * w, rnd(0, 1) * h
                addParticle(S, {mode = "glitch", color = GLITCH[math.random(1, #GLITCH)], w = rnd(50, 160), h = rnd(3, 7),
                    noPop = true, x0 = bx, x = bx, y0 = by, y = by, life = rnd(0.15, 0.4), maxAlpha = 0.6,
                    fadeIn = 0.05, fadeOut = 0.2})
            end
        elseif m == "nova" then
            shockwave(S)
            for k = 1, 12 do
                local ang = k / 12 * 6.283
                local sp = rnd(110, 150)
                addParticle(S, {mode = "burst", text = emojis[math.random(1, #emojis)], x = cx, y = cy,
                    vx = math.cos(ang) * sp, vy = math.sin(ang) * sp, grav = 0, drag = 0.3,
                    spin = rnd(-200, 200), life = rnd(1.0, 1.5), size = math.random(14, 22),
                    fadeIn = 0.05, fadeOut = 0.5})
            end
        end
    end

    local function spawnFrameParticle(S)
        local em = S.decor.emit
        if not em then return end
        local cx, cy = S.center()
        local text = em.emojis[math.random(1, #em.emojis)]
        local a = rnd(0, 6.283)
        local rr = R.size / 2 + rnd(-2, 6)
        local x = cx + math.cos(a) * rr
        local y = cy + math.sin(a) * rr
        if em.mode == "ring_ember" then
            addParticle(S, {mode = "ember", text = text, x0 = x, x = x, y = y, vy = rnd(40, 80),
                freq = rnd(3, 6), amp = rnd(3, 8), phase = rnd(0, 6.28), life = rnd(0.9, 1.5),
                size = math.random(14, 20)})
        else
            addParticle(S, {mode = "twinkle", text = text, x = x, y = y, spin = rnd(-90, 90),
                life = rnd(0.7, 1.2), size = math.random(12, 18)})
        end
    end

    local function clearOrbiters(S)
        for _, o in ipairs(S.orbiters) do
            if o.label and o.label.Parent then o.label:Destroy() end
        end
        S.orbiters = {}
    end

    local function buildOrbiters(S, dec)
        clearOrbiters(S)
        if not dec.orbit then return end
        for _, d in ipairs(dec.orbit) do
            local label, scale = makeEmoji(d.e, d.size or 15, S.emoji)
            S.orbiters[#S.orbiters + 1] = {label = label, scale = scale, def = d, front = true}
        end
    end

    local function stepOrbiters(S, t)
        local cx, cy = S.center()
        for _, o in ipairs(S.orbiters) do
            local d = o.def
            local ang = (d.phase or 0) + t * (d.speed or 1)
            local r = d.r or 54
            local s = math.sin(ang)
            o.label.Position = UDim2.fromOffset(cx + math.cos(ang) * r, cy + s * r * (d.ry or 0.9))
            o.label.Rotation = math.sin(t * 2 + (d.phase or 0)) * 12
            o.scale.Scale = 0.85 + 0.25 * s
            local front = s >= 0
            if front ~= o.front then
                o.front = front
                o.label.Parent = front and S.emoji or S.back
            end
        end
    end

    local function stepFrame(S, t)
        local d = S.decor
        S.ringGrad.Rotation = (t * (d.spin or 0.3) * 360) % 360
        local pulse = d.pulse or 1
        if d.flicker then
            S.ringStroke.Thickness = 3.4 + math.random() * 2
        else
            S.ringStroke.Thickness = 4 + (math.sin(t * pulse * 2) + 1) * 0.6
        end
        for i, hl in ipairs(S.halos) do
            if hl.frame.Visible then
                local ph = (math.sin(t * pulse * 2 - i * 0.9) + 1) / 2
                hl.stroke.Transparency = math.min(1, 0.35 + (1 - ph) * 0.5 + (i - 1) * 0.05)
                hl.stroke.Thickness = 1.5 + ph * 2.5
                local sz = R.size + 4 + i * 7 + ph * 6
                hl.frame.Size = UDim2.fromOffset(sz, sz)
                hl.grad.Rotation = -((t * (d.spin or 0.3) * 200) % 360)
            end
        end
    end

    local function purgeOther(S)
        local i = 1
        while i <= #particles do
            local p = particles[i]
            if p.stage ~= S then
                if p.label and p.label.Parent then p.label:Destroy() end
                table.remove(particles, i)
            else
                i = i + 1
            end
        end
    end

    applyDecoration = function(decorId, stage)
        local S = stage or PF.s1
        local dec = decorById(decorId or "None")
        S.decor = dec
        S.ringGrad.Color = dec.grad
        for i, hl in ipairs(S.halos) do
            hl.frame.Visible = i <= (dec.halo or 0)
            hl.grad.Color = dec.grad
        end
        local ownerView = (S == PF.s1) and (state.viewIsOwner == true)
        S.crown.Visible = ownerView or (dec.crown == true)
        buildOrbiters(S, dec)
        emitTimer = 0
    end

    applyEffectTheme = function(effectId, stage)
        local S = stage or PF.s1
        local pack = effectById(effectId)
        S.effectId = effectId
        if pack.rainbow then
            S.ambientGrad.Color = seq(Color3.fromRGB(255, 90, 120), Color3.fromRGB(255, 190, 70), Color3.fromRGB(90, 230, 140),
                Color3.fromRGB(90, 170, 255), Color3.fromRGB(190, 110, 255))
        else
            S.ambientGrad.Color = ColorSequence.new(pack.tint)
        end
        if S == PF.s1 then
            EffectStat.TextColor3 = pack.tint:Lerp(Color3.new(1, 1, 1), 0.4)
        end
        spawnTimer = 0
    end

    clearParticles = function()
        for _, p in ipairs(particles) do
            if p.label and p.label.Parent then p.label:Destroy() end
        end
        particles = {}
    end

    resizeProfileCard = function()
        local h
        if EditHolder.Visible then
            h = 212 + EditHolder.Size.Y.Offset + 24
        else
            h = 356
        end
        ProfileCard.Size = UDim2.new(1, -8, 0, h)
        ProfilePage.CanvasSize = UDim2.new(0, 0, 0, h + 6)
    end

    burst = function(n, stage)
        local S = stage or PF.s1
        if not (S.card.Parent and S.card.Parent.Visible) then return end
        shockwave(S)
        for i = 1, n do
            task.delay(i * 0.04, function()
                if not state.isAlive then return end
                if not (S.card.Parent and S.card.Parent.Visible) then return end
                local pk = effectById(S.effectId)
                if not pk.emojis or #pk.emojis == 0 then return end
                local cx, cy = S.center()
                local ang = rnd(0, 6.283)
                local sp = rnd(90, 210)
                addParticle(S, {mode = "burst", text = pk.emojis[math.random(1, #pk.emojis)],
                    x = cx, y = cy, vx = math.cos(ang) * sp, vy = math.sin(ang) * sp - 60,
                    grav = 240, spin = rnd(-200, 200), life = rnd(1.2, 2.0), size = math.random(16, 24),
                    fadeIn = 0.08, fadeOut = 0.4})
            end)
        end
    end

    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not state.isAlive or not ScreenGui.Parent then
            if conn then conn:Disconnect() end
            return
        end
        PF.mainStrokeGrad.Rotation = (os.clock() * 40) % 360

        local tab = state.currentTab

        -- animated chat-bubble borders / gradients
        if tab == "Chat" or tab == "Studio" then
            local list = PF.animGrads
            local now = os.clock()
            for i = #list, 1, -1 do
                local e = list[i]
                if e.g.Parent then
                    e.g.Rotation = (now * e.speed) % 360
                else
                    table.remove(list, i)
                end
            end
        end

        local S = nil
        if tab == "Profile" then
            S = PF.s1
        elseif tab == "Studio" then
            S = PF.s2
        end
        if not S or not S.card.Parent or not S.card.Parent.Visible then
            if A then
                A = nil
                clearParticles()
            end
            return
        end
        if S ~= A then
            purgeOther(S)
            A = S
            spawnTimer = 0
            emitTimer = 0
        end

        clock = clock + dt
        local pack = effectById(A.effectId)

        if pack.aurora then
            local hh = (clock * 0.05) % 1
            A.ambientGrad.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromHSV(hh, 0.7, 1)),
                ColorSequenceKeypoint.new(0.5, Color3.fromHSV((hh + 0.2) % 1, 0.7, 1)),
                ColorSequenceKeypoint.new(1, Color3.fromHSV((hh + 0.4) % 1, 0.8, 1)),
            })
        end
        A.ambient.BackgroundTransparency = 0.05 + (math.sin(clock * 1.3) + 1) * 0.1

        stepFrame(A, clock)
        stepOrbiters(A, clock)
        if A.crown.Visible then
            A.crown.Position = UDim2.new(A.cxs, A.cxo, 0, A.cy - R.size / 2 - 6 + math.sin(clock * 2.4) * 2.5)
            A.crown.Rotation = math.sin(clock * 1.6) * 6
        end

        if pack.mode ~= "none" and pack.emojis and #pack.emojis > 0 then
            spawnTimer = spawnTimer + dt
            if spawnTimer >= pack.rate then
                if pack.mode == "lightning" or pack.mode == "nova" then
                    spawnTimer = -rnd(0, 1.0)
                else
                    spawnTimer = 0
                end
                spawnEffectParticle(A, pack)
            end
        end
        if A.decor.emit then
            emitTimer = emitTimer + dt
            if emitTimer >= A.decor.emit.rate then
                emitTimer = 0
                spawnFrameParticle(A)
            end
        end

        local i = 1
        while i <= #particles do
            local p = particles[i]
            if stepParticle(p, dt) then
                i = i + 1
            else
                if p.label and p.label.Parent then p.label:Destroy() end
                table.remove(particles, i)
            end
        end
    end)
    track(conn)
end

-- ===================== STUDIO TAB (live preview + info + contact) =====================
local StudioPage = Instance.new("ScrollingFrame")
StudioPage.Size = UDim2.new(1, 0, 1, 0)
StudioPage.BackgroundTransparency = 1
StudioPage.BorderSizePixel = 0
StudioPage.ScrollBarThickness = 4
StudioPage.ScrollBarImageColor3 = Color3.fromRGB(255, 140, 50)
StudioPage.CanvasSize = UDim2.new(0, 0, 0, 0)
StudioPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
StudioPage.Visible = false
StudioPage.Parent = Content

do
    local K = PF.K
    local DISCORD_ID = "sirrubo"

    local lay = Instance.new("UIListLayout")
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Padding = UDim.new(0, 8)
    lay.Parent = StudioPage
    local sp = Instance.new("UIPadding")
    sp.PaddingRight = UDim.new(0, 6)
    sp.PaddingBottom = UDim.new(0, 8)
    sp.Parent = StudioPage

    local function newCard(order, h)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, h or 0)
        f.BackgroundColor3 = Color3.fromRGB(22, 10, 6)
        f.BorderSizePixel = 0
        f.LayoutOrder = order
        f.Parent = StudioPage
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 14)
        return f
    end
    local function pad(parent, n)
        local p = Instance.new("UIPadding")
        p.PaddingTop = UDim.new(0, n)
        p.PaddingBottom = UDim.new(0, n)
        p.PaddingLeft = UDim.new(0, n)
        p.PaddingRight = UDim.new(0, n)
        p.Parent = parent
    end
    local function newLabel(parent, text, size, color, font)
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1
        l.Text = text
        l.TextSize = size
        l.TextColor3 = color
        l.Font = font or FONT
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Parent = parent
        return l
    end

    -- 1) preview stage
    local stageH = PF.compact and 226 or 250
    local stageCard = newCard(1, stageH)
    stageCard.ClipsDescendants = true
    do
        local sg = Instance.new("UIGradient")
        sg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(48, 18, 10)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(18, 8, 6)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 3, 2)),
        })
        sg.Rotation = 90
        sg.Parent = stageCard
    end
    PF.s2 = PF.buildStage(stageCard, 0.5, 0, 100)
    PF.s2.avatar.Image = headshot(LocalPlayer.UserId)

    local sName = newLabel(stageCard, "Preview Stage", 18, Color3.fromRGB(250, 245, 240), FONT_HEAVY)
    sName.Size = UDim2.new(1, -20, 0, 24)
    sName.Position = UDim2.new(0, 10, 0, stageH - 60)
    sName.TextXAlignment = Enum.TextXAlignment.Center
    sName.ZIndex = 4
    local sSub = newLabel(stageCard, "Tap anything below to preview it live", 13, Color3.fromRGB(200, 182, 172), FONT)
    sSub.Size = UDim2.new(1, -20, 0, 22)
    sSub.Position = UDim2.new(0, 10, 0, stageH - 34)
    sSub.TextXAlignment = Enum.TextXAlignment.Center
    sSub.ZIndex = 4

    -- 2) info card
    local info = newCard(2, 0)
    info.AutomaticSize = Enum.AutomaticSize.Y
    pad(info, 10)
    local il = Instance.new("UIListLayout")
    il.SortOrder = Enum.SortOrder.LayoutOrder
    il.Padding = UDim.new(0, 4)
    il.Parent = info
    local infoTitle = newLabel(info, "Welcome to Studio", 18, Color3.fromRGB(255, 244, 235), FONT_HEAVY)
    infoTitle.Size = UDim2.new(1, 0, 0, 24)
    infoTitle.LayoutOrder = 1
    local infoStatus = newLabel(info, "Effects  •  Frames  •  Bubbles", 14, Color3.fromRGB(200, 182, 172), FONT)
    infoStatus.Size = UDim2.new(1, 0, 0, 20)
    infoStatus.LayoutOrder = 2
    local infoDesc = newLabel(info, "Preview anything here, even locked items (🔒). Locked items are unlocked by the owner - contact info is at the bottom.", 14, Color3.fromRGB(228, 214, 204), FONT)
    infoDesc.Size = UDim2.new(1, 0, 0, 0)
    infoDesc.AutomaticSize = Enum.AutomaticSize.Y
    infoDesc.TextWrapped = true
    infoDesc.TextYAlignment = Enum.TextYAlignment.Top
    infoDesc.LayoutOrder = 3

    -- 3) category tabs
    local pv = {effect = "Hearts", decor = "None", bubble = "Default", cat = "Effects"}
    local catRow = Instance.new("Frame")
    catRow.Size = UDim2.new(1, 0, 0, 36)
    catRow.BackgroundTransparency = 1
    catRow.LayoutOrder = 3
    catRow.Parent = StudioPage
    local cats = {"Effects", "Frames", "Bubbles"}
    local catButtons = {}
    for i, c in ipairs(cats) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1 / 3, -4, 1, 0)
        b.Position = UDim2.new((i - 1) / 3, 2, 0, 0)
        b.BackgroundColor3 = Color3.fromRGB(30, 15, 11)
        b.Text = c
        b.TextColor3 = Color3.fromRGB(205, 186, 176)
        b.Font = FONT_HEAVY
        b.TextSize = 15
        b.Parent = catRow
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
        fit(b, 15, 9)
        catButtons[c] = b
    end

    -- 4) items grid
    local gridHolder = Instance.new("Frame")
    gridHolder.Size = UDim2.new(1, 0, 0, 100)
    gridHolder.BackgroundTransparency = 1
    gridHolder.LayoutOrder = 4
    gridHolder.Parent = StudioPage
    local gl = Instance.new("UIGridLayout")
    gl.CellSize = UDim2.new(0.5, -3, 0, 34)
    gl.CellPadding = UDim2.new(0, 6, 0, 6)
    gl.SortOrder = Enum.SortOrder.LayoutOrder
    gl.Parent = gridHolder

    -- 5) bubble preview
    local bubCard = newCard(5, 0)
    bubCard.AutomaticSize = Enum.AutomaticSize.Y
    pad(bubCard, 10)
    local bl = Instance.new("UIListLayout")
    bl.SortOrder = Enum.SortOrder.LayoutOrder
    bl.Padding = UDim.new(0, 6)
    bl.Parent = bubCard
    local bubTitle = newLabel(bubCard, "Chat bubble preview", 15, Color3.fromRGB(255, 196, 130), FONT_HEAVY)
    bubTitle.Size = UDim2.new(1, 0, 0, 20)
    bubTitle.LayoutOrder = 1
    local sampleHolder = Instance.new("Frame")
    sampleHolder.Size = UDim2.new(1, 0, 0, 0)
    sampleHolder.AutomaticSize = Enum.AutomaticSize.Y
    sampleHolder.BackgroundTransparency = 1
    sampleHolder.LayoutOrder = 2
    sampleHolder.Parent = bubCard

    local function refreshSample()
        for _, c in ipairs(sampleHolder:GetChildren()) do
            c:Destroy()
        end
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, 0)
        f.AutomaticSize = Enum.AutomaticSize.Y
        f.BackgroundColor3 = Color3.fromRGB(34, 17, 12)
        f.BorderSizePixel = 0
        f.Parent = sampleHolder
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 12)
        pad(f, K.msgPad + 2)
        local fl = Instance.new("UIListLayout")
        fl.SortOrder = Enum.SortOrder.LayoutOrder
        fl.Padding = UDim.new(0, 4)
        fl.Parent = f
        local nm = newLabel(f, LocalPlayer.Name, K.nameS, Color3.fromRGB(255, 214, 170), FONT_HEAVY)
        nm.Size = UDim2.new(1, 0, 0, K.nameH)
        nm.TextTruncate = Enum.TextTruncate.AtEnd
        nm.LayoutOrder = 1
        local tx = newLabel(f, "Hey! Ye RUBO Chat bubble ka preview hai 😎🔥", K.txtS, Color3.fromRGB(248, 243, 238), FONT)
        tx.Size = UDim2.new(1, 0, 0, 0)
        tx.AutomaticSize = Enum.AutomaticSize.Y
        tx.TextWrapped = true
        tx.TextYAlignment = Enum.TextYAlignment.Top
        tx.LayoutOrder = 2
        local alpha = PF.applyBubble(f, pv.bubble, tx, nm)
        if alpha then f.BackgroundTransparency = alpha end
    end

    -- 6) contact card
    local contact = newCard(6, 0)
    contact.AutomaticSize = Enum.AutomaticSize.Y
    pad(contact, 10)
    local cl = Instance.new("UIListLayout")
    cl.SortOrder = Enum.SortOrder.LayoutOrder
    cl.Padding = UDim.new(0, 6)
    cl.Parent = contact
    local cTitle = newLabel(contact, "📩 Unlock / Contact", 17, Color3.fromRGB(255, 196, 130), FONT_HEAVY)
    cTitle.Size = UDim2.new(1, 0, 0, 22)
    cTitle.LayoutOrder = 1
    local cNote = newLabel(contact, "Locked effects, frames aur bubbles sirf owner unlock karta hai. DM karo:", 13, Color3.fromRGB(205, 186, 176), FONT)
    cNote.Size = UDim2.new(1, 0, 0, 0)
    cNote.AutomaticSize = Enum.AutomaticSize.Y
    cNote.TextWrapped = true
    cNote.TextYAlignment = Enum.TextYAlignment.Top
    cNote.LayoutOrder = 2

    local function copyText(s)
        local fn = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if fn then
            local ok = pcall(fn, s)
            if ok then
                StatusLabel.Text = "Copied: " .. s
                return
            end
        end
        StatusLabel.Text = s .. "  (copy manually)"
    end

    local function contactRow(order, title, value, btnText, onClick)
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 48)
        row.BackgroundColor3 = Color3.fromRGB(34, 17, 12)
        row.BorderSizePixel = 0
        row.LayoutOrder = order
        row.Parent = contact
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)
        local t = newLabel(row, title, 12, Color3.fromRGB(180, 160, 150), FONT)
        t.Size = UDim2.new(1, -100, 0, 16)
        t.Position = UDim2.new(0, 10, 0, 5)
        local v = newLabel(row, value, 17, Color3.fromRGB(255, 246, 238), FONT_HEAVY)
        v.Size = UDim2.new(1, -100, 0, 22)
        v.Position = UDim2.new(0, 10, 0, 21)
        v.TextTruncate = Enum.TextTruncate.AtEnd
        fit(v, 17, 10)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 80, 0, 32)
        b.Position = UDim2.new(1, -88, 0.5, -16)
        b.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
        b.Text = btnText
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = FONT_HEAVY
        b.TextSize = 14
        b.Parent = row
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        fit(b, 14, 9)
        b.MouseButton1Click:Connect(onClick)
    end

    contactRow(3, "Discord ID", DISCORD_ID, "Copy", function()
        copyText(DISCORD_ID)
    end)
    contactRow(4, "Roblox username", OWNER_NAME, "Copy", function()
        copyText(OWNER_NAME)
    end)
    contactRow(5, "RUBO Chat (in-app)", "DM the Owner", "Open DM", function()
        local function openDM(uid)
            setTab("DM")
            state.dmTargetId = uid
            DMChatTitle.Text = "DM • " .. OWNER_NAME
            loadDMConversation(uid)
        end
        local uid = state.ownerUserId
        if uid and uid ~= LocalPlayer.UserId then
            openDM(uid)
            return
        end
        StatusLabel.Text = "Finding owner..."
        task.spawn(function()
            local ok, id = pcall(function()
                return Players:GetUserIdFromNameAsync(OWNER_NAME)
            end)
            if ok and id and id ~= LocalPlayer.UserId then
                state.ownerUserId = id
                openDM(id)
            else
                StatusLabel.Text = "Owner not found - DM on Discord: " .. DISCORD_ID
            end
        end)
    end)

    -- logic
    local function kindOf(cat)
        if cat == "Effects" then return "effect" end
        if cat == "Frames" then return "frame" end
        return "bubble"
    end

    local function selectItem(cat, it)
        local kind = kindOf(cat)
        local unlocked = PF.isUnlocked(kind, it)
        local icon = it.icon or (it.emojis and it.emojis[1]) or ""
        infoTitle.Text = ((icon ~= "") and (icon .. " ") or "") .. (it.name or it.id)
        local kindName = (cat == "Effects") and "Profile effect" or ((cat == "Frames") and "Profile frame" or "Chat bubble")
        if not it.locked then
            infoStatus.Text = kindName .. "  •  ✅ Free"
            infoStatus.TextColor3 = Color3.fromRGB(140, 230, 150)
        elseif unlocked then
            infoStatus.Text = kindName .. "  •  ✅ Unlocked"
            infoStatus.TextColor3 = Color3.fromRGB(140, 230, 150)
        else
            infoStatus.Text = kindName .. "  •  🔒 Locked"
            infoStatus.TextColor3 = Color3.fromRGB(255, 160, 120)
        end
        local desc = it.desc or ""
        if it.locked and not unlocked then
            desc = desc .. "\n\nUnlock karne ke liye owner ko DM karo:\n• Discord: " .. DISCORD_ID .. "\n• Roblox: " .. OWNER_NAME .. "\n• RUBO Chat DM (neeche button)"
        end
        infoDesc.Text = desc

        if cat == "Effects" then
            pv.effect = it.id
            applyEffectTheme(it.id, PF.s2)
            burst(12, PF.s2)
        elseif cat == "Frames" then
            pv.decor = it.id
            applyDecoration(it.id, PF.s2)
            burst(6, PF.s2)
        else
            pv.bubble = it.id
            refreshSample()
        end
    end

    local function refreshItems()
        for _, c in ipairs(gridHolder:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local cat = pv.cat
        local list = (cat == "Effects") and EFFECTS or ((cat == "Frames") and DECORATIONS or BUBBLES)
        local kind = kindOf(cat)
        for i, it in ipairs(list) do
            local unlocked = PF.isUnlocked(kind, it)
            local btn = Instance.new("TextButton")
            btn.BackgroundColor3 = unlocked and Color3.fromRGB(30, 15, 11) or Color3.fromRGB(40, 20, 18)
            btn.Text = (unlocked and "" or "🔒 ") .. (it.name or it.id)
            btn.TextColor3 = unlocked and Color3.fromRGB(235, 220, 210) or Color3.fromRGB(150, 128, 118)
            btn.Font = FONT
            btn.TextSize = 14
            btn.LayoutOrder = i
            btn.Parent = gridHolder
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
            fit(btn, 14, 9)
            btn.MouseButton1Click:Connect(function()
                selectItem(cat, it)
            end)
        end
        local rows = math.ceil(#list / 2)
        gridHolder.Size = UDim2.new(1, 0, 0, rows * 34 + (rows - 1) * 6)
        for c, b in pairs(catButtons) do
            local on = c == cat
            b.BackgroundColor3 = on and Color3.fromRGB(255, 132, 40) or Color3.fromRGB(30, 15, 11)
            b.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(205, 186, 176)
        end
    end

    for c, b in pairs(catButtons) do
        b.MouseButton1Click:Connect(function()
            pv.cat = c
            refreshItems()
        end)
    end

    PF.studioEnter = function()
        PF.s2.avatar.Image = headshot(LocalPlayer.UserId)
        applyDecoration(pv.decor, PF.s2)
        applyEffectTheme(pv.effect, PF.s2)
        refreshItems()
        refreshSample()
    end
end


local function putProfile(userId, profile)
    safeRequest("PUT", FIREBASE_URL .. "/profiles/" .. tostring(userId) .. ".json", profile)
end

-- applyDecoration is defined in the visual engine above

local function highlightEffects()
    for name, btn in pairs(effectButtons) do
        local pack = effectById(name)
        local on = name == state.editEffect
        local unlocked = PF.isUnlocked("effect", pack)
        btn.Text = (unlocked and "" or "🔒 ") .. name
        if on then
            btn.BackgroundColor3 = Color3.fromRGB(255, 132, 40)
            btn.TextColor3 = Color3.new(1, 1, 1)
        else
            btn.BackgroundColor3 = unlocked and Color3.fromRGB(30, 15, 11) or Color3.fromRGB(40, 20, 18)
            btn.TextColor3 = unlocked and pack.tint:Lerp(Color3.new(1, 1, 1), 0.45) or Color3.fromRGB(120, 100, 90)
        end
    end
end

local function highlightDecors()
    for id, btn in pairs(decorButtons) do
        local on = id == state.editDecor
        local unlocked = state.unlockedDecor[id] or isOwnerPlayer
        if on then
            btn.BackgroundColor3 = Color3.fromRGB(255, 132, 40)
            btn.TextColor3 = Color3.new(1, 1, 1)
        else
            btn.BackgroundColor3 = unlocked and Color3.fromRGB(28, 14, 10) or Color3.fromRGB(40, 20, 18)
            btn.TextColor3 = unlocked and decorById(id).color:Lerp(Color3.new(1, 1, 1), 0.3) or Color3.fromRGB(120, 100, 90)
        end
        if id ~= "None" and not unlocked then
            btn.Text = "🔒 " .. (decorById(id).name or id)
        else
            btn.Text = decorById(id).name or id
        end
    end
end

local function applyProfile(userId, profile)
    state.viewingUserId = userId
    state.viewingProfile = profile
    local owner = isOwner(profile.name, state.nameHint, userId == LocalPlayer.UserId and LocalPlayer.Name or nil)
    local likes = tonumber(profile.likes) or 0
    if owner then likes = math.max(likes, OWNER_LIKES) end

    local effect = profile.effect or (owner and "Unicorn" or "Hearts")
    local decor = profile.decor or (owner and "UnicornFrame" or "None")
    state.viewingEffect = effect
    state.viewingDecor = decor

    Avatar.Image = headshot(userId)
    local displayName = profile.name or state.nameHint or "Unknown"
    HandleLabel.Text = "@" .. displayName
    LikesNum.Text = formatNumber(likes)
    EffectStat.Text = effect
    BioLabel.Text = (profile.bio and profile.bio ~= "") and profile.bio or "No bio yet"

    state.viewIsOwner = owner
    UnicornMark.Visible = owner
    TitleLabel.Visible = owner

    if owner then
        TitleLabel.Text = "OWNER"
        NameLabel.Position = UDim2.new(0, 124, 0, 146)
        NameLabel.Size = UDim2.new(1, -140, 0, 26)
    else
        NameLabel.Position = UDim2.new(0, 16, 0, 146)
        NameLabel.Size = UDim2.new(1, -32, 0, 26)
        NameLabel.TextColor3 = Color3.fromRGB(250, 245, 240)
    end
    NameLabel.Text = displayName

    applyEffectTheme(effect)
    applyDecoration(decor)

    local mine = userId == LocalPlayer.UserId
    LikeBtn.Visible = not mine and userId ~= 0
    BioLabel.Visible = not mine
    EditHolder.Visible = mine
    resizeProfileCard()

    if mine then
        BioBox.Text = profile.bio or ""
        state.editEffect = effect
        state.editDecor = decor
        highlightEffects()
        highlightDecors()
        state.editBubble = profile.bubble or "Default"
        PF.highlightBubbles()
        state.myProfile = profile
    end

    if not mine then
        if state.likedCache[userId] then
            LikeBtn.Text = "Liked"
            LikeBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 120)
        else
            LikeBtn.Text = "Like"
            LikeBtn.BackgroundColor3 = Color3.fromRGB(168, 85, 247)
        end
    end
end

local function clearReply()
    state.replyTo = nil
    ReplyBar.Visible = false
    ReplyInfo.Text = "Replying..."
end

local function setReply(data)
    if not data or not data.text then return end
    local snippet = tostring(data.text)
    if #snippet > 38 then snippet = snippet:sub(1, 38) .. "..." end
    state.replyTo = {
        user = data.user,
        userId = data.userId,
        text = data.text,
        time = data.time,
    }
    ReplyInfo.Text = "↩ " .. tostring(data.user or "Player") .. ": " .. snippet
    ReplyBar.Visible = true
    MsgBox:CaptureFocus()
end

-- FIXED Reply Message (no merge + blue)
local function addChatMessage(data)
    if not data or not data.text or not state.isAlive then return end

    local key = tostring(data.time) .. "_" .. tostring(data.userId or data.user) .. "_" .. tostring(data.text):sub(1, 40)
    if state.seenMessages[key] then return end
    state.seenMessages[key] = true

    -- Limit seen cache size
    local count = 0
    for _ in pairs(state.seenMessages) do count = count + 1 end
    if count > 120 then
        state.seenMessages = {}
        state.seenMessages[key] = true
    end

    if isOwner(data.user) and data.userId then
        state.ownerUserId = tonumber(data.userId)
    end

    local K = PF.K
    state.order = state.order + 1
    local owner = isOwner(data.user)
    local mine = tonumber(data.userId) == LocalPlayer.UserId
    local hasReply = type(data.replyUser) == "string" and data.replyText ~= nil

    -- only auto-scroll if the person is already at the bottom (or it's their own message)
    local nearBottom = ChatScroll.AbsoluteCanvasSize.Y <= ChatScroll.AbsoluteWindowSize.Y + 4
        or (ChatScroll.CanvasPosition.Y + ChatScroll.AbsoluteWindowSize.Y) >= ChatScroll.AbsoluteCanvasSize.Y - 80

    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundColor3 = mine and Color3.fromRGB(46, 22, 66) or Color3.fromRGB(34, 17, 12)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.LayoutOrder = state.order
    f.Parent = ChatScroll
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 12)

    if owner or mine then
        local st = Instance.new("UIStroke")
        st.Color = owner and Color3.fromRGB(255, 186, 70) or Color3.fromRGB(168, 85, 247)
        st.Thickness = owner and 1.5 or 1
        st.Transparency = owner and 0 or 0.5
        st.Parent = f
    end

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, K.msgPad)
    pad.PaddingBottom = UDim.new(0, K.msgPad)
    pad.PaddingLeft = UDim.new(0, K.msgPad)
    pad.PaddingRight = UDim.new(0, K.msgPad)
    pad.Parent = f

    -- vertical stack: header -> reply quote -> text. Every row has its own height, so nothing can overlap.
    local contentLayout = Instance.new("UIListLayout")
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, PF.compact and 4 or 6)
    contentLayout.Parent = f

    local function openFromChat()
        local uid = tonumber(data.userId)
        if not uid or uid == 0 then
            StatusLabel.Text = "No profile id"
            return
        end
        state.viewingUserId = uid
        state.nameHint = data.user
        setTab("Profile")
    end

    -- Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, K.head)
    header.BackgroundTransparency = 1
    header.LayoutOrder = 1
    header.Parent = f

    local av = Instance.new("ImageButton")
    av.Size = UDim2.new(0, K.av, 0, K.av)
    av.Position = UDim2.new(0, 0, 0, 1)
    av.BackgroundColor3 = Color3.fromRGB(40, 22, 18)
    av.Image = data.userId and headshot(data.userId) or ""
    av.Parent = header
    Instance.new("UICorner", av).CornerRadius = UDim.new(1, 0)
    local avStroke = Instance.new("UIStroke")
    avStroke.Color = owner and Color3.fromRGB(255, 196, 80) or Color3.fromRGB(255, 140, 40)
    avStroke.Thickness = 1.6
    avStroke.Parent = av
    av.MouseButton1Click:Connect(openFromChat)

    local textX = K.av + 8
    local name = Instance.new("TextButton")
    name.Size = UDim2.new(1, -(textX + K.rw + 4), 0, K.nameH)
    name.Position = UDim2.new(0, textX, 0, 0)
    name.BackgroundTransparency = 1
    name.Text = owner and ("🦄 " .. tostring(data.user)) or tostring(data.user or "Player")
    name.TextColor3 = owner and Color3.fromRGB(255, 196, 90) or Color3.fromRGB(255, 214, 170)
    name.Font = FONT_HEAVY
    name.TextSize = K.nameS
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextTruncate = Enum.TextTruncate.AtEnd
    name.Parent = header
    name.MouseButton1Click:Connect(openFromChat)

    local subText = os.date("%H:%M", tonumber(data.time) or os.time())
    if type(data.game) == "string" and data.game ~= "" and data.game ~= "Unknown" then
        subText = subText .. "  •  " .. data.game
    end
    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -(textX + K.rw + 4), 0, 14)
    sub.Position = UDim2.new(0, textX, 0, K.head - 16)
    sub.BackgroundTransparency = 1
    sub.Text = subText
    sub.TextColor3 = Color3.fromRGB(165, 145, 135)
    sub.Font = FONT
    sub.TextSize = K.subS
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.TextTruncate = Enum.TextTruncate.AtEnd
    sub.Parent = header

    local replyBtn = Instance.new("TextButton")
    replyBtn.Size = UDim2.new(0, K.rw, 0, K.rh)
    replyBtn.Position = UDim2.new(1, -K.rw, 0, (K.head - K.rh) / 2)
    replyBtn.BackgroundColor3 = Color3.fromRGB(52, 30, 74)
    replyBtn.Text = "Reply"
    replyBtn.TextColor3 = Color3.fromRGB(196, 170, 255)
    replyBtn.Font = FONT
    replyBtn.TextSize = PF.compact and 12 or 14
    replyBtn.Parent = header
    Instance.new("UICorner", replyBtn).CornerRadius = UDim.new(0, 8)
    replyBtn.MouseButton1Click:Connect(function()
        setReply(data)
    end)

    -- Blue Reply Box
    if hasReply then
        local replyBox = Instance.new("Frame")
        replyBox.Size = UDim2.new(1, 0, 0, 0)
        replyBox.AutomaticSize = Enum.AutomaticSize.Y
        replyBox.BackgroundColor3 = Color3.fromRGB(18, 28, 50)
        replyBox.BorderSizePixel = 0
        replyBox.LayoutOrder = 2
        replyBox.Parent = f
        Instance.new("UICorner", replyBox).CornerRadius = UDim.new(0, 8)

        local rPad = Instance.new("UIPadding")
        rPad.PaddingTop = UDim.new(0, 5)
        rPad.PaddingBottom = UDim.new(0, 5)
        rPad.PaddingLeft = UDim.new(0, 8)
        rPad.PaddingRight = UDim.new(0, 8)
        rPad.Parent = replyBox

        local rBar = Instance.new("Frame")
        rBar.Size = UDim2.new(0, 3, 1, 0)
        rBar.BackgroundColor3 = Color3.fromRGB(80, 160, 255)
        rBar.BorderSizePixel = 0
        rBar.Parent = replyBox

        local rTxt = Instance.new("TextLabel")
        rTxt.Size = UDim2.new(1, -12, 0, 0)
        rTxt.AutomaticSize = Enum.AutomaticSize.Y
        rTxt.Position = UDim2.new(0, 12, 0, 0)
        rTxt.BackgroundTransparency = 1
        local rSnippet = tostring(data.replyText)
        if #rSnippet > 55 then rSnippet = rSnippet:sub(1, 55) .. "..." end
        rTxt.Text = tostring(data.replyUser or "Player") .. ": " .. rSnippet
        rTxt.TextColor3 = Color3.fromRGB(150, 196, 255)
        rTxt.Font = FONT
        rTxt.TextSize = PF.compact and 13 or 14
        rTxt.TextXAlignment = Enum.TextXAlignment.Left
        rTxt.TextYAlignment = Enum.TextYAlignment.Top
        rTxt.TextWrapped = true
        rTxt.Parent = replyBox
    end

    -- Message text
    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1, 0, 0, 0)
    txt.AutomaticSize = Enum.AutomaticSize.Y
    txt.BackgroundTransparency = 1
    txt.Text = data.text
    txt.TextColor3 = Color3.fromRGB(248, 243, 238)
    txt.Font = FONT
    txt.TextSize = K.txtS
    txt.LineHeight = 1.1
    txt.TextWrapped = true
    txt.RichText = false
    txt.TextXAlignment = Enum.TextXAlignment.Left
    txt.TextYAlignment = Enum.TextYAlignment.Top
    txt.LayoutOrder = 3
    txt.Parent = f

    -- chat bubble style chosen by the sender (cosmetic)
    local targetAlpha = PF.applyBubble(f, data.bubble, txt, name) or 0
    TweenService:Create(f, TweenInfo.new(0.25), {BackgroundTransparency = targetAlpha}):Play()

    if nearBottom or mine then
        scrollToBottom(ChatScroll)
    end
end

local function sendPromo()
    if not ENABLE_GLOBAL_PROMO or state.promoSending or not state.isAlive or not ScreenGui.Parent then return end
    state.promoSending = true
    local line = PROMO_LINES[state.promoIndex]
    state.promoIndex = state.promoIndex % #PROMO_LINES + 1

    local payload = {
        user = LocalPlayer.Name,
        userId = LocalPlayer.UserId,
        text = line,
        time = os.time(),
        game = "RUBO CHAT",
    }
    local res = safeRequest("POST", FIREBASE_URL .. "/messages.json", payload)
    if res then
        addChatMessage(payload)
        state.lastTime = math.max(state.lastTime, payload.time)
        StatusLabel.Text = "Promo sent"
    end
    state.promoSending = false
end

loadProfile = function(userId)
    userId = tonumber(userId) or LocalPlayer.UserId
    state.viewingUserId = userId
    LikesNum.Text = "..."
    NameLabel.Text = "Loading..."
    BioLabel.Text = ""

    local body = safeRequest("GET", FIREBASE_URL .. "/profiles/" .. userId .. ".json")
    local profile = safeJSON(body)

    local hint = state.nameHint
    if userId == LocalPlayer.UserId then hint = LocalPlayer.Name end
    local owner = isOwner(hint, profile and profile.name, userId == LocalPlayer.UserId and LocalPlayer.Name or nil)

    -- unlocked decorations
    if userId == LocalPlayer.UserId then
        local ubody = safeRequest("GET", FIREBASE_URL .. "/unlockedDecor/" .. userId .. ".json")
        local udata = safeJSON(ubody)
        if udata then
            state.unlockedDecor = udata
            state.unlockedDecor.None = true
        end
        if owner then
            for _, d in ipairs(DECORATIONS) do
                state.unlockedDecor[d.id] = true
            end
        end
    end

    if not profile then
        profile = {
            name = hint or "Player",
            likes = owner and OWNER_LIKES or 0,
            bio = owner and "Owner of RUBO Chat" or "Hey! I'm using RUBO Chat",
            effect = owner and "Unicorn" or "Hearts",
            decor = owner and "UnicornFrame" or "None",
            title = owner and "OWNER" or "",
        }
        if userId == LocalPlayer.UserId or owner then
            putProfile(userId, profile)
        end
    else
        profile.name = profile.name or hint or "Player"
        profile.likes = tonumber(profile.likes) or 0
        profile.bio = profile.bio or ""
        profile.effect = profile.effect or (owner and "Unicorn" or "Hearts")
        profile.decor = profile.decor or (owner and "UnicornFrame" or "None")
        if owner then
            profile.title = "OWNER"
            if profile.likes < OWNER_LIKES then
                profile.likes = OWNER_LIKES
                putProfile(userId, profile)
            end
        end
    end

    if owner then state.ownerUserId = userId end
    if userId == LocalPlayer.UserId then state.myProfile = profile end

    applyProfile(userId, profile)
    burst(6)

    if userId ~= LocalPlayer.UserId and userId ~= 0 then
        task.spawn(function()
            local check = safeRequest("GET", FIREBASE_URL .. "/profileLikes/" .. userId .. "/" .. LocalPlayer.UserId .. ".json")
            if check and check ~= "null" then
                state.likedCache[userId] = true
                if state.viewingUserId == userId then
                    LikeBtn.Text = "Liked"
                    LikeBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 120)
                end
            end
        end)
    end
end

local function saveCustomization()
    if state.viewingUserId ~= LocalPlayer.UserId then return end
    local bio = sanitizeText(BioBox.Text, MAX_BIO)

    local profile = state.myProfile or {}
    profile.name = LocalPlayer.Name
    profile.bio = bio
    profile.effect = state.editEffect or "Hearts"
    profile.decor = state.editDecor or "None"
    profile.bubble = state.editBubble or "Default"
    profile.likes = tonumber(profile.likes) or 0

    if isOwner(LocalPlayer.Name) then
        profile.likes = math.max(profile.likes, OWNER_LIKES)
        profile.title = "OWNER"
    end

    putProfile(LocalPlayer.UserId, profile)
    state.myProfile = profile
    state.viewingEffect = profile.effect
    state.viewingDecor = profile.decor
    applyProfile(LocalPlayer.UserId, profile)
    StatusLabel.Text = "Saved"
    burst(5)
end

local function doLike()
    local target = state.viewingUserId
    if target == LocalPlayer.UserId or target == 0 then return end
    if state.likedCache[target] then
        StatusLabel.Text = "Already liked"
        return
    end

    local check = safeRequest("GET", FIREBASE_URL .. "/profileLikes/" .. target .. "/" .. LocalPlayer.UserId .. ".json")
    if check and check ~= "null" then
        state.likedCache[target] = true
        StatusLabel.Text = "Already liked"
        LikeBtn.Text = "Liked"
        return
    end

    safeRequest("PUT", FIREBASE_URL .. "/profileLikes/" .. target .. "/" .. LocalPlayer.UserId .. ".json", "true")

    local body = safeRequest("GET", FIREBASE_URL .. "/profiles/" .. target .. ".json")
    local profile = state.viewingProfile or {}
    local data = safeJSON(body)
    if data then profile = data end

    local likes = tonumber(profile.likes) or 0
    if isOwner(profile.name, state.nameHint) then
        likes = math.max(likes, OWNER_LIKES)
    end
    likes = likes + 1
    profile.likes = likes
    profile.name = profile.name or state.nameHint or "Player"
    profile.bio = profile.bio or ""
    profile.effect = profile.effect or "Hearts"
    profile.decor = profile.decor or "None"

    putProfile(target, profile)
    state.likedCache[target] = true
    state.viewingProfile = profile
    applyProfile(target, profile)
    LikeBtn.Text = "Liked"
    LikeBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 120)
    StatusLabel.Text = "Liked"
    burst(8)
end

loadLeaderboard = function()
    for _, c in pairs(LBScroll:GetChildren()) do
        if c:IsA("GuiButton") or c:IsA("Frame") then c:Destroy() end
    end

    local body = safeRequest("GET", FIREBASE_URL .. "/profiles.json")
    local data = safeJSON(body)

    local list = {}
    local foundOwner = false
    if data then
        for uid, p in pairs(data) do
            if type(p) == "table" then
                p.uid = uid
                p.likes = tonumber(p.likes) or 0
                if isOwner(p.name) then
                    foundOwner = true
                    p.likes = math.max(p.likes, OWNER_LIKES)
                    p.title = "OWNER"
                    state.ownerUserId = tonumber(uid) or state.ownerUserId
                end
                table.insert(list, p)
            end
        end
    end
    if not foundOwner then
        table.insert(list, {
            name = "WORLD_RULER07",
            likes = OWNER_LIKES,
            uid = state.ownerUserId and tostring(state.ownerUserId) or "0",
            effect = "Unicorn",
            decor = "UnicornFrame",
            title = "OWNER",
        })
    end
    table.sort(list, function(a, b) return a.likes > b.likes end)
    if #list > 30 then
        local t = {}
        for i = 1, 30 do t[i] = list[i] end
        list = t
    end

    for i, p in ipairs(list) do
        local owner = isOwner(p.name)
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -6, 0, 58)
        row.BackgroundColor3 = Color3.fromRGB(34, 17, 12)
        row.Text = ""
        row.LayoutOrder = i
        row.Parent = LBScroll
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
        if owner then
            local st = Instance.new("UIStroke")
            st.Color = Color3.fromRGB(255, 186, 70)
            st.Thickness = 1.5
            st.Parent = row
        end

        local medals = {"🥇", "🥈", "🥉"}
        local rank = Instance.new("TextLabel")
        rank.Size = UDim2.new(0, 40, 1, 0)
        rank.Position = UDim2.new(0, 6, 0, 0)
        rank.BackgroundTransparency = 1
        rank.Text = medals[i] or ("#" .. i)
        rank.TextColor3 = Color3.fromRGB(205, 186, 176)
        rank.Font = FONT_HEAVY
        rank.TextSize = medals[i] and 24 or 17
        rank.Parent = row

        local av = Instance.new("ImageLabel")
        av.Size = UDim2.new(0, 42, 0, 42)
        av.Position = UDim2.new(0, 52, 0.5, -21)
        av.BackgroundColor3 = Color3.fromRGB(40, 22, 18)
        av.Image = tonumber(p.uid) and headshot(p.uid) or ""
        av.Parent = row
        Instance.new("UICorner", av).CornerRadius = UDim.new(1, 0)

        local nm = Instance.new("TextLabel")
        nm.Size = UDim2.new(1, -200, 1, 0)
        nm.Position = UDim2.new(0, 102, 0, 0)
        nm.BackgroundTransparency = 1
        nm.Text = owner and ("🦄 " .. (p.name or "WORLD_RULER07")) or (p.name or "Unknown")
        nm.TextColor3 = owner and Color3.fromRGB(255, 206, 110) or Color3.fromRGB(246, 240, 234)
        nm.Font = FONT_HEAVY
        nm.TextSize = 16
        nm.TextXAlignment = Enum.TextXAlignment.Left
        nm.TextTruncate = Enum.TextTruncate.AtEnd
        nm.Parent = row

        local lk = Instance.new("TextLabel")
        lk.Size = UDim2.new(0, 88, 1, 0)
        lk.Position = UDim2.new(1, -94, 0, 0)
        lk.BackgroundTransparency = 1
        lk.Text = "❤ " .. formatNumber(p.likes)
        lk.TextColor3 = Color3.fromRGB(255, 150, 170)
        lk.Font = FONT
        lk.TextSize = 15
        lk.TextXAlignment = Enum.TextXAlignment.Right
        lk.Parent = row
        fit(lk, 15, 9)

        row.MouseButton1Click:Connect(function()
            local uid = tonumber(p.uid)
            state.nameHint = p.name
            if not uid or uid == 0 then
                applyProfile(0, {
                    name = p.name or "WORLD_RULER07",
                    likes = p.likes or OWNER_LIKES,
                    bio = "Owner of RUBO Chat",
                    effect = "Unicorn",
                    decor = "UnicornFrame",
                    title = "OWNER",
                })
                LikeBtn.Visible = false
                setTab("Profile")
                StatusLabel.Text = "Owner profile"
                return
            end
            state.viewingUserId = uid
            setTab("Profile")
        end)
    end

    task.defer(function()
        if LBScroll and LBScroll.Parent then
            LBScroll.CanvasSize = UDim2.new(0, 0, 0, LBList.AbsoluteContentSize.Y + 12)
        end
    end)
end

-- DM
loadDMList = function()
    for _, c in pairs(DMScroll:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("Frame") then c:Destroy() end
    end

    local body = safeRequest("GET", FIREBASE_URL .. "/profileLikes/" .. LocalPlayer.UserId .. ".json")
    local data = safeJSON(body)
    if not data then
        DMChatTitle.Text = "No one liked you yet"
        return
    end

    local order = 0
    for likerId, _ in pairs(data) do
        order = order + 1
        local uid = tonumber(likerId)
        if uid and uid ~= LocalPlayer.UserId then
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, -4, 0, 48)
            row.BackgroundColor3 = Color3.fromRGB(28, 14, 10)
            row.Text = ""
            row.LayoutOrder = order
            row.Parent = DMScroll
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

            local av = Instance.new("ImageLabel")
            av.Size = UDim2.new(0, 34, 0, 34)
            av.Position = UDim2.new(0, 6, 0, 7)
            av.BackgroundColor3 = Color3.fromRGB(40, 22, 18)
            av.Image = headshot(uid)
            av.Parent = row
            Instance.new("UICorner", av).CornerRadius = UDim.new(1, 0)

            local nm = Instance.new("TextLabel")
            nm.Size = UDim2.new(1, -50, 1, 0)
            nm.Position = UDim2.new(0, 46, 0, 0)
            nm.BackgroundTransparency = 1
            nm.Text = "User " .. tostring(uid)
            nm.TextColor3 = Color3.fromRGB(230, 220, 210)
            nm.Font = FONT
            nm.TextSize = 14
            nm.TextXAlignment = Enum.TextXAlignment.Left
            nm.TextTruncate = Enum.TextTruncate.AtEnd
            nm.Parent = row

            task.spawn(function()
                local pbody = safeRequest("GET", FIREBASE_URL .. "/profiles/" .. uid .. ".json")
                local pdata = safeJSON(pbody)
                if pdata and pdata.name then
                    nm.Text = pdata.name
                end
            end)

            row.MouseButton1Click:Connect(function()
                state.dmTargetId = uid
                DMChatTitle.Text = "DM • " .. nm.Text
                loadDMConversation(uid)
            end)
        end
    end

    task.defer(function()
        if DMScroll and DMScroll.Parent then
            DMScroll.CanvasSize = UDim2.new(0, 0, 0, DMListLayout.AbsoluteContentSize.Y + 8)
        end
    end)
end

local function addDMMessage(data, isMe)
    if not state.isAlive then return end
    state.dmOrder = state.dmOrder + 1
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -4, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundColor3 = isMe and Color3.fromRGB(60, 30, 80) or Color3.fromRGB(28, 14, 10)
    f.BorderSizePixel = 0
    f.LayoutOrder = state.dmOrder
    f.Parent = DMMsgScroll
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 5)
    pad.PaddingBottom = UDim.new(0, 5)
    pad.PaddingLeft = UDim.new(0, 7)
    pad.PaddingRight = UDim.new(0, 7)
    pad.Parent = f

    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1, 0, 0, 0)
    txt.AutomaticSize = Enum.AutomaticSize.Y
    txt.BackgroundTransparency = 1
    txt.Text = data.text or ""
    txt.TextColor3 = Color3.fromRGB(240, 235, 230)
    txt.Font = FONT
    txt.TextSize = 14
    txt.TextWrapped = true
    txt.TextXAlignment = Enum.TextXAlignment.Left
    txt.Parent = f

    scrollToBottom(DMMsgScroll)
end

loadDMConversation = function(targetId)
    for _, c in pairs(DMMsgScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    state.dmOrder = 0
    state.dmLastTime = 0

    local key = makeDMKey(LocalPlayer.UserId, targetId)
    local body = safeRequest("GET", FIREBASE_URL .. "/dms/" .. key .. ".json")
    local data = safeJSON(body)
    if not data then return end

    local list = {}
    for _, m in pairs(data) do
        if type(m) == "table" and m.time and m.text then
            table.insert(list, m)
        end
    end
    table.sort(list, function(a, b) return (a.time or 0) < (b.time or 0) end)

    for _, m in ipairs(list) do
        addDMMessage(m, tonumber(m.userId) == LocalPlayer.UserId)
        state.dmLastTime = math.max(state.dmLastTime, m.time or 0)
    end
end

local function sendDM()
    if not state.dmTargetId then
        StatusLabel.Text = "Select someone first"
        return
    end
    local text = sanitizeText(DMMsgBox.Text, MAX_TEXT)
    if text == "" then return end
    DMMsgBox.Text = ""

    local payload = {
        user = LocalPlayer.Name,
        userId = LocalPlayer.UserId,
        text = text,
        time = os.time(),
    }
    local key = makeDMKey(LocalPlayer.UserId, state.dmTargetId)
    local res = safeRequest("POST", FIREBASE_URL .. "/dms/" .. key .. ".json", payload)
    if res then
        addDMMessage(payload, true)
        state.dmLastTime = payload.time
        StatusLabel.Text = "DM sent"
    else
        StatusLabel.Text = "DM failed"
    end
end

-- Admin (client-side only – not secure)
local function resolveTarget()
    local raw = sanitizeText(TargetBox.Text, 40)
    if raw == "" then return nil, nil end
    local uid = tonumber(raw)
    if uid then return uid, nil end

    local body = safeRequest("GET", FIREBASE_URL .. "/profiles.json")
    local data = safeJSON(body)
    if data then
        for id, p in pairs(data) do
            if type(p) == "table" and p.name and string.lower(p.name) == string.lower(raw) then
                return tonumber(id), p.name
            end
        end
    end
    return nil, raw
end

local function adminGiveLikes()
    local uid, name = resolveTarget()
    if not uid then
        AdminStatus.Text = "User not found"
        return
    end
    local amount = tonumber(LikesGiveBox.Text) or 0
    if amount <= 0 then
        AdminStatus.Text = "Enter valid likes"
        return
    end
    local body = safeRequest("GET", FIREBASE_URL .. "/profiles/" .. uid .. ".json")
    local profile = {name = name or "Player", likes = 0, bio = "", effect = "Hearts", decor = "None"}
    local data = safeJSON(body)
    if data then profile = data end
    profile.likes = (tonumber(profile.likes) or 0) + amount
    putProfile(uid, profile)
    AdminStatus.Text = "Gave " .. amount .. " likes (client-side)"
end

local function adminUnlockDecor(decorId)
    local uid, name = resolveTarget()
    if not uid then
        AdminStatus.Text = "User not found"
        return
    end
    local body = safeRequest("GET", FIREBASE_URL .. "/unlockedDecor/" .. uid .. ".json")
    local unlocked = {None = true}
    local data = safeJSON(body)
    if data then unlocked = data end
    unlocked[decorId] = true
    safeRequest("PUT", FIREBASE_URL .. "/unlockedDecor/" .. uid .. ".json", unlocked)

    local pbody = safeRequest("GET", FIREBASE_URL .. "/profiles/" .. uid .. ".json")
    local pdata = safeJSON(pbody)
    if pdata then
        pdata.decor = decorId
        putProfile(uid, pdata)
    end
    AdminStatus.Text = "Unlocked " .. decorId .. " (client-side)"
end

for _, child in pairs(AdminDecorRow:GetChildren()) do
    if child:IsA("TextButton") and child.Name:match("^Unlock_") then
        local decorId = child.Name:gsub("^Unlock_", "")
        child.MouseButton1Click:Connect(function()
            adminUnlockDecor(decorId)
        end)
    end
end

-- Admin: unlock premium effects + chat bubbles (stored in the same unlock table, keys fx_* / bb_*)
local function adminUnlockItem(key, label)
    local uid = resolveTarget()
    if not uid then
        AdminStatus.Text = "User not found"
        return
    end
    local body = safeRequest("GET", FIREBASE_URL .. "/unlockedDecor/" .. uid .. ".json")
    local unlocked = {None = true}
    local data = safeJSON(body)
    if data then unlocked = data end
    unlocked[key] = true
    safeRequest("PUT", FIREBASE_URL .. "/unlockedDecor/" .. uid .. ".json", unlocked)
    AdminStatus.Text = "Unlocked " .. label .. " (client-side)"
end

do
    local function section(labelText, y, list, prefix)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -20, 0, 20)
        lbl.Position = UDim2.new(0, 10, 0, y)
        lbl.BackgroundTransparency = 1
        lbl.Text = labelText
        lbl.TextColor3 = Color3.fromRGB(205, 186, 166)
        lbl.Font = FONT
        lbl.TextSize = 13
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = AdminCard

        local items = {}
        for _, it in ipairs(list) do
            if it.locked then items[#items + 1] = it end
        end
        local rows = math.ceil(#items / 2)
        local h = rows * 28 + (rows - 1) * 5
        local holder = Instance.new("Frame")
        holder.Size = UDim2.new(1, -20, 0, h)
        holder.Position = UDim2.new(0, 10, 0, y + 24)
        holder.BackgroundTransparency = 1
        holder.Parent = AdminCard
        local g = Instance.new("UIGridLayout")
        g.CellSize = UDim2.new(0.48, -4, 0, 28)
        g.CellPadding = UDim2.new(0, 5, 0, 5)
        g.Parent = holder
        for _, it in ipairs(items) do
            local btn = Instance.new("TextButton")
            btn.BackgroundColor3 = Color3.fromRGB(40, 20, 18)
            btn.Text = "Unlock " .. (it.name or it.id)
            btn.TextColor3 = Color3.fromRGB(220, 200, 180)
            btn.Font = FONT
            btn.TextSize = 13
            btn.Parent = holder
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
            fit(btn, 13, 8)
            btn.MouseButton1Click:Connect(function()
                adminUnlockItem(prefix .. it.id, it.name or it.id)
            end)
        end
    end
    section("Unlock Effects for target:", 336, EFFECTS, "fx_")
    section("Unlock Chat Bubbles for target:", 497, BUBBLES, "bb_")
end

setTab = function(name)
    state.currentTab = name
    if name ~= "Profile" then clearParticles() end
    ChatPage.Visible = name == "Chat"
    StudioPage.Visible = name == "Studio"
    LBPage.Visible = name == "Leaderboard"
    ProfilePage.Visible = name == "Profile"
    DMPage.Visible = name == "DM"
    AdminPage.Visible = name == "Admin"
    Title.Text = name == "Chat" and "RUBO Chat" or name

    for n, btn in pairs(tabButtons) do
        if n == name then
            btn.BackgroundColor3 = Color3.fromRGB(255, 122, 40)
            btn.TextColor3 = Color3.new(1, 1, 1)
        else
            btn.BackgroundColor3 = Color3.fromRGB(20, 10, 8)
            btn.TextColor3 = Color3.fromRGB(180, 160, 150)
        end
    end

    if name == "Leaderboard" then
        loadLeaderboard()
    elseif name == "Profile" then
        loadProfile(state.viewingUserId)
    elseif name == "Studio" then
        PF.studioEnter()
    elseif name == "DM" then
        loadDMList()
    end
end

local function pushTyping(active)
    local now = os.clock()
    if active and (now - state.lastTypingPush) < 1.3 then return end
    state.lastTypingPush = now
    if active then
        safeRequest("PUT", FIREBASE_URL .. "/typing/" .. LocalPlayer.UserId .. ".json", {
            user = LocalPlayer.Name,
            userId = LocalPlayer.UserId,
            time = os.time(),
        })
    else
        safeRequest("DELETE", FIREBASE_URL .. "/typing/" .. LocalPlayer.UserId .. ".json")
    end
end

local typingDot = 0
local function fetchTyping()
    local body = safeRequest("GET", FIREBASE_URL .. "/typing.json")
    local data = safeJSON(body)
    if not data then
        TypingLabel.Visible = false
        return
    end
    local now = os.time()
    local names = {}
    for uid, t in pairs(data) do
        if type(t) == "table" and tonumber(uid) ~= LocalPlayer.UserId then
            if now - (tonumber(t.time) or 0) <= TYPING_TTL then
                table.insert(names, tostring(t.user or "Player"))
            end
        end
    end
    if #names == 0 then
        TypingLabel.Visible = false
        return
    end
    typingDot = (typingDot % 3) + 1
    local dots = string.rep(".", typingDot)
    if #names == 1 then
        TypingLabel.Text = names[1] .. " is typing" .. dots
    else
        TypingLabel.Text = names[1] .. " + " .. (#names - 1) .. " typing" .. dots
    end
    TypingLabel.Visible = true
end

local function sendMessage()
    local text = sanitizeText(MsgBox.Text, MAX_TEXT)
    if text == "" or state.sending then return end
    state.sending = true
    MsgBox.Text = ""
    StatusLabel.Text = "Sending..."
    pushTyping(false)

    local gameName = "Unknown"
    pcall(function()
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name then gameName = info.Name end
    end)

    local payload = {
        user = LocalPlayer.Name,
        userId = LocalPlayer.UserId,
        text = text,
        time = os.time(),
        game = gameName,
        bubble = (state.myProfile and state.myProfile.bubble) or "Default",
    }
    if state.replyTo then
        payload.replyUser = state.replyTo.user
        payload.replyUserId = state.replyTo.userId
        payload.replyText = state.replyTo.text
        payload.replyTime = state.replyTo.time
    end

    local res = safeRequest("POST", FIREBASE_URL .. "/messages.json", payload)
    if res then
        StatusLabel.Text = "Sent"
        addChatMessage(payload)
        state.lastTime = math.max(state.lastTime, payload.time)
        clearReply()
    else
        StatusLabel.Text = "Failed to send"
    end
    state.sending = false
end

local function fetchMessages()
    local url = FIREBASE_URL .. '/messages.json?orderBy="time"&limitToLast=' .. MAX_MSG
    local body = safeRequest("GET", url)
    local data = safeJSON(body)
    if not data then
        body = safeRequest("GET", FIREBASE_URL .. "/messages.json")
        data = safeJSON(body)
        if not data then return end
    end

    local list = {}
    for _, m in pairs(data) do
        if type(m) == "table" and m.time and m.text then
            table.insert(list, m)
        end
    end
    table.sort(list, function(a, b) return (a.time or 0) < (b.time or 0) end)
    if #list > MAX_MSG then
        local t = {}
        for i = #list - MAX_MSG + 1, #list do
            table.insert(t, list[i])
        end
        list = t
    end
    for _, m in ipairs(list) do
        if m.time > state.lastTime then
            addChatMessage(m)
            state.lastTime = m.time
        end
    end
    StatusLabel.Text = "Connected"
end

-- RGB Owner Name (limited)
local hue = 0
local rgbConn
rgbConn = RunService.RenderStepped:Connect(function(dt)
    if not state.isAlive or not ScreenGui.Parent then
        if rgbConn then rgbConn:Disconnect() end
        return
    end
    if state.currentTab == "Profile" and (isOwner(NameLabel.Text) or state.viewingUserId == state.ownerUserId) then
        hue = (hue + dt * 0.35) % 1
        NameLabel.TextColor3 = Color3.fromHSV(hue, 0.8, 1)
    end
end)
track(rgbConn)

-- ===================== EVENTS =====================
for name, btn in pairs(tabButtons) do
    btn.MouseButton1Click:Connect(function()
        if name == "Profile" then
            state.viewingUserId = LocalPlayer.UserId
            state.nameHint = LocalPlayer.Name
        end
        setTab(name)
    end)
end

for id, btn in pairs(effectButtons) do
    btn.MouseButton1Click:Connect(function()
        local pack = effectById(id)
        if not PF.isUnlocked("effect", pack) then
            StatusLabel.Text = "🔒 Locked - preview in Studio, unlock: Discord sirrubo"
            return
        end
        state.editEffect = id
        state.viewingEffect = id
        EffectStat.Text = id
        highlightEffects()
        applyEffectTheme(id)
        burst(10)
    end)
end

for id, btn in pairs(bubbleButtons) do
    btn.MouseButton1Click:Connect(function()
        local b = PF.bubbleById(id)
        if not PF.isUnlocked("bubble", b) then
            StatusLabel.Text = "🔒 Locked - preview in Studio, unlock: Discord sirrubo"
            return
        end
        state.editBubble = id
        PF.highlightBubbles()
        StatusLabel.Text = "Bubble: " .. b.name .. " (press Save)"
    end)
end

-- tap the avatar for a burst
Avatar.MouseButton1Click:Connect(function()
    burst(16)
    TweenService:Create(PF.s1.avatarScale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1.15}):Play()
    task.delay(0.14, function()
        TweenService:Create(PF.s1.avatarScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end)
end)
PF.s2.avatar.MouseButton1Click:Connect(function()
    burst(16, PF.s2)
    TweenService:Create(PF.s2.avatarScale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1.15}):Play()
    task.delay(0.14, function()
        TweenService:Create(PF.s2.avatarScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end)
end)

for id, btn in pairs(decorButtons) do
    btn.MouseButton1Click:Connect(function()
        local unlocked = state.unlockedDecor[id] or isOwnerPlayer
        if not unlocked then
            StatusLabel.Text = "🔒 Locked — Ask Owner"
            return
        end
        state.editDecor = id
        state.viewingDecor = id
        highlightDecors()
        applyDecoration(id)
    end)
end

SendBtn.MouseButton1Click:Connect(sendMessage)
MsgBox.FocusLost:Connect(function(enter)
    if enter then sendMessage() else pushTyping(false) end
end)
MsgBox:GetPropertyChangedSignal("Text"):Connect(function()
    if (MsgBox.Text or "") ~= "" then
        pushTyping(true)
    else
        pushTyping(false)
    end
end)

ReplyCancel.MouseButton1Click:Connect(clearReply)
LikeBtn.MouseButton1Click:Connect(doLike)
SaveBtn.MouseButton1Click:Connect(saveCustomization)
CloseBtn.MouseButton1Click:Connect(function()
    pushTyping(false)
    cleanup()
    ScreenGui:Destroy()
end)

DMSendBtn.MouseButton1Click:Connect(sendDM)
DMMsgBox.FocusLost:Connect(function(enter)
    if enter then sendDM() end
end)
GiveLikesBtn.MouseButton1Click:Connect(adminGiveLikes)

-- Start
setTab("Chat")

task.spawn(function()
    loadProfile(LocalPlayer.UserId)
    fetchMessages()
    while state.isAlive and ScreenGui.Parent do
        task.wait(POLL_TIME)
        if not state.isAlive or not ScreenGui.Parent then break end
        if state.currentTab == "Chat" then
            fetchMessages()
            fetchTyping()
        elseif state.currentTab == "DM" and state.dmTargetId then
            local key = makeDMKey(LocalPlayer.UserId, state.dmTargetId)
            local body = safeRequest("GET", FIREBASE_URL .. "/dms/" .. key .. ".json")
            local data = safeJSON(body)
            if data then
                for _, m in pairs(data) do
                    if type(m) == "table" and m.time and m.time > state.dmLastTime then
                        addDMMessage(m, tonumber(m.userId) == LocalPlayer.UserId)
                        state.dmLastTime = m.time
                    end
                end
            end
        end
    end
end)

-- (profile particles / frame animation now run from the visual engine Heartbeat loop)

-- Global Chat Promo (7 min)
task.spawn(function()
    task.wait(5)
    while state.isAlive and ScreenGui.Parent do
        if ENABLE_GLOBAL_PROMO then
            sendPromo()
        end
        task.wait(PROMO_TIME)
    end
end)

-- RUBO System Notification Promo (2 min) – custom GUI, no legacy chat
task.spawn(function()
    local index = 1
    while state.isAlive and ScreenGui.Parent do
        if ENABLE_SYSTEM_PROMO then
            local message = RUBO_SYSTEM_MESSAGES[index]
            showSystemNotif(message)
            index = index + 1
            if index > #RUBO_SYSTEM_MESSAGES then index = 1 end
        end
        task.wait(SYSTEM_PROMO_TIME)
    end
end)

print("[RUBO Chat V4] BROOKHAVEN COMPATIBLE LOADED")
print("→ Reply Fixed (Blue) | Custom System Notifs")
print("→ Decorations + Admin + DM | Safe HTTP + Cleanup")
print("→ RGB Owner Name | Promos Active (toggleable)")
