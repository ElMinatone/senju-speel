RegisterNetEvent('um-senju:server:request', function()
  local src = source
  TriggerClientEvent('um-senju:client:activate', src, src)
end)
