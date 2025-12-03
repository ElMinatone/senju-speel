local last = 0
local senjuActive = false
local targetPos
local RADIUS_MIN = 2.0 -- raio mínimo da área em metros
local RADIUS_MAX = 15.0 -- raio máximo da área em metros
local AUDIO_BASE_VOLUME = 0.9 -- volume no centro da área (0.0 a 1.0)
local AUDIO_MAX_DISTANCE = 60.0 -- distância máxima para ouvir o áudio em metros
local DENSITY_MIN = 0.10 -- densidade mínima de árvores por m²
local DENSITY_MAX = 0.20 -- densidade máxima de árvores por m²
local DENSITY_MIN_COUNT = 8 -- quantidade mínima de árvores
local DENSITY_MAX_COUNT = 40 -- quantidade máxima de árvores
local DENSITY_BASE_RADIUS = 4.0 -- raio referência onde a densidade padrão é mantida
local DENSITY_FINAL_MULT = 6.0 -- multiplicador final da densidade ao atingir RADIUS_MAX
local ACCEL_MULT = 1.3 -- multiplicador de aceleração; maior = mais brusco e mais impacto
local radius = 5.0 -- raio inicial da área em metros
local lastTargetPos
local lastRadius
local blinkUntil = 0
local treeModels = {
  `prop_tree_olive_cr2`,
  `prop_tree_eng_oak_cr2`,
  `prop_sapling_break_02`,
  `prop_tree_birch_03b`,
}

local activeProps = {}
local casting = false
local shapes = { 'circle', 'bar' }
local shapeIndex = 1

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
  radius = 5.0
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

local function drawCircleAt(pos, rad)
  if not pos then return end
  local x, y, z = pos.x, pos.y, pos.z
  local _, gz = GetGroundZFor_3dCoord(x, y, z, false)
  local now = GetGameTimer()
  local alpha = 180
  if blinkUntil > now then
    alpha = 120 + math.floor(80 * math.abs(math.sin(now / 120.0)))
  end
  DrawMarker(1, x, y, (gz or z) + 0.03, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, rad * 2.2, rad * 2.2, 0.35, 255, 255, 255, alpha,
    false, true, 2, false, nil, nil, false)
end

local function drawBarAt(pos, rad)
  if not pos then return end
  local right = camRight()
  local _, gz = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z, false)
  local baseZ = (gz or pos.z) + 0.03
  local heading = math.deg(math.atan2(right.y, right.x))
  local now = GetGameTimer()
  local alpha = 180
  if blinkUntil > now then
    alpha = 120 + math.floor(80 * math.abs(math.sin(now / 120.0)))
  end
  DrawMarker(1, pos.x, pos.y, baseZ, 0.0, 0.0, 0.0, 0.0, 0.0, heading, rad * 2.2, rad * 0.6, 0.25, 255, 255, 255, alpha, false, true, 2, false, nil, nil, false)
end

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

local function castTrees(center, rad, shape, basis)
  if not center then return end
  local cx, cy, cz = center.x, center.y, center.z
  local _, gz = GetGroundZFor_3dCoord(cx, cy, cz, false)
  local baseZ = (gz or cz)
  local objs = {}
  local placed = {}
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
  local rawCount = math.floor(area * dens)
  local count = math.min(DENSITY_MAX_COUNT, math.max(DENSITY_MIN_COUNT, rawCount))
  for i = 1, count do
    local ox, oy
    if shape == 'bar' and basis and basis.right and basis.forward then
      local L = rad
      local W = rad * 0.5
      local s = (math.random() * 2.0 - 1.0) * L
      local w = (math.random() * 2.0 - 1.0) * W
      ox = cx + basis.right.x * s + basis.forward.x * w
      oy = cy + basis.right.y * s + basis.forward.y * w
    else
      local minSep = math.max(2.5, rad * 0.15)
      local found = false
      for try = 1, 12 do
        local ang = math.random() * 2.0 * math.pi
        local r = (math.random() * 0.8 + 0.4) * rad
        local tx = cx + math.cos(ang) * r
        local ty = cy + math.sin(ang) * r
        local ok = true
        for j = 1, #placed do
          local dx = tx - placed[j].x
          local dy = ty - placed[j].y
          if (dx * dx + dy * dy) < (minSep * minSep) then
            ok = false
            break
          end
        end
        if ok then
          ox, oy = tx, ty
          found = true
          break
        end
      end
      if not found then
        local ang = math.random() * 2.0 * math.pi
        local r = (math.random() * 0.8 + 0.4) * rad
        ox = cx + math.cos(ang) * r
        oy = cy + math.sin(ang) * r
      end
    end
    placed[#placed + 1] = { x = ox, y = oy }
    local _, ogz = GetGroundZFor_3dCoord(ox, oy, baseZ, false)
    local zStart = (ogz or baseZ) - 18.0
    local model = treeModels[math.random(1, #treeModels)]
    if not ensureModel(model) then goto continue end
    local obj = CreateObject(model, ox, oy, zStart, true, true, false)
    if not obj or obj == 0 then goto continue end
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityCollision(obj, true, true)
    SetEntityDynamic(obj, true)
    ActivatePhysics(obj)
    local yaw = math.random() * 360.0
    local tiltChance = (math.random() < 0.35)
    local tiltX = tiltChance and ((math.random() - 0.5) * 6.0) or 0.0
    local tiltY = tiltChance and ((math.random() - 0.5) * 6.0) or 0.0
    SetEntityRotation(obj, tiltX, tiltY, yaw, 2)
    local s = 0.8 + math.random() * 1.2
    local f, rgt, up, pos = GetEntityMatrix(obj)
    local fx, fy, fz = f.x * s, f.y * s, f.z * s
    local rx, ry, rz = rgt.x * s, rgt.y * s, rgt.z * s
    local ux, uy, uz = up.x * s, up.y * s, up.z * s
    SetEntityMatrix(obj, fx, fy, fz, rx, ry, rz, ux, uy, uz, ox, oy, zStart)
    objs[#objs + 1] = { obj = obj, x = ox, y = oy, z0 = zStart, zf = zStart - 6.0, z1 = (ogz or baseZ), model = model, tiltX = tiltX, tiltY = tiltY, yaw = yaw }
    activeProps[#activeProps + 1] = obj
    ::continue::
  end
  local start = GetGameTimer()
  local dur = 1500
  local affectedVehs = {}
  TriggerServerEvent('um-senju:server:playAudio', {x=cx,y=cy,z=baseZ}, AUDIO_MAX_DISTANCE, AUDIO_BASE_VOLUME, 1500 + 10000 + 1500)
  CreateThread(function()
    local frame = 0
    while true do
      local now = GetGameTimer()
      local t = (now - start) / dur
      if t >= 1.0 then t = 1.0 end
      local eased = 1.0 - ((1.0 - t) ^ 3)
      for _, o in ipairs(objs) do
        local nz = o.z0 + (o.z1 - o.z0) * eased
        local dz = nz - (GetEntityCoords(o.obj).z)
        SetEntityCoordsNoOffset(o.obj, o.x, o.y, nz, true, true, true)
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.yaw, 2)
        SetEntityVelocity(o.obj, 0.0, 0.0, math.max(0.0, dz * (20.0 * ACCEL_MULT)))
      end
      if (frame % 2) == 0 then
        local players = GetActivePlayers()
        for i = 1, #players do
          local pid = players[i]
          local pped = GetPlayerPed(pid)
          local px, py, pz = table.unpack(GetEntityCoords(pped))
          local dx = px - cx
          local dy = py - cy
          local dist2 = dx * dx + dy * dy
          if dist2 <= rad2 then
            local dlen = math.sqrt(dist2) + 0.001
            local nx = dx / dlen
            local ny = dy / dlen
            local zBoost = 35.0 * ACCEL_MULT
            local veh = GetVehiclePedIsIn(pped, false)
            if veh and veh ~= 0 then
              if not affectedVehs[veh] then
                SetEntityAsMissionEntity(veh, true, true)
                affectedVehs[veh] = true
              end
              ApplyForceToEntity(veh, 1, nx * (60.0 * ACCEL_MULT), ny * (60.0 * ACCEL_MULT), zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
            else
              ApplyForceToEntity(pped, 1, nx * (60.0 * ACCEL_MULT), ny * (60.0 * ACCEL_MULT), zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
            end
          end
        end
      end
      if t >= 1.0 then break end
      frame = frame + 1
      Wait(0)
    end
    local holdStart = GetGameTimer()
    local ddur = 6000
    local finalAudioPlayed = false
    while GetGameTimer() - holdStart < 10000 do
      for _, o in ipairs(objs) do
        SetEntityCoordsNoOffset(o.obj, o.x, o.y, o.z1, true, true, true)
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.yaw, 2)
        FreezeEntityPosition(o.obj, true)
      end
      if not finalAudioPlayed and (GetGameTimer() - holdStart) >= 8000 then
        TriggerServerEvent('um-senju:server:playAudio', {x=cx,y=cy,z=baseZ}, AUDIO_MAX_DISTANCE, AUDIO_BASE_VOLUME, ddur)
        finalAudioPlayed = true
      end
      Wait(0)
    end
    local dstart = GetGameTimer()
    while true do
      local now = GetGameTimer()
      local t = (now - dstart) / ddur
      if t >= 1.0 then t = 1.0 end
      local eased = 1.0 - ((1.0 - t) ^ 3)
      for _, o in ipairs(objs) do
        FreezeEntityPosition(o.obj, false)
        SetEntityDynamic(o.obj, true)
        local nz = o.z1 + (o.zf - o.z1) * eased
        local dz = nz - (GetEntityCoords(o.obj).z)
        SetEntityCoordsNoOffset(o.obj, o.x, o.y, nz, true, true, true)
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.yaw, 2)
        SetEntityVelocity(o.obj, 0.0, 0.0, math.min(0.0, dz * (25.0 * ACCEL_MULT)))
      end
      if (frame % 2) == 0 then
        local players2 = GetActivePlayers()
        for i = 1, #players2 do
          local pid = players2[i]
          local pped = GetPlayerPed(pid)
          local px, py, pz = table.unpack(GetEntityCoords(pped))
          local dx = px - cx
          local dy = py - cy
          local dist2 = dx * dx + dy * dy
          if dist2 <= rad2 then
            local dlen = math.sqrt(dist2) + 0.001
            local nx = dx / dlen
            local ny = dy / dlen
            local zBoost = 25.0 * ACCEL_MULT
            local veh = GetVehiclePedIsIn(pped, false)
            if veh and veh ~= 0 then
              if not affectedVehs[veh] then
                SetEntityAsMissionEntity(veh, true, true)
                affectedVehs[veh] = true
              end
              ApplyForceToEntity(veh, 1, nx * (55.0 * ACCEL_MULT), ny * (55.0 * ACCEL_MULT), zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
            else
              ApplyForceToEntity(pped, 1, nx * (55.0 * ACCEL_MULT), ny * (55.0 * ACCEL_MULT), zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
            end
          end
        end
      end
      if t >= 1.0 then break end
      frame = frame + 1
      Wait(0)
    end
    for _, o in ipairs(objs) do
      if DoesEntityExist(o.obj) then
        DeleteObject(o.obj)
      end
      SetModelAsNoLongerNeeded(o.model)
    end
    activeProps = {}
    for veh, _ in pairs(affectedVehs) do
      if DoesEntityExist(veh) then
        SetEntityAsNoLongerNeeded(veh)
      end
    end
    casting = false
  end)
end

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
      local d = math.sqrt(dx*dx + dy*dy + dz*dz)
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

RegisterNetEvent('um-senju:client:activate', function(src)
  local now = GetGameTimer()
  if casting or next(activeProps) ~= nil then
    -- TriggerEvent('QBCore:Notify', 'Magia ainda está recarregando', 'error', 2000)
    return
  end
  if senjuActive then
    cancelSenju()
    return
  end
  if now - last < Config.cooldown_ms then return end
  last = now
  -- TriggerEvent('QBCore:Notify', 'Usando senju', 'success', 3000)
  shapeIndex = 1
  radius = 5.0
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
        targetPos = hitPos
        if lastTargetPos then
          local dx = targetPos.x - lastTargetPos.x
          local dy = targetPos.y - lastTargetPos.y
          local dz = targetPos.z - lastTargetPos.z
          if (dx*dx + dy*dy + dz*dz) > 0.04 then
            blinkUntil = GetGameTimer() + 600
          end
        end
        lastTargetPos = targetPos
      else
        targetPos = lastTargetPos or (origin + dir * 5.0)
      end
      if IsControlJustPressed(0, 15) then radius = math.min(radius + 0.5, RADIUS_MAX); blinkUntil = GetGameTimer() + 600 end
      if IsControlJustPressed(0, 14) then radius = math.max(radius - 0.5, RADIUS_MIN); blinkUntil = GetGameTimer() + 600 end
      if shapes[shapeIndex] == 'bar' then
        drawBarAt(targetPos, radius)
      else
        drawCircleAt(targetPos, radius)
      end
      BeginTextCommandDisplayHelp("STRING")
      local hint = "~INPUT_COVER~/~INPUT_CONTEXT~ Trocar formato | ~INPUT_ATTACK~ Castar"
      AddTextComponentSubstringPlayerName(hint)
      EndTextCommandDisplayHelp(0, false, false, -1)
      
      if IsDisabledControlJustPressed(0, 24) then
        if casting or next(activeProps) ~= nil then
          TriggerEvent('QBCore:Notify', 'O solo ainda está se recuperando.', 'error', 2000)
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
