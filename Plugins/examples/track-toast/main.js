// Shows a toast in the notch on every new track.
notch.on('media', function (m) {
  if (m.changed !== 'track' || !m.playing) return;
  notch.toast({
    id: 'track',                    // a toast with the same id updates in place
    text: m.title,
    symbol: 'music.note',
    tint: '#FF2D55',
    duration: 2
  });
});
