RegisterNetEvent('um-senju:server:request', function()
  local src = source
  TriggerClientEvent('um-senju:client:activate', src, src)
end)

RegisterNetEvent('um-senju:server:playAudio', function(center, maxDist, baseVol, duration)
  TriggerClientEvent('um-senju:client:playAudio', -1, center, maxDist, baseVol, duration)
end)

RegisterNetEvent('um-senju:server:startImpact', function(center, radius, ascendMs, holdMs, descendMs)
  TriggerClientEvent('um-senju:client:impact', -1, center, radius, ascendMs, holdMs, descendMs)
end)

RegisterNetEvent('um-senju:server:stopImpact', function()
  TriggerClientEvent('um-senju:client:impactStop', -1)
end)

RegisterCommand('clearTrees', function(source, args)
  TriggerClientEvent('um-senju:client:clearTrees', -1)
end, false)

RegisterNetEvent('um-senju:server:clearTreesNear', function(center, radius, castId)
  TriggerClientEvent('um-senju:client:clearTreesWorldNear', -1, center, radius, castId)
end)
