// When a Focus turns on a 25 minute timer starts; it is cancelled when the Focus ends.
var MINUTES = 25;

notch.on('focus', function (f) {
  if (f.on) {
    notch.timer({ id: 'focus', seconds: MINUTES * 60, label: f.name, symbol: 'brain.head.profile', tint: '#5E5CE6' });
  } else {
    notch.endActivity('focus');
  }
});

// When time is up
notch.on('timer', function (t) {
  notch.card({ title: 'Time for a break', subtitle: t.label + ' session finished', symbol: 'cup.and.saucer.fill', tint: '#FF9F0A', duration: 6 });
});
