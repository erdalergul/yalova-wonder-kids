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

    if (
      !Number.isInteger(pageId) ||
      pageId < 1751 ||
      pageId > 1755
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
// 3. YEREL LİG KAYNAKLARI
//
// Haftalık program sabittir.
// Lig ve grup sayfaları arşivden dinamik keşfedilir.
// ============================================================

const ASKF_KAYNAKLARI = [
  {
    id: 'haftalik_program',

    url:
      'https://yalovaskf.com/haftalik-program',

    ad:
      'Haftalık maç programı',

    grup:
      'genel',

    lig:
      'Yalova Yerel Ligleri',

    sezon:
      '2026-2027',

    veriTuru:
      'fikstur',
  },
];

const ASKF_BASE_URL =
  'https://yalovaskf.com';

const ASKF_ARSIV_URL =
  `${ASKF_BASE_URL}/puan-arsivi`;

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
        kaynak.sezon ||
        ASKF_SEZON,

      lig:
        kaynak.lig ||
        (kaynak.grup === 'A'
          ? 'Süper Amatör A Grubu'
          : kaynak.grup === 'B'
            ? 'Süper Amatör B Grubu'
            : 'Yalova Yerel Ligleri'),

      grup:
        kaynak.grup ||
        '',

      ligId:
        String(
          kaynak.ligId ||
          '',
        ),

      grupId:
        String(
          kaynak.grupId ||
          '',
        ),

      grupSlug:
        String(
          kaynak.slug ||
          '',
        ),

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
//
// Gerçek kaynak HTML'sindeki yapı:
//
// Sıra | Takım | O | G | B | M | AG | YG | AV | P
//
// ============================================================

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
    const satirlar =
      tabloSatirlariniCikar(
        tablo,
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
        /oynanan|\bog\b|\bo\b/.test(
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
      const row of satirlar.slice(
        1,
      )
    ) {
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

      /*
       * Gerçek satır:
       *
       * 1
       * SULTANİYE SPOR
       * 0
       * 0
       * 0
       * 0
       * 0
       * 0
       * 0
       * 0
       *
       * Toplam 9 sayı.
       */

      if (
        nums.length < 8
      ) {
        continue;
      }

      const n =
        nums;

      takimlar.push({
        sira:
          n[0] ||
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
   * Böylece maçın tarihi/saatinin değişmesi
   * yeni maç oluşturmaz.
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

async function fiksturleriKaydet(
  maclar,
  kaynak,
) {
  let yeniMacSayisi = 0;

  for (
    const mac of maclar
  ) {
    const ref =
      db
        .collection(
          ASKF_FIKSTUR_KOLEKSIYONU,
        )
        .doc(
          macBelgeId(
            mac,
          ),
        );

    let yeniMac = false;

    await db.runTransaction(
      async (tx) => {
        const snap =
          await tx.get(
            ref,
          );

        const onceki =
          snap.exists
            ? (
                snap.data() ||
                {}
              )
            : {};

        yeniMac =
          !snap.exists;

        tx.set(
          ref,
          {
            ...mac,

            yayinlandi:
              true,

            kaynakId:
              kaynak.id,

            otomatikAktarim:
              true,

            olusturmaTarihi:
              onceki.olusturmaTarihi ||
              FieldValue.serverTimestamp(),

            sonGuncelleme:
              FieldValue.serverTimestamp(),

            bildirimGonderildi:
              onceki.bildirimGonderildi === true,
          },
          {
            merge: true,
          },
        );
      },
    );

    if (yeniMac) {
      yeniMacSayisi++;
    }
  }

  /*
   * İlk taramada eski bütün maçlar için
   * bildirim göndermiyoruz.
   */

  if (
    yeniMacSayisi > 0 &&
    kaynak.ilkTarama !== true
  ) {
    const bildirimRef =
      db
        .collection(
          'askf_bildirim_kayitlari',
        )
        .doc(
          kaynak.id,
        );

    const bugun =
      new Date()
        .toISOString()
        .slice(
          0,
          10,
        );

    const sonuc =
      await db.runTransaction(
        async (tx) => {
          const snap =
            await tx.get(
              bildirimRef,
            );

          const veri =
            snap.exists
              ? snap.data()
              : {};

          if (
            veri?.sonBildirimGunu ===
            bugun
          ) {
            return {
              gonder:
                false,
            };
          }

          tx.set(
            bildirimRef,
            {
              sonBildirimGunu:
                bugun,

              sonBildirimTarihi:
                FieldValue.serverTimestamp(),

              kaynakId:
                kaynak.id,
            },
            {
              merge: true,
            },
          );

          return {
            gonder:
              true,
          };
        },
      );

    if (
      sonuc.gonder
    ) {
      try {
        const messageId =
          await getMessaging().send(
            {
              topic:
                'ligler',

              notification: {
                title:
                  ASKF_BILDIRIM_BASLIK,

                body:
                  ASKF_BILDIRIM_GOVDE,
              },

              data: {
                tur:
                  'yerel_yeni_fikstur',

                kaynakId:
                  kaynak.id,

                ligTuru:
                  'yerel',
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
            },
          );

        await bildirimRef.set(
          {
            fcmMessageId:
              messageId,

            bildirimDurumu:
              'gonderildi',
          },
          {
            merge: true,
          },
        );

      } catch (error) {
        console.error(
          'Yerel fikstür bildirimi gönderilemedi:',
          error,
        );

        await bildirimRef.set(
          {
            bildirimDurumu:
              'hata',

            bildirimHatasi:
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
  }

  return {
    toplamMac:
      maclar.length,

    yeniMacSayisi,
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

  const docId =
    kaynak.puanDocId ||
    kaynak.id;

  await db
    .collection(
      ASKF_PUAN_KOLEKSIYONU,
    )
    .doc(docId)
    .set(
      {
        sezon:
          kaynak.sezon ||
          ASKF_SEZON,

        lig:
          kaynak.lig ||
          'Yalova Yerel Ligleri',

        grup:
          kaynak.grup ||
          '',

        ligId:
          String(
            kaynak.ligId ||
            '',
          ),

        grupId:
          String(
            kaynak.grupId ||
            '',
          ),

        grupSlug:
          String(
            kaynak.slug ||
            '',
          ),

        kaynakId:
          kaynak.id,

        takimlar,

        kaynak:
          kaynak.url,

        otomatikAktarim:
          true,

        sonGuncelleme:
          FieldValue.serverTimestamp(),
      },
      {
        merge: true,
      },
    );

  return true;
}


// ============================================================
// 10. DİNAMİK LİG / GRUP KEŞFİ
// ============================================================

async function askfGetir(
  url,
  jsonBekleniyor = false,
) {
  const response =
    await fetch(
      url,
      {
        method:
          'GET',

        headers: {
          'User-Agent':
            'Mozilla/5.0 (compatible; YalovaWonderKids/1.0)',

          'Accept':
            jsonBekleniyor
              ? 'application/json,text/plain,*/*'
              : 'text/html,application/xhtml+xml,*/*',

          'Accept-Language':
            'tr-TR,tr;q=0.9,en;q=0.8',

          'Cache-Control':
            'no-cache',
        },

        signal:
          AbortSignal.timeout(
            25000,
          ),
      },
    );

  const body =
    await response.text();

  if (!response.ok) {
    throw new Error(
      `Kaynak HTTP ${response.status}: ${url}`,
    );
  }

  if (
    !body ||
    body.length < 2
  ) {
    throw new Error(
      `Kaynak boş yanıt döndürdü: ${url}`,
    );
  }

  return body;
}


function askfJsonDizisiCoz(
  body,
  endpoint,
) {
  let parsed;

  try {
    parsed =
      JSON.parse(
        body,
      );
  } catch (_) {
    throw new Error(
      `${endpoint} geçerli JSON döndürmedi.`,
    );
  }

  if (
    !Array.isArray(parsed)
  ) {
    throw new Error(
      `${endpoint} JSON dizisi döndürmedi.`,
    );
  }

  return parsed;
}


function askfSezonuNormallestir(
  label,
) {
  const m =
    String(label || '').match(
      /(\d{4})\s*[-/]\s*(\d{4})/,
    );

  return m
    ? `${m[1]}-${m[2]}`
    : ASKF_SEZON;
}


function askfKaynakId(
  slug,
) {
  if (
    slug ===
    'super-amator-lig-a-grubu-2026-2027-1'
  ) {
    return 'super_amator_a_2026_2027';
  }

  if (
    slug ===
    'super-amator-lig-b-grubu-2026-2027-1'
  ) {
    return 'super_amator_b_2026_2027';
  }

  return (
    `yerel_${String(slug || '')
      .toLowerCase()
      .replace(
        /[^a-z0-9]+/g,
        '_',
      )
      .replace(
        /^_+|_+$/g,
        '',
      )
      .slice(
        0,
        100,
      )}`
  );
}


async function askfLigGruplariniKesfet() {
  const html =
    await askfGetir(
      ASKF_ARSIV_URL,
    );

  /*
   * Arşiv sayfasındaki gerçek yapı:
   *
   * <option value="5">2026-2027</option>
   */

  const options =
    [
      ...html.matchAll(
        /<option\b[^>]*value=["']([^"']+)["'][^>]*>([\s\S]*?)<\/option>/gi,
      ),
    ]
      .map(
        (m) => ({
          id:
            m[1].trim(),

          name:
            htmlMetniniTemizle(
              m[2],
            ).trim(),
        }),
      )
      .filter(
        (x) =>
          /^\d+$/.test(
            x.id,
          ) &&
          /\d{4}\s*[-/]\s*\d{4}/.test(
            x.name,
          ),
      );

  if (
    !options.length
  ) {
    throw new Error(
      'Arşivde sezon listesi bulunamadı.',
    );
  }

  /*
   * En yeni sezonu seçiyoruz.
   */

  options.sort(
    (a, b) => {
      const ay =
        Number(
          (
            a.name.match(
              /\d{4}/,
            ) || [
              '0',
            ]
          )[0],
        );

      const by =
        Number(
          (
            b.name.match(
              /\d{4}/,
            ) || [
              '0',
            ]
          )[0],
        );

      return by - ay;
    },
  );

  const season =
    options[0];

  const sezon =
    askfSezonuNormallestir(
      season.name,
    );

  /*
   * Gerçek AJAX endpoint:
   *
   * ajax/get_leagues.php?season_id=5
   */

  const leagueUrl =
    `${ASKF_BASE_URL}/ajax/get_leagues.php?season_id=${encodeURIComponent(
      season.id,
    )}`;

  const leagues =
    askfJsonDizisiCoz(
      await askfGetir(
        leagueUrl,
        true,
      ),
      'get_leagues.php',
    );

  const sources = [];

  for (
    const league of leagues
  ) {
    if (
      league?.id == null ||
      !league?.name
    ) {
      continue;
    }

    /*
     * Gerçek AJAX endpoint:
     *
     * ajax/get_groups.php?
     * season_id=5&
     * league_id=39
     */

    const groupsUrl =
      `${ASKF_BASE_URL}/ajax/get_groups.php?season_id=${encodeURIComponent(
        season.id,
      )}&league_id=${encodeURIComponent(
        league.id,
      )}`;

    const groups =
      askfJsonDizisiCoz(
        await askfGetir(
          groupsUrl,
          true,
        ),
        'get_groups.php',
      );

    for (
      const group of groups
    ) {
      const slug =
        String(
          group?.slug ||
          '',
        ).trim();

      if (
        !slug ||
        !group?.name
      ) {
        continue;
      }

      const ligAdi =
        String(
          league.name,
        ).trim();

      const grupAdi =
        String(
          group.name,
        ).trim();

      const ad =
        `${ligAdi} ${grupAdi}`
          .replace(
            /\s+/g,
            ' ',
          );

      const id =
        askfKaynakId(
          slug,
        );

      const oldA =
        slug.includes(
          'super-amator-lig-a-grubu',
        );

      const oldB =
        slug.includes(
          'super-amator-lig-b-grubu',
        );

      sources.push({
        id,

        url:
          `${ASKF_BASE_URL}/grup/${slug}`,

        ad,

        lig:
          ligAdi,

        grup:
          grupAdi,

        sezon,

        ligId:
          String(
            league.id,
          ),

        grupId:
          String(
            group.id ??
            '',
          ),

        slug,

        puanDocId:
          oldA
            ? 'super-amator-a-2026-2027'
            : oldB
              ? 'super-amator-b-2026-2027'
              : id,

        veriTuru:
          'grup',
      });
    }
  }

  if (
    !sources.length
  ) {
    throw new Error(
      `${sezon} sezonunda grup bulunamadı.`,
    );
  }

  console.log(
    `Dinamik keşif: ${sezon}; ` +
    `${leagues.length} lig, ` +
    `${sources.length} grup.`,
  );

  return sources;
}


// ============================================================
// 11. GÜVENLİ YEDEK GRUPLAR
// ============================================================

function askfYedekGruplar() {
  return [
    {
      id:
        'super_amator_a_2026_2027',

      url:
        `${ASKF_BASE_URL}/grup/super-amator-lig-a-grubu-2026-2027-1`,

      ad:
        'Süper Amatör Lig A Grubu',

      lig:
        'Süper Amatör Lig',

      grup:
        'A GRUBU',

      sezon:
        ASKF_SEZON,

      slug:
        'super-amator-lig-a-grubu-2026-2027-1',

      puanDocId:
        'super-amator-a-2026-2027',

      veriTuru:
        'grup',
    },

    {
      id:
        'super_amator_b_2026_2027',

      url:
        `${ASKF_BASE_URL}/grup/super-amator-lig-b-grubu-2026-2027-1`,

      ad:
        'Süper Amatör Lig B Grubu',

      lig:
        'Süper Amatör Lig',

      grup:
        'B GRUBU',

      sezon:
        ASKF_SEZON,

      slug:
        'super-amator-lig-b-grubu-2026-2027-1',

      puanDocId:
        'super-amator-b-2026-2027',

      veriTuru:
        'grup',
    },
  ];
}


// ============================================================
// 12. KAYNAK KONTROLÜ
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

    const html =
      await response.text();

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

    /*
     * İlk başarılı taramada mevcut maçlar
     * için toplu bildirim göndermiyoruz.
     */

    kaynak.ilkTarama =
      eskiVeri.ilkAktarimTamamlandi !==
      true;

    let fiksturSonucu = {
      toplamMac:
        0,

      yeniMacSayisi:
        0,
    };

    let puanDurumuKaydedildi =
      false;

    let kaynakVerisiDogrulandi =
      false;

    // --------------------------------------------------------
    // GRUP SAYFASI
    // --------------------------------------------------------

    if (
      kaynak.veriTuru ===
      'grup'
    ) {
      const maclar =
        fiksturleriAyrisla(
          html,
          kaynak,
        );

      /*
       * Maç bulunduysa kaydet.
       *
       * Maç bulunamadığında mevcut Firestore
       * kayıtlarını silmiyoruz.
       */

      if (
        maclar.length > 0
      ) {
        fiksturSonucu =
          await fiksturleriKaydet(
            maclar,
            kaynak,
          );

        kaynakVerisiDogrulandi =
          true;
      }

      const takimlar =
        puanDurumunuAyrisla(
          html,
          kaynak,
        );

      /*
       * Gerçek puan tablosu bulunduysa kaydet.
       */

      if (
        takimlar.length >= 4
      ) {
        puanDurumuKaydedildi =
          await puanDurumunuKaydet(
            takimlar,
            kaynak,
          );

        kaynakVerisiDogrulandi =
          true;
      }

      if (
        maclar.length === 0 &&
        takimlar.length === 0
      ) {
        console.warn(
          `Kaynak açıldı ancak tanınan ` +
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

        kaynakVerisiDogrulandi =
          true;
      }
    }

    /*
     * Kaynak HTML'i değişmiş olabilir.
     *
     * Ancak HTML değişti diye bildirim göndermiyoruz.
     * Bildirim yalnızca gerçek yeni maç bulunduğunda
     * gönderiliyor.
     */

    const degisti =
      !eskiSnap.exists ||
      String(
        eskiVeri.sonHash ||
        '',
      ) !==
        yeniHash;

    const durumVerisi = {
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
        kaynak.grup ||
        '',

      lig:
        kaynak.lig ||
        '',

      sezon:
        kaynak.sezon ||
        ASKF_SEZON,

      ligId:
        String(
          kaynak.ligId ||
          '',
        ),

      grupId:
        String(
          kaynak.grupId ||
          '',
        ),

      grupSlug:
        String(
          kaynak.slug ||
          '',
        ),

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

      kaynakVerisiDogrulandi,
    };

    /*
     * İlk veri aktarımı başarılıysa işaretle.
     *
     * Böylece sonraki kontrollerde gerçekten
     * yeni maç geldiğinde bildirim gönderilebilir.
     */

    if (
      kaynakVerisiDogrulandi
    ) {
      durumVerisi.ilkAktarimTamamlandi =
        true;
    }

    await kaynakRef.set(
      durumVerisi,
      {
        merge: true,
      },
    );

    /*
     * HTML değişiklik kaydı.
     *
     * Bu kayıt kullanıcıya bildirim gönderildiği
     * anlamına gelmez.
     */

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
              0 &&
              kaynak.ilkTarama !== true,

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
      `Yerel lig kontrolü tamamlandı: ${kaynak.id}`,

      JSON.stringify(
        {
          ...fiksturSonucu,

          puanDurumuKaydedildi,

          kaynakVerisiDogrulandi,

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

      kaynakVerisiDogrulandi,
    };

  } catch (error) {

    console.error(
      `Yerel lig kontrol hatası: ${kaynak.id}`,
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
          kaynak.grup ||
          '',

        lig:
          kaynak.lig ||
          '',

        sezon:
          kaynak.sezon ||
          ASKF_SEZON,

        ligId:
          String(
            kaynak.ligId ||
            '',
          ),

        grupId:
          String(
            kaynak.grupId ||
            '',
          ),

        grupSlug:
          String(
            kaynak.slug ||
            '',
          ),

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
// 13. ANA YEREL LİG KONTROLÜ
//
// HER 6 SAATTE BİR ÇALIŞIR.
//
// 1. Haftalık program
// 2. Arşivden güncel sezon
// 3. Güncel ligler
// 4. Güncel gruplar
// 5. Grup puan durumları
// 6. Grup fikstürleri
// ============================================================

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
        'Yalova yerel lig kontrolü başladı.',
      );

      const sonuclar =
        [];

      /*
       * 1) Haftalık program
       */

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
            `Kaynak çalıştırma hatası: ${kaynak.id}`,
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

      /*
       * 2) Lig ve grupları dinamik keşfet.
       */

      let grupKaynaklari = [];

      try {

        grupKaynaklari =
          await askfLigGruplariniKesfet();

      } catch (error) {

        console.error(
          'Dinamik lig/grup keşfi başarısız:',
          error,
        );

        /*
         * Keşif başarısız olursa güvenli yedek
         * olarak mevcut Süper Amatör A/B
         * sayfalarını kontrol ediyoruz.
         */

        grupKaynaklari =
          askfYedekGruplar();

        console.warn(
          'Güvenli yedek grup kaynakları kullanılacak.',
        );
      }

      /*
       * 3) Bulunan bütün grupları kontrol et.
       */

      for (
        const kaynak of
        grupKaynaklari
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
            `Grup kaynak çalıştırma hatası: ${kaynak.id}`,
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

      console.log(
        'Yalova yerel lig kontrolü tamamlandı.',

        JSON.stringify(
          sonuclar,
        ),
      );
    },
  );


// ============================================================
// DOSYA SONU
// ============================================================