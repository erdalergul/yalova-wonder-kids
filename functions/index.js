const {
  onDocumentCreated,
  onDocumentWritten,
} = require('firebase-functions/v2/firestore');

const {
  onCall,
  HttpsError,
} = require('firebase-functions/v2/https');

const {
  onSchedule,
} = require('firebase-functions/v2/scheduler');

const {
  initializeApp,
} = require('firebase-admin/app');

const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require('firebase-admin/firestore');

const {
  getMessaging,
} = require('firebase-admin/messaging');

const {
  getAuth,
} = require('firebase-admin/auth');

const crypto = require('crypto');

const {
  defineString,
} = require('firebase-functions/params');

// Firebase web API anahtarı (herkese açık anahtardır; firebase_options.dart içindeki apiKey).
// functions/.env dosyasına:  WEB_API_KEY=AIza...  şeklinde yazılır.
const WEB_API_KEY = defineString('WEB_API_KEY');

initializeApp();

const db = getFirestore();

// Otomatik lig bildirimleri Firestore'daki ayarlar/bildirim belgesinden
// (alan: aktif, boolean) yönetilir. ASKF/TFF verileri her durumda Firestore'a
// aktarılmaya devam eder; yalnızca otomatik push bildirimi etkilenir.
// Belge yoksa veya okunamazsa bildirimler KAPALI kabul edilir.
// Yönetici tarafından bildirim_istekleri koleksiyonuna oluşturulan manuel
// bildirimler (bildirimGonder) bu ayardan etkilenmez.
// Açıp kapatmak için: Uygulama > Yönetim Paneli > Otomatik Bildirimler.
// (Fonksiyonları yeniden yüklemeye gerek yoktur.)
//   aktif    : ASKF yerel lig bildirimleri (ana anahtar)
//   tffAktif : TFF gelişim ligi / PGL bildirimleri (ana anahtar da açık olmalı)

async function bildirimAyarlariniOku() {
  try {
    const snap = await db.collection('ayarlar').doc('bildirim').get();
    return snap.exists ? (snap.data() || {}) : {};
  } catch (error) {
    console.error('Bildirim ayarı okunamadı, bildirimler kapalı sayıldı:', error);
    return {};
  }
}

async function otomatikBildirimlerAcikMi() {
  const ayar = await bildirimAyarlariniOku();
  return ayar.aktif === true;
}

async function tffBildirimleriAcikMi() {
  const ayar = await bildirimAyarlariniOku();
  return ayar.aktif === true && ayar.tffAktif === true;
}


// ============================================================
// GENEL BİLDİRİM KONULARI
// ============================================================

const izinliKonular = new Set([
  'genel',
  'maclar',
  'haberler',
  'ligler',
]);


// ============================================================
// 1. YÖNETİCİ BİLDİRİMİ
// ============================================================

exports.bildirimGonder = onDocumentCreated(
  {
    document: 'bildirim_istekleri/{istekId}',
    region: 'europe-west1',
  },

  async (event) => {
    const snap = event.data;

    if (!snap) {
      return;
    }

    const veri = snap.data() || {};

    const baslik = String(veri.baslik || '').trim();
    const mesaj = String(veri.mesaj || '').trim();
    const konu = String(veri.konu || 'genel').trim();
    const uid = String(veri.olusturanUid || '').trim();

    try {
      if (!uid) {
        throw new Error('Gönderen yönetici bilgisi eksik.');
      }

      if (!baslik || !mesaj) {
        throw new Error('Başlık ve mesaj zorunludur.');
      }

      if (baslik.length > 80) {
        throw new Error('Başlık çok uzun.');
      }

      if (mesaj.length > 240) {
        throw new Error('Mesaj çok uzun.');
      }

      if (!izinliKonular.has(konu)) {
        throw new Error('Geçersiz bildirim konusu.');
      }

      const adminSnap = await db
        .collection('adminler')
        .doc(uid)
        .get();

      if (
        !adminSnap.exists ||
        adminSnap.data()?.aktif !== true
      ) {
        throw new Error(
          'Gönderen hesabın yönetici yetkisi yok.',
        );
      }

      const messageId = await getMessaging().send({
        topic: konu,

        notification: {
          title: baslik,
          body: mesaj,
        },

        data: {
          title: baslik,
          body: mesaj,
          tur: 'admin_bildirimi',
          bildirimIstekId: snap.id,
        },

        android: {
          priority: 'high',

          notification: {
            channelId: 'yalova_wonder_kids',
            sound: 'default',
          },
        },
      });

      await snap.ref.update({
        durum: 'gonderildi',

        gonderilmeTarihi:
          FieldValue.serverTimestamp(),

        fcmMessageId: messageId,

        hata: FieldValue.delete(),
      });

    } catch (error) {
      console.error(
        'Bildirim gönderme hatası:',
        error,
      );

      await snap.ref.update({
        durum: 'hata',

        hata: String(
          error?.message || error,
        ).slice(0, 500),

        tamamlanmaTarihi:
          FieldValue.serverTimestamp(),
      });
    }
  },
);


// ============================================================
// 2. TFF GELİŞİM LİGLERİ VERİSİ
//
// BU FONKSİYONA DOKUNMUYORUZ.
// ============================================================

exports.tffGelisimVeri = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 60,
    memory: '256MiB',
  },

  async (request) => {
    const url = String(
      request.data?.url || '',
    ).trim();

    if (!url) {
      throw new HttpsError(
        'invalid-argument',
        'URL zorunludur.',
      );
    }

    let parsedUrl;

    try {
      parsedUrl = new URL(url);
    } catch (_) {
      throw new HttpsError(
        'invalid-argument',
        'Geçersiz URL.',
      );
    }

    if (
      parsedUrl.protocol !== 'https:' ||
      parsedUrl.hostname !== 'www.tff.org' ||
      parsedUrl.pathname !== '/Default.aspx'
    ) {
      throw new HttpsError(
        'permission-denied',
        'Bu URL için erişim izni yok.',
      );
    }

    const pageId = Number(
      parsedUrl.searchParams.get('pageID'),
    );

    // 29 = TFF maç detay sayfası (kadro, gol, kart). Yalnızca sayısal macId ile.
    const macId = Number(
      parsedUrl.searchParams.get('macId') ||
        parsedUrl.searchParams.get('macid') ||
        '',
    );
    const macDetayMi =
      pageId === 29 &&
      Number.isInteger(macId) &&
      macId > 0;

    if (
      !Number.isInteger(pageId) ||
      !(
        (pageId >= 1751 && pageId <= 1755) ||
        pageId === 1596 ||
        macDetayMi
      )
    ) {
      throw new HttpsError(
        'permission-denied',
        'Bu TFF sayfası Gelişim Ligleri kapsamında değil.',
      );
    }

    let sonHata = null;

    for (
      let deneme = 1;
      deneme <= 2;
      deneme++
    ) {
      try {
        const response = await fetch(url, {
          method: 'GET',

          headers: {
            'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
              'AppleWebKit/537.36 (KHTML, like Gecko) ' +
              'Chrome/152.0.0.0 Safari/537.36',

            'Referer':
              'https://www.tff.org/',

            'Accept':
              'text/html,application/xhtml+xml,' +
              'application/xml;q=0.9,*/*;q=0.8',

            'Accept-Language':
              'tr-TR,tr;q=0.9,en;q=0.7',

            'Cache-Control':
              'no-cache',

            'Pragma':
              'no-cache',
          },

          signal: AbortSignal.timeout(55000),
        });

        const body = await response.text();

        if (response.status === 200) {
          return {
            statusCode: response.status,
            body: body,
            contentType:
              response.headers.get(
                'content-type',
              ) ||
              'text/html; charset=utf-8',
          };
        }

        sonHata = new Error(
          `HTTP ${response.status}`,
        );

        if (
          response.status >= 400 &&
          response.status < 500
        ) {
          break;
        }

      } catch (error) {
        sonHata = error;
      }

      if (deneme === 1) {
        await new Promise(
          (resolve) =>
            setTimeout(resolve, 450),
        );
      }
    }

    throw new HttpsError(
      'unavailable',
      String(
        sonHata?.message ||
        'TFF isteği başarısız.',
      ),
    );
  },
);


// ============================================================
// 3. ASKF KAYNAKLARI
// ============================================================

const ASKF_KAYNAKLARI = [
  {
    id: 'haftalik_program',
    url: 'https://yalovaskf.com/haftalik-program',
    ad: 'Haftalık maç programı',
    lig: 'Yalova Yerel Ligleri',
    grup: 'genel',
    veriTuru: 'fikstur',
  },
  {
    id: 'super_amator_a_2026_2027',
    url: 'https://yalovaskf.com/grup/super-amator-lig-a-grubu-2026-2027-1',
    ad: 'Süper Amatör A Grubu', lig: 'Süper Amatör Lig', grup: 'A Grubu',
    puanDocId: 'super-amator-a-2026-2027', veriTuru: 'grup',
  },
  {
    id: 'super_amator_b_2026_2027',
    url: 'https://yalovaskf.com/grup/super-amator-lig-b-grubu-2026-2027-1',
    ad: 'Süper Amatör B Grubu', lig: 'Süper Amatör Lig', grup: 'B Grubu',
    puanDocId: 'super-amator-b-2026-2027', veriTuru: 'grup',
  },
  {
    id: 'birinci_amator_2026_2027',
    url: 'https://yalovaskf.com/grup/1-amator-lig-1-amator-lig-2026-2027',
    ad: '1. Amatör Lig', lig: '1. Amatör Lig', grup: '1. Amatör Lig',
    puanDocId: '1-amator-2026-2027', veriTuru: 'grup',
  },
  {
    id: 'u17_2026_2027',
    url: 'https://yalovaskf.com/grup/u17-ligi-u17-ligi-2026-2027',
    ad: 'U17 Ligi', lig: 'U17 Ligi', grup: 'U17 Ligi',
    puanDocId: 'u17-2026-2027', veriTuru: 'grup',
  },
  {
    id: 'u14_a_2026_2027',
    url: 'https://yalovaskf.com/grup/u14-ligi-a-grubu-2026-2027',
    ad: 'U14 Ligi A Grubu', lig: 'U14 Ligi', grup: 'A Grubu',
    puanDocId: 'u14-a-2026-2027', veriTuru: 'grup',
  },
  {
    id: 'u14_b_2026_2027',
    url: 'https://yalovaskf.com/grup/u14-ligi-b-grubu-2026-2027',
    ad: 'U14 Ligi B Grubu', lig: 'U14 Ligi', grup: 'B Grubu',
    puanDocId: 'u14-b-2026-2027', veriTuru: 'grup',
  },
  ...['a', 'b', 'c', 'd'].map((harf) => ({
    id: `u12_${harf}_2026_2027`,
    url: `https://yalovaskf.com/grup/u12-senlik-ligi-${harf}-grubu-2026-2027`,
    ad: `U12 Şenlik Ligi ${harf.toUpperCase()} Grubu`,
    lig: 'U12 Şenlik Ligi', grup: `${harf.toUpperCase()} Grubu`,
    puanDocId: `u12-${harf}-2026-2027`, veriTuru: 'grup',
  })),
];

// Varsayılan sezon. Yönetici panelinden (ayarlar/lig.sezon) değiştirilebilir;
// her ASKF kontrolünün başında askfKaynaklariniYukle() ile güncellenir.
let ASKF_SEZON =
  '2026-2027';

// Yönetici panelindeki "Lig ve Sezon" ekranından yönetilen lig listesi
// (yerelLigler koleksiyonu). Koleksiyon boşsa / okunamazsa yukarıdaki
// ASKF_KAYNAKLARI listesi kullanılır. Haftalık program her zaman eklenir.
async function askfKaynaklariniYukle() {
  try {
    const [ayarSnap, ligSnap] = await Promise.all([
      db.collection('ayarlar').doc('lig').get(),
      db.collection('yerelLigler').get(),
    ]);

    const sezon = String(ayarSnap.data()?.sezon || '').trim();
    if (/^\d{4}-\d{4}$/.test(sezon)) {
      ASKF_SEZON = sezon;
    }

    const ligler = ligSnap.docs
      .map((d) => ({ id: d.id, ...d.data() }))
      .filter((v) => v.aktif !== false)
      .filter((v) => /^https:\/\/(www\.)?yalovaskf\.com\/.+/.test(String(v.url || '').trim()))
      .sort((a, b) => (Number(a.sira) || 9999) - (Number(b.sira) || 9999))
      .map((v) => {
        const ad = String(v.ad || v.id).trim();
        const kaynak = {
          id: v.id,
          url: String(v.url).trim(),
          ad,
          lig: String(v.lig || ad).trim(),
          grup: String(v.grup || ad).trim(),
          veriTuru: 'grup',
        };
        const puanDocId = String(v.puanDocId || '').trim();
        if (puanDocId) kaynak.puanDocId = puanDocId;
        return kaynak;
      });

    if (ligler.length > 0) {
      const haftalik = ASKF_KAYNAKLARI.filter((k) => k.veriTuru === 'fikstur');
      return [...haftalik, ...ligler];
    }
  } catch (error) {
    console.error('yerelLigler okunamadı, varsayılan liste kullanılıyor:', error);
  }
  return ASKF_KAYNAKLARI;
}

const ASKF_FIKSTUR_KOLEKSIYONU =
  'fiksturler';

const ASKF_PUAN_KOLEKSIYONU =
  'yerelLigPuanlari';

const ASKF_BILDIRIM_BASLIK =
  'Yeni Haftalık Maç Programı Yayında!';

const ASKF_BILDIRIM_GOVDE =
  'Yalova yerel liglerinde yeni haftanın maç programı yayınlandı. Fikstürü görmek için uygulamayı açın.';


// ============================================================
// 4. HTML / METİN YARDIMCILARI
// ============================================================

function htmlDecode(metin) {
  return String(metin || '')
    .replace(
      /&nbsp;|&#160;/gi,
      ' ',
    )
    .replace(
      /&amp;/gi,
      '&',
    )
    .replace(
      /&quot;/gi,
      '"',
    )
    .replace(
      /&#0*39;|&apos;/gi,
      "'",
    )
    .replace(
      /&lt;/gi,
      '<',
    )
    .replace(
      /&gt;/gi,
      '>',
    )
    .replace(
      /&#(\d+);/g,
      (_, n) =>
        String.fromCodePoint(
          Number(n),
        ),
    )
    .replace(
      /&#x([0-9a-f]+);/gi,
      (_, n) =>
        String.fromCodePoint(
          parseInt(n, 16),
        ),
    );
}


function htmlMetniniTemizle(html) {
  return htmlDecode(
    String(html || '')
      .replace(
        /<script[\s\S]*?<\/script>/gi,
        ' ',
      )
      .replace(
        /<style[\s\S]*?<\/style>/gi,
        ' ',
      )
      .replace(
        /<noscript[\s\S]*?<\/noscript>/gi,
        ' ',
      )
      .replace(
        /<!--[\s\S]*?-->/g,
        ' ',
      )
      .replace(
        /<br\s*\/?>/gi,
        ' | ',
      )
      .replace(
        /<\/(?:td|th|tr|p|div|li|h[1-6])\s*>/gi,
        ' | ',
      )
      .replace(
        /<[^>]+>/g,
        ' ',
      ),
  )
    .replace(
      /[\u00a0\t\r\n]+/g,
      ' ',
    )
    .replace(
      /\s*\|\s*/g,
      ' | ',
    )
    .replace(
      /\s+/g,
      ' ',
    )
    .trim();
}


function normalizeText(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(
      /[\u0300-\u036f]/g,
      '',
    )
    .replace(
      /İ/g,
      'I',
    )
    .replace(
      /ı/g,
      'i',
    )
    .toLocaleLowerCase(
      'tr-TR',
    )
    .replace(
      /\s+/g,
      ' ',
    )
    .trim();
}


function hashOlustur(metin) {
  return crypto
    .createHash('sha256')
    .update(
      String(metin || ''),
      'utf8',
    )
    .digest('hex');
}


function hucreleriCikar(rowHtml) {
  const sonuc = [];

  const regex =
    /<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi;

  let match;

  while (
    (match = regex.exec(rowHtml)) !== null
  ) {
    sonuc.push(
      htmlMetniniTemizle(
        match[1],
      )
        .replace(
          /\s*\|\s*/g,
          ' ',
        )
        .trim(),
    );
  }

  return sonuc.filter(
    (x) => x.length > 0,
  );
}


function tabloSatirlariniCikar(html) {
  const satirlar = [];

  const regex =
    /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;

  let match;

  while (
    (match = regex.exec(html)) !== null
  ) {
    const hucreler =
      hucreleriCikar(
        match[1],
      );

    if (hucreler.length) {
      satirlar.push(
        hucreler,
      );
    }
  }

  return satirlar;
}


function sayiCoz(value) {
  const match =
    String(value || '')
      .replace(',', '.')
      .match(/-?\d+/);

  return match
    ? Number(match[0])
    : 0;
}


function haftaBul(text) {
  const match =
    String(text || '').match(
      /(\d+)\s*\.\s*hafta/i,
    ) ||
    String(text || '').match(
      /hafta\s*(\d+)/i,
    );

  return match
    ? `${match[1]}. Hafta`
    : '';
}


function tarihSaatCoz(text) {
  const t =
    String(text || '')
      .replace(
        /\s+/g,
        ' ',
      )
      .trim();

  const match =
    t.match(
      /(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})(?:\s*(?:[-|,])?\s*(\d{1,2}):(\d{2}))?/,
    );

  if (!match) {
    return null;
  }

  let yil =
    Number(match[3]);

  if (yil < 100) {
    yil += 2000;
  }

  const gun =
    String(
      Number(match[1]),
    ).padStart(
      2,
      '0',
    );

  const ay =
    String(
      Number(match[2]),
    ).padStart(
      2,
      '0',
    );

  const saat =
    match[4]
      ? `${String(
          Number(match[4]),
        ).padStart(
          2,
          '0',
        )}:${match[5]}`
      : '00:00';

  return {
    tarihSaat:
      `${gun}.${ay}.${yil} ${saat}`,

    tarih:
      `${gun}.${ay}.${yil}`,

    saat,
  };
}


function skorCoz(text) {
  const match =
    String(text || '').match(
      /(?:^|\s)(\d{1,2})\s*[-:]\s*(\d{1,2})(?:\s|$)/,
    );

  return match
    ? `${match[1]}-${match[2]}`
    : '';
}


function takimAdiMi(text) {
  const t =
    String(text || '').trim();

  if (
    t.length < 3 ||
    t.length > 70
  ) {
    return false;
  }

  const norm =
    normalizeText(t);

  if (
    /^\d+$/.test(t) ||
    /puan durumu|fikstur|hafta|tarih|saat|stadyum|stad|oynanan|galibiyet|maglubiyet/i.test(
      norm,
    )
  ) {
    return false;
  }

  return /[a-zçğıöşü]/i.test(t);
}


// ============================================================
// 5. FİKSTÜR AYRIŞTIRMA
// ============================================================

// ASKF grup sayfaları bazen yalnızca JS kabuğu döndürür. Takım sayfaları
// ise fixture-card kartlarını sunucu tarafında HTML olarak içerir.
function askfSlugOlustur(value) {
  return normalizeText(value)
    .replace(/ı/g, 'i')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function takimSayfasiMaclariniAyrisla(html, kaynak, takimAdi) {
  const maclar = [];
  const cards = [...String(html || '').matchAll(/<([a-z][\w:-]*)\b([^>]*class=["'][^"']*fixture-card[^"']*["'][^>]*)>([\s\S]*?)<\/\1>/gi)];
  for (const card of cards) {
    const blok = card[0];
    const metin = htmlMetniniTemizle(blok);
    const takimLinkleri = [...blok.matchAll(/<a\b([^>]*href=["']([^"']*\/takim\/[^"']+)["'][^>]*)>([\s\S]*?)<\/a>/gi)]
      .map(m => ({ url: m[2], ad: htmlMetniniTemizle(m[3]) }))
      .filter(x => x.ad && takimAdiMi(x.ad));
    let evSahibi = '', deplasman = '';
    const teamsMatch = blok.match(/class=["'][^"']*fixture-teams[^"']*["'][^>]*>([\s\S]*?)(?:<div\b|<p\b|<span\b[^>]*class=["'][^"']*(?:fixture-status|fixture-date)|$)/i);
    const teamsHtml = teamsMatch ? teamsMatch[1] : blok;
    const names = [...teamsHtml.matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)]
      .map(m => htmlMetniniTemizle(m[1]))
      .filter(n => takimAdiMi(n));
    if (names.length >= 2) {
      evSahibi = names[0]; deplasman = names[1];
    } else if (takimLinkleri.length >= 2) {
      evSahibi = takimLinkleri[0].ad; deplasman = takimLinkleri[1].ad;
    }
    if (!evSahibi || !deplasman || normalizeText(evSahibi) === normalizeText(deplasman)) continue;
    const tarih = tarihSaatCoz(metin);
    const hafta = haftaBul(metin) || haftaBul(htmlMetniniTemizle(html)) || 'Hafta bilgisi yok';
    const skorMatch = metin.match(/\b(\d{1,2})\s*[-:]\s*(\d{1,2})\b/);
    maclar.push({
      sezon: ASKF_SEZON,
      lig: kaynak.lig || kaynak.ad || 'Yalova Yerel Ligleri',
      grup: kaynak.grup,
      hafta,
      evSahibi,
      deplasman,
      tarihSaat: tarih?.tarihSaat || '',
      stadyum: '',
      sonuc: skorMatch ? `${skorMatch[1]}-${skorMatch[2]}` : '-',
      kaynak: `https://yalovaskf.com/takim/${askfSlugOlustur(takimAdi)}`,
    });
  }
  return maclar;
}

async function takimSayfalarindanFiksturGetir(kaynak, grupHtml) {
  const takimUrlSet = new Set();
  for (const m of String(grupHtml || '').matchAll(/href=["']([^"']*\/takim\/[^"']+)["']/gi)) {
    try { takimUrlSet.add(new URL(m[1], 'https://yalovaskf.com').href); } catch (_) {}
  }
  // Puan tablosu daha önce kaydedildiyse takım adlarından takım sayfası URL'lerini oluştur.
  if (kaynak.puanDocId) {
    const snap = await db.collection(ASKF_PUAN_KOLEKSIYONU).doc(kaynak.puanDocId).get();
    const takimlar = snap.exists && Array.isArray(snap.data()?.takimlar) ? snap.data().takimlar : [];
    for (const t of takimlar) {
      const ad = String(t.takim || t.takimAdi || t.ad || t.name || t.isim || '').trim();
      if (ad) takimUrlSet.add(`https://yalovaskf.com/takim/${askfSlugOlustur(ad)}`);
    }
  }
  const macMap = new Map();
  for (const url of [...takimUrlSet].slice(0, 40)) {
    try {
      const r = await fetch(url, { headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/155.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
        'Accept-Language': 'tr-TR,tr;q=0.9,en;q=0.8',
      }, signal: AbortSignal.timeout(15000) });
      if (!r.ok) continue;
      const html = await r.text();
      if (!/fixture-card/i.test(html)) continue;
      const slug = decodeURIComponent(url.split('/takim/').pop().split(/[?#]/)[0]);
      const takimAdi = slug.replace(/-/g, ' ');
      for (const mac of takimSayfasiMaclariniAyrisla(html, kaynak, takimAdi)) {
        if (!mac.tarihSaat || !mac.evSahibi || !mac.deplasman) continue;
        const key = [normalizeText(mac.evSahibi), normalizeText(mac.deplasman), mac.hafta, mac.tarihSaat].join('|');
        macMap.set(key, mac);
      }
    } catch (e) {
      console.warn(`ASKF takım fikstürü okunamadı: ${url}`, String(e?.message || e));
    }
  }
  return [...macMap.values()];
}

function fiksturleriAyrisla(
  html,
  kaynak,
) {
  const maclar = [];

  const satirlar =
    tabloSatirlariniCikar(
      html,
    );

  const tumMetin =
    htmlMetniniTemizle(
      html,
    );

  const varsayilanHafta =
    haftaBul(
      tumMetin,
    );

  for (
    const hucreler of satirlar
  ) {
    const birlesik =
      hucreler.join(
        ' | ',
      );

    const tarih =
      tarihSaatCoz(
        birlesik,
      );

    if (!tarih) {
      continue;
    }

    const adaylar =
      hucreler.filter(
        (h) =>
          !tarihSaatCoz(h) &&
          takimAdiMi(h) &&
          !skorCoz(h) &&
          // Saha/stadyum adları takım sanılmasın.
          !/stad|saha|tesis/i.test(h),
      );

    let evSahibi = '';
    let deplasman = '';
    let sonuc = '';

    for (
      const h of hucreler
    ) {
      // Tarih/saat hücresindeki "11:00" skor sanılmasın.
      if (tarihSaatCoz(h)) continue;
      const skor =
        skorCoz(h);

      if (skor) {
        sonuc = skor;
        break;
      }
    }

    if (
      adaylar.length >= 2
    ) {
      evSahibi =
        adaylar[0];

      deplasman =
        adaylar[
          adaylar.length - 1
        ];
    }

    // ASKF grup sayfaları: "Hafta | Ev - Deplasman | Sonuç | Tarih/Saat | Stadyum"
    // (iki takım aynı hücrede, " - " ile ayrılmış).
    // Bu biçim varsa ayrı hücre adaylarına göre önceliklidir (stadyum adı
    // takım adı sanılmasın).
    {
      const macHucresi = hucreler.find(
        (h) => /\S\s+-\s+\S/.test(h) && !tarihSaatCoz(h) && !skorCoz(h),
      );
      // Takımlar ayrı hücrelerdeyse (ilk aday tek takım adı) dokunma; ör.
      // "Altınova - Kaytazdere Sahası" gibi bir saha adı maç sanılmasın.
      if (macHucresi && (adaylar.length < 2 || adaylar[0] === macHucresi)) {
        const parcalar = macHucresi.split(/\s+-\s+/);
        if (parcalar.length >= 2) {
          evSahibi = parcalar[0].trim();
          deplasman = parcalar.slice(1).join(' - ').trim();
        }
      }
    }

    if (
      !evSahibi ||
      !deplasman ||
      normalizeText(
        evSahibi,
      ) ===
        normalizeText(
          deplasman,
        )
    ) {
      continue;
    }

    const stadyum =
      hucreler.find(
        (h) =>
          /stad|stadyum|saha/i.test(
            h,
          ),
      ) || '';

    const ilkHucre = String(hucreler[0] || '').trim();
    const hafta =
      haftaBul(
        birlesik,
      ) ||
      (/^\d{1,2}\.?$/.test(ilkHucre) ? `${ilkHucre.replace('.', '')}. Hafta` : '') ||
      varsayilanHafta;

    maclar.push({
      sezon:
        ASKF_SEZON,

      lig:
        kaynak.lig || kaynak.ad || 'Yalova Yerel Ligleri',

      grup:
        kaynak.grup,

      hafta:
        hafta ||
        'Hafta bilgisi yok',

      evSahibi,

      deplasman,

      tarihSaat:
        tarih.tarihSaat,

      stadyum:
        stadyum.replace(
          /^(stadyum|stad|saha)\s*:?\s*/i,
          '',
        ),

      sonuc:
        sonuc || '-',

      kaynak:
        kaynak.url,
    });
  }

  const tekil =
    new Map();

  for (
    const mac of maclar
  ) {
    const key = [
      normalizeText(
        mac.evSahibi,
      ),

      normalizeText(
        mac.deplasman,
      ),

      mac.hafta,

      mac.tarihSaat,
    ].join('|');

    tekil.set(
      key,
      mac,
    );
  }

  return [
    ...tekil.values(),
  ];
}


// ============================================================
// 6. PUAN DURUMU AYRIŞTIRMA
// ============================================================

// Tablo satırlarını hem hücre metinleriyle hem ham HTML ile döndürür
// (takım logosunu ham HTML'den almak için).
function tabloSatirlariniHtmlIleCikar(tabloHtml) {
  const sonuc = [];
  const regex = /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;
  let match;
  while ((match = regex.exec(tabloHtml)) !== null) {
    const hucreler = hucreleriCikar(match[1]);
    if (hucreler.length) {
      sonuc.push({ hucreler, html: match[1] });
    }
  }
  return sonuc;
}

function puanDurumunuAyrisla(
  html,
  kaynak,
) {
  const tablolar =
    [
      ...String(
        html || '',
      ).matchAll(
        /<table\b[^>]*>([\s\S]*?)<\/table>/gi,
      ),
    ].map(
      (m) => m[1],
    );

  for (
    const tablo of tablolar
  ) {
    const satirKayitlari =
      tabloSatirlariniHtmlIleCikar(
        tablo,
      );
    const satirlar =
      satirKayitlari.map(
        (x) => x.hucreler,
      );

    if (
      satirlar.length < 2
    ) {
      continue;
    }

    const baslik =
      normalizeText(
        satirlar
          .slice(
            0,
            2,
          )
          .flat()
          .join(' '),
      );

    const puanTablosu =
      /puan|takim/.test(
        baslik,
      ) &&
      (
        /oynanan|\bog\b|\bo\b|\bom\b/.test(
          baslik,
        )
      ) &&
      (
        /averaj|\bav\b/.test(
          baslik,
        )
      ) &&
      (
        /puan|\bp\b/.test(
          baslik,
        )
      );

    if (
      !puanTablosu
    ) {
      continue;
    }

    const takimlar = [];

    for (
      const satirKaydi of satirKayitlari.slice(
        1,
      )
    ) {
      const row = satirKaydi.hucreler;

      if (
        row.length < 7
      ) {
        continue;
      }

      const adayTakim =
        row.find(
          (cell) =>
            takimAdiMi(cell) &&
            !/^\d+$/.test(
              cell,
            ),
        );

      if (!adayTakim) {
        continue;
      }

      const nums =
        row
          .filter(
            (cell) =>
              /^-?\d+$/.test(
                cell.trim(),
              ),
          )
          .map(
            Number,
          );

      if (
        nums.length < 8
      ) {
        continue;
      }

      const n =
        nums;

      takimlar.push({
        sira:
          nums[0] ||
          takimlar.length + 1,

        takim:
          adayTakim,

        oynanan:
          n[n.length - 8] ??
          0,

        galibiyet:
          n[n.length - 7] ??
          0,

        beraberlik:
          n[n.length - 6] ??
          0,

        maglubiyet:
          n[n.length - 5] ??
          0,

        atilanGol:
          n[n.length - 4] ??
          0,

        yenilenGol:
          n[n.length - 3] ??
          0,

        averaj:
          n[n.length - 2] ??
          0,

        puan:
          n[n.length - 1] ??
          0,

        logoUrl:
          logoUrlBul(
            satirKaydi.html,
          ),
      });
    }

    if (
      takimlar.length >= 4
    ) {
      return takimlar;
    }
  }

  return [];
}


// ============================================================
// 7. MÜKERRER MAÇ KONTROLÜ
// ============================================================

function macBelgeId(mac) {
  /*
   * Tarih ve saat ID'ye dahil değil.
   *
   * Böylece:
   *
   * 14.10.2026 18:00
   *
   * daha sonra
   *
   * 15.10.2026 19:00
   *
   * olursa yeni maç oluşturulmaz.
   * Mevcut kayıt güncellenir.
   */

  return hashOlustur(
    [
      mac.sezon,

      mac.hafta,

      normalizeText(
        mac.evSahibi,
      ),

      normalizeText(
        mac.deplasman,
      ),
    ].join('|'),
  ).substring(
    0,
    40,
  );
}


// ============================================================
// 8. FİKSTÜRÜ FIRESTORE'A KAYDET
// ============================================================

function fiksturTarihiZamaniCoz(value) {
  const match = String(value || '').match(/(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})(?:\s+(\d{1,2}):(\d{2}))?/);
  if (!match) return null;

  let year = Number(match[3]);
  if (year < 100) year += 2000;
  const month = Number(match[2]);
  const day = Number(match[1]);
  const hour = Number(match[4] || 0);
  const minute = Number(match[5] || 0);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return null;

  // Türkiye yerel saatiyle karşılaştır; sunucunun saat dilimine bağlı kalma.
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Istanbul', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date());
  const nowParts = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const nowComparable = `${nowParts.year}-${nowParts.month}-${nowParts.day}T${nowParts.hour}:${nowParts.minute}`;
  const matchComparable = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  return { comparable: matchComparable, future: matchComparable > nowComparable, date: matchComparable.slice(0, 10) };
}

async function fiksturleriKaydet(
  maclar,
  kaynak,
) {
  let yeniMacSayisi = 0;
  let programDegisikligiMacSayisi = 0;
  const bildirimlikDegisiklikler = [];

  for (const mac of maclar) {
    const ref = db
      .collection(ASKF_FIKSTUR_KOLEKSIYONU)
      .doc(macBelgeId(mac));

    let yeniMac = false;
    let programDegisikligi = false;
    let degisiklikTuru = '';

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const onceki = snap.exists ? (snap.data() || {}) : {};
      const oncekiKaynaklar = Array.isArray(onceki.kaynakIds)
        ? onceki.kaynakIds
        : (onceki.kaynakId ? [onceki.kaynakId] : []);

      const oncekiKaynakProgrami = onceki.kaynakProgramlari?.[kaynak.id] || null;
      // Genel haftalık sayfa aynı maç belgesini daha önce güncellemiş olabilir.
      // Bu nedenle lig/grup sayfasının kendi önceki tarih-saatini ayrıca izliyoruz.
      const oncekiTarihSaat = String(
        oncekiKaynakProgrami?.tarihSaat ?? onceki.tarihSaat ?? '',
      ).trim();
      const yeniTarihSaat = String(mac.tarihSaat || '').trim();
      const oncekiZaman = fiksturTarihiZamaniCoz(oncekiTarihSaat);
      const yeniZaman = fiksturTarihiZamaniCoz(yeniTarihSaat);
      const zamanDegisti = oncekiTarihSaat !== yeniTarihSaat;
      const tarihSaatIlkKezBelirlendi = !oncekiZaman && !!yeniZaman;
      const macIlkKezEklendi = !snap.exists;

      yeniMac = macIlkKezEklendi;
      // İlk kez bu grup kaynağına rastlandığında, genel kaynakta zaten tarihi belli
      // olan maçları topluca bildirmiyoruz. Sadece gerçekten yeni/belirlenen/değişen
      // tarih-saat bilgisi ve gelecekte oynanacak maç bildirim üretir.
      programDegisikligi = kaynak.veriTuru === 'grup' && !!yeniZaman?.future && (
        macIlkKezEklendi || tarihSaatIlkKezBelirlendi || (zamanDegisti && !!oncekiZaman?.future)
      );

      if (programDegisikligi) {
        degisiklikTuru = macIlkKezEklendi
          ? 'yeni_mac'
          : (tarihSaatIlkKezBelirlendi ? 'tarih_saat_belirlendi' : 'tarih_saat_degisti');
      }

      tx.set(ref, {
        ...mac,
        yayinlandi: true,
        kaynakId: kaynak.id,
        kaynakIds: FieldValue.arrayUnion(kaynak.id),
        otomatikAktarim: true,
        olusturmaTarihi: onceki.olusturmaTarihi || FieldValue.serverTimestamp(),
        sonGuncelleme: FieldValue.serverTimestamp(),
        bildirimGonderildi: onceki.bildirimGonderildi === true,
        sonProgramBildirimHash: programDegisikligi
          ? hashOlustur(`${kaynak.id}|${macBelgeId(mac)}|${yeniTarihSaat}`)
          : (onceki.sonProgramBildirimHash || ''),
        kaynakProgramlari: {
          ...(onceki.kaynakProgramlari || {}),
          [kaynak.id]: {
            ...(onceki.kaynakProgramlari?.[kaynak.id] || {}),
            tarihSaat: yeniTarihSaat,
            sonKontrol: FieldValue.serverTimestamp(),
          },
        },
      }, { merge: true });
    });

    if (yeniMac) yeniMacSayisi++;
    if (programDegisikligi) {
      programDegisikligiMacSayisi++;
      bildirimlikDegisiklikler.push({
        evSahibi: mac.evSahibi,
        deplasman: mac.deplasman,
        hafta: mac.hafta,
        tarihSaat: mac.tarihSaat,
        tur: degisiklikTuru,
      });
    }
  }

  /*
   * Haftalık genel sayfa yalnızca veriyi günceller, bildirim göndermez.
   * Bildirim sadece lig/grup sayfasında tespit edilen ve gelecekte oynanacak
   * maçın ilk kez eklenmesi, tarih-saatinin belirlenmesi veya değiştirilmesi
   * halinde gönderilir. Geçmiş maçlardaki değişiklikler bildirim üretmez.
   */
  // Bir grubun fikstürü ilk kez aktarıldığında tüm maçlar "yeni" görünür;
  // bu ilk aktarımda toplu bildirim göndermiyoruz.
  let ilkFiksturAktarimi = false;
  if (kaynak.veriTuru === 'grup' && programDegisikligiMacSayisi > 0) {
    const ilkRef = db.collection('askf_bildirim_kayitlari').doc(kaynak.id);
    const ilkSnap = await ilkRef.get();
    if (ilkSnap.data()?.fiksturIlkAktarimTamam !== true) {
      ilkFiksturAktarimi = true;
      await ilkRef.set({ fiksturIlkAktarimTamam: true, kaynakId: kaynak.id }, { merge: true });
      console.log(`ASKF ${kaynak.id}: ilk fikstür aktarımı, bildirim gönderilmedi (${programDegisikligiMacSayisi} maç).`);
    }
  }

  if (!ilkFiksturAktarimi && kaynak.veriTuru === 'grup' && programDegisikligiMacSayisi > 0 && await otomatikBildirimlerAcikMi()) {
    const ligAdi = kaynak.lig || kaynak.ad || 'Yalova Yerel Ligi';
    const grupAdi = kaynak.grup && kaynak.grup !== 'genel' ? ` ${kaynak.grup}` : '';
    const kaynakAdi = kaynak.ad || `${ligAdi}${grupAdi}`;
    const degisiklikHash = hashOlustur(
      bildirimlikDegisiklikler
        .map((m) => `${m.evSahibi}|${m.deplasman}|${m.hafta}|${m.tarihSaat}|${m.tur}`)
        .sort()
        .join('\n'),
    );
    const bildirimRef = db.collection('askf_bildirim_kayitlari').doc(kaynak.id);
    const sonuc = await db.runTransaction(async (tx) => {
      const snap = await tx.get(bildirimRef);
      const veri = snap.exists ? (snap.data() || {}) : {};
      if (veri.sonProgramBildirimHash === degisiklikHash) return { gonder: false };
      tx.set(bildirimRef, {
        kaynakId: kaynak.id,
        kaynakAdi: kaynakAdi,
        sonProgramBildirimHash: degisiklikHash,
        sonProgramBildirimTarihi: FieldValue.serverTimestamp(),
        bildirimDurumu: 'hazirlaniyor',
      }, { merge: true });
      return { gonder: true };
    });

    if (sonuc.gonder) {
      // Her takım için yalnızca kendi maçları: o takımı favorileyen ve
      // "Ligler" bildirimleri açık olan kullanıcılara gider.
      const takimMaclari = new Map();
      for (const m of bildirimlikDegisiklikler) {
        for (const takim of [m.evSahibi, m.deplasman]) {
          const id = takimKonuKimligi(takim);
          if (!id) continue;
          if (!takimMaclari.has(id)) takimMaclari.set(id, { takim, maclar: [] });
          takimMaclari.get(id).maclar.push(m);
        }
      }

      const mesajIdleri = [];
      let sonHata = null;
      for (const [id, { takim, maclar: tm }] of takimMaclari) {
        const satirlar = tm.slice(0, 2).map((m) =>
          `${m.evSahibi} - ${m.deplasman}: ${m.tarihSaat}`
        );
        const fazla = tm.length > 2 ? ` (+${tm.length - 2} maç)` : '';
        const degisti = tm.some((m) => m.tur === 'tarih_saat_degisti');
        try {
          mesajIdleri.push(await getMessaging().send(bildirimVerisiEkle({
            condition: `'ligler' in topics && 'fav_${id}' in topics`,
            notification: {
              title: degisti ? `📅 ${takim} maç saati değişti` : `📅 ${takim} maç programı belli oldu`,
              body: `${satirlar.join(' • ')}${fazla}`.slice(0, 200),
            },
            data: {
              tur: 'askf_fikstur_tarih_saat_guncelleme',
              kaynakId: kaynak.id,
              lig: ligAdi,
              grup: kaynak.grup || '',
              sezon: ASKF_SEZON,
              ligTuru: 'yerel',
              takim,
            },
            android: {
              priority: 'high',
              notification: { channelId: 'yalova_wonder_kids', sound: 'default' },
            },
          })));
        } catch (error) {
          sonHata = error;
          console.error(`ASKF fikstür bildirimi gönderilemedi (${takim}):`, error);
        }
      }

      if (mesajIdleri.length > 0 || !sonHata) {
        await bildirimRef.set({
          fcmMessageId: mesajIdleri.join(',').slice(0, 500),
          bildirimDurumu: 'gonderildi',
          bildirimMacSayisi: programDegisikligiMacSayisi,
          bildirimTakimSayisi: mesajIdleri.length,
        }, { merge: true });
      } else {
        console.error(`ASKF ${kaynakAdi} fikstür bildirimi gönderilemedi:`, sonHata);
        await bildirimRef.set({
          bildirimDurumu: 'hata',
          bildirimHatasi: String(sonHata?.message || sonHata).slice(0, 500),
        }, { merge: true });
      }
    }
  }

  return {
    toplamMac: maclar.length,
    yeniMacSayisi,
    ligBazindaBildirimlikMacSayisi: programDegisikligiMacSayisi,
  };
}

// ============================================================
// 9. PUAN DURUMUNU FIRESTORE'A KAYDET
// ============================================================

async function puanDurumunuKaydet(
  takimlar,
  kaynak,
) {
  if (
    !Array.isArray(takimlar) ||
    takimlar.length < 4
  ) {
    return false;
  }

  const grup = kaynak.grup;
  // Önceden kullanılan Süper Amatör belge kimlikleri korunur.
  const docId = kaynak.puanDocId || kaynak.id;
  const ligAdi = kaynak.lig || kaynak.ad || 'Yalova Yerel Ligleri';
  const puanRef = db.collection(ASKF_PUAN_KOLEKSIYONU).doc(docId);
  const oncekiSnap = await puanRef.get();
  const oncekiVeri = oncekiSnap.exists ? (oncekiSnap.data() || {}) : {};

  // HTML tasarımındaki değişiklikleri değil, gerçek puan tablosunu karşılaştır.
  const karsilastirmaVerisi = takimlar.map((takim) => ({
    sira: Number(takim.sira || 0),
    takim: normalizeText(takim.takim || ''),
    oynanan: Number(takim.oynanan || 0),
    galibiyet: Number(takim.galibiyet || 0),
    beraberlik: Number(takim.beraberlik || 0),
    maglubiyet: Number(takim.maglubiyet || 0),
    atilanGol: Number(takim.atilanGol || 0),
    yenilenGol: Number(takim.yenilenGol || 0),
    averaj: Number(takim.averaj || 0),
    puan: Number(takim.puan || 0),
  }));
  const yeniPuanHash = hashOlustur(JSON.stringify(karsilastirmaVerisi));
  const oncekiPuanHash = String(oncekiVeri.puanDurumuHash || '');
  const ilkKayit = !oncekiPuanHash;
  const puanDegisti = !ilkKayit && oncekiPuanHash !== yeniPuanHash;

  const guncelAlanlar = {
    sezon: ASKF_SEZON,
    lig: ligAdi,
    grup,
    kaynakId: kaynak.id,
    kaynakAdi: kaynak.ad,
    takimlar,
    kaynak: kaynak.url,
    otomatikAktarim: true,
    puanDurumuHash: yeniPuanHash,
    sonGuncelleme: FieldValue.serverTimestamp(),
  };

  // Bildirim gönderilemezse bir sonraki kontrolde yeniden denenebilmesi için
  // bekleyen hash saklanır. İlk veri aktarımında bildirim gönderilmez.
  if (puanDegisti) {
    guncelAlanlar.puanDurumuBildirimBekleyenHash = yeniPuanHash;
  }

  await puanRef.set(guncelAlanlar, { merge: true });

  const kayitliVeri = { ...oncekiVeri, ...guncelAlanlar };
  const bekleyenHash = String(kayitliVeri.puanDurumuBildirimBekleyenHash || '');
  const sonBildirimHash = String(kayitliVeri.sonBildirimPuanDurumuHash || '');

  if (bekleyenHash && bekleyenHash === yeniPuanHash && sonBildirimHash !== yeniPuanHash && await otomatikBildirimlerAcikMi()) {
    const baslik = `${kaynak.ad || ligAdi} Puan Durumu Güncellendi`;
    const mesaj = `${kaynak.ad || ligAdi} puan durumu güncellendi. Güncel sıralamayı Wonder Kids uygulamasından inceleyebilirsiniz.`;

    try {
      const mesajIdleri = await favoriTakimlaraGonder(takimlar.map((t) => t.takim), {
        notification: { title: baslik, body: mesaj },
        data: {
          tur: 'askf_yerel_puan_durumu',
          kaynakId: String(kaynak.id),
          lig: String(ligAdi),
          grup: String(grup || ''),
          sezon: String(ASKF_SEZON),
          ligTuru: 'yerel',
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'yalova_wonder_kids',
            sound: 'default',
          },
        },
      });

      await puanRef.set({
        sonBildirimPuanDurumuHash: yeniPuanHash,
        sonBildirimTarihi: FieldValue.serverTimestamp(),
        sonBildirimMessageId: mesajIdleri.join(',').slice(0, 500),
        puanDurumuBildirimBekleyenHash: FieldValue.delete(),
        sonBildirimDurumu: 'gonderildi',
        sonBildirimHatasi: FieldValue.delete(),
      }, { merge: true });

      console.log(`ASKF puan durumu bildirimi gönderildi: ${kaynak.ad || ligAdi}`);
    } catch (error) {
      console.error(`ASKF puan durumu bildirimi gönderilemedi: ${kaynak.id}`, error);
      await puanRef.set({
        sonBildirimDurumu: 'hata',
        sonBildirimHatasi: String(error?.message || error).slice(0, 500),
      }, { merge: true });
    }
  }

  return true;
}

// ============================================================
// 10. ASKF KAYNAK KONTROLÜ
// ============================================================

async function askfKaynakKontrolEt(
  kaynak,
) {
  const kaynakRef =
    db
      .collection(
        'askf_kaynak_durumlari',
      )
      .doc(
        kaynak.id,
      );

  try {
    const response =
      await fetch(
        kaynak.url,
        {
          method:
            'GET',

          headers: {
            'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
              'AppleWebKit/537.36 (KHTML, like Gecko) ' +
              'Chrome/155.0.0.0 Safari/537.36',

            'Accept':
              'text/html,application/xhtml+xml,' +
              'application/xml;q=0.9,*/*;q=0.8',

            'Accept-Language':
              'tr-TR,tr;q=0.9,en;q=0.8',

            'Cache-Control':
              'no-cache',

            'Pragma':
              'no-cache',
          },

          signal:
            AbortSignal.timeout(
              45000,
            ),
        },
      );

    let html =
      await response.text();

    // ASKF'nin haftalık-program sayfası bazı isteklerde yalnızca
    // JavaScript yükleme kabuğu döndürüyor. Ana sayfada aynı haftalık
    // maçlar sunucu tarafında HTML olarak yayımlanabildiği için,
    // yalnızca haftalık program kaynağında güvenli yedek dene.
    let kullanilanUrl = kaynak.url;
    const yukleniyorKabugu =
      /site yükleniyor|site yukleniyor|lütfen bekleyin/i.test(
        htmlMetniniTemizle(html),
      ) &&
      !/<tr\b/i.test(html);

    if (
      kaynak.id === 'haftalik_program' &&
      yukleniyorKabugu
    ) {
      const yedekResponse = await fetch(
        'https://yalovaskf.com/',
        {
          method: 'GET',
          headers: {
            'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
              'AppleWebKit/537.36 (KHTML, like Gecko) ' +
              'Chrome/155.0.0.0 Safari/537.36',
            'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'tr-TR,tr;q=0.9,en;q=0.8',
            'Cache-Control': 'no-cache',
          },
          signal: AbortSignal.timeout(45000),
        },
      );
      const yedekHtml = await yedekResponse.text();
      if (
        yedekResponse.status === 200 &&
        /<tr\b/i.test(yedekHtml) &&
        /haftanın maçları|haftanin maclari|haftalık maç programı|haftalik mac programi/i.test(
          normalizeText(htmlMetniniTemizle(yedekHtml)),
        )
      ) {
        html = yedekHtml;
        kullanilanUrl = yedekResponse.url || 'https://yalovaskf.com/';
        console.log('ASKF haftalık program için ana sayfa yedeği kullanıldı.');
      }
    }

    // Tanı kaydı: URL gerçekten istenen lig sayfasını mı döndürüyor?
    // Veri ayrıştırma başarısız olduğunda HTML yapısını teşhis etmeyi sağlar.
    const sayfaBasligi =
      (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] || '')
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 180);

    const tabloSayisi =
      (html.match(/<table\b/gi) || []).length;

    const satirSayisi =
      (html.match(/<tr\b/gi) || []).length;

    console.log(
      `ASKF kaynak yanıtı: ${kaynak.id}`,
      JSON.stringify({
        istenenUrl: kaynak.url,
        sonUrl: kullanilanUrl,
        httpDurumu: response.status,
        htmlUzunlugu: html.length,
        sayfaBasligi,
        tabloSayisi,
        satirSayisi,
        kaynakAdiSayfada: normalizeText(htmlMetniniTemizle(html))
          .includes(normalizeText(kaynak.ad)),
      }),
    );

    if (
      response.status !== 200 ||
      !html ||
      html.length < 300
    ) {
      throw new Error(
        `Kaynak geçerli HTML döndürmedi (HTTP ${response.status}).`,
      );
    }

    const metin =
      htmlMetniniTemizle(
        html,
      );

    // Genel bir hata/boş sayfa 200 döndürülse bile kaynak verisi gibi kaydedilmesin.
    const normMetin = normalizeText(metin);
    const sayfaBeklenenIcerik =
      kaynak.veriTuru === 'fikstur'
        ? (
            /haftalik mac programi|haftanin maclari/.test(normMetin) ||
            /\d{1,2}\.\d{1,2}\.20\d{2}/.test(metin)
          )
        : (
            normMetin.includes(normalizeText(kaynak.ad)) ||
            /puan durumu/.test(normMetin)
          );

    if (!sayfaBeklenenIcerik) {
      throw new Error(
        `Kaynak URL beklenen lig/program içeriğini döndürmedi. ` +
        `HTTP ${response.status}; son URL: ${response.url || kaynak.url}; ` +
        `başlık: ${(sayfaBasligi || 'yok')}. URL doğrulanmalı.`,
      );
    }

    const yeniHash =
      hashOlustur(
        metin,
      );

    const eskiSnap =
      await kaynakRef.get();

    const eskiVeri =
      eskiSnap.exists
        ? (
            eskiSnap.data() ||
            {}
          )
        : {};

    let fiksturSonucu = {
      toplamMac:
        0,

      yeniMacSayisi:
        0,
    };

    let puanDurumuKaydedildi =
      false;

    // --------------------------------------------------------
    // GRUP SAYFALARI
    // --------------------------------------------------------

    if (
      kaynak.veriTuru ===
      'grup'
    ) {
      let maclar =
        fiksturleriAyrisla(
          html,
          kaynak,
        );

      if (maclar.length === 0) {
        maclar = await takimSayfalarindanFiksturGetir(kaynak, html);
        console.log(`ASKF takım sayfalarından fikstür: ${kaynak.id}; ${maclar.length} maç`);
      }

      /*
       * Çok önemli:
       *
       * Parser hiçbir maç bulamazsa
       * mevcut Firestore kayıtlarını silmiyoruz.
       */

      if (
        maclar.length > 0
      ) {
        fiksturSonucu =
          await fiksturleriKaydet(
            maclar,
            kaynak,
          );
      }

      const takimlar =
        puanDurumunuAyrisla(
          html,
          kaynak,
        );

      /*
       * Puan tablosu yeterli sayıda takım
       * içermiyorsa mevcut puan durumunu
       * değiştirmiyoruz.
       */

      if (
        takimlar.length >= 4
      ) {
        puanDurumuKaydedildi =
          await puanDurumunuKaydet(
            takimlar,
            kaynak,
          );
      }

      if (
        maclar.length === 0 &&
        takimlar.length === 0
      ) {
        console.warn(
          `ASKF sayfası açıldı ancak tanınan ` +
          `fikstür/puan tablosu bulunamadı: ` +
          `${kaynak.id}. ` +
          `Mevcut veriler korunuyor.`,
        );
      }

    } else {

      // ------------------------------------------------------
      // HAFTALIK PROGRAM
      // ------------------------------------------------------

      const maclar =
        fiksturleriAyrisla(
          html,
          kaynak,
        );

      if (
        maclar.length > 0
      ) {
        fiksturSonucu =
          await fiksturleriKaydet(
            maclar,
            kaynak,
          );
      }
    }

    const degisti =
      !eskiSnap.exists ||
      String(
        eskiVeri.sonHash ||
        '',
      ) !== yeniHash;

    await kaynakRef.set(
      {
        aktif:
          true,

        kaynakAdi:
          kaynak.ad,

        kaynakId:
          kaynak.id,

        kaynakUrl:
          kullanilanUrl,

        ligTuru:
          'yerel',

        grup:
          kaynak.grup,

        veriTuru:
          kaynak.veriTuru,

        sonHash:
          yeniHash,

        sonMetin:
          metin.slice(
            0,
            90000,
          ),

        sonHttpDurumu:
          response.status,

        sonKontrol:
          FieldValue.serverTimestamp(),

        sonHata:
          FieldValue.delete(),

        sonMacSayisi:
          fiksturSonucu.toplamMac,

        sonYeniMacSayisi:
          fiksturSonucu.yeniMacSayisi,

        puanDurumuKaydedildi,

        htmlDegisti:
          degisti,
      },
      {
        merge: true,
      },
    );

    if (
      degisti
    ) {
      const degisimId =
        `${kaynak.id}_${yeniHash.substring(
          0,
          24,
        )}`;

      await db
        .collection(
          'askf_degisimler',
        )
        .doc(
          degisimId,
        )
        .set(
          {
            kaynakId:
              kaynak.id,

            kaynakAdi:
              kaynak.ad,

            kaynakUrl:
              kaynak.url,

            ligTuru:
              'yerel',

            durum:
              'kontrol_edildi',

            bildirimGonderildi:
              fiksturSonucu.yeniMacSayisi >
              0,

            oncekiHash:
              String(
                eskiVeri.sonHash ||
                '',
              ),

            yeniHash,

            olusturmaTarihi:
              FieldValue.serverTimestamp(),
          },
          {
            merge: true,
          },
        );
    }

    console.log(
      `ASKF kontrolü tamamlandı: ${kaynak.id}`,

      JSON.stringify(
        {
          ...fiksturSonucu,

          puanDurumuKaydedildi,

          degisti,
        },
      ),
    );

    return {
      kaynakId:
        kaynak.id,

      degisti,

      ...fiksturSonucu,

      puanDurumuKaydedildi,
    };

  } catch (error) {

    console.error(
      `ASKF kontrol hatası: ${kaynak.id}`,
      error,
    );

    await kaynakRef.set(
      {
        aktif:
          true,

        kaynakAdi:
          kaynak.ad,

        kaynakId:
          kaynak.id,

        kaynakUrl:
          kaynak.url,

        ligTuru:
          'yerel',

        grup:
          kaynak.grup,

        veriTuru:
          kaynak.veriTuru,

        sonKontrol:
          FieldValue.serverTimestamp(),

        sonHata:
          String(
            error?.message ||
            error,
          ).slice(
            0,
            500,
          ),
      },
      {
        merge: true,
      },
    );

    return {
      kaynakId:
        kaynak.id,

      degisti:
        false,

      hata:
        true,

      hataMesaji:
        String(error?.message || error).slice(0, 300),
    };
  }
}

// Yönetim panelindeki "ASKF Veri Durumu" ekranı için hafif özet kaydı.
// (askf_kaynak_durumlari belgeleri sayfa metnini de tuttuğu için büyüktür.)
async function askfOzetYaz(kaynak, sonuc, elle = false) {
  try {
    const basarili = !sonuc?.hata;
    const kayit = {
      ad: String(kaynak.ad || kaynak.id),
      url: String(kaynak.url || ''),
      veriTuru: String(kaynak.veriTuru || ''),
      sonKontrol: FieldValue.serverTimestamp(),
      basarili,
      elleGuncelleme: elle === true,
    };
    if (basarili) {
      kayit.sonBasari = FieldValue.serverTimestamp();
      kayit.macSayisi = Number(sonuc?.toplamMac || 0);
      kayit.puanDurumu = sonuc?.puanDurumuKaydedildi === true;
      kayit.hata = FieldValue.delete();
    } else {
      kayit.hata = String(sonuc?.hataMesaji || 'Bilinmeyen hata').slice(0, 300);
    }
    await db.collection('askfOzet').doc(String(kaynak.id)).set(kayit, { merge: true });
  } catch (error) {
    console.error('askfOzet yazılamadı:', kaynak?.id, error);
  }
}


// ============================================================
// 11. ASKF YEREL LİG KONTROLÜ
//
// HER 6 SAATTE BİR ÇALIŞIR.
//
// KONTROL EDİLENLER:
//
// Haftalık program + Süper Amatör, 1. Amatör, U17, U14 ve U12 kaynakları
//
// ============================================================

// ============================================================
// ANA SAYFA "HAFTANIN MAÇLARI" PROGRAMI
//
// yalovaskf.com ana sayfasındaki "Yalova Haftalık Maç Programı"
// tablosunu okur ve Firestore'a haftalikProgram/guncel olarak yazar.
// Uygulamadaki Haftalık Fikstür ekranı bu belgeyi gösterir.
// Sayfadan hiç maç okunamazsa eski veri korunur.
// ============================================================

function ligEtiketiTemizle(etiket) {
  let t = String(etiket || '').replace(/\s+/g, ' ').trim();
  // "U17 LİGİ U17 LİGİ" gibi tekrarları tek yap
  const yarim = Math.floor(t.length / 2);
  const a = t.slice(0, yarim).trim();
  const b = t.slice(yarim).trim();
  if (a && a === b) t = a;
  const parcalar = t.split(' ');
  if (parcalar.length % 2 === 0) {
    const ilk = parcalar.slice(0, parcalar.length / 2).join(' ');
    const son = parcalar.slice(parcalar.length / 2).join(' ');
    if (ilk === son) t = ilk;
  }
  return t;
}

function logoUrlBul(parcaHtml) {
  const m = String(parcaHtml || '').match(
    /<img\b[^>]*?\b(?:data-src|data-lazy-src|src)=["']([^"']+)["']/i,
  );
  if (!m) return '';
  const url = m[1].trim();
  if (!url || url.startsWith('data:')) return '';
  if (url.startsWith('//')) return `https:${url}`;
  if (/^https?:\/\//i.test(url)) return url;
  return `https://yalovaskf.com${url.startsWith('/') ? '' : '/'}${url}`;
}

function haftalikProgramSatiriAyrisla(satirHtml) {
  const metin = htmlMetniniTemizle(satirHtml)
    .replace(/\s*\|\s*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  const tarihMatch = metin.match(
    /(\d{1,2})\.(\d{1,2})\.(\d{4})\s+(\d{1,2}):(\d{2})/,
  );
  const haftaMatch = metin.match(/^(.*?)\s*-\s*(\d+)\.\s*Hafta/i);
  if (!tarihMatch || !haftaMatch) return null;

  const gun = tarihMatch[1].padStart(2, '0');
  const ay = tarihMatch[2].padStart(2, '0');
  const yil = tarihMatch[3];
  const saat = tarihMatch[4].padStart(2, '0');
  const dakika = tarihMatch[5];
  const tarihMs = Date.parse(`${yil}-${ay}-${gun}T${saat}:${dakika}:00+03:00`);
  if (Number.isNaN(tarihMs)) return null;

  // Takım adları: /takim/ bağlantılarından; yoksa metinden
  const takimlar = [];
  const logolar = [];
  const takimRegex =
    /<a\b[^>]*href=["'][^"']*\/takim\/[^"']*["'][^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = takimRegex.exec(satirHtml)) !== null) {
    const ad = htmlMetniniTemizle(m[1]).replace(/\s*\|\s*/g, ' ')
      .replace(/\s+/g, ' ').trim();
    if (ad) {
      takimlar.push(ad);
      logolar.push(logoUrlBul(m[1]));
    }
  }

  // Bağlantı içinde logo bulunamadıysa satırdaki resimleri sırayla kullan.
  if (!logolar[0] || !logolar[1]) {
    const resimler = [];
    const imgRegex = /<img\b[^>]*>/gi;
    let im;
    while ((im = imgRegex.exec(satirHtml)) !== null) {
      const u = logoUrlBul(im[0]);
      if (u) resimler.push(u);
    }
    if (resimler.length >= 2) {
      if (!logolar[0]) logolar[0] = resimler[0];
      if (!logolar[1]) logolar[1] = resimler[1];
    }
  }

  let evSahibi = takimlar[0] || '';
  let deplasman = takimlar[1] || '';

  if (!evSahibi || !deplasman) {
    const haftaBitis = haftaMatch[0].length;
    const tarihBasi = metin.indexOf(tarihMatch[0]);
    const aradaki = metin.slice(haftaBitis, tarihBasi).trim();
    const bol = aradaki.split(/\s+-\s+/);
    if (bol.length >= 2) {
      evSahibi = bol[0].trim();
      deplasman = bol.slice(1).join(' - ').trim();
    }
  }
  if (!evSahibi || !deplasman) return null;

  let stadyum = '';
  const tarihSonrasi = metin.slice(
    metin.indexOf(tarihMatch[0]) + tarihMatch[0].length,
  );
  const stadMatch = tarihSonrasi.match(/[·•]\s*([^|]+?)(?:\s+\d+\s*-\s*\d+\s*)?$/);
  if (stadMatch) stadyum = stadMatch[1].trim();

  // Sonuç: ikinci hücrede "2 - 1" biçimi
  let sonuc = '';
  const hucreler = hucreleriCikar(satirHtml);
  if (hucreler.length >= 2) {
    const son = hucreler[hucreler.length - 1];
    const sm = son.match(/^(\d+)\s*-\s*(\d+)$/);
    if (sm) sonuc = `${sm[1]} - ${sm[2]}`;
  }
  // Yedek: skor satırın sonunda ("... STADI 2 - 1") ya da başka hücrede olabilir.
  if (!sonuc) {
    const sonDeneme = metin.match(/(?:^|\s)(\d{1,2})\s*-\s*(\d{1,2})\s*$/);
    if (sonDeneme) sonuc = `${sonDeneme[1]} - ${sonDeneme[2]}`;
  }

  const macLink = satirHtml.match(/href=["']([^"']*\/mac\/[^"']*)["']/i);
  let macUrl = '';
  if (macLink) {
    macUrl = macLink[1].startsWith('http')
      ? macLink[1]
      : `https://yalovaskf.com${macLink[1].startsWith('/') ? '' : '/'}${macLink[1]}`;
  }

  return {
    lig: ligEtiketiTemizle(haftaMatch[1]),
    hafta: `${haftaMatch[2]}. Hafta`,
    evSahibi,
    deplasman,
    tarihSaat: `${gun}.${ay}.${yil} ${saat}:${dakika}`,
    tarihMs,
    stadyum,
    sonuc,
    macUrl,
    evLogo: logolar[0] || '',
    depLogo: logolar[1] || '',
  };
}

function haftalikProgramiAyrisla(html) {
  const maclar = [];
  const gorulen = new Set();
  const trRegex = /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;
  let m;
  while ((m = trRegex.exec(html)) !== null) {
    const mac = haftalikProgramSatiriAyrisla(m[1]);
    if (!mac) continue;
    const anahtar = `${mac.lig}|${mac.hafta}|${mac.evSahibi}|${mac.deplasman}|${mac.tarihMs}`;
    if (gorulen.has(anahtar)) continue;
    gorulen.add(anahtar);
    maclar.push(mac);
  }
  maclar.sort((a, b) => a.tarihMs - b.tarihMs);

  const metin = htmlMetniniTemizle(html).replace(/\s+/g, ' ');
  const aralik = metin.match(
    /Haftalık Maç Programı\s*[|]?\s*(\d{2}\.\d{2}\.\d{4})\s*-\s*(\d{2}\.\d{2}\.\d{4})/i,
  );

  return {
    maclar,
    haftaBaslangic: aralik ? aralik[1] : '',
    haftaBitis: aralik ? aralik[2] : '',
  };
}

async function haftalikProgramiGuncelle() {
  const response = await fetch('https://yalovaskf.com/', {
    method: 'GET',
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
        'AppleWebKit/537.36 (KHTML, like Gecko) ' +
        'Chrome/155.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'tr-TR,tr;q=0.9,en;q=0.8',
      'Cache-Control': 'no-cache',
    },
    signal: AbortSignal.timeout(45000),
  });
  const html = await response.text();
  const sonuc = haftalikProgramiAyrisla(html);

  if (!response.ok || sonuc.maclar.length === 0) {
    console.warn(
      `Haftalık program okunamadı (HTTP ${response.status}, maç: ${sonuc.maclar.length}). Eski veri korunuyor.`,
    );
    return { guncellendi: false, macSayisi: 0 };
  }

  await db.collection('haftalikProgram').doc('guncel').set({
    haftaBaslangic: sonuc.haftaBaslangic,
    haftaBitis: sonuc.haftaBitis,
    maclar: sonuc.maclar,
    macSayisi: sonuc.maclar.length,
    kaynak: 'https://yalovaskf.com/',
    sonGuncelleme: FieldValue.serverTimestamp(),
  });

  console.log(`Haftalık program güncellendi: ${sonuc.maclar.length} maç.`);
  return { guncellendi: true, macSayisi: sonuc.maclar.length };
}


// ============================================================
// YÖNETİCİ YÖNETİMİ (ekleme / yetki güncelleme / kaldırma)
// ============================================================
// adminler/{uid} belgesi: { aktif, ad, email, yetkiler: [..] }
// yetkiler alanı olmayan eski kayıtlar TAM yetkili sayılır.
// Yalnızca "yonetici" veya "tam" yetkisi olan yöneticiler bu işlemi yapabilir.
const YONETICI_YETKILERI = [
  'haber',
  'futbolcu',
  'basvuru',
  'takim',
  'duyuru',
  'bildirim',
  'ayar',
  'canli',
  'yonetici',
  'tam',
];

function yetkiBilgisi(veri) {
  const liste = Array.isArray(veri?.yetkiler) ? veri.yetkiler : null;
  const tam = liste === null || liste.includes('tam');
  return { liste: liste || [], tam };
}

exports.yoneticiYonet = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  async (request) => {
    const cagiranUid = request.auth?.uid;
    if (!cagiranUid) {
      throw new HttpsError('unauthenticated', 'Giriş yapmalısın.');
    }

    const cagiranSnap = await db.collection('adminler').doc(cagiranUid).get();
    const cagiranVeri = cagiranSnap.exists ? cagiranSnap.data() : null;
    if (!cagiranVeri || cagiranVeri.aktif !== true) {
      throw new HttpsError('permission-denied', 'Yönetici değilsin.');
    }
    const cagiran = yetkiBilgisi(cagiranVeri);
    if (!cagiran.tam && !cagiran.liste.includes('yonetici')) {
      throw new HttpsError(
        'permission-denied',
        'Yönetici ekleme yetkin yok.',
      );
    }

    const islem = String(request.data?.islem || '');

    function yetkileriTemizle(ham) {
      const liste = Array.isArray(ham) ? ham : [];
      const temiz = [...new Set(
        liste.map((x) => String(x)).filter((x) => YONETICI_YETKILERI.includes(x)),
      )];
      if (temiz.includes('tam') && !cagiran.tam) {
        throw new HttpsError(
          'permission-denied',
          'Tam yetkiyi yalnızca tam yetkili yönetici verebilir.',
        );
      }
      // "tam" varsa diğerlerine gerek yok.
      return temiz.includes('tam') ? ['tam'] : temiz;
    }

    if (islem === 'ekle') {
      const email = String(request.data?.email || '').trim().toLowerCase();
      const ad = String(request.data?.ad || '').trim().slice(0, 80);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 120) {
        throw new HttpsError('invalid-argument', 'Geçerli bir e-posta gir.');
      }
      const yetkiler = yetkileriTemizle(request.data?.yetkiler);
      if (yetkiler.length === 0) {
        throw new HttpsError('invalid-argument', 'En az bir yetki seç.');
      }

      const auth = getAuth();
      let kullanici;
      try {
        kullanici = await auth.getUserByEmail(email);
      } catch (e) {
        if (e.code !== 'auth/user-not-found') throw e;
        kullanici = await auth.createUser({
          email,
          password: crypto.randomBytes(18).toString('base64url'),
          displayName: ad || undefined,
        });
      }

      const ref = db.collection('adminler').doc(kullanici.uid);
      const mevcut = await ref.get();
      if (mevcut.exists && mevcut.data()?.aktif === true) {
        throw new HttpsError('already-exists', 'Bu kişi zaten yönetici.');
      }

      await ref.set({
        aktif: true,
        ad,
        email,
        yetkiler,
        ekleyenUid: cagiranUid,
        olusturmaTarihi: FieldValue.serverTimestamp(),
        guncellenmeTarihi: FieldValue.serverTimestamp(),
      });

      const sifreLinki = await auth.generatePasswordResetLink(email);
      return { uid: kullanici.uid, sifreLinki };
    }

    if (islem === 'guncelle' || islem === 'kaldir' || islem === 'sifreLinki') {
      const uid = String(request.data?.uid || '');
      if (!uid) {
        throw new HttpsError('invalid-argument', 'Yönetici seçilmedi.');
      }
      if (uid === cagiranUid) {
        throw new HttpsError(
          'failed-precondition',
          'Kendi yetkini bu ekrandan değiştiremezsin.',
        );
      }
      const ref = db.collection('adminler').doc(uid);
      const hedefSnap = await ref.get();
      if (!hedefSnap.exists) {
        throw new HttpsError('not-found', 'Yönetici bulunamadı.');
      }
      const hedef = yetkiBilgisi(hedefSnap.data());
      if (hedef.tam && !cagiran.tam) {
        throw new HttpsError(
          'permission-denied',
          'Tam yetkili yöneticiyi yalnızca tam yetkili yönetici değiştirebilir.',
        );
      }

      if (islem === 'sifreLinki') {
        // Kilidi aç (varsa) ve yeni şifre belirleme bağlantısı üret.
        const hedefVeri = hedefSnap.data() || {};
        const email = String(hedefVeri.email || '').trim().toLowerCase();
        if (!email) {
          throw new HttpsError('failed-precondition', 'Bu yöneticinin e-postası kayıtlı değil.');
        }
        const auth = getAuth();
        await auth.updateUser(uid, { disabled: false });
        const guncelle = {
          kilitli: false,
          guncellenmeTarihi: FieldValue.serverTimestamp(),
        };
        if (hedefVeri.kilitli === true) guncelle.aktif = true;
        await ref.update(guncelle);
        await db.collection('adminGirisDenemeleri').doc(uid).delete().catch(() => {});
        try {
          await auth.revokeRefreshTokens(uid);
        } catch (_) {}
        const sifreLinki = await auth.generatePasswordResetLink(email);
        return { sifreLinki };
      }

      if (islem === 'kaldir') {
        await ref.update({
          aktif: false,
          guncellenmeTarihi: FieldValue.serverTimestamp(),
        });
        try {
          await getAuth().revokeRefreshTokens(uid);
        } catch (_) {}
        return { tamam: true };
      }

      const yetkiler = yetkileriTemizle(request.data?.yetkiler);
      if (yetkiler.length === 0) {
        throw new HttpsError('invalid-argument', 'En az bir yetki seç.');
      }
      await ref.update({
        yetkiler,
        aktif: request.data?.aktif !== false,
        guncellenmeTarihi: FieldValue.serverTimestamp(),
      });
      return { tamam: true };
    }

    throw new HttpsError('invalid-argument', 'Bilinmeyen işlem.');
  },
);


// ============================================================
// YÖNETİCİ GİRİŞİ: 3 yanlış şifrede kilit + tam yetkililere giriş bildirimi
// ============================================================
// Giriş uygulama içinde bu fonksiyon üzerinden yapılır: şifre sunucuda doğrulanır,
// yanlış denemeler sayılır, 3. yanlışta hesap kilitlenir (Auth hesabı devre dışı,
// adminler/{uid}.kilitli = true, aktif = false). Kilidi tam yetkili yönetici,
// "Yönetici Yönetimi" ekranından yeni şifre bağlantısı üreterek açar.
// Başarılı girişte tam yetkili yöneticilere bildirim gider.
const MAKS_YANLIS_SIFRE = 3;

async function tamYetkiliTokenlari(haricUid, ekYetki) {
  const snap = await db.collection('adminler').get();
  const hedefUidler = [];
  snap.forEach((doc) => {
    const v = doc.data() || {};
    if (doc.id === haricUid || v.aktif !== true) return;
    const bilgi = yetkiBilgisi(v);
    if (bilgi.tam || (ekYetki && bilgi.liste.includes(ekYetki))) hedefUidler.push(doc.id);
  });
  const tokenlar = [];
  for (const uid of hedefUidler) {
    const t = await db.collection('adminTokenlari').doc(uid).get();
    const liste = t.exists && Array.isArray(t.data()?.tokenlar) ? t.data().tokenlar : [];
    for (const token of liste) tokenlar.push({ uid, token });
  }
  return tokenlar;
}

async function yoneticilereBildir(haricUid, baslik, mesaj, tur, ekYetki) {
  try {
    const hedefler = await tamYetkiliTokenlari(haricUid, ekYetki);
    if (hedefler.length === 0) return;
    const yanit = await getMessaging().sendEachForMulticast({
      tokens: hedefler.map((h) => h.token),
      notification: { title: baslik, body: mesaj },
      data: { tur, title: String(baslik || ''), body: String(mesaj || '') },
      android: {
        priority: 'high',
        notification: { channelId: 'yalova_wonder_kids', sound: 'default' },
      },
    });
    // Geçersiz token'ları temizle.
    const silinecek = {};
    yanit.responses.forEach((r, i) => {
      const kod = r.error?.code || '';
      if (
        !r.success &&
        (kod.includes('registration-token-not-registered') ||
          kod.includes('invalid-registration-token'))
      ) {
        const h = hedefler[i];
        (silinecek[h.uid] = silinecek[h.uid] || []).push(h.token);
      }
    });
    for (const uid of Object.keys(silinecek)) {
      await db.collection('adminTokenlari').doc(uid).update({
        tokenlar: FieldValue.arrayRemove(...silinecek[uid]),
      }).catch(() => {});
    }
  } catch (error) {
    console.error('Yönetici bildirimi gönderilemedi:', error);
  }
}

exports.yoneticiGiris = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 30,
    memory: '256MiB',
  },
  async (request) => {
    const email = String(request.data?.email || '').trim().toLowerCase();
    const sifre = String(request.data?.sifre || '');
    if (!email || !sifre || email.length > 120 || sifre.length > 200) {
      throw new HttpsError('invalid-argument', 'E-posta ve şifre gerekli.');
    }

    const genelHata = () =>
      new HttpsError('unauthenticated', 'E-posta veya şifre hatalı.');

    const auth = getAuth();
    let kullanici = null;
    try {
      kullanici = await auth.getUserByEmail(email);
    } catch (_) {
      kullanici = null;
    }
    if (!kullanici) throw genelHata();

    const adminRef = db.collection('adminler').doc(kullanici.uid);
    const adminSnap = await adminRef.get();
    const admin = adminSnap.exists ? adminSnap.data() : null;
    // Yönetici olmayan hesaplarda bilgi sızdırmamak için aynı hata.
    if (!admin) throw genelHata();

    if (kullanici.disabled || admin.kilitli === true) {
      throw new HttpsError(
        'permission-denied',
        'Hesap güvenlik nedeniyle kilitlendi. Yeni şifre bağlantısı için yöneticiyle iletişime geç.',
      );
    }
    if (admin.aktif !== true) {
      throw new HttpsError(
        'permission-denied',
        'Bu hesap için yönetici yetkisi tanımlı değil.',
      );
    }

    const denemeRef = db.collection('adminGirisDenemeleri').doc(kullanici.uid);

    let yanit;
    try {
      yanit = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${WEB_API_KEY.value()}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email, password: sifre, returnSecureToken: false }),
        },
      );
    } catch (error) {
      console.error('Şifre doğrulama isteği başarısız:', error);
      throw new HttpsError('unavailable', 'Giriş şu an doğrulanamıyor, tekrar dene.');
    }

    if (!yanit.ok) {
      const govde = await yanit.json().catch(() => ({}));
      const kod = String(govde?.error?.message || '');
      if (
        kod.startsWith('INVALID_PASSWORD') ||
        kod.startsWith('INVALID_LOGIN_CREDENTIALS') ||
        kod.startsWith('EMAIL_NOT_FOUND')
      ) {
        await denemeRef.set(
          { sayac: FieldValue.increment(1), son: FieldValue.serverTimestamp() },
          { merge: true },
        );
        const guncel = await denemeRef.get();
        const sayac = Number(guncel.data()?.sayac || 1);
        if (sayac >= MAKS_YANLIS_SIFRE) {
          await auth.updateUser(kullanici.uid, { disabled: true });
          await adminRef.update({
            kilitli: true,
            aktif: false,
            kilitTarihi: FieldValue.serverTimestamp(),
          });
          try {
            await auth.revokeRefreshTokens(kullanici.uid);
          } catch (_) {}
          await yoneticilereBildir(
            kullanici.uid,
            'Yönetici hesabı kilitlendi',
            `${admin.ad || email} hesabı ${MAKS_YANLIS_SIFRE} kez yanlış şifre nedeniyle kilitlendi.`,
            'yonetici_kilit',
          );
          throw new HttpsError(
            'permission-denied',
            `Şifre ${MAKS_YANLIS_SIFRE} kez yanlış girildi, hesap kilitlendi. Yeni şifre bağlantısı için yöneticiyle iletişime geç.`,
          );
        }
        throw new HttpsError(
          'unauthenticated',
          `Şifre hatalı. Kalan deneme hakkı: ${MAKS_YANLIS_SIFRE - sayac}`,
        );
      }
      if (kod.startsWith('TOO_MANY_ATTEMPTS')) {
        throw new HttpsError('resource-exhausted', 'Çok fazla deneme. Bir süre sonra tekrar dene.');
      }
      console.error('Beklenmeyen giriş doğrulama yanıtı:', kod);
      throw new HttpsError('internal', 'Giriş doğrulanamadı.');
    }

    // Başarılı giriş: sayacı sıfırla, kayıt tut, bildirim gönder, oturum anahtarı ver.
    await denemeRef.delete().catch(() => {});
    await db.collection('yoneticiGirisKayitlari').add({
      uid: kullanici.uid,
      email,
      zaman: FieldValue.serverTimestamp(),
    }).catch(() => {});
    await yoneticilereBildir(
      kullanici.uid,
      'Yönetici girişi',
      `${admin.ad || email} yönetim paneline giriş yaptı.`,
      'yonetici_giris',
    );

    let customToken;
    try {
      customToken = await auth.createCustomToken(kullanici.uid);
    } catch (error) {
      console.error('Oturum anahtarı üretilemedi:', error);
      const metin = String(error?.message || error);
      if (/signBlob|iam\.serviceAccounts|Token Creator|permission/i.test(metin)) {
        throw new HttpsError(
          'failed-precondition',
          'Sunucuda "Service Account Token Creator" yetkisi eksik. Yetki verilip tekrar denenmeli.',
        );
      }
      throw new HttpsError('internal', 'Oturum anahtarı üretilemedi. Sunucu günlüğüne bak.');
    }
    return { customToken };
  },
);

// Hoca girişi: yönetici hocaya 4 haneli bir numara verir. Hoca ilk girişte
// kendi şifresini belirler; sonraki girişlerde numara + şifre kullanılır.
// Şifre yalnızca hocaSifreleri/{numara} belgesinde (scrypt özeti) tutulur;
// bu koleksiyona istemci erişemez. Özel claim: hoca, kod, takimId.
const HOCA_MAKS_YANLIS = 3;

function hocaSifreOzeti(sifre, tuz) {
  return crypto.scryptSync(sifre, tuz, 32).toString('hex');
}

// Hocanın takım/lig listesi. Eski kayıtlarda tek takım alanları kullanılır.
function hocaTakimlari(hoca) {
  const liste = [];
  const gorulen = new Set();
  const ekle = (t) => {
    const takim = String(t?.takim || '').slice(0, 100);
    const takimId = String(t?.takimId || '').slice(0, 100);
    const ligUrl = String(t?.ligUrl || '').slice(0, 500);
    const ligAd = String(t?.ligAd || '').slice(0, 150);
    if (!takimId || !ligUrl) return;
    const anahtar = `${takimId}|${ligUrl}`;
    if (gorulen.has(anahtar)) return;
    gorulen.add(anahtar);
    liste.push({ takim, takimId, ligUrl, ligAd });
  };
  if (Array.isArray(hoca?.takimlar)) hoca.takimlar.slice(0, 12).forEach(ekle);
  if (liste.length === 0) ekle(hoca);
  return liste;
}

exports.hocaGiris = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 30,
    memory: '256MiB',
  },
  async (request) => {
    const kod = String(request.data?.kod || '')
      .toLowerCase()
      .replace(/[^a-z0-9]/g, '');
    const sifre = String(request.data?.sifre || '');
    const yeniSifre = String(request.data?.yeniSifre || '');
    if (kod.length < 4 || kod.length > 60) {
      throw new HttpsError('invalid-argument', 'Numara geçersiz.');
    }
    if (sifre.length > 100 || yeniSifre.length > 100) {
      throw new HttpsError('invalid-argument', 'Şifre çok uzun.');
    }

    // IP başına 15 dakikada en fazla 8 başarısız deneme.
    const ip = String(request.rawRequest?.ip || 'bilinmiyor');
    const ipId = crypto.createHash('sha256').update(ip).digest('hex').slice(0, 32);
    const denemeRef = db.collection('hocaGirisDenemeleri').doc(ipId);
    const simdi = Date.now();
    const pencere = 15 * 60 * 1000;
    const onceki = (await denemeRef.get()).data() || {};
    const pencereAcik = onceki.baslangic && simdi - onceki.baslangic < pencere;
    const sayac = pencereAcik ? Number(onceki.sayac || 0) : 0;
    const baslangic = pencereAcik ? onceki.baslangic : simdi;
    if (sayac >= 8) {
      throw new HttpsError(
        'resource-exhausted',
        'Çok fazla yanlış deneme yapıldı. 15 dakika sonra tekrar dene.',
      );
    }
    const basarisiz = async (mesaj) => {
      await denemeRef.set({ sayac: sayac + 1, baslangic });
      throw new HttpsError('unauthenticated', mesaj);
    };

    const hocaSnap = await db.collection('hocalar').doc(kod).get();
    const hoca = hocaSnap.exists ? hocaSnap.data() : null;
    if (!hoca || hoca.aktif !== true) {
      return basarisiz('Numara hatalı. Yöneticiden numaranı tekrar iste.');
    }

    const sifreRef = db.collection('hocaSifreleri').doc(kod);
    const kayit = (await sifreRef.get()).data() || null;

    if (!kayit || !kayit.hash) {
      // İlk giriş: şifre henüz belirlenmemiş.
      if (!yeniSifre) {
        return { durum: 'sifre_olustur', takim: String(hoca.takim || '') };
      }
      if (yeniSifre.length < 6) {
        throw new HttpsError('invalid-argument', 'Şifre en az 6 karakter olmalı.');
      }
      const tuz = crypto.randomBytes(16).toString('hex');
      await sifreRef.set({
        tuz,
        hash: hocaSifreOzeti(yeniSifre, tuz),
        yanlis: 0,
        olusturma: FieldValue.serverTimestamp(),
      });
      await db.collection('hocalar').doc(kod).update({ sifreVar: true }).catch(() => {});
    } else {
      if (kayit.kilitli === true) {
        throw new HttpsError(
          'permission-denied',
          'Çok fazla yanlış şifre girildi, hesap kilitlendi. Yöneticiden şifreni sıfırlamasını iste.',
        );
      }
      if (!sifre) {
        throw new HttpsError('invalid-argument', 'Şifreni yaz.');
      }
      const beklenen = Buffer.from(String(kayit.hash), 'hex');
      const gelen = Buffer.from(hocaSifreOzeti(sifre, String(kayit.tuz || '')), 'hex');
      const dogru = beklenen.length === gelen.length && crypto.timingSafeEqual(beklenen, gelen);
      if (!dogru) {
        const yanlis = Number(kayit.yanlis || 0) + 1;
        const kilitle = yanlis >= HOCA_MAKS_YANLIS;
        await sifreRef.update({ yanlis, kilitli: kilitle });
        await denemeRef.set({ sayac: sayac + 1, baslangic });
        throw new HttpsError(
          'unauthenticated',
          kilitle
            ? 'Çok fazla yanlış şifre girildi, hesap kilitlendi. Yöneticiden şifreni sıfırlamasını iste.'
            : `Şifre hatalı. Kalan deneme hakkı: ${HOCA_MAKS_YANLIS - yanlis}`,
        );
      }
      if (Number(kayit.yanlis || 0) > 0) {
        await sifreRef.update({ yanlis: 0 }).catch(() => {});
      }
    }

    await denemeRef.delete().catch(() => {});

    // Hoca birden fazla ligde (U12, U14, Süper Amatör...) olabilir.
    const takimlar = hocaTakimlari(hoca);

    // İstatistik: giriş sayısı ve son giriş zamanı.
    await db.collection('hocalar').doc(kod).update({
      girisSayisi: FieldValue.increment(1),
      sonGiris: FieldValue.serverTimestamp(),
    }).catch(() => {});

    let customToken;
    try {
      customToken = await getAuth().createCustomToken(`hoca_${kod}`, {
        hoca: true,
        kod,
        takimId: String(hoca.takimId || ''),
        takimIds: Array.from(new Set(takimlar.map((t) => t.takimId))),
      });
    } catch (error) {
      console.error('Hoca oturum anahtarı üretilemedi:', error);
      throw new HttpsError('internal', 'Giriş yapılamadı. Biraz sonra tekrar dene.');
    }
    return {
      durum: 'tamam',
      customToken,
      takim: String(hoca.takim || ''),
      takimId: String(hoca.takimId || ''),
      ligUrl: String(hoca.ligUrl || ''),
      ad: String(hoca.ad || ''),
      takimlar,
    };
  },
);

// Yönetici, hocanın şifresini sıfırlar; hoca bir sonraki girişte yenisini belirler.
exports.hocaSifreSifirla = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 30,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Giriş yapmalısın.');
    const adminSnap = await db.collection('adminler').doc(uid).get();
    const admin = adminSnap.exists ? adminSnap.data() : null;
    if (!admin || admin.aktif !== true) {
      throw new HttpsError('permission-denied', 'Yönetici değilsin.');
    }
    const yetki = yetkiBilgisi(admin);
    if (!yetki.tam && !yetki.liste.includes('takim')) {
      throw new HttpsError('permission-denied', 'Bu işlem için yetkin yok.');
    }
    const kod = String(request.data?.kod || '')
      .toLowerCase()
      .replace(/[^a-z0-9]/g, '');
    if (kod.length < 4) throw new HttpsError('invalid-argument', 'Numara geçersiz.');

    await db.collection('hocaSifreleri').doc(kod).delete().catch(() => {});
    await db.collection('hocalar').doc(kod).update({ sifreVar: false }).catch(() => {});
    try {
      await getAuth().revokeRefreshTokens(`hoca_${kod}`);
    } catch (_) {}
    return { tamam: true };
  },
);

// Yöneticinin cihaz bildirim anahtarını (FCM token) sunucuya kaydeder.
exports.yoneticiTokenKaydet = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 30,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Giriş yapmalısın.');
    const adminSnap = await db.collection('adminler').doc(uid).get();
    if (!adminSnap.exists || adminSnap.data()?.aktif !== true) {
      throw new HttpsError('permission-denied', 'Yönetici değilsin.');
    }
    const token = String(request.data?.token || '');
    if (token.length < 50 || token.length > 400) {
      throw new HttpsError('invalid-argument', 'Geçersiz token.');
    }
    const ref = db.collection('adminTokenlari').doc(uid);
    const mevcut = await ref.get();
    const liste = mevcut.exists && Array.isArray(mevcut.data()?.tokenlar)
      ? mevcut.data().tokenlar.filter((t) => t !== token)
      : [];
    liste.push(token);
    await ref.set({ tokenlar: liste.slice(-5), guncelleme: FieldValue.serverTimestamp() });
    return { tamam: true };
  },
);


// ============================================================
// FAVORİ TAKIM MAÇ HATIRLATMA
// ============================================================
// Uygulama, favori takım seçilince FCM konusuna abone olur: fav_<takimId>.
// Takım kimliği istemcideki _takimFirestoreId ile aynı kuralla üretilir.
// ============================================================
// FAVORİ TAKIMA GÖRE LİG BİLDİRİMİ
// ============================================================
// Lig bildirimleri yalnızca o ligde/grupta favori takımı olan ve uygulamada
// "Ligler" bildirimleri açık olan kullanıcılara gider:
//   'ligler' in topics && ('fav_a' in topics || 'fav_b' in topics ...)
// FCM koşulu en fazla 5 konu alır; bu yüzden takımlar 4'erli gönderilir.
// Başlık ve metni data alanına da koyar: uygulama arka planda/kapalıyken
// gelen bildirimi "Bildirimler" geçmişine bu alanlardan kaydeder.
function bildirimVerisiEkle(mesaj) {
  const n = mesaj?.notification || {};
  return {
    ...mesaj,
    data: {
      ...(mesaj?.data || {}),
      title: String(n.title || ''),
      body: String(n.body || ''),
    },
  };
}

async function favoriTakimlaraGonder(takimAdlari, mesaj) {
  const idler = [...new Set(
    (takimAdlari || []).map((t) => takimKonuKimligi(t)).filter((id) => id.length > 0),
  )];
  const mesajIdleri = [];
  let sonHata = null;
  for (let i = 0; i < idler.length; i += 4) {
    const parca = idler.slice(i, i + 4);
    const kosul = `'ligler' in topics && (${parca.map((id) => `'fav_${id}' in topics`).join(' || ')})`;
    try {
      mesajIdleri.push(await getMessaging().send({ ...bildirimVerisiEkle(mesaj), condition: kosul }));
    } catch (error) {
      sonHata = error;
      console.error('Favori takım bildirimi gönderilemedi:', parca.join(','), error);
    }
  }
  if (mesajIdleri.length === 0 && sonHata) throw sonHata;
  return mesajIdleri;
}

function takimKonuKimligi(ad) {
  return String(ad || '')
    .toLowerCase()
    .replace(/ı/g, 'i')
    .replace(/ş/g, 's')
    .replace(/ğ/g, 'g')
    .replace(/ü/g, 'u')
    .replace(/ö/g, 'o')
    .replace(/ç/g, 'c')
    .replace(/[^a-z0-9]/g, '');
}

exports.macHatirlatma = onSchedule(
  {
    schedule: 'every 30 minutes',
    timeZone: 'Europe/Istanbul',
    region: 'europe-west1',
    timeoutSeconds: 120,
    memory: '256MiB',
  },
  async () => {
    try {
      const ayar = await db.collection('ayarlar').doc('bildirim').get();
      if (ayar.exists && ayar.data()?.hatirlatmaKapali === true) return;

      const snap = await db.collection('haftalikProgram').doc('guncel').get();
      const maclar = snap.exists && Array.isArray(snap.data()?.maclar)
        ? snap.data().maclar
        : [];
      const simdi = Date.now();
      const alt = simdi + 105 * 60 * 1000;
      const ust = simdi + 135 * 60 * 1000;

      for (const mac of maclar) {
        const ms = Number(mac.tarihMs);
        if (!Number.isFinite(ms) || ms < alt || ms >= ust) continue;

        const ev = String(mac.evSahibi || '').trim();
        const dep = String(mac.deplasman || '').trim();
        if (!ev || !dep) continue;

        const macKimlik = `${ms}_${takimKonuKimligi(ev)}_${takimKonuKimligi(dep)}`
          .slice(0, 200);
        const kayit = db.collection('hatirlatmaKayitlari').doc(macKimlik);
        try {
          await kayit.create({ gonderim: FieldValue.serverTimestamp() });
        } catch (_) {
          continue; // Bu maç için hatırlatma zaten gönderilmiş.
        }

        const saat = String(mac.tarihSaat || '').split(' ')[1] || '';
        const gonderilecekler = [
          { konu: takimKonuKimligi(ev), rakip: dep },
          { konu: takimKonuKimligi(dep), rakip: ev },
        ];
        for (const g of gonderilecekler) {
          if (!g.konu) continue;
          try {
            await getMessaging().send(bildirimVerisiEkle({
              topic: `fav_${g.konu}`,
              notification: {
                title: 'Maç hatırlatma',
                body: `${ev} - ${dep} maçı yaklaşık 2 saat sonra${saat ? ` (${saat})` : ''} başlıyor.`,
              },
              data: { tur: 'mac_hatirlatma' },
              android: {
                priority: 'high',
                notification: {
                  channelId: 'yalova_wonder_kids',
                  sound: 'default',
                },
              },
            }));
          } catch (error) {
            console.error('Hatırlatma gönderilemedi:', g.konu, error);
          }
        }
      }
    } catch (error) {
      console.error('Maç hatırlatma hatası:', error);
    }
  },
);


// ---------------------------------------------------------------
// MAÇ KADROSU BİLDİRİMİ
// Bir takımın maç kadrosu herkese ilk kez görünür olduğunda, o takımı
// favorilerine ekleyenlere bildirim gider. Üç durum:
//  1) Hoca erken girer: kadro maçtan 1 saat önce açılınca (zamanlayıcı yakalar).
//  2) Hoca 1 saatten az kala girer: kayıt anında (tetikleyici yakalar).
//  3) Hoca maçtan sonra girer: kayıt anında (tetikleyici yakalar).
// Her kadro için bildirim yalnızca BİR kez gider (kadroBildirimleri kaydı);
// kadro sonradan değiştirilirse tekrar bildirim gitmez.
// Kapatmak için ayarlar/bildirim belgesine kadroBildirimiKapali: true yazılır.
// ---------------------------------------------------------------
async function kadroBildirimiGonder(kadroId, veri) {
  try {
    const ayar = await db.collection('ayarlar').doc('bildirim').get();
    if (ayar.exists && ayar.data()?.kadroBildirimiKapali === true) return;

    const takim = String(veri?.takim || '').trim();
    const rakip = String(veri?.rakip || '').trim();
    const konu = takimKonuKimligi(takim);
    if (!takim || !konu) return;

    // Maçtan 3 saat sonra girilen kadrolar (ör. yöneticinin geçmiş maça
    // sonradan girdiği kadro) için bildirim gönderme.
    const macZamani = veri?.macZamani?.toMillis ? veri.macZamani.toMillis() : null;
    if (macZamani !== null && macZamani < Date.now() - 3 * 60 * 60 * 1000) return;

    const kayit = db.collection('kadroBildirimleri').doc(kadroId);
    try {
      await kayit.create({ gonderim: FieldValue.serverTimestamp() });
    } catch (_) {
      return; // Bu kadro için bildirim zaten gönderilmiş.
    }

    // Belge kimliği: <takımId>__<evId>_<depId>_<hafta>_<ligHash>
    // Ev sahibi / deplasman sırası, bildirime dokununca kadro ekranını açmak için gerekir.
    const sonEk = String(kadroId).split('__')[1] || '';
    const evdeMi = sonEk.startsWith(`${konu}_`);
    const ev = evdeMi ? takim : rakip;
    const dep = evdeMi ? rakip : takim;

    await getMessaging().send(bildirimVerisiEkle({
      topic: `fav_${konu}`,
      notification: {
        title: '📋 Maç kadrosu açıklandı',
        body: rakip
          ? `${takim} - ${rakip} maçının kadrosu belli oldu. Görmek için dokun.`
          : `${takim} maç kadrosu belli oldu.`,
      },
      data: {
        tur: 'mac_kadrosu',
        ligUrl: String(veri?.ligUrl || ''),
        hafta: String(veri?.hafta || ''),
        ev: String(ev || ''),
        dep: String(dep || ''),
      },
      android: {
        priority: 'high',
        notification: {
          channelId: 'yalova_wonder_kids',
          sound: 'default',
        },
      },
    }));
  } catch (error) {
    console.error('Kadro bildirimi gönderilemedi:', kadroId, error);
  }
}

// Hoca kadroyu kaydedince: kadro zaten görünür durumdaysa hemen bildir.
// Yeni oyuncu başvurusu gelince başvuru yetkisi olan yöneticilere bildirim.
exports.yeniOyuncuBasvurusu = onDocumentCreated(
  {
    document: 'oyuncuBasvurulari/{basvuruId}',
    region: 'europe-west1',
  },
  async (event) => {
    const v = event.data?.data() || {};
    const ad = String(v.adSoyad || 'Yeni oyuncu').slice(0, 60);
    const takim = String(v.takim || '').slice(0, 60);
    await yoneticilereBildir(
      '',
      'Yeni oyuncu başvurusu',
      takim ? `${ad} (${takim}) onayını bekliyor.` : `${ad} onayını bekliyor.`,
      'yeni_basvuru',
      'basvuru',
    );
  },
);

// ============================================================
// CANLI SKOR BİLDİRİMİ
// ============================================================

// Bir ligin/grubun takım adları: önce sunucunun kaydettiği puan durumu,
// yoksa fikstür kayıtları. Örnek başına 30 dk önbellek.
const grupTakimlariOnbellek = new Map();
async function grupTakimlari(ligUrl) {
  const url = String(ligUrl || '').trim();
  if (!url) return [];
  const kayit = grupTakimlariOnbellek.get(url);
  if (kayit && Date.now() - kayit.zaman < 30 * 60 * 1000) return kayit.takimlar;

  const adlar = new Set();
  try {
    const puan = await db.collection('yerelLigPuanlari').where('kaynak', '==', url).limit(1).get();
    for (const d of puan.docs) {
      for (const t of (d.data()?.takimlar || [])) {
        if (t?.takim) adlar.add(String(t.takim));
      }
    }
    if (adlar.size === 0) {
      const fikstur = await db.collection(ASKF_FIKSTUR_KOLEKSIYONU).where('kaynak', '==', url).limit(300).get();
      for (const d of fikstur.docs) {
        const v = d.data() || {};
        if (v.evSahibi) adlar.add(String(v.evSahibi));
        if (v.deplasman) adlar.add(String(v.deplasman));
      }
    }
  } catch (error) {
    console.error('Grup takımları okunamadı:', url, error);
  }
  const takimlar = [...adlar].filter((a) => !/^bay$/i.test(a.trim()));
  grupTakimlariOnbellek.set(url, { zaman: Date.now(), takimlar });
  return takimlar;
}
// canliMaclar/{macId} değişince (hoca veya yönetici skor girdiğinde)
// iki takımı favorileyenlere (fav_<takım> konuları) bildirim gönderir.
// Kapatmak için: Yönetim Paneli > Otomatik Bildirimler > Canlı skor.
exports.canliMacBildirimi = onDocumentWritten(
  {
    document: 'canliMaclar/{macId}',
    region: 'europe-west1',
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  async (event) => {
    const once = event.data?.before?.exists ? (event.data.before.data() || {}) : {};
    const sonra = event.data?.after?.exists ? (event.data.after.data() || {}) : null;
    if (!sonra) return;

    // Aynı olay iki kez işlenmesin.
    if (Number(sonra.olayNo || 0) <= Number(once.olayNo || 0)) return;

    const ayar = await bildirimAyarlariniOku();
    if (ayar.canliAktif === false) return;

    const olay = sonra.sonOlay || {};
    const ev = String(sonra.ev || '').trim();
    const dep = String(sonra.dep || '').trim();
    const evId = takimKonuKimligi(ev);
    const depId = takimKonuKimligi(dep);
    if (!evId || !depId) return;

    const skor = `${ev} ${Number(sonra.evSkor || 0)}-${Number(sonra.depSkor || 0)} ${dep}`;
    const lig = String(sonra.lig || '').trim();
    let baslik = '';
    let govde = '';

    if (olay.tur === 'gol') {
      const atan = olay.t === 'ev' ? ev : dep;
      const oyuncu = String(olay.o || '').trim();
      const dakika = String(olay.d || '').trim();
      baslik = `⚽ GOL! ${atan}`;
      govde = `${skor}${oyuncu ? ` • ${oyuncu}` : ''}${dakika ? ` ${dakika}'` : ''}`;
    } else if (olay.tur === 'geri') {
      baslik = 'Skor düzeltildi';
      govde = skor;
    } else if (olay.tur === 'durum') {
      const oncekiDurum = String(once.durum || 'baslamadi');
      const durum = String(olay.durum || sonra.durum || '');
      if (durum === 'ilk_yari' && oncekiDurum === 'baslamadi') {
        baslik = '🟢 Maç başladı';
        govde = `${ev} - ${dep}`;
      } else if (durum === 'devre') {
        baslik = '⏸️ Devre arası';
        govde = skor;
      } else if (durum === 'ikinci_yari' && oncekiDurum === 'devre') {
        baslik = '▶️ İkinci yarı başladı';
        govde = skor;
      } else if (durum === 'bitti') {
        baslik = '🏁 Maç sonucu';
        govde = skor;
      }
    }
    if (!baslik) return;
    if (lig) govde = `${govde} (${lig})`;

    // Alıcılar: iki takımı ve aynı ligde/grupta bir takımı favorileyenler.
    // Diğer gruplardaki kullanıcılar canlı skoru yalnızca uygulamada görür.
    const grup = await grupTakimlari(sonra.ligUrl);
    const idler = [...new Set(
      [ev, dep, ...grup].map((a) => takimKonuKimligi(a)).filter((id) => id.length > 0),
    )];
    const mesaj = bildirimVerisiEkle({
      notification: { title: baslik.slice(0, 80), body: govde.slice(0, 200) },
      data: {
        tur: 'canli_skor',
        macId: String(event.params.macId),
        ev,
        dep,
      },
      android: { priority: 'high' },
      apns: { headers: { 'apns-priority': '10' } },
    });
    // FCM koşulu en fazla 5 konu alır.
    for (let i = 0; i < idler.length; i += 5) {
      const parca = idler.slice(i, i + 5);
      try {
        await getMessaging().send({
          ...mesaj,
          condition: parca.map((id) => `'fav_${id}' in topics`).join(' || '),
        });
      } catch (error) {
        console.error('Canlı skor bildirimi gönderilemedi:', event.params.macId, parca.join(','), error);
      }
    }
  },
);


exports.macKadrosuKaydedildi = onDocumentWritten(
  {
    document: 'macKadrolari/{kadroId}',
    region: 'europe-west1',
  },
  async (event) => {
    const sonra = event.data?.after;
    if (!sonra || !sonra.exists) return;
    const veri = sonra.data() || {};
    const gorunur = veri.gorunurDan?.toMillis ? veri.gorunurDan.toMillis() : null;
    if (gorunur === null || gorunur > Date.now()) return; // Henüz görünür değil.
    await kadroBildirimiGonder(event.params.kadroId, veri);
  },
);

// Önceden girilmiş kadrolar görünür olduğunda (maçtan 1 saat önce) bildir.
exports.macKadrosuAcildi = onSchedule(
  {
    schedule: 'every 5 minutes',
    timeZone: 'Europe/Istanbul',
    region: 'europe-west1',
    timeoutSeconds: 120,
    memory: '256MiB',
  },
  async () => {
    try {
      const simdi = Date.now();
      const snap = await db.collection('macKadrolari')
        .where('gorunurDan', '>', Timestamp.fromMillis(simdi - 20 * 60 * 1000))
        .where('gorunurDan', '<=', Timestamp.fromMillis(simdi))
        .get();
      for (const doc of snap.docs) {
        await kadroBildirimiGonder(doc.id, doc.data());
      }
    } catch (error) {
      console.error('Kadro açılış kontrolü hatası:', error);
    }
  },
);


exports.askfYerelLigKontrol =
  onSchedule(
    {
      schedule:
        'every 3 hours',

      timeZone:
        'Europe/Istanbul',

      region:
        'europe-west1',

      timeoutSeconds:
        240,

      memory:
        '512MiB',
    },

    async () => {

      console.log(
        'ASKF Yalova yerel lig kontrolü başladı.',
      );

      const sonuclar =
        [];

      for (
        const kaynak of
        await askfKaynaklariniYukle()
      ) {
        try {
          const sonuc =
            await askfKaynakKontrolEt(
              kaynak,
            );

          sonuclar.push(
            sonuc,
          );

          await askfOzetYaz(kaynak, sonuc);

        } catch (error) {

          console.error(
            `ASKF kaynak çalıştırma hatası: ${kaynak.id}`,
            error,
          );

          sonuclar.push(
            {
              kaynakId:
                kaynak.id,

              hata:
                true,
            },
          );

          await askfOzetYaz(kaynak, {
            hata: true,
            hataMesaji: String(error?.message || error),
          });
        }
      }

      try {
        const haftalik = await haftalikProgramiGuncelle();
        sonuclar.push({ kaynakId: 'anasayfa_haftalik_program', ...haftalik });
      } catch (error) {
        console.error('Haftalık program güncelleme hatası:', error);
        sonuclar.push({ kaynakId: 'anasayfa_haftalik_program', hata: true });
      }

      console.log(
        'ASKF yerel lig kontrolü tamamlandı.',

        JSON.stringify(
          sonuclar,
        ),
      );
    },
  );


// ============================================================
// 12. TFF GELİŞİM LİGLERİ PUAN DURUMU BİLDİRİMİ
//
// Her 3 saatte bir çalışır.
// İlk kontrolde bildirim göndermez.
// Sonraki kontrollerde gerçek puan durumu değişmişse
// sadece değişen ligin bildirimini gönderir.
// ============================================================

// ============================================================
// ASKF "ŞİMDİ GÜNCELLE" (yönetim panelinden elle tetikleme)
// ============================================================
// data: { kaynakId: 'super_amator_a_2026_2027' }  veya  { kaynakId: 'hepsi' }
// Yetki: "ayar" veya tam yetkili yönetici. Aynı kaynak 2 dakikada bir.
exports.askfSimdiGuncelle = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 300,
    memory: '512MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Giriş yapmalısın.');
    }
    const adminSnap = await db.collection('adminler').doc(uid).get();
    const adminVeri = adminSnap.exists ? adminSnap.data() : null;
    if (!adminVeri || adminVeri.aktif !== true) {
      throw new HttpsError('permission-denied', 'Yönetici değilsin.');
    }
    const yetki = yetkiBilgisi(adminVeri);
    if (!yetki.tam && !yetki.liste.includes('ayar')) {
      throw new HttpsError('permission-denied', 'Bu işlem için "Uygulama ayarları" yetkisi gerekli.');
    }

    const istenen = String(request.data?.kaynakId || '').trim();
    if (!istenen) {
      throw new HttpsError('invalid-argument', 'Kaynak seçilmedi.');
    }

    const tumKaynaklar = await askfKaynaklariniYukle();
    const secilenler = istenen === 'hepsi'
      ? tumKaynaklar
      : tumKaynaklar.filter((k) => k.id === istenen);
    if (secilenler.length === 0) {
      throw new HttpsError('not-found', 'Bu lig güncel listede yok (kapalı olabilir).');
    }

    // Çok sık tetiklemeyi engelle.
    const kilitRef = db.collection('askfOzet').doc('_elleGuncelleme');
    const simdi = Date.now();
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(kilitRef);
      const son = Number(snap.data()?.[istenen] || 0);
      if (simdi - son < 2 * 60 * 1000) {
        throw new HttpsError('resource-exhausted', 'Az önce güncellendi. 2 dakika sonra tekrar dene.');
      }
      tx.set(kilitRef, { [istenen]: simdi }, { merge: true });
    });

    const sonuclar = [];
    for (const kaynak of secilenler) {
      let sonuc;
      try {
        sonuc = await askfKaynakKontrolEt(kaynak);
      } catch (error) {
        sonuc = { kaynakId: kaynak.id, hata: true, hataMesaji: String(error?.message || error) };
      }
      await askfOzetYaz(kaynak, sonuc, true);
      sonuclar.push({
        kaynakId: kaynak.id,
        ad: kaynak.ad,
        basarili: !sonuc?.hata,
        macSayisi: Number(sonuc?.toplamMac || 0),
        hata: sonuc?.hata ? String(sonuc?.hataMesaji || 'Hata') : '',
      });
    }

    if (istenen === 'hepsi') {
      try {
        await haftalikProgramiGuncelle();
      } catch (error) {
        console.error('Haftalık program güncelleme hatası (elle):', error);
      }
    }

    console.log('ASKF elle güncelleme:', uid, JSON.stringify(sonuclar));
    return {
      basarili: sonuclar.filter((s) => s.basarili).length,
      hatali: sonuclar.filter((s) => !s.basarili).length,
      sonuclar,
    };
  },
);


// Gelişim ligleri ve PGL için otomatik puan durumu bildirimi artık
// ayarlar/bildirim.tffAktif ile yönetilir (Yönetim Paneli > Otomatik Bildirimler).
// Kapalıyken veri Firestore'a yazılmaya devam eder, bildirim GİTMEZ.

const TFF_GELISIM_GRUPLARI = [
  {
    id: 'u14-gelisim-5-grup-2026-2027',
    lig: 'U-14 Gelişim Ligi',
    grup: '5. Grup',
    pageId: 1755,
    grupId: 3738,
  },
  {
    id: 'u15-gelisim-5-grup-2026-2027',
    lig: 'U-15 Gelişim Ligi',
    grup: '5. Grup',
    pageId: 1754,
    grupId: 3756,
  },
  {
    id: 'u16-gelisim-6-grup-2026-2027',
    lig: 'U-16 Gelişim Ligi',
    grup: '6. Grup',
    pageId: 1753,
    grupId: 3875,
  },
  {
    id: 'u17-gelisim-6-grup-2026-2027',
    lig: 'U-17 Gelişim Ligi',
    grup: '6. Grup',
    pageId: 1752,
    grupId: 3858,
  },
  {
    id: 'u19-gelisim-6-grup-2026-2027',
    lig: 'U-19 Gelişim Ligi',
    grup: '6. Grup',
    pageId: 1751,
    grupId: 3826,
  },
  {
    id: 'pgl-11-grup-2026-2027',
    lig: 'Profesyonelliğe Geçiş Ligi',
    grup: '11. Grup',
    pageId: 1596,
    grupId: 3948,
  },
];


// ============================================================
// TFF HTML GETİR
// ============================================================

async function tffHtmlGetir(url) {
  const response = await fetch(url, {
    method: 'GET',

    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
        'AppleWebKit/537.36 (KHTML, like Gecko) ' +
        'Chrome/155.0.0.0 Safari/537.36',

      'Referer':
        'https://www.tff.org/',

      'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',

      'Accept-Language':
        'tr-TR,tr;q=0.9,en;q=0.8',

      'Cache-Control':
        'no-cache',

      'Pragma':
        'no-cache',
    },

    signal:
      AbortSignal.timeout(45000),
  });

  if (!response.ok) {
    throw new Error(
      `TFF HTTP ${response.status}`,
    );
  }

  const bytes =
    Buffer.from(
      await response.arrayBuffer(),
    );

  const contentType =
    String(
      response.headers.get(
        'content-type',
      ) || '',
    ).toLowerCase();

  if (
    contentType.includes(
      'windows-1254',
    ) ||
    contentType.includes(
      'cp1254',
    ) ||
    contentType.includes(
      'iso-8859-9',
    )
  ) {
    return new TextDecoder(
      'windows-1254',
    ).decode(bytes);
  }

  return new TextDecoder(
    'utf-8',
  ).decode(bytes);
}


// ============================================================
// TFF PUAN TABLOSU
// ============================================================

function tffPuanDurumunuAyrisla(
  html,
  kaynak,
) {
  const tabloRegex =
    /<table\b[^>]*>[\s\S]*?<\/table>/gi;

  const tablolar =
    html.match(tabloRegex) || [];

  for (const tablo of tablolar) {
    const satirRegex =
      /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;

    const takimlar = [];
    let satirMatch;

    while ((satirMatch = satirRegex.exec(tablo)) !== null) {
      const hucreRegex =
        /<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi;

      const hucreler = [];
      let hucreMatch;

      while ((hucreMatch = hucreRegex.exec(satirMatch[1])) !== null) {
        // Hücreleri boş olsa bile sıralarını koruyarak al.
        hucreler.push(
          htmlMetniniTemizle(hucreMatch[1])
            .replace(/\s+/g, ' ')
            .trim(),
        );
      }

      if (hucreler.length < 8) {
        continue;
      }

      let sira = null;
      let takimIndex = 0;
      let takim = '';
      const ilkHucre = String(hucreler[0] || '').trim();

      // Bazı TFF tablolarında sıra ve takım adı aynı hücrede,
      // bazılarında sıra ayrı hücrede bulunuyor.
      const siraVeTakim = ilkHucre.match(/^\s*(\d{1,2})\s*[.)-]?\s+(.+)$/);
      const yalnizSira = ilkHucre.match(/^\s*(\d{1,2})\s*[.)-]?\s*$/);

      if (siraVeTakim && siraVeTakim[2].trim().length >= 3) {
        sira = Number(siraVeTakim[1]);
        takim = siraVeTakim[2].trim();
        takimIndex = 0;
      } else if (yalnizSira && hucreler.length >= 9) {
        sira = Number(yalnizSira[1]);
        takimIndex = 1;
        takim = String(hucreler[takimIndex] || '').trim();
      } else {
        takim = ilkHucre;
        takimIndex = 0;
      }

      const normalizeTakim = normalizeText(takim);
      if (
        !takim ||
        takim.length < 3 ||
        /^(takim|takim adi|kulup|kulup adi|oynanan|galibiyet|beraberlik|maglubiyet|puan|o g b m a y av p)$/i.test(normalizeTakim) ||
        normalizeTakim.includes('toplam') ||
        normalizeTakim.includes('devre') ||
        normalizeTakim.includes('puan cetveli')
      ) {
        continue;
      }

      const sayilar = [];
      for (let j = takimIndex + 1; j < hucreler.length; j++) {
        const ham = String(hucreler[j] || '').trim();
        if (!ham) {
          continue;
        }

        const temizSayi = ham.replace(/\s+/g, '').replace(/,/g, '.');
        if (!/^-?\d+$/.test(temizSayi)) {
          // Takım adı veya tablo başlığı gibi metinleri istatistik sayma.
          continue;
        }
        sayilar.push(Number(temizSayi));
      }

      if (sayilar.length < 8) {
        continue;
      }

      takimlar.push({
        sira: sira || takimlar.length + 1,
        takim,
        oynanan: sayilar[0],
        galibiyet: sayilar[1],
        beraberlik: sayilar[2],
        maglubiyet: sayilar[3],
        atilanGol: sayilar[4],
        yenilenGol: sayilar[5],
        averaj: sayilar[6],
        puan: sayilar[7],
      });
    }

    if (takimlar.length >= 2) {
      takimlar.sort((a, b) => a.sira - b.sira);
      return takimlar;
    }
  }

  return [];
}

// ============================================================
// TEK TFF GELİŞİM LİGİNİ KONTROL ET
// ============================================================

async function
tffGelisimGrubunuKontrolEt(
  kaynak,
) {
  const url =
    `https://www.tff.org/Default.aspx?grupID=${kaynak.grupId}` +
    `&hafta=1&pageID=${kaynak.pageId}`;

  const html =
    await tffHtmlGetir(
      url,
    );

  if (
    !/<html\b|<table\b/i.test(
      html,
    ) ||
    html.length < 500
  ) {
    throw new Error(
      'TFF geçerli bir lig sayfası döndürmedi.',
    );
  }

  const takimlar =
    tffPuanDurumunuAyrisla(
      html,
      kaynak,
    );

  if (
    !Array.isArray(takimlar) ||
    takimlar.length < 2
  ) {
    console.log(
      `TFF puan cetveli henüz okunabilir değil: ${kaynak.lig} ${kaynak.grup}`,
    );

    return {
      kaynakId:
        kaynak.id,

      atlandi:
        true,

      neden:
        'puan_tablosu_henuz_yok_veya_cozumlenemedi',
    };
  }

  const hash =
    hashOlustur(
      JSON.stringify(
        takimlar.map(
          (takim) => ({
            sira:
              Number(
                takim.sira || 0,
              ),

            takim:
              String(
                takim.takim || '',
              ),

            oynanan:
              Number(
                takim.oynanan || 0,
              ),

            galibiyet:
              Number(
                takim.galibiyet || 0,
              ),

            beraberlik:
              Number(
                takim.beraberlik || 0,
              ),

            maglubiyet:
              Number(
                takim.maglubiyet || 0,
              ),

            atilanGol:
              Number(
                takim.atilanGol || 0,
              ),

            yenilenGol:
              Number(
                takim.yenilenGol || 0,
              ),

            averaj:
              Number(
                takim.averaj || 0,
              ),

            puan:
              Number(
                takim.puan || 0,
              ),
          }),
        ),
      ),
    );

  const ref =
    db
      .collection(
        'tff_gelisim_puan_durumlari',
      )
      .doc(
        kaynak.id,
      );

  const oldSnap =
    await ref.get();

  const old =
    oldSnap.exists
      ? (
          oldSnap.data() || {}
        )
      : {};

  const oncekiHash =
    String(
      old.puanDurumuHash || '',
    );

  const degisti =
    Boolean(
      oncekiHash,
    ) &&
    oncekiHash !== hash;

  await ref.set(
    {
      sezon:
        '2026-2027',

      lig:
        kaynak.lig,

      grup:
        kaynak.grup,

      pageId:
        kaynak.pageId,

      grupId:
        kaynak.grupId,

      kaynakUrl:
        url,

      takimlar,

      puanDurumuHash:
        hash,

      sonKontrol:
        FieldValue.serverTimestamp(),

      otomatikKontrol:
        true,
    },
    {
      merge: true,
    },
  );

  let bildirimGonderildi =
    false;

  if (
    degisti &&
    await tffBildirimleriAcikMi()
  ) {
    const baslik =
      `🏆 ${kaynak.lig}'nde Puan Durumu Değişti!`;

    const mesaj =
      `${kaynak.grup} puan durumu güncellendi. ` +
      'Güncel sıralamayı Yalova Wonder Kids uygulamasından inceleyebilirsiniz.';

    try {
      const mesajIdleri =
        await favoriTakimlaraGonder(
          (takimlar || []).map((t) => t?.takim || t?.ad || t?.takimAdi || ''),
          {
            notification: {
              title:
                baslik,

              body:
                mesaj,
            },

            data: {
              tur:
                'tff_gelisim_puan_durumu',

              kaynakId:
                kaynak.id,

              lig:
                kaynak.lig,

              grup:
                kaynak.grup,

              ligTuru:
                'gelisim',
            },

            android: {
              priority:
                'high',

              notification: {
                channelId:
                  'yalova_wonder_kids',

                sound:
                  'default',
              },
            },
          });

      await ref.set(
        {
          sonBildirimTarihi:
            FieldValue.serverTimestamp(),

          sonBildirimMessageId:
            mesajIdleri.join(',').slice(0, 500),

          sonBildirimDurumu:
            'gonderildi',
        },
        {
          merge: true,
        },
      );

      bildirimGonderildi =
        true;

      console.log(
        `TFF bildirim gönderildi: ${kaynak.lig} ${kaynak.grup}`,
      );

    } catch (error) {
      console.error(
        `TFF puan durumu bildirimi gönderilemedi: ${kaynak.id}`,
        error,
      );

      await ref.set(
        {
          sonBildirimDurumu:
            'hata',

          sonBildirimHatasi:
            String(
              error?.message ||
              error,
            ).slice(
              0,
              500,
            ),
        },
        {
          merge: true,
        },
      );
    }
  }

  return {
    kaynakId:
      kaynak.id,

    lig:
      kaynak.lig,

    grup:
      kaynak.grup,

    takimSayisi:
      takimlar.length,

    degisti,

    bildirimGonderildi,
  };
}


// ============================================================
// TFF GELİŞİM LİGLERİ OTOMATİK KONTROL
//
// HER 6 SAATTE BİR
// ============================================================

exports.tffGelisimPuanKontrol =
  onSchedule(
    {
      schedule:
        'every 6 hours',

      timeZone:
        'Europe/Istanbul',

      region:
        'europe-west1',

      timeoutSeconds:
        300,

      memory:
        '256MiB',
    },

    async () => {
      console.log(
        'TFF Gelişim Ligleri puan durumu kontrolü başladı.',
      );

      const sonuclar =
        [];

      for (
        const kaynak
        of TFF_GELISIM_GRUPLARI
      ) {
        try {
          const sonuc =
            await tffGelisimGrubunuKontrolEt(
              kaynak,
            );

          sonuclar.push(
            sonuc,
          );

        } catch (error) {
          console.error(
            `TFF Gelişim kontrol hatası: ${kaynak.id}`,
            error,
          );

          sonuclar.push({
            kaynakId:
              kaynak.id,

            hata:
              true,
          });
        }
      }

      console.log(
        'TFF Gelişim Ligleri puan durumu kontrolü tamamlandı.',
        JSON.stringify(
          sonuclar,
        ),
      );
    },
  );


// ============================================================
// DOSYA SONU
// ============================================================