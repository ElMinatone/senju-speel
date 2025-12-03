local last = 0
local senjuActive = false
local targetPos
local RADIUS_MIN = 2.0
local RADIUS_MAX = 20.0
local radius = 3.0
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

local function castTrees(center, rad)
  if not center then return end
  local cx, cy, cz = center.x, center.y, center.z
  local _, gz = GetGroundZFor_3dCoord(cx, cy, cz, false)
  local baseZ = (gz or cz)
  local objs = {}
  local placed = {}
  local count = math.min(36, math.max(8, math.floor(rad * 4)))
  for i = 1, count do
    local minSep = math.max(2.5, rad * 0.15)
    local ox, oy
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
    local tiltX = (math.random() - 0.5) * 8.0
    local tiltY = (math.random() - 0.5) * 8.0
    local tiltZ = (math.random() - 0.5) * 6.0
    SetEntityRotation(obj, tiltX, tiltY, tiltZ, 2)
    local s = 0.8 + math.random() * 1.2
    local f, rgt, up, pos = GetEntityMatrix(obj)
    local fx, fy, fz = f.x * s, f.y * s, f.z * s
    local rx, ry, rz = rgt.x * s, rgt.y * s, rgt.z * s
    local ux, uy, uz = up.x * s, up.y * s, up.z * s
    SetEntityMatrix(obj, fx, fy, fz, rx, ry, rz, ux, uy, uz, ox, oy, zStart)
    objs[#objs + 1] = { obj = obj, x = ox, y = oy, z0 = zStart, zf = zStart - 6.0, z1 = (ogz or baseZ), model = model, tiltX =
    tiltX, tiltY = tiltY, tiltZ = tiltZ }
    activeProps[#activeProps + 1] = obj
    ::continue::
  end
  local start = GetGameTimer()
  local dur = 1500
  local affectedVehs = {}
  TriggerServerEvent('um-senju:server:playAudio', {x=cx,y=cy,z=baseZ}, Config.audio.max_distance, Config.audio.base_volume, 1500 + 10000 + 1500)
  CreateThread(function()
    while true do
      local now = GetGameTimer()
      local t = (now - start) / dur
      if t >= 1.0 then t = 1.0 end
      local eased = 1.0 - ((1.0 - t) ^ 3)
      for _, o in ipairs(objs) do
        local nz = o.z0 + (o.z1 - o.z0) * eased
        local dz = nz - (GetEntityCoords(o.obj).z)
        SetEntityCoordsNoOffset(o.obj, o.x, o.y, nz, true, true, true)
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.tiltZ, 2)
        SetEntityVelocity(o.obj, 0.0, 0.0, math.max(0.0, dz * 20.0))
      end
      local players = GetActivePlayers()
      for i = 1, #players do
        local pid = players[i]
        local pped = GetPlayerPed(pid)
        local px, py, pz = table.unpack(GetEntityCoords(pped))
        local dx = px - cx
        local dy = py - cy
        local dist2 = dx * dx + dy * dy
        if dist2 <= (rad * rad) then
          local dlen = math.sqrt(dist2) + 0.001
          local nx = dx / dlen
          local ny = dy / dlen
          local zBoost = 35.0
          local veh = GetVehiclePedIsIn(pped, false)
          if veh and veh ~= 0 then
            SetEntityAsMissionEntity(veh, true, true)
            affectedVehs[veh] = true
            ApplyForceToEntity(veh, 1, nx * 60.0, ny * 60.0, zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
          else
            ApplyForceToEntity(pped, 1, nx * 60.0, ny * 60.0, zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
          end
        end
      end
      if t >= 1.0 then break end
      Wait(0)
    end
    local holdStart = GetGameTimer()
    while GetGameTimer() - holdStart < 10000 do
      for _, o in ipairs(objs) do
        SetEntityCoordsNoOffset(o.obj, o.x, o.y, o.z1, true, true, true)
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.tiltZ, 2)
        FreezeEntityPosition(o.obj, true)
      end
      Wait(0)
    end
    local dstart = GetGameTimer()
    local ddur = 1500
    TriggerServerEvent('um-senju:server:playAudio', {x=cx,y=cy,z=baseZ}, Config.audio.max_distance, Config.audio.base_volume, ddur)
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
        SetEntityRotation(o.obj, o.tiltX, o.tiltY, o.tiltZ, 2)
        SetEntityVelocity(o.obj, 0.0, 0.0, math.min(0.0, dz * 25.0))
      end
      local players2 = GetActivePlayers()
      for i = 1, #players2 do
        local pid = players2[i]
        local pped = GetPlayerPed(pid)
        local px, py, pz = table.unpack(GetEntityCoords(pped))
        local dx = px - cx
        local dy = py - cy
        local dist2 = dx * dx + dy * dy
        if dist2 <= (rad * rad) then
          local dlen = math.sqrt(dist2) + 0.001
          local nx = dx / dlen
          local ny = dy / dlen
          local zBoost = 25.0
          local veh = GetVehiclePedIsIn(pped, false)
          if veh and veh ~= 0 then
            SetEntityAsMissionEntity(veh, true, true)
            affectedVehs[veh] = true
            ApplyForceToEntity(veh, 1, nx * 55.0, ny * 55.0, zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
          else
            ApplyForceToEntity(pped, 1, nx * 55.0, ny * 55.0, zBoost, 0.0, 0.0, 0.0, false, true, true, false, true)
          end
        end
      end
      if t >= 1.0 then break end
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
  SendNUIMessage({ action = 'play', volume = baseVol })
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
      Wait(200)
    end
    SendNUIMessage({ action = 'stop' })
  end)
end)

RegisterNetEvent('um-senju:client:activate', function(src)
  local now = GetGameTimer()
  if senjuActive then
    cancelSenju()
    return
  end
  if now - last < Config.cooldown_ms then return end
  last = now
  TriggerEvent('QBCore:Notify', 'Usando senju', 'success', 3000)
  senjuActive = true
  local ped = PlayerPedId()
  CreateThread(function()
    while senjuActive do
      DisableControlAction(0, 24, true)
      DisableControlAction(0, 25, true)
      DisableControlAction(0, 140, true)
      DisableControlAction(0, 141, true)
      DisableControlAction(0, 142, true)
      targetPos = raycastFromCam(60.0) or GetEntityCoords(ped)
      if lastTargetPos then
        local dx = targetPos.x - lastTargetPos.x
        local dy = targetPos.y - lastTargetPos.y
        local dz = targetPos.z - lastTargetPos.z
        if (dx * dx + dy * dy + dz * dz) > 0.04 then
          blinkUntil = GetGameTimer() + 600
        end
      end
      lastTargetPos = targetPos
      if IsControlJustPressed(0, 15) then radius = math.min(radius + 0.5, RADIUS_MAX); blinkUntil = GetGameTimer() + 600 end
      if IsControlJustPressed(0, 14) then radius = math.max(radius - 0.5, RADIUS_MIN); blinkUntil = GetGameTimer() + 600 end
      drawCircleAt(targetPos, radius)
      BeginTextCommandDisplayHelp("STRING")
      AddTextComponentSubstringPlayerName("~INPUT_ATTACK~ para castar")
      EndTextCommandDisplayHelp(0, false, false, -1)
      if IsDisabledControlJustPressed(0, 24) then
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
            if IsControlJustPressed(0, 167) or IsControlJustPressed(0, 73) then
              ClearPedTasksImmediately(ped)
              casting = false
            end
            Wait(0)
          end
        end)
        Wait(500)
        castTrees(targetPos, radius)
        senjuActive = false
        break
      end
      if IsControlJustPressed(0, 167) or IsControlJustPressed(0, 73) then
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
