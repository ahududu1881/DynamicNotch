# Eklenti yazma kılavuzu

[English](PLUGINS.md) · **Türkçe**

Eklentiler JavaScript ile yazılır. Sunucu, port ya da ek program gerekmez: uygulama eklentiyi kendi içinde,
diğer eklentilerden ve uygulamanın kendisinden yalıtılmış olarak çalıştırır.

## 1. İlk eklenti (2 dakika)

Menü çubuğundaki simge → **Ayarlar → Eklentiler → Örnek eklentileri ekle** ile üç örnek kopyalanır.
Ya da elle bir klasör aç:

```
~/Library/Application Support/DynamicNotch/Plugins/benim-eklentim/
    plugin.json
    main.js
```

`plugin.json`:

```json
{
  "id": "ben.merhaba",
  "name": "Merhaba",
  "version": "1.0",
  "description": "Notch'ta selam verir.",
  "permissions": []
}
```

`main.js`:

```js
notch.toast({ text: "Merhaba!", symbol: "hand.wave.fill", tint: "#FF9F0A" });
```

Dosyayı kaydettiğin anda eklenti kendiliğinden yeniden yüklenir (yaklaşık 2 saniye). Hatalar
**Ayarlar → Eklentiler → Günlüğü göster** altında görünür.

### plugin.json alanları

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `id` | evet | 3–80 karakter: harf, rakam, `-`, `_`, `.`. Eklentiyi tanımlar, değiştirme |
| `name` | evet | Listede görünen ad |
| `version`, `description`, `author` | hayır | Bilgi |
| `main` | hayır | Ana betik, varsayılan `main.js`. Klasörün dışına çıkamaz |
| `permissions` | hayır | Aşağıdaki izinler |

## 2. Notch'ta göstermek

```js
notch.toast({ text: "Bitti", symbol: "checkmark.circle.fill", tint: "#34C759", duration: 2, id: "build" })
notch.toast({ level: 0.6, symbol: "arrow.down.circle.fill" })          // çubuk
notch.card({ title: "Deploy tamam", subtitle: "v2.4 yayında", symbol: "shippingbox.fill", tint: "#0A84FF",
             url: "https://example.com", duration: 6 })                // karta basınca bağlantı açılır
notch.activity({ id: "indirme", text: "İndiriliyor", symbol: "arrow.down.circle.fill", level: 0.4 })  // kalıcı gösterge
notch.activity({ id: "kayit", text: "Kayıt", countsUp: true })         // geçen süreyi sayar
notch.endActivity("indirme")
notch.timer({ id: "cay", seconds: 300, label: "Çay" })                 // geri sayım; bitince ses + 'timer' olayı
```

- `symbol`: herhangi bir SF Symbol adı. `tint`: `#RRGGBB`.
- Aynı `id` ile gelen toast/kart yerinde güncellenir, farklılar sıraya girer.
- Bir eklenti 10 saniyede en fazla 8 toast/kart gösterebilir, aynı anda en fazla 4 etkinlik tutabilir.
- Tam ekran bir uygulama açıkken toast ve kartlar gösterilmez.

## 3. Olaylara tepki vermek

```js
notch.on("media", function (m) { ... })
notch.off("media", handler)
```

| Olay | Verilen bilgi |
|---|---|
| `launch` | `{}`, eklenti yüklenince |
| `media` | `changed` (`track` / `state` / `stopped`), `title`, `artist`, `album`, `app`, `appName`, `playing`, `duration`, `position` |
| `volume` | `level` (0–1), `muted` |
| `brightness` | `level` |
| `focus` | `on`, `name`, `id` |
| `battery` | `percent`, `charging`, `plugged` |
| `accessory` | `name`, `connected`, `model` (AirPods, Beats, JBL...) |
| `recording` | `active`, `seconds` (bittiğinde) |
| `touchid` | `phase`: `waiting`, `success`, `cancelled` |
| `lock` | `locked`: Mac kilitlenince `true`, kilit açılınca `false` |
| `timer` | `id`, `label`: eklentinin kurduğu zamanlayıcı bitince |
| `notification` | `app`, `bundleId`, `title`, `subtitle`, `body` (**`notifications` izni gerekir**) |

Bir olay işleyicisi hata verirse diğerleri çalışmaya devam eder; hata günlüğe yazılır.

## 4. Okumak ve kalıcı veri

```js
notch.media.state()          // { title, artist, playing, duration, position, ... }  (çalmıyorsa {})
notch.system.volume()        // 0–1 ya da null
notch.storage.set("anahtar", { a: 1 }); notch.storage.get("anahtar"); notch.storage.remove("anahtar")
setTimeout(fn, ms); setInterval(fn, ms); clearTimeout(id); clearInterval(id)   // en az 50 ms, en çok 20 zamanlayıcı
console.log / info / warn / error                                              // günlüğe yazar
notch.plugin   // { id, name, version, permissions }
```

`storage` eklenti başına 64 KB'a kadar JSON saklar ve yeniden başlatmalarda kalır.
`Promise` ve `async/await` çalışır.

## 5. İzinler

İzin istemeyen eklentiler hiç soru sormadan çalışır. İzin isteyenlerde ilk yüklemede bir onay penceresi çıkar;
**eklentinin kodu değişirse yeniden sorulur.** İzin verilmezse eklenti hiç çalışmaz
(Ayarlar'dan "İzin sor" ile yeniden sorulabilir).

| İzin | Açar |
|---|---|
| `network` | `notch.fetch(url, {method, headers, body})` (Promise), `notch.http.get/request(…, callback)`. Yalnızca http/https; 15 sn zaman aşımı; 1 MB yanıt sınırı |
| `shell` | `notch.shell.run("/mutlak/yol", [args], function (err, {code, stdout, stderr}) {})`. Kabuk yoktur: yalnızca çalıştırılabilir dosyanın tam yolu ve argümanları. 30 sn, aynı anda 3 |
| `control` | `notch.media.toggle/next/previous/seek(sn)`, `notch.system.setVolume(0–1)`, `notch.openURL(url)` (yalnızca http, https, mailto, sistem ayarları bağlantıları) |
| `notifications` | `notification` olayı |

```js
// network
notch.fetch("https://api.example.com/durum").then(function (r) { return r.json(); }).then(function (d) {
  notch.card({ title: d.baslik, symbol: "cloud.fill" });
});
// shell
notch.shell.run("/usr/bin/say", ["Merhaba"], function (err, r) { if (err) console.error(err); });
```

## 6. Güvenlik ve dayanıklılık

- Her eklenti kendi JavaScript ortamında ve kendi iş parçacığında çalışır. Sonsuz döngüye giren bir eklenti
  yalnızca kendini kilitler; notch ve diğer eklentiler etkilenmez. Eklentiyi kapatıp açmak (ya da dosyayı kaydetmek) yeniler.
- Eklenti dosya sistemine, ortama, diğer eklentilere ya da uygulamanın içine erişemez; yalnızca yukarıdaki işlevleri görür.
- Betik 512 KB'ı, günlük 100 satırı geçemez. Klasör dışına işaret eden sembolik bağlantılar reddedilir.
- Hatalı `plugin.json` ya da betik, uygulamayı etkilemez; eklentinin yanında hata olarak gösterilir.

## 7. Örnekler

`Plugins/examples/` altında:

- **track-toast**: yeni şarkıda adını gösterir.
- **focus-timer**: Odak modu açılınca 25 dakikalık sayaç, bitince mola kartı.
- **weather**: `network` izniyle hava durumu kartı.
