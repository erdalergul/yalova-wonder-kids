const {
  onDocumentCreated,
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
} = require('firebase-admin/firestore');

const {
  getMessaging,
} = require('firebase-admin/messaging');

const crypto = require('crypto');

initializeApp();

const db = getFirestore();

// Otomatik lig bildirimleri Firestore'daki ayarlar/bildirim belgesinden
// (alan: aktif, boolean) yönetilir. ASKF/TFF verileri her durumda Firestore'a
// aktarılmaya devam eder; yalnızca otomatik push bildirimi etkilenir.
// Belge yoksa veya okunamazsa bildirimler KAPALI kabul edilir.
// Yönetici tarafından bildirim_istekleri koleksiyonuna oluşturulan manuel
// bildirimler (bildirimGonder) bu ayardan etkilenmez.
async function otomatikBildirimlerAcikMi() {
  try {
    const snap = await db.collection('ayarlar').doc('bildirim').get();
    return snap.exists && snap.data()?.aktif === true;
  } catch (error) {
    console.error('Bildirim ayarı okunamadı, bildirimler kapalı sayıldı:', error);
    return false;
  }
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

const ASKF_SEZON =
  '2026-2027';

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
          !skorCoz(h),
      );

    let evSahibi = '';
    let deplasman = '';
    let sonuc = '';

    for (
      const h of hucreler
    ) {
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

    const hafta =
      haftaBul(
        birlesik,
      ) ||
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
        /oynanan|\bog\b/.test(
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
  if (kaynak.veriTuru === 'grup' && programDegisikligiMacSayisi > 0 && await otomatikBildirimlerAcikMi()) {
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
      const macDetaylari = bildirimlikDegisiklikler.slice(0, 3).map((m) =>
        `${m.hafta}: ${m.evSahibi} - ${m.deplasman} (${m.tarihSaat})`
      );
      const dahaFazla = bildirimlikDegisiklikler.length > 3
        ? ` ve ${bildirimlikDegisiklikler.length - 3} maç daha`
        : '';
      const aciklama = bildirimlikDegisiklikler.some((m) => m.tur === 'tarih_saat_degisti')
        ? 'İleri tarihli maçların tarih/saat bilgisi değişti.'
        : 'İleri tarihli maçların tarih ve saatleri belli oldu veya yeni maç eklendi.';
      try {
        const messageId = await getMessaging().send({
          topic: 'ligler',
          notification: {
            title: `${kaynakAdi} Maç Programı Güncellendi`,
            body: `${aciklama} ${macDetaylari.join('; ')}${dahaFazla}`,
          },
          data: {
            tur: 'askf_fikstur_tarih_saat_guncelleme',
            kaynakId: kaynak.id,
            lig: ligAdi,
            grup: kaynak.grup || '',
            sezon: ASKF_SEZON,
            ligTuru: 'yerel',
            degisiklikSayisi: String(programDegisikligiMacSayisi),
          },
          android: {
            priority: 'high',
            notification: { channelId: 'yalova_wonder_kids', sound: 'default' },
          },
        });
        await bildirimRef.set({
          fcmMessageId: messageId,
          bildirimDurumu: 'gonderildi',
          bildirimMacSayisi: programDegisikligiMacSayisi,
        }, { merge: true });
      } catch (error) {
        console.error(`ASKF ${kaynakAdi} fikstür bildirimi gönderilemedi:`, error);
        await bildirimRef.set({
          bildirimDurumu: 'hata',
          bildirimHatasi: String(error?.message || error).slice(0, 500),
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
      const messageId = await getMessaging().send({
        topic: 'ligler',
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
        sonBildirimMessageId: messageId,
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
    };
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


exports.askfYerelLigKontrol =
  onSchedule(
    {
      schedule:
        'every 6 hours',

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
        ASKF_KAYNAKLARI
      ) {
        try {
          const sonuc =
            await askfKaynakKontrolEt(
              kaynak,
            );

          sonuclar.push(
            sonuc,
          );

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
// Her 6 saatte bir çalışır.
// İlk kontrolde bildirim göndermez.
// Sonraki kontrollerde gerçek puan durumu değişmişse
// sadece değişen ligin bildirimini gönderir.
// ============================================================

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
    await otomatikBildirimlerAcikMi()
  ) {
    const baslik =
      `🏆 ${kaynak.lig}'nde Puan Durumu Değişti!`;

    const mesaj =
      `${kaynak.grup} puan durumu güncellendi. ` +
      'Güncel sıralamayı Yalova Wonder Kids uygulamasından inceleyebilirsiniz.';

    try {
      const messageId =
        await getMessaging()
          .send({
            topic:
              'ligler',

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
            messageId,

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