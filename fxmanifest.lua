fx_version "cerulean"
game "gta5"
name "um-senju"
version "0.1.0"

client_scripts {
  'client/main.lua'
}

server_scripts {
  'server/main.lua'
}

shared_script 'config.lua'

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/app.js',
  'html/growing.mp3'
}

lua54 'yes'
