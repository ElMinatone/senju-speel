-- Refatorado: um sistema por árvore com estados, colisão otimizada e descida profunda
-- Mantive a maioria das configurações originais (CFG) e eventos para compatibilidade

local last = 0
local senjuActive = false
local targetPos
local CFG = {
  radius_min = 15.0,            -- raio mínimo permitido para a área (m)
  radius_max = 15.0,           -- raio máximo permitido para a área (m)
  initial_radius = 15.0,        -- raio inicial ao abrir o Senju (m)
  audio_base_volume = 0.80,    -- volume no centro da área (0.0–1.0)
  audio_max_distance = 100.0,  -- distância máxima para ouvir o áudio (m)
  density_per_m2_min = 0.12,   -- densidade mínima por m² (árvores/m²)
  density_per_m2_max = 0.24,   -- densidade máxima por m² (árvores/m²)
  density_base_radius = 6.0,   -- raio de referência para manter densidade base (m)
  density_geom_mult = 2.0,     -- multiplicador geométrico ao atingir radius_max
  density_min_count = 16,       -- quantidade mínima absoluta de árvores
  density_max_count = 256,      -- quantidade máxima absoluta de árvores
  min_sep_factor = 0.20,       -- separação mínima relativa ao raio (m = raio*factor)
  spawn_depth = 8.0,           -- profundidade inicial abaixo do solo (m)
  descent_depth = 6.0,         -- profundidade extra na descida final (m) (valor original)
  accel_mult = 1.5,            -- multiplicador de aceleração/impacto
  tilt_max_deg = 24.0,         -- máxima inclinação X/Y em graus
  bar_width_factor = 0.5,      -- largura visual da barra (escala do raio)
  indicator_alpha = 220,       -- opacidade do indicador (0–255)
  impact_h = 2.0,
  impact_v = 3.0,
  bar_density_mult = 2.5,
  density_max_count_bar = 512,
}

local RADIUS_MIN = CFG.radius_min
local RADIUS_MAX = CFG.radius_max
local AUDIO_BASE_VOLUME = CFG.audio_base_volume
local AUDIO_MAX_DISTANCE = CFG.audio_max_distance
local DENSITY_MIN = CFG.density_per_m2_min
local DENSITY_MAX = CFG.density_per_m2_max
local DENSITY_BASE_RADIUS = CFG.density_base_radius
local DENSITY_FINAL_MULT = CFG.density_geom_mult
local DENSITY_MIN_COUNT = CFG.density_min_count
local DENSITY_MAX_COUNT = CFG.density_max_count
local ACCEL_MULT = CFG.accel_mult
local TILT_MAX_DEG = CFG.tilt_max_deg
local BAR_WIDTH_FACTOR = CFG.bar_width_factor
local INDICATOR_ALPHA = CFG.indicator_alpha
local SPAWN_DEPTH = CFG.spawn_depth
local DESCENT_DEPTH = CFG.descent_depth
local IMPACT_H = CFG.impact_h
local IMPACT_V = CFG.impact_v
local MIN_SEP_FACTOR = CFG.min_sep_factor
local BAR_DENSITY_MULT = CFG.bar_density_mult
local DENSITY_MAX_COUNT_BAR = CFG.density_max_count_bar
local radius = CFG.initial_radius
local lastTargetPos
local lastRadius
local blinkUntil = 0

-- modelos originais mantidos
local treeModels = {
  `prop_tree_olive_cr2`,
  `prop_tree_eng_oak_cr2`,
  `prop_tree_olive_01`,
  `prop_tree_cedar_s_01`
}
local DECOR_CAST = 'senju_cast'
if not DecorIsRegisteredAsType(DECOR_CAST, 3) then
  DecorRegister(DECOR_CAST, 3)
end
local function isSenjuTreeModel(model)
  return model == GetHashKey('prop_tree_olive_cr2')
      or model == GetHashKey('prop_tree_eng_oak_cr2')
      or model == GetHashKey('prop_tree_olive_01')
      or model == GetHashKey('prop_tree_cedar_s_01')
end

local function modelLabel(h)
  if h == GetHashKey('prop_tree_olive_cr2') then return 'prop_tree_olive_cr2' end
  if h == GetHashKey('prop_tree_eng_oak_cr2') then return 'prop_tree_eng_oak_cr2' end
  if h == GetHashKey('prop_tree_olive_01') then return 'prop_tree_olive_01' end
  if h == GetHashKey('prop_tree_cedar_s_01') then return 'prop_tree_cedar_s_01' end
  return tostring(h)
end

-- compatibilidade (mantive activeProps pois várias partes usam)
local activeProps = {}   -- tabela com objeto ids (para compatibilidade com clearTreesNear original)
local activeTrees = {}   -- objetos do tipo Tree (com estado e métodos)
local casting = false
local shapes = { 'circle', 'bar' }
local shapeIndex = 1
local clearTreesNear -- forward

-- utilitários
local function ensureAnim(dict)
  RequestAnimDict(dict)
  while not HasAnimDictLoaded(dict) do
    Wait(0)
  end
end

local function cancelSenju()
  if not senjuActive then return end
  senjuActive = false
  ClearPedTasksImmediately(PlayerPedId())
  shapeIndex = 1
  radius = CFG.initial_radius
end

local function camForward()
  local r = GetGameplayCamRot(2)
  local rx = math.rad(r.x)
  local rz = math.rad(r.z)
  local cx = -math.sin(rz) * math.cos(rx)
  local cy = math.cos(rz) * math.cos(rx)
  local cz = math.sin(rx)
  return vector3(cx, cy, cz)
end

local function camRight()
  local f = camForward()
  local len = math.sqrt(f.x * f.x + f.y * f.y)
  if len <= 0.0001 then return vector3(1.0, 0.0, 0.0) end
  return vector3(-f.y / len, f.x / len, 0.0)
end

local function raycastFromCam(dist)
  local origin = GetGameplayCamCoord()
  local dir = camForward()
  local dest = origin + dir * (dist or 50.0)
  local ray = StartShapeTestRay(origin.x, origin.y, origin.z, dest.x, dest.y, dest.z, -1, PlayerPedId(), 7)
  local _, hit, endCoord = GetShapeTestResult(ray)
  if hit == 1 then return endCoord end
end

local function stableGroundZ(x, y, z)
  local sx, sy, sz = x, y, z + 20.0
  local ex, ey, ez = x, y, z - 60.0
  local ray = StartShapeTestRay(sx, sy, sz, ex, ey, ez, 1, 0, 7)
  local _, hit, endCoord = GetShapeTestResult(ray)
  if hit == 1 then
    return endCoord.z
  end
  local ok, gz = GetGroundZFor_3dCoord(x, y, z, false)
  if ok then
    return gz
  end
  return z
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function easeOutCubic(t)
  return 1.0 - ((1.0 - t) ^ 3)
end

local TREE_MIN_DISTANCE = 3.5
local POISSON_ATTEMPTS = 60
local function generatePoissonPoints2D(center, radius, minDist)
  local cellSize = minDist / math.sqrt(2)
  local grid = {}
  local points = {}
  local spawnPoints = {}
  spawnPoints[#spawnPoints + 1] = center
  while #spawnPoints > 0 do
    local idx = math.random(#spawnPoints)
    local spawn = spawnPoints[idx]
    local accepted = false
    for _ = 1, POISSON_ATTEMPTS do
      local angle = math.random() * math.pi * 2
      local dist = minDist * (1 + math.random())
      local x = spawn.x + math.cos(angle) * dist
      local y = spawn.y + math.sin(angle) * dist
      if #(vector3(x, y, spawn.z) - center) <= radius then
        local gx = math.floor(x / cellSize)
        local gy = math.floor(y / cellSize)
        local ok = true
        for ix = -1, 1 do
          for iy = -1, 1 do
            local key = (gx + ix) .. ':' .. (gy + iy)
            local neighbor = grid[key]
            if neighbor then
              if #(vector3(x, y, spawn.z) - neighbor) < minDist then
                ok = false
                break
              end
            end
          end
          if not ok then break end
        end
        if ok then
          local pos = vector3(x, y, spawn.z)
          points[#points + 1] = pos
          spawnPoints[#spawnPoints + 1] = pos
          grid[gx .. ':' .. gy] = pos
          accepted = true
          break
        end
      end
    end
    if not accepted then table.remove(spawnPoints, idx) end
  end
  return points
end

local function generatePoissonPointsBar(center, basis, L, W, minDist)
  local cellSize = minDist / math.sqrt(2)
  local grid = {}
  local points = {}
  local spawnPoints = {}
  spawnPoints[#spawnPoints + 1] = center
  local rx, ry = basis.right.x, basis.right.y
  local fx, fy = basis.forward.x, basis.forward.y
  while #spawnPoints > 0 do
    local idx = math.random(#spawnPoints)
    local spawn = spawnPoints[idx]
    local accepted = false
    for _ = 1, POISSON_ATTEMPTS do
      local angle = math.random() * math.pi * 2
      local dist = minDist * (1 + math.random())
      local x = spawn.x + math.cos(angle) * dist
      local y = spawn.y + math.sin(angle) * dist
      local dx = x - center.x
      local dy = y - center.y
      local s = dx * rx + dy * ry
      local w = dx * fx + dy * fy
      if math.abs(s) <= L and math.abs(w) <= W then
        local gx = math.floor(x / cellSize)
        local gy = math.floor(y / cellSize)
        local ok = true
        for ix = -1, 1 do
          for iy = -1, 1 do
            local key = (gx + ix) .. ':' .. (gy + iy)
            local neighbor = grid[key]
            if neighbor then
              if #(vector3(x, y, spawn.z) - neighbor) < minDist then
                ok = false
                break
              end
            end
          end
          if not ok then break end
        end
        if ok then
          local pos = vector3(x, y, spawn.z)
          points[#points + 1] = pos
          spawnPoints[#spawnPoints + 1] = pos
          grid[gx .. ':' .. gy] = pos
          accepted = true
          break
        end
      end
    end
    if not accepted then table.remove(spawnPoints, idx) end
  end
  return points
end

local function drawCircleAt(pos, rad)
  if not pos then return end
  local x, y, z = pos.x, pos.y, pos.z
  local baseZ = stableGroundZ(x, y, z) + 0.05
  local seg = 32
  local a = 0.0
  local px = x + math.cos(a) * rad
  local py = y + math.sin(a) * rad
  for i = 1, seg do
    a = (i / seg) * 2.0 * math.pi
    local nx = x + math.cos(a) * rad
    local ny = y + math.sin(a) * rad
    DrawLine(px, py, baseZ, nx, ny, baseZ, 255, 255, 255, 200)
    px, py = nx, ny
  end
end

local function drawBarAt(pos, rad)
  if not pos then return end
  local right = camRight()
  local forward = camForward()
  local baseZ = stableGroundZ(pos.x, pos.y, pos.z) + 0.05
  local ex = rad
  local ey = rad * BAR_WIDTH_FACTOR
  local c1x = pos.x + right.x * ex
  local c1y = pos.y + right.y * ex
  local c2x = pos.x - right.x * ex
  local c2y = pos.y - right.y * ex
  local fx = forward.x
  local fy = forward.y
  local p1x = c1x + fx * ey
  local p1y = c1y + fy * ey
  local p2x = c2x + fx * ey
  local p2y = c2y + fy * ey
  local p3x = c2x - fx * ey
  local p3y = c2y - fy * ey
  local p4x = c1x - fx * ey
  local p4y = c1y - fy * ey
  DrawLine(p1x, p1y, baseZ, p2x, p2y, baseZ, 255, 255, 255, 200)
  DrawLine(p2x, p2y, baseZ, p3x, p3y, baseZ, 255, 255, 255, 200)
  DrawLine(p3x, p3y, baseZ, p4x, p4y, baseZ, 255, 255, 255, 200)
  DrawLine(p4x, p4y, baseZ, p1x, p1y, baseZ, 255, 255, 255, 200)
end

-- velocidade/temporizadores ajustáveis: mantenho durações originais similares
local ASCEND_DUR = 1500
local HOLD_DUR = 10000 -- total hold timeline original foi 10000 em server event combo
local VISIBLE_HOLD = 8000
local DESCEND_VISIBLE_DUR = 1500
local DESCEND_DEEP_DUR = 1800
local HIDDEN_WAIT = 700 -- espera antes de apagar quando já estiver profundamente abaixo

-- profundidade extra para garantir invisibilidade total antes do delete
local DEEP_DESCENT_EXTRA = 20.0  -- extra além do descida visível; ajuste se quiser desaparecer mais rápido

-- Armazenar frame id para cache de matrices (reduz chamadas GetEntityMatrix)
local frameCounter = 0
local matrixCache = {} -- [entity] = { frame = n, r=fwd, f=right, u=up, pos=pos }

local function cacheGetMatrix(ent)
  if not DoesEntityExist(ent) then return nil end
  local c = matrixCache[ent]
  if c and c.frame == frameCounter then
    return c.r, c.f, c.u, c.pos
  end
  local r, f, u, pos = GetEntityMatrix(ent)
  matrixCache[ent] = { frame = frameCounter, r = r, f = f, u = u, pos = pos }
  return r, f, u, pos
end

-- objeto Tree com máquina de estados
local Tree = {}
Tree.__index = Tree

function Tree:new(o)
  local self = setmetatable({}, Tree)
  self.obj = o.obj
  self.x = o.x
  self.y = o.y
  self.model = o.model
  self.yaw = o.yaw
  self.tiltX = o.tiltX
  self.tiltY = o.tiltY
  self.extX = o.extX
  self.extY = o.extY
  self.extZ = o.extZ
  self.z0 = o.z0 -- z de spawn inicial (abaixo do solo)
  self.z1 = o.z1 -- z do ground (superfície)
  self.zf = o.zf -- z final visível (originally z0 - DESCENT_DEPTH)
  -- novos campos para descent profunda:
  self.zDeep = self.z1 - (DESCENT_DEPTH + DEEP_DESCENT_EXTRA)
  self.state = "ASCENDING" -- ASCENDING -> ACTIVE -> DESCENDING_VISIBLE -> DESCENDING_DEEP -> HIDDEN -> DELETED
  self.stateStart = GetGameTimer()
  self.castId = o.castId
  self.deleted = false
  return self
end

function Tree:setCoords(z)
  if DoesEntityExist(self.obj) then
    SetEntityCoordsNoOffset(self.obj, self.x, self.y, z, true, true, true)
  end
end

function Tree:updateAscending(elapsed)
  local t = math.min(elapsed / ASCEND_DUR, 1.0)
  local eased = easeOutCubic(t)
  local nz = self.z0 + (self.z1 - self.z0) * eased
  self:setCoords(nz)
  if t >= 1.0 then
    self.state = "ACTIVE"
    self.stateStart = GetGameTimer()
  end
end

function Tree:updateActive(elapsed)
  -- simulate holding the trees frozen in ground; after hold move to visible descend
  if elapsed >= VISIBLE_HOLD then
    self.state = "DESCENDING_VISIBLE"
    self.stateStart = GetGameTimer()
  end
end

function Tree:updateDescendingVisible(elapsed)
  local t = math.min(elapsed / DESCEND_VISIBLE_DUR, 1.0)
  local eased = easeOutCubic(t)
  local nz = self.z1 + (self.zf - self.z1) * eased
  self:setCoords(nz)
  if t >= 1.0 then
    self.state = "DESCENDING_DEEP"
    self.stateStart = GetGameTimer()
  end
end

function Tree:updateDescendingDeep(elapsed)
  local t = math.min(elapsed / DESCEND_DEEP_DUR, 1.0)
  local eased = easeOutCubic(t)
  local nz = self.zf + (self.zDeep - self.zf) * eased
  self:setCoords(nz)
  if t >= 1.0 then
    self.state = "HIDDEN"
    self.stateStart = GetGameTimer()
  end
end

function Tree:updateHidden(elapsed)
  if elapsed >= HIDDEN_WAIT then
    if DoesEntityExist(self.obj) then
      SetEntityAsMissionEntity(self.obj, true, true)
      DeleteObject(self.obj)
    end
    self.state = "DELETED"
    self.deleted = true
  end
end

-- checagem otimizada de impacto: primeira esfera, depois box rotacionado via matrix (apenas quando estiver perto)
function Tree:testPedImpact(ped)
  if not DoesEntityExist(self.obj) or not DoesEntityExist(ped) then return false end
  if self.state ~= "ASCENDING" then return false end
  local px, py, pz = table.unpack(GetEntityCoords(ped))
  local dx = px - self.x
  local dy = py - self.y
  local dist2 = dx * dx + dy * dy
  local radiusCheck = math.max(self.extX, self.extY) * 1.02 + 0.1
  if dist2 > (radiusCheck * radiusCheck) then
    return false
  end
  -- se passou na checagem grosseira, faz o teste de matriz (preciso)
  local r, f, u, pos = cacheGetMatrix(self.obj)
  if not r then return false end
  local ddx = px - pos.x
  local ddy = py - pos.y
  local ddz = pz - pos.z
  local lx = r.x * ddx + r.y * ddy + r.z * ddz
  local ly = f.x * ddx + f.y * ddy + f.z * ddz
  local lz = u.x * ddx + u.y * ddy + u.z * ddz
  if math.abs(lx) <= (self.extX * 1.02) and math.abs(ly) <= (self.extY * 1.02) and math.abs(lz) <= (self.extZ * 1.02) then
    -- impacto verdadeiro
    return true, ddx, ddy
  end
  return false
end

function Tree:update()
  -- atualizar estado por tempo
  local now = GetGameTimer()
  local elapsed = now - self.stateStart
  if self.state == "ASCENDING" then
    self:updateAscending(elapsed)
  elseif self.state == "ACTIVE" then
    self:updateActive(elapsed)
  elseif self.state == "DESCENDING_VISIBLE" then
    self:updateDescendingVisible(elapsed)
  elseif self.state == "DESCENDING_DEEP" then
    self:updateDescendingDeep(elapsed)
  elseif self.state == "HIDDEN" then
    self:updateHidden(elapsed)
  end
end

-- limpar arrays helper
local function removeTreeByIndex(i)
  local t = activeTrees[i]
  if t and t.obj then
    for idx = #activeProps, 1, -1 do
      if activeProps[idx] == t.obj then
        table.remove(activeProps, idx)
        break
      end
    end
  end
  table.remove(activeTrees, i)
end

-- função que limpa árvores perto (mantive compatível)
function clearTreesNear(center, radius)
  if activeProps and #activeProps > 0 then
    for i = 1, #activeProps do
      local obj = activeProps[i]
      if DoesEntityExist(obj) then
        local ox, oy = table.unpack(GetEntityCoords(obj))
        local dx = ox - center.x
        local dy = oy - center.y
        if (dx * dx + dy * dy) <= (radius * radius * 1.5) then
          SetEntityAsMissionEntity(obj, true, true)
          DeleteObject(obj)
        end
      end
    end
  end
  -- limpar também nossa lista com estado
  for i = #activeTrees, 1, -1 do
    local t = activeTrees[i]
    local dx = t.x - center.x
    local dy = t.y - center.y
    if (dx * dx + dy * dy) <= (radius * radius * 1.5) then
      -- apagar imediatamente
      if DoesEntityExist(t.obj) then
        SetEntityAsMissionEntity(t.obj, true, true)
        DeleteObject(t.obj)
      end
      table.remove(activeTrees, i)
    end
  end
  activeProps = {}
end

-- modelo carregador robusto (mantive)
local function ensureModel(model)
  if not IsModelInCdimage(model) or not IsModelValid(model) then return false end
  RequestModel(model)
  local tries = 0
  while not HasModelLoaded(model) and tries < 500 do
    tries = tries + 1
    Wait(0)
  end
  return HasModelLoaded(model)
end

-- spawn e distribuição (mantive a abordagem de densidade, mas limpei lógica)
local function castTrees(center, rad, shape, basis)
  if not center then return end
  local cx, cy, cz = center.x, center.y, center.z
  local baseZ = stableGroundZ(cx, cy, cz)
  local objs = {}
  local placed = {}
  local castId = GetGameTimer() + math.random(100, 999)
  local area = math.pi * rad * rad
  local rad2 = rad * rad
  local densRand = DENSITY_MIN + (DENSITY_MAX - DENSITY_MIN) * math.random()
  local t
  if rad <= DENSITY_BASE_RADIUS then
    t = 0.0
  elseif rad >= RADIUS_MAX then
    t = 1.0
  else
    t = (rad - DENSITY_BASE_RADIUS) / (RADIUS_MAX - DENSITY_BASE_RADIUS)
  end
  local geomFactor = DENSITY_FINAL_MULT ^ t
  local dens = densRand * geomFactor
  local baseCount = math.floor(area * dens)
  local capShape = (shape == 'bar') and DENSITY_MAX_COUNT_BAR or DENSITY_MAX_COUNT
  local cap = capShape
  local count_target = math.floor(baseCount * ((shape == 'bar') and (BAR_DENSITY_MULT * 6.76) or 6.76))
  local maxFoot = 0.0
  for _, m in ipairs(treeModels) do
    if ensureModel(m) then
      local mn, mx = GetModelDimensions(m)
      local bx = math.max(math.abs(mn.x or 0.0), math.abs(mx.x or 0.0))
      local by = math.max(math.abs(mn.y or 0.0), math.abs(mx.y or 0.0))
      local f = math.max(bx, by)
      if f > maxFoot then maxFoot = f end
    end
  end
  local sepScale
  if rad <= DENSITY_BASE_RADIUS then
    sepScale = 0.0
  elseif rad >= RADIUS_MAX then
    sepScale = 1.0
  else
    sepScale = (rad - DENSITY_BASE_RADIUS) / (RADIUS_MAX - DENSITY_BASE_RADIUS)
  end
  local footTarget = math.max(TREE_MIN_DISTANCE, maxFoot * 0.85)
  local radiusFactor = math.max(0.24, MIN_SEP_FACTOR)
  local radiusTarget = rad * (radiusFactor + 0.18 * sepScale)
  local minDist = math.min(footTarget, radiusTarget)
  print(('[Senju] sepScale=%.2f maxFoot=%.2f footTarget=%.2f radiusTarget=%.2f minDist=%.2f'):format(sepScale, maxFoot, footTarget, radiusTarget, minDist))
  local points
  if shape == 'bar' and basis and basis.right and basis.forward then
    local L = rad
    local W = rad * BAR_WIDTH_FACTOR
    points = generatePoissonPointsBar(vector3(cx, cy, baseZ), basis, L, W, minDist)
  else
    points = generatePoissonPoints2D(vector3(cx, cy, baseZ), rad, minDist)
  end
  local target = math.min(count_target, cap)
  local limit = math.min(target, #points)
  print(('[Senju] points=%d target=%d cap=%d limit=%d minDist=%.2f shape=%s rad=%.2f'):format(#points, target, cap, limit, minDist, shape, rad))
  if limit < target then
    local combined = {}
    for i = 1, #points do combined[i] = points[i] end
    local md = minDist
    for step = 1, 10 do
      md = md * 0.80
      local extra
      if shape == 'bar' and basis and basis.right and basis.forward then
        local L = rad
        local W = rad * BAR_WIDTH_FACTOR
        extra = generatePoissonPointsBar(vector3(cx, cy, baseZ), basis, L, W, md)
      else
        extra = generatePoissonPoints2D(vector3(cx, cy, baseZ), rad, md)
      end
      for i = 1, #extra do
        local px = extra[i].x
        local py = extra[i].y
        local ok = true
        for j = 1, #combined do
          local dx = px - combined[j].x
          local dy = py - combined[j].y
          if (dx * dx + dy * dy) < (md * md) then ok = false break end
        end
        if ok then combined[#combined + 1] = extra[i] end
        if #combined >= target then break end
      end
      if #combined >= target then break end
    end
    points = combined
    limit = math.min(target, #points)
    print(('[Senju] fallback combined=%d limit=%d md=%.2f'):format(#points, limit, md))
  end
  if limit <= 0 then print('[Senju] no spawn points generated') end
  for i = 1, limit do
    local px = points[i].x
    local py = points[i].y
    local model = treeModels[math.random(1, #treeModels)]
    if not ensureModel(model) then goto continue end
    local minDim, maxDim = GetModelDimensions(model)
    local baseX = math.max(math.abs(minDim.x or 0.0), math.abs(maxDim.x or 0.0))
    local baseY = math.max(math.abs(minDim.y or 0.0), math.abs(maxDim.y or 0.0))
    local foot = math.max(baseX, baseY)
    local ok = true
    for j = 1, #placed do
      local dx = px - placed[j].x
      local dy = py - placed[j].y
      local req = minDist
      if (dx * dx + dy * dy) < (req * req) then ok = false break end
    end
    if not ok then goto continue end
    placed[#placed + 1] = { x = px, y = py, foot = foot }
    local ogz = stableGroundZ(px, py, baseZ)
    local zStart = math.min(baseZ, ogz) - SPAWN_DEPTH
    local obj = CreateObject(model, px, py, zStart, true, true, false)
    if not obj or obj == 0 then goto continue end
    print(('[Senju] spawn %s (%.2f, %.2f, %.2f)'):format(modelLabel(model), px, py, zStart))
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityCollision(obj, true, true)
    SetEntityDynamic(obj, false)
    DecorSetInt(obj, DECOR_CAST, castId)
    local yaw = math.random() * 360.0
    local tiltChance = (math.random() < 0.35)
    local tiltX = tiltChance and ((math.random() - 0.5) * TILT_MAX_DEG) or 0.0
    local tiltY = tiltChance and ((math.random() - 0.5) * TILT_MAX_DEG) or 0.0
    SetEntityRotation(obj, tiltX, tiltY, yaw, 2)
    local s = 0.8 + math.random() * 1.2
    local f, rgt, up, pos = GetEntityMatrix(obj)
    local fx, fy, fz = f.x * s, f.y * s, f.z * s
    local rx, ry, rz = rgt.x * s, rgt.y * s, rgt.z * s
    local ux, uy, uz = up.x * s, up.y * s, up.z * s
    SetEntityMatrix(obj, fx, fy, fz, rx, ry, rz, ux, uy, uz, px, py, zStart)
    local minDim2, maxDim2 = GetModelDimensions(model)
    local extX = math.max(math.abs(minDim2.x or 0.0), math.abs(maxDim2.x or 0.0))
    local extY = math.max(math.abs(minDim2.y or 0.0), math.abs(maxDim2.y or 0.0))
    local extZ = math.max(math.abs(minDim2.z or 0.0), math.abs(maxDim2.z or 0.0))
    local treeObj = {
      obj = obj,
      x = px,
      y = py,
      z0 = zStart,
      zf = zStart - DESCENT_DEPTH,
      z1 = ogz,
      model = model,
      tiltX = tiltX,
      tiltY = tiltY,
      yaw = yaw,
      extX = extX,
      extY = extY,
      extZ = extZ,
      castId = castId
    }
    table.insert(objs, treeObj)
    table.insert(activeProps, obj)
    ::continue::
  end

  -- alinhar todos ao mesmo z0 mínimo para animação sincronizada (como no original)
  local minZStart = 1e9
  for i = 1, #objs do
    if objs[i].z0 < minZStart then minZStart = objs[i].z0 end
  end
  if minZStart < 1e9 then
    for i = 1, #objs do
      local o = objs[i]
      SetEntityCoordsNoOffset(o.obj, o.x, o.y, minZStart, true, true, true)
      o.z0 = minZStart
      o.zf = minZStart - DESCENT_DEPTH
      -- calculamos zDeep maior que zf para esconder de fato
      o.zDeep = o.z1 - (DESCENT_DEPTH + DEEP_DESCENT_EXTRA)
    end
  end

  -- criar instâncias Tree para gerenciamento fino
  for _, o in ipairs(objs) do
    table.insert(activeTrees, Tree:new(o))
  end

  -- Trigger eventos de audio/impact (mesma lógica)
  TriggerServerEvent('um-senju:server:playAudio', { x = cx, y = cy, z = baseZ }, AUDIO_MAX_DISTANCE, AUDIO_BASE_VOLUME,
    ASCEND_DUR + HOLD_DUR + DESCEND_VISIBLE_DUR + DESCEND_DEEP_DUR + 6000)
  TriggerServerEvent('um-senju:server:startImpact', { x = cx, y = cy, z = baseZ }, rad, ASCEND_DUR, VISIBLE_HOLD, (DESCEND_VISIBLE_DUR + DESCEND_DEEP_DUR))

  -- thread principal que animava objetos (subi/impacto/descida original) agora reduzido:
  CreateThread(function()
    local start = GetGameTimer()
    local frame = 0
    local dur = ASCEND_DUR
    local rad2local = rad * rad
    local affectedVehs = {}
    local ragdolled = {}

    -- ASCEND (sincroniza setup e aplica forças durante subida)
    while true do
      local now = GetGameTimer()
      local t = (now - start) / dur
      if t >= 1.0 then t = 1.0 end
      local eased = 1.0 - ((1.0 - t) ^ 3)
      frameCounter = frameCounter + 1
      for _, tr in ipairs(activeTrees) do
        if tr.state == "ASCENDING" then
          local nz = tr.z0 + (tr.z1 - tr.z0) * eased
          SetEntityCoordsNoOffset(tr.obj, tr.x, tr.y, nz, true, true, true)
          SetEntityRotation(tr.obj, tr.tiltX, tr.tiltY, tr.yaw, 2)
          SetEntityVelocity(tr.obj, 0.0, 0.0, math.max(0.0, (nz - GetEntityCoords(tr.obj).z) * (20.0 * ACCEL_MULT)))
        end
      end

      -- impacto antecipado (check coarse players & peds) - apenas a cada 2 frames para menor custo
      if (frame % 2) == 0 then
        local players = GetActivePlayers()
        for i = 1, #players do
          local pid = players[i]
          local pped = GetPlayerPed(pid)
          local px, py, pz = table.unpack(GetEntityCoords(pped))
          local dx = px - cx
          local dy = py - cy
          local dist2 = dx * dx + dy * dy
          if dist2 <= rad2local then
            -- para cada tree: primeiro checagem grossa e depois caixa rotacionada (via Tree:testPedImpact)
            for _, tr in ipairs(activeTrees) do
              local ok, ddx, ddy = tr:testPedImpact(pped)
              if ok and not ragdolled[pped] then
                ragdolled[pped] = true
                local dlen = math.sqrt((ddx or 0) * (ddx or 0) + (ddy or 0) * (ddy or 0)) + 0.001
                local enx = (ddx or 0) / dlen
                local eny = (ddy or 0) / dlen
                -- aplicar força similar ao original
                SetPedToRagdoll(pped, 2000, 2000, 0, false, false, false)
                ApplyForceToEntityCenterOfMass(pped, 1, enx * (IMPACT_H * ACCEL_MULT * 0.6), eny * (IMPACT_H * ACCEL_MULT * 0.6), (IMPACT_V * ACCEL_MULT * 0.6), false, true, true, false)
              end
            end
          end
        end

        -- NPCs (FindFirstPed) - reduzimos chamadas ao mínimo necessário
        local handle, ped = FindFirstPed()
        local success = true
        while success do
          if ped ~= 0 and ped ~= PlayerPedId() and not IsPedAPlayer(ped) and not IsEntityDead(ped) then
            local px, py, pz = table.unpack(GetEntityCoords(ped))
            local dx = px - cx
            local dy = py - cy
            local dist2 = dx * dx + dy * dy
            if dist2 <= rad2local then
              for _, tr in ipairs(activeTrees) do
                local ok, ddx, ddy = tr:testPedImpact(ped)
                if ok and not ragdolled[ped] then
                  ragdolled[ped] = true
                  local dlen = math.sqrt((ddx or 0) * (ddx or 0) + (ddy or 0) * (ddy or 0)) + 0.001
                  local enx = (ddx or 0) / dlen
                  local eny = (ddy or 0) / dlen
                  SetPedToRagdoll(ped, 2000, 2000, 0, false, false, false)
                  ApplyForceToEntityCenterOfMass(ped, 1, enx * (IMPACT_H * ACCEL_MULT * 0.6), eny * (IMPACT_H * ACCEL_MULT * 0.6), (IMPACT_V * ACCEL_MULT * 0.6), false, true, true, false)
                  break
                end
              end
            end
          end
          success, ped = FindNextPed(handle)
        end
        EndFindPed(handle)
      end

      if t >= 1.0 then break end
      frame = frame + 1
      Wait(0)
    end

    -- HOLD (faz as árvores ficarem no ground por um tempo, original tinha hold com audio)
    local holdStart = GetGameTimer()
    while GetGameTimer() - holdStart < VISIBLE_HOLD do
      -- garantir árvores congeladas na z1
      for _, tr in ipairs(activeTrees) do
        if DoesEntityExist(tr.obj) then
          SetEntityCoordsNoOffset(tr.obj, tr.x, tr.y, tr.z1, true, true, true)
          SetEntityRotation(tr.obj, tr.tiltX, tr.tiltY, tr.yaw, 2)
          FreezeEntityPosition(tr.obj, true)
        end
      end
      Wait(0)
    end

    -- descongelar e iniciar descida (visível -> profunda)
    -- áudio final: toca no início da descida
    TriggerServerEvent('um-senju:server:playAudio', { x = cx, y = cy, z = baseZ }, AUDIO_MAX_DISTANCE, AUDIO_BASE_VOLUME,
      (DESCEND_VISIBLE_DUR + DESCEND_DEEP_DUR))
    local dstart = GetGameTimer()
    frame = 0
    while true do
      local now = GetGameTimer()
      local t = (now - dstart) / (DESCEND_VISIBLE_DUR + DESCEND_DEEP_DUR)
      if t >= 1.0 then t = 1.0 end
      frameCounter = frameCounter + 1
      -- atualizamos cada tree via máquina de estados (Tree:update será chamada no loop global)
      if t >= 1.0 then break end
      frame = frame + 1
      Wait(0)
    end

    -- aguardar até que árvores entrem no estado DELETED para finalizar esta thread
    while true do
      local allDeleted = true
      for _, tr in ipairs(activeTrees) do
        if not tr.deleted then
          allDeleted = false
          break
        end
      end
      if allDeleted then break end
      Wait(200)
    end

    -- final cleanup
    for _, o in ipairs(objs) do
      SetModelAsNoLongerNeeded(o.model)
    end
    activeProps = {}
    for veh, _ in pairs(affectedVehs) do
      if DoesEntityExist(veh) then
        SetEntityAsNoLongerNeeded(veh)
      end
    end
    casting = false
    TriggerServerEvent('um-senju:server:stopImpact')
    clearTreesNear({ x = cx, y = cy, z = baseZ }, rad + 8.0)
    TriggerServerEvent('um-senju:server:clearTreesNear', { x = cx, y = cy, z = baseZ }, rad + 12.0, castId)
  end)
end

-- Evento do servidor (impact) usa checagem do player (mantive compatível)
RegisterNetEvent('um-senju:client:impact', function(center, radius, ascendMs, holdMs, descendMs)
  -- Mantive função para compatibilidade com server triggers, mas nossa lógica de impacto
  -- principal está dentro do castTrees (thread local criada no cast)
  -- Aqui apenas reproduzemos fallback: se for chamado diretamente, faz a mesma coisa leve.
  local start = GetGameTimer()
  local ped = PlayerPedId()
  local frame = 0
  local function violentPhase(now)
    local el = now - start
    if el < ascendMs then return true end
    return false
  end
  CreateThread(function()
    while true do
      local now = GetGameTimer()
      if not violentPhase(now) then
        if now - start > (ascendMs + holdMs + descendMs) then break end
        Wait(0)
        goto continue
      end
      if (frame % 2) == 0 then
        -- fallback: buscar objetos e aplicar ragdoll se tocar
        local px, py, pz = table.unpack(GetEntityCoords(ped))
        local ok, obj = FindFirstObject()
        local success = true
        while success do
          if obj ~= 0 then
            local model = GetEntityModel(obj)
            if model == GetHashKey('prop_tree_olive_cr2') or model == GetHashKey('prop_tree_eng_oak_cr2') or model == GetHashKey('prop_sapling_break_02') or model == GetHashKey('prop_tree_birch_03b') or model == GetHashKey('prop_tree_cedar_02') or model == GetHashKey('test_tree_forest_trunk_01') then
              if IsEntityTouchingEntity(ped, obj) then
                local dx = px - center.x
                local dy = py - center.y
                local dlen = math.sqrt(dx * dx + dy * dy) + 0.001
                local nx = dx / dlen
                local ny = dy / dlen
                SetPedToRagdoll(ped, 1500, 1500, 0, false, false, false)
                ApplyForceToEntity(ped, 1, nx * (85.0 * ACCEL_MULT), ny * (85.0 * ACCEL_MULT), (40.0 * ACCEL_MULT), 0.0, 0.0, 0.0, false, true, true, false, true)
                break
              end
            end
          end
          success, obj = FindNextObject(ok)
        end
        EndFindObject(ok)
      end
      ::continue::
      frame = frame + 1
      Wait(0)
    end
  end)
end)

RegisterNetEvent('um-senju:client:impactStop', function()
  -- thread exits por timeline, sem ação aqui
end)

RegisterNetEvent('um-senju:client:clearTrees', function()
  local handle, obj = FindFirstObject()
  local success = true
  while success do
    if obj ~= 0 then
      local model = GetEntityModel(obj)
      if isSenjuTreeModel(model) then
        SetEntityAsMissionEntity(obj, true, true)
        DeleteObject(obj)
      end
    end
    success, obj = FindNextObject(handle)
  end
  EndFindObject(handle)
  activeProps = {}
  -- limpar instâncias Tree também
  for i = #activeTrees, 1, -1 do
    local t = activeTrees[i]
    if t and t.obj and DoesEntityExist(t.obj) then
      SetEntityAsMissionEntity(t.obj, true, true)
      DeleteObject(t.obj)
    end
    table.remove(activeTrees, i)
  end
end)

RegisterNetEvent('um-senju:client:clearTreesWorldNear', function(center, radius, castId)
  local handle, obj = FindFirstObject()
  local success = true
  while success do
    if obj ~= 0 then
      local model = GetEntityModel(obj)
      if isSenjuTreeModel(model) then
        local ox, oy, oz = table.unpack(GetEntityCoords(obj))
        local dx = ox - center.x
        local dy = oy - center.y
        if (dx * dx + dy * dy) <= (radius * radius) then
          if DecorExistOn(obj, DECOR_CAST) then
            local oid = DecorGetInt(obj, DECOR_CAST)
            if oid == castId then
              SetEntityAsMissionEntity(obj, true, true)
              DeleteObject(obj)
            end
          end
        end
      end
    end
    success, obj = FindNextObject(handle)
  end
  EndFindObject(handle)
  -- limpeza local de activeTrees
  for i = #activeTrees, 1, -1 do
    local t = activeTrees[i]
    local dx = t.x - center.x
    local dy = t.y - center.y
    if (dx * dx + dy * dy) <= (radius * radius) then
      if t.castId == castId then
        if DoesEntityExist(t.obj) then
          SetEntityAsMissionEntity(t.obj, true, true)
          DeleteObject(t.obj)
        end
        table.remove(activeTrees, i)
      end
    end
  end
end)

RegisterNetEvent('um-senju:client:playAudio', function(center, maxDist, baseVol, duration)
  local ped = PlayerPedId()
  local start = GetGameTimer()
  SendNUIMessage({ action = 'play', volume = baseVol, src = 'nui://um-senju/html/growing.mp3' })
  CreateThread(function()
    while GetGameTimer() - start < (duration or 13000) do
      local p = GetEntityCoords(ped)
      local dx = p.x - center.x
      local dy = p.y - center.y
      local dz = p.z - center.z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      local vol = 0.0
      if d < maxDist then
        vol = baseVol * (1.0 - (d / maxDist))
      end
      SendNUIMessage({ action = 'volume', volume = vol })
      Wait(250)
    end
    SendNUIMessage({ action = 'stop' })
  end)
end)

-- Global update loop: atualiza todas as árvores (estado e colisões)
CreateThread(function()
  while true do
    frameCounter = frameCounter + 1
    frameCounter = frameCounter % 2147483647
    matrixCache = matrixCache or {}
    -- atualiza cada árvore por estado
    for i = #activeTrees, 1, -1 do
      local tr = activeTrees[i]
      if tr and not tr.deleted then
        tr:update()
        -- se ACTIVE, checar colisões contra player (aplica força/vs ragdoll)
        if tr.state == "ACTIVE" then
        end
      else
        -- se deletado, remover da lista
        if tr and tr.deleted then
          removeTreeByIndex(i)
        end
      end
    end
    Wait(0)
  end
end)

-- interface de ativação (mantive seu comportamento de UI/controles)
RegisterNetEvent('um-senju:client:activate', function(src)
  local now = GetGameTimer()
  if casting or next(activeProps) ~= nil then
    TriggerEvent('QBCore:Notify', 'O solo ainda está se recuperando...', 'error', 2000)
    return
  end
  if senjuActive then
    cancelSenju()
    return
  end

  last = now
  shapeIndex = 1
  radius = 15.0
  senjuActive = true
  local ped = PlayerPedId()
  CreateThread(function()
    while senjuActive do
      DisableControlAction(0, 24, true)
      DisableControlAction(0, 25, true)
      DisableControlAction(0, 140, true)
      DisableControlAction(0, 141, true)
      DisableControlAction(0, 142, true)
      local origin = GetGameplayCamCoord()
      local dir = camForward()
      local hitPos = raycastFromCam(60.0)
      if hitPos then
        local gz = stableGroundZ(hitPos.x, hitPos.y, hitPos.z)
        if lastTargetPos then
          targetPos = vec3(lerp(lastTargetPos.x, hitPos.x, 0.35), lerp(lastTargetPos.y, hitPos.y, 0.35), gz)
        else
          targetPos = vec3(hitPos.x, hitPos.y, gz)
        end
        lastTargetPos = targetPos
      else
        local fb = lastTargetPos or (origin + dir * 5.0)
        local gz = stableGroundZ(fb.x, fb.y, fb.z)
        targetPos = vec3(fb.x, fb.y, gz)
      end
      
      if shapes[shapeIndex] == 'bar' then
        drawBarAt(targetPos, radius)
      else
        drawCircleAt(targetPos, radius)
      end

      BeginTextCommandDisplayHelp("STRING")
      AddTextComponentSubstringPlayerName("~INPUT_CELLPHONE_CANCEL~ Cancelar | ~INPUT_COVER~ Formato | ~INPUT_ATTACK~ Castar")
      EndTextCommandDisplayHelp(0, false, false, -1)

      if IsDisabledControlJustPressed(0, 24) then
        if casting or next(activeProps) ~= nil then
        else
          ensureAnim('misslamar1leadinout')
          TaskPlayAnim(ped, 'misslamar1leadinout', 'yoga_02_idle', 8.0, 1.0, 3000, 1, 0.0, false, false, false)
          CreateThread(function()
            Wait(3000)
            ClearPedTasksImmediately(ped)
          end)
          casting = true
          CreateThread(function()
            while casting do
              DisableControlAction(0, 24, true)
              DisableControlAction(0, 25, true)
              DisableControlAction(0, 140, true)
              DisableControlAction(0, 141, true)
              DisableControlAction(0, 142, true)
              if IsControlJustPressed(0, 167) or IsControlJustPressed(0, 73) or IsControlJustPressed(0, 200) or IsControlJustPressed(0, 177) then
                ClearPedTasksImmediately(ped)
                casting = false
                castAbort = true
              end
              Wait(0)
            end
          end)
          Wait(500)
          castTrees(targetPos, radius, shapes[shapeIndex], { right = camRight(), forward = camForward() })
          senjuActive = false
          break
        end
      end
      if IsControlJustPressed(0, 44) then
        shapeIndex = shapeIndex - 1
        if shapeIndex < 1 then shapeIndex = #shapes end
      end
      if IsControlJustPressed(0, 38) then
        shapeIndex = shapeIndex + 1
        if shapeIndex > #shapes then shapeIndex = 1 end
      end
      if IsControlJustPressed(0, 167) or IsControlJustPressed(0, 73) or IsControlJustPressed(0, 200) or IsControlJustPressed(0, 177) then
        castAbort = true
        cancelSenju()
        break
      end
      Wait(0)
    end
  end)
end)

RegisterCommand('senju', function()
  TriggerServerEvent('um-senju:server:request')
end)
