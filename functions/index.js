const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

const db = getFirestore();

const izinliKonular = new Set([
  'genel',
  'maclar',
  'haberler',
  'ligler',
]);

// ============================================================
// YÖNETİCİ BİLDİRİMİ
// ============================================================

exports.bildirimGonder = onDocumentCreated(
  {
    document: 'bildirim_istekleri/{istekId}',
    region: 'europe-west1',
  },
  async (event) => {
    const snap = event.data;

    if (!snap) return;

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

      const adminSnap =
          await db.collection('adminler').doc(uid).get();

      if (!adminSnap.exists ||
          adminSnap.data()?.aktif !== true) {
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
// TFF GELİŞİM LİGLERİ PROXY
// ============================================================
//
// Android
//    ↓
// Firebase Cloud Function
//    ↓
// TFF
//
// TFF bazı Android/operatör isteklerinde 504
// döndürebildiği için gelişim ligi HTML'i
// sunucu tarafından alınır.
//
// Flutter tarafı dönen HTML'i mevcut parser
// ile işleyecek.
//

exports.tffGelisimVeri = onCall(
  {
    region: 'europe-west1',
    timeoutSeconds: 60,
    memory: '256MiB',
  },

  async (request) => {

    const url =
        String(request.data?.url || '').trim();

    // --------------------------------------------------------
    // URL KONTROLÜ
    // --------------------------------------------------------

    if (!url) {
      throw new HttpsError(
        'invalid-argument',
        'TFF URL bilgisi eksik.',
      );
    }

    let parsed;

    try {
      parsed = new URL(url);
    } catch (_) {
      throw new HttpsError(
        'invalid-argument',
        'Geçersiz TFF URL.',
      );
    }

    // --------------------------------------------------------
    // SADECE TFF
    // --------------------------------------------------------

    if (
      parsed.protocol !== 'https:' ||
      parsed.hostname !== 'www.tff.org'
    ) {
      throw new HttpsError(
        'invalid-argument',
        'Sadece www.tff.org adresi kullanılabilir.',
      );
    }

    // --------------------------------------------------------
    // PAGE ID
    // --------------------------------------------------------

    const pageId =
        Number(
          parsed.searchParams.get('pageID'),
        );

    // --------------------------------------------------------
    // GRUP ID
    // --------------------------------------------------------

    const groupId =
        Number(
          parsed.searchParams.get('grupID'),
        );

    // --------------------------------------------------------
    // GELİŞİM LİGİ PAGE ID KONTROLÜ
    // --------------------------------------------------------

    const izinliPageIdleri = [
      1751,
      1752,
      1753,
      1754,
      1755,
    ];

    if (!izinliPageIdleri.includes(pageId)) {
      throw new HttpsError(
        'invalid-argument',
        'Geçersiz gelişim ligi pageID.',
      );
    }

    // --------------------------------------------------------
    // GRUP ID KONTROLÜ
    // --------------------------------------------------------

    if (
      !Number.isInteger(groupId) ||
      groupId <= 0
    ) {
      throw new HttpsError(
        'invalid-argument',
        'Geçersiz TFF grup ID.',
      );
    }

    // --------------------------------------------------------
    // TFF İSTEĞİ
    // --------------------------------------------------------

    const controller =
        new AbortController();

    const timer = setTimeout(
      () => controller.abort(),
      50000,
    );

    try {

      const response =
          await fetch(
            parsed.toString(),
            {
              method: 'GET',

              signal:
                  controller.signal,

              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/154.0 Safari/537.36',

                'Referer':
                    'https://www.tff.org/',

                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',

                'Accept-Language':
                    'tr-TR,tr;q=0.9,en;q=0.7',

                'Cache-Control':
                    'no-cache',

                'Pragma':
                    'no-cache',
              },
            },
          );

      const body =
          await response.text();

      const contentType =
          response.headers.get(
            'content-type',
          ) ||
          'text/html; charset=utf-8';

      console.log(
        `TFF proxy: pageID=${pageId}, grupID=${groupId}, HTTP=${response.status}, bytes=${Buffer.byteLength(body, 'utf8')}`,
      );

      // ------------------------------------------------------
      // FLUTTER'A GERİ DÖN
      // ------------------------------------------------------

      return {
        statusCode: response.status,
        contentType: contentType,
        body: body,
      };

    } catch (error) {

      console.error(
        'TFF proxy hatası:',
        error,
      );

      throw new HttpsError(
        'unavailable',
        `TFF sunucusuna erişilemedi: ${String(
          error?.message || error,
        ).slice(0, 300)}`,
      );

    } finally {

      clearTimeout(timer);

    }
  },
);