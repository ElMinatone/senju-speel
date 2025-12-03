RegisterNetEvent('um-senju:server:request', function()
  local src = source
  TriggerClientEvent('um-senju:client:activate', src, src)
end)

RegisterNetEvent('um-senju:server:playAudio', function(center, maxDist, baseVol, duration)
  TriggerClientEvent('um-senju:client:playAudio', -1, center, maxDist, baseVol, duration)
end)
