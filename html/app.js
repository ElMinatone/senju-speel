const audio = document.getElementById('senju-audio')
let playing = false
window.addEventListener('message', (e) => {
  const d = e.data
  if (d && d.action === 'play') {
    try {
      audio.currentTime = 0
      audio.volume = Math.max(0, Math.min(1, d.volume || 0.8))
      audio.loop = false
      audio.play()
      playing = true
    } catch (_) {}
  } else if (d && d.action === 'volume') {
    if (playing) audio.volume = Math.max(0, Math.min(1, d.volume || 0))
  } else if (d && d.action === 'stop') {
    try {
      audio.pause()
      audio.currentTime = 0
      playing = false
    } catch (_) {}
  }
})
