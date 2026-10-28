// Needs the network permission. Edit the latitude/longitude to change the city.
var LAT = 41.01, LON = 28.98, CITY = 'Istanbul';

function refresh() {
  var url = 'https://api.open-meteo.com/v1/forecast?latitude=' + LAT + '&longitude=' + LON + '&current=temperature_2m,weather_code';
  notch.fetch(url)
    .then(function (r) { return r.json(); })
    .then(function (data) {
      var t = Math.round(data.current.temperature_2m);
      var code = data.current.weather_code;
      var symbol = code === 0 ? 'sun.max.fill' : code < 4 ? 'cloud.sun.fill' : code < 60 ? 'cloud.fill' : code < 70 ? 'cloud.rain.fill' : 'snowflake';
      notch.storage.set('last', { t: t, at: Date.now() });
      notch.card({ title: CITY + ' · ' + t + '°C', subtitle: 'Current weather', symbol: symbol, tint: '#64D2FF', duration: 5 });
    })
    .catch(function (e) { console.error('could not fetch the weather: ' + e.message); });
}

refresh();
setInterval(refresh, 30 * 60 * 1000);
