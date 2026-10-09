import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

// TFF karakter düzeltmesi: bazı TFF yanıtları Türkçe karakterleri
// Windows-1254/ISO-8859-9 benzeri biçimde çözümlenmiş olarak döndürebiliyor.
String _tffKarakterleriniDuzelt(String value) {
  return value
      .replaceAll('Ð', 'Ğ')
      .replaceAll('Þ', 'Ş')
      .replaceAll('Ý', 'İ')
      .replaceAll('ð', 'ğ')
      .replaceAll('þ', 'ş')
      .replaceAll('ý', 'ı');
}

// ============================================================
// ARKA PLAN BİLDİRİM HANDLER'I
// ============================================================
// DÜZELTME: bu fonksiyon tanımlıydı ama main() içinde hiç
// FirebaseMessaging.onBackgroundMessage(...) ile kaydedilmemişti.
// Kaydedilmeden bu handler asla çağrılmaz; uygulama kapalıyken/arka
// plandayken gelen bildirimler için gerekli.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Arka plan izolate'i ayrı çalıştığı için Firebase burada
  // tekrar başlatılmalı.
  Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  DartPluginRegistrant.ensureInitialized();

  debugPrint('ARKA PLAN BİLDİRİMİ: ${message.notification?.title}');

  // Uygulama arka plandayken/kapalıyken alınan bildirimi de geçmişe kaydet.
  await BildirimGecmisi.kaydet(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );
  } catch (e) {
    debugPrint('Firebase başlatılamadı: $e');
  }

  runApp(const YalovaWonderKidsApp());
}

// ============================================================
// UYGULAMA SÜRÜMÜ
// ============================================================

const String uygulamaSurumu = '1.0.13';

// ============================================================
// SORGU SINIRLARI
// ============================================================
// Firestore sorgularında limit kullanılmadığında koleksiyon büyüdükçe
// her açılışta tüm belgeler indirilir ve okuma kotası doğrusal artar.
// Aşağıdaki sabitler indirilen belge sayısını sabitler.
//
// ÖNEMLİ: where(...) + orderBy(...) birlikte kullanıldığında Firestore
// bileşik (composite) indeks ister. Uygulamayı ilk çalıştırdığında
// konsola "The query requires an index ..." şeklinde bir hata ve
// hazır bir oluşturma bağlantısı düşer; o bağlantıya tıklayıp indeksi
// oluşturman yeterli. Gereken indeksler:
//   haberler            : yayinlandi (asc) + tarih (desc)
const int _bildirimDinlemeLimiti = 30;
const int _haberListesiLimiti = 50;

// GitHub'daki güncel sürüm numarasını kontrol eder.
const String versionUrl =
    'https://raw.githubusercontent.com/erdalergul/yalova-wonder-kids/main/version.txt';

// GitHub'daki APK bağlantısını kontrol eder.
const String apkUrlUrl =
    'https://raw.githubusercontent.com/erdalergul/yalova-wonder-kids/main/apk_url.txt';

// GitHub'daki APK'nın SHA-256 özetini (hash) kontrol eder.
// Bu dosyayı her yeni APK yayınladığında güncellemen gerekir:
//   sha256sum app-release.apk  ->  çıktıyı apk_sha256.txt içine yaz.
// Bu adım, indirilen APK'nın GitHub'da yayınladığın APK ile birebir
// aynı olduğunu doğrular; aradaki bağlantı (DNS/hesap ele geçirme vb.)
// değiştirilmiş bir dosya sunarsa kullanıcıyı uyarır.
const String apkHashUrl =
    'https://raw.githubusercontent.com/erdalergul/yalova-wonder-kids/main/apk_sha256.txt';

// ============================================================
// UYGULAMA
// ============================================================

final GlobalKey<NavigatorState> uygulamaNavigatorKey = GlobalKey<NavigatorState>();

class YalovaWonderKidsApp extends StatelessWidget {
  const YalovaWonderKidsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: uygulamaNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Yalova Wonder Kids',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7F6),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF087A3D),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF12352A),
          elevation: 0,
        ),
      ),
      home: const AnaSayfa(),
    );
  }
}

// ============================================================
// RENKLER
// ============================================================

const Color anaYesil = Color(0xFF087A3D);
const Color koyuYesil = Color(0xFF07552D);
const Color acikYesil = Color(0xFFE8F5ED);
const Color siyah = Color(0xFF17221D);
const Color gri = Color(0xFF6B756F);


// ============================================================
// SITE VERİ ÖNBELLEĞİ (CACHE)
// ============================================================
// Son başarılı veriyi cihazda saklar. Sayfa tekrar açıldığında
// internet beklenmeden önce bu veri gösterilir; ardından arka
// planda güncel veri alınır. Böylece internet yavaşken veya
// geçici olarak yokken kullanıcı boş/hata ekranında kalmaz.
class SiteCacheKaydi {
  final DateTime tarih;
  final dynamic veri;

  const SiteCacheKaydi({required this.tarih, required this.veri});
}

class SiteVeriCache {
  static const String _surum = 'site_cache_v1';

  static String _anahtar(String tur, String kaynak) {
    final hash = sha256.convert(utf8.encode(kaynak)).toString();
    return '${_surum}_${tur}_${hash.substring(0, 24)}';
  }

  static Future<void> kaydet({
    required String tur,
    required String kaynak,
    required dynamic veri,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paket = <String, dynamic>{
        'tarih': DateTime.now().toIso8601String(),
        'veri': veri,
      };
      await prefs.setString(_anahtar(tur, kaynak), jsonEncode(paket));
    } catch (e) {
      debugPrint('Site cache kaydedilemedi: $e');
    }
  }

  static Future<SiteCacheKaydi?> oku({
    required String tur,
    required String kaynak,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ham = prefs.getString(_anahtar(tur, kaynak));
      if (ham == null || ham.isEmpty) return null;

      final paket = jsonDecode(ham);
      if (paket is! Map<String, dynamic>) return null;

      final tarih = DateTime.tryParse(paket['tarih']?.toString() ?? '');
      if (tarih == null || !paket.containsKey('veri')) return null;

      return SiteCacheKaydi(tarih: tarih, veri: paket['veri']);
    } catch (e) {
      debugPrint('Site cache okunamadı: $e');
      return null;
    }
  }
}

String cacheGuncellemeMetni(DateTime? tarih) {
  if (tarih == null) return '';

  String iki(int deger) => deger.toString().padLeft(2, '0');
  return 'Son güncelleme: ${iki(tarih.day)}.${iki(tarih.month)}.${tarih.year} '
      '${iki(tarih.hour)}:${iki(tarih.minute)}';
}

// ============================================================
// ============================================================
// BİLDİRİM GEÇMİŞİ
// ============================================================
// Uygulamanın aldığı bildirimleri cihazda saklar.
// Liste uygulama silinene kadar cihazda tutulur.
class BildirimGecmisi {
  static const String _anahtar = 'bildirim_gecmisi_v1';

  static Future<List<Map<String, dynamic>>> oku() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final liste = prefs.getStringList(_anahtar) ?? <String>[];
      final sonuc = <Map<String, dynamic>>[];

      for (final kayit in liste) {
        try {
          final veri = jsonDecode(kayit);
          if (veri is Map<String, dynamic>) {
            sonuc.add(veri);
          }
        } catch (_) {}
      }

      sonuc.sort((a, b) {
        final aTarih = DateTime.tryParse(a['tarih']?.toString() ?? '') ?? DateTime(1970);
        final bTarih = DateTime.tryParse(b['tarih']?.toString() ?? '') ?? DateTime(1970);
        return bTarih.compareTo(aTarih);
      });

      return sonuc;
    } catch (e) {
      debugPrint('Bildirim geçmişi okunamadı: $e');
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> kaydet(RemoteMessage message) async {
    final baslik = message.notification?.title ??
        message.data['title']?.toString() ??
        'Yalova Wonder Kids';
    final govde = message.notification?.body ??
        message.data['body']?.toString() ??
        '';

    await kaydetMetin(
      baslik: baslik,
      govde: govde,
      mesajId: message.messageId,
    );
  }

  static Future<void> kaydetMetin({
    required String baslik,
    required String govde,
    String? mesajId,
  }) async {
    if (baslik.trim().isEmpty && govde.trim().isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final mevcut = prefs.getStringList(_anahtar) ?? <String>[];

      // Aynı FCM mesajı iki farklı callback'ten gelirse çift kayıt oluşmasın.
      if (mesajId != null && mesajId.isNotEmpty) {
        for (final kayit in mevcut) {
          try {
            final veri = jsonDecode(kayit);
            if (veri is Map<String, dynamic> && veri['mesajId'] == mesajId) {
              return;
            }
          } catch (_) {}
        }
      }

      final yeniKayit = <String, dynamic>{
        'mesajId': mesajId ?? '',
        'title': baslik.trim().isEmpty ? 'Yalova Wonder Kids' : baslik.trim(),
        'body': govde.trim(),
        'tarih': DateTime.now().toIso8601String(),
      };

      mevcut.add(jsonEncode(yeniKayit));

      // Bildirim geçmişi büyüyüp cihazda gereksiz yer kaplamasın.
      // Kullanıcıya son 200 bildirimi gösteriyoruz.
      if (mevcut.length > 200) {
        mevcut.removeRange(0, mevcut.length - 200);
      }

      await prefs.setStringList(_anahtar, mevcut);
    } catch (e) {
      debugPrint('Bildirim geçmişi kaydedilemedi: $e');
    }
  }
}

// BİLDİRİM SERVİSİ
// ============================================================
// DÜZELTME: Bu servis daha önce main() içinde, runApp()'tan ÖNCE
// çalışıyordu (izin diyalogları + token alma + kanal oluşturma).
// Şimdi runApp()'tan SONRA, ilk frame basıldıktan sonra çağrılıyor
// (bkz. AnaSayfa.initState). Ayrıca:
//  - flutter_local_notifications artık gerçekten initialize
//    ediliyor (önceden hiç initialize edilmemişti).
//  - Ön planda (foreground) gelen bildirimler artık gerçekten
//    ekranda gösteriliyor (önceden alınıp hiçbir şey yapılmıyordu).
//  - Tüm adımlar try/catch içinde; bildirim kurulumu başarısız
//    olsa bile uygulamanın geri kalanı etkilenmiyor.
class BildirimServisi {
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static bool _baslatildiMi = false;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _haberDinleme;
  static bool _haberDinlemeIlkSnapshot = true;
  static const String _bilinenHaberIdleriAnahtari = 'bilinen_haber_idleri_v1';
  static const String _haberBildirimIlklendiAnahtari = 'haber_bildirim_ilklendi_v1';

  static const String genelKonu = 'genel';
  static const String maclarKonu = 'maclar';
  static const String haberlerKonu = 'haberler';
  static const String liglerKonu = 'ligler';

  // Bildirim ayarları: uygulama çalışırken kullanıcı tercihlerine göre
  // Firebase konu abonelikleri açılıp/kapatılır.
  static bool genelAktif = true;
  static bool maclarAktif = true;
  static bool haberlerAktif = true;
  static bool liglerAktif = true;

  static const AndroidNotificationChannel _bildirimKanali =
      AndroidNotificationChannel(
    'yalova_wonder_kids',
    'Yalova Wonder Kids',
    description: 'Yalova Wonder Kids bildirimleri',
    importance: Importance.high,
    playSound: true,
  );

  static Future<void> baslat() async {
    if (_baslatildiMi) return;

    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);

      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _yerelBildirimeTiklandi,
      );

      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.createNotificationChannel(_bildirimKanali);
      await androidPlugin?.requestNotificationsPermission();

      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      // FCM otomatik başlatmayı açık tut. Token alınmadan konu aboneliği
      // başlatmak bazı cihazlarda aboneliğin sessizce başarısız olmasına
      // neden olabildiği için önce kayıt/token durumunu doğrula.
      await FirebaseMessaging.instance.setAutoInitEnabled(true);

      final token = await FirebaseMessaging.instance.getToken();
      debugPrint('FCM token alındı.');
      debugPrint('FCM token uzunluğu: ${token?.length ?? 0}');

      // Bildirim ayarlarında aktif olan konulara güvenli şekilde abone ol.
      await _konuAboneliginiUygula(genelKonu, genelAktif);
      await _konuAboneliginiUygula(maclarKonu, maclarAktif);
      await _konuAboneliginiUygula(haberlerKonu, haberlerAktif);
      await _konuAboneliginiUygula(liglerKonu, liglerAktif);

      FirebaseMessaging.instance.onTokenRefresh.listen((yeniToken) async {
        debugPrint('FCM token yenilendi. Uzunluk: ${yeniToken.length}');
        // Token yenilenirse aktif konu aboneliklerini tekrar doğrula.
        await _konuAboneliginiUygula(genelKonu, genelAktif);
        await _konuAboneliginiUygula(maclarKonu, maclarAktif);
        await _konuAboneliginiUygula(haberlerKonu, haberlerAktif);
        await _konuAboneliginiUygula(liglerKonu, liglerAktif);
      });

      debugPrint('Bildirim ayarları uygulandı.');

      // Uygulama açıkken gelen FCM bildirimi Android sistem bildirimi
      // olarak ayrıca gösterilir.
      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        final bildirim = message.notification;
        final baslik = bildirim?.title ?? message.data['title']?.toString();
        final govde = bildirim?.body ?? message.data['body']?.toString();

        if ((baslik == null || baslik.isEmpty) &&
            (govde == null || govde.isEmpty)) {
          return;
        }

        await BildirimGecmisi.kaydet(message);

        await _localNotifications.show(
          id: DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
          title: baslik ?? 'Yalova Wonder Kids',
          body: govde ?? '',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _bildirimKanali.id,
              _bildirimKanali.name,
              channelDescription: _bildirimKanali.description,
              importance: Importance.high,
              priority: Priority.high,
              playSound: true,
              icon: '@mipmap/ic_launcher',
            ),
          ),
          payload: _payloadOlustur(message),
        );
      });

      // Uygulama arka plandayken bildirime dokunulursa burası çalışır.
      FirebaseMessaging.onMessageOpenedApp.listen(_bildirimeTiklandi);

      // Uygulama tamamen kapalıyken bildirime dokunarak açıldıysa.
      final ilkMesaj = await FirebaseMessaging.instance.getInitialMessage();
      if (ilkMesaj != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _bildirimeTiklandi(ilkMesaj);
        });
      }

      // Uygulama açıldığında ücretsiz haber bildirimleri için Firestore
      // kontrolünü başlatır. Manuel yönetici bildirimleri artık Cloud
      // Functions + FCM üzerinden gönderilmektedir.
      await _ucretsizHaberBildirimleriniBaslat();
      _baslatildiMi = true;
    } catch (e) {
      _baslatildiMi = false;
      debugPrint('Bildirim servisi başlatılamadı: $e');
    }
  }

  static String _payloadOlustur(RemoteMessage message) {
    final veri = <String, String>{};
    message.data.forEach((key, value) {
      veri[key] = value.toString();
    });
    veri['title'] = message.notification?.title ?? veri['title'] ?? '';
    veri['body'] = message.notification?.body ?? veri['body'] ?? '';
    return jsonEncode(veri);
  }

  static void _yerelBildirimeTiklandi(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final veri = jsonDecode(payload) as Map<String, dynamic>;
      final haberId = veri['haberId']?.toString() ?? '';
      if (haberId.isNotEmpty) {
        _haberSayfasiniAc(haberId);
        return;
      }

      _bildirimSayfasiniAc(
        veri['title']?.toString() ?? 'Yalova Wonder Kids',
        veri['body']?.toString() ?? '',
      );
    } catch (_) {
      _bildirimSayfasiniAc('Yalova Wonder Kids', payload);
    }
  }

  static void _bildirimeTiklandi(RemoteMessage message) {
    // Arka plan callback'i kayıt bırakmadıysa, bildirime dokunulduğu anda
    // yine de geçmişe ekle. Aynı messageId varsa kaydet metodu çiftlemez.
    BildirimGecmisi.kaydet(message);

    // Haber bildirimi ise doğrudan haber detayını aç.
    // Cloud Functions olmadan çalışan yerel bildirimler ve ileride
    // gönderilecek FCM bildirimleri haberId bilgisini data alanında taşır.
    final haberId = message.data['haberId']?.toString() ?? '';
    if (haberId.isNotEmpty) {
      _haberSayfasiniAc(haberId);
      return;
    }

    final baslik = message.notification?.title ??
        message.data['title']?.toString() ??
        'Yalova Wonder Kids';
    final govde = message.notification?.body ??
        message.data['body']?.toString() ??
        '';
    _bildirimSayfasiniAc(baslik, govde);
  }

  static void _bildirimSayfasiniAc(String baslik, String govde) {
    final navigator = uygulamaNavigatorKey.currentState;
    if (navigator == null) return;

    navigator.push(
      MaterialPageRoute(
        builder: (_) => BildirimDetaySayfasi(
          baslik: baslik,
          govde: govde,
        ),
      ),
    );
  }

  static Future<void> _haberSayfasiniAc(String haberId) async {
    final navigator = uygulamaNavigatorKey.currentState;
    if (navigator == null) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('haberler')
          .doc(haberId)
          .get();

      if (!doc.exists || doc.data() == null) {
        _bildirimSayfasiniAc('Haber bulunamadı', 'Bu haber artık yayınlanmıyor olabilir.');
        return;
      }

      final haber = Haber.fromFirestore(doc);
      if (!haber.yayinlandi) {
        _bildirimSayfasiniAc('Haber bulunamadı', 'Bu haber artık yayınlanmıyor olabilir.');
        return;
      }

      navigator.push(
        MaterialPageRoute(builder: (_) => HaberDetaySayfasi(haber: haber)),
      );
    } catch (e) {
      debugPrint('Bildirimden haber açma hatası: $e');
      _bildirimSayfasiniAc(
        'Haber açılamadı',
        'Haber şu anda alınamıyor. Lütfen tekrar deneyin.',
      );
    }
  }

  static Future<void> _ucretsizHaberBildirimleriniBaslat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final kayitliIdler = prefs.getStringList(_bilinenHaberIdleriAnahtari) ?? <String>[];
      final ilklendi = prefs.getBool(_haberBildirimIlklendiAnahtari) ?? false;
      final bilinenIdler = <String>{...kayitliIdler};

      // İlk çalıştırmada mevcut haberleri bildirim olarak yağdırma.
      final ilkSorgu = await FirebaseFirestore.instance
          .collection('haberler')
          .where('yayinlandi', isEqualTo: true)
          .orderBy('tarih', descending: true)
          .limit(_bildirimDinlemeLimiti)
          .get();

      ilkSorgu.docs.sort((a, b) {
        final aTarih = (a.data()['tarih'] is Timestamp)
            ? (a.data()['tarih'] as Timestamp).toDate()
            : DateTime.fromMillisecondsSinceEpoch(0);
        final bTarih = (b.data()['tarih'] is Timestamp)
            ? (b.data()['tarih'] as Timestamp).toDate()
            : DateTime.fromMillisecondsSinceEpoch(0);
        return bTarih.compareTo(aTarih);
      });

      if (!ilklendi) {
        final mevcutIdler = ilkSorgu.docs.map((doc) => doc.id).toList();
        await prefs.setStringList(
          _bilinenHaberIdleriAnahtari,
          mevcutIdler,
        );
        await prefs.setBool(_haberBildirimIlklendiAnahtari, true);
      } else {
        final yeniHaberler = ilkSorgu.docs
            .where((doc) => !bilinenIdler.contains(doc.id))
            .map(Haber.fromFirestore)
            .where((haber) => haber.yayinlandi)
            .toList();

        // Eskiden yeniye sırala; kullanıcıya bildirimler mantıklı sırada gelsin.
        yeniHaberler.sort((a, b) => a.tarih.compareTo(b.tarih));
        if (haberlerAktif) {
          for (final haber in yeniHaberler) {
            await _yerelHaberBildirimiGoster(haber);
          }
        }

        bilinenIdler.addAll(ilkSorgu.docs.map((doc) => doc.id));
        final sonIdler = bilinenIdler.toList();
        if (sonIdler.length > 100) {
          sonIdler.removeRange(0, sonIdler.length - 100);
        }
        await prefs.setStringList(_bilinenHaberIdleriAnahtari, sonIdler);
      }

      await _haberDinleme?.cancel();
      _haberDinlemeIlkSnapshot = true;
      _haberDinleme = FirebaseFirestore.instance
          .collection('haberler')
          .where('yayinlandi', isEqualTo: true)
          // DÜZELTME: limit yokken koleksiyondaki tüm yayınlanmış haberler
          // her açılışta indiriliyordu. Bildirim üretmek için sadece en yeni
          // kayıtlar gerekli; Firestore okuma maliyeti sabit kalıyor.
          .orderBy('tarih', descending: true)
          .limit(_bildirimDinlemeLimiti)
          .snapshots()
          .listen((snapshot) async {
        if (_haberDinlemeIlkSnapshot) {
          _haberDinlemeIlkSnapshot = false;
          return;
        }

        final mevcutPrefs = await SharedPreferences.getInstance();
        final idler = <String>{
          ...(mevcutPrefs.getStringList(_bilinenHaberIdleriAnahtari) ?? <String>[]),
        };

        // Sadece sorguya yeni dahil olan belgeler bildirim üretir.
        // Böylece mevcut bir haberin başlık/özet düzenlemesi tekrar bildirilmez.
        final yeniHaberler = snapshot.docChanges
            .where((degisim) => degisim.type == DocumentChangeType.added)
            .where((degisim) => !idler.contains(degisim.doc.id))
            .map((degisim) => Haber.fromFirestore(degisim.doc))
            .where((haber) => haber.yayinlandi)
            .toList();

        yeniHaberler.sort((a, b) => a.tarih.compareTo(b.tarih));
        if (haberlerAktif) {
          for (final haber in yeniHaberler) {
            await _yerelHaberBildirimiGoster(haber);
          }
        }

        final yeniIdler = snapshot.docs.map((doc) => doc.id);
        idler.addAll(yeniIdler);
        final sonIdler = idler.toList();
        if (sonIdler.length > 100) {
          sonIdler.removeRange(0, sonIdler.length - 100);
        }
        await mevcutPrefs.setStringList(_bilinenHaberIdleriAnahtari, sonIdler);
      });
    } catch (e) {
      debugPrint('Ücretsiz haber bildirim kontrolü hatası: $e');
    }
  }

  static Future<void> _yerelHaberBildirimiGoster(Haber haber) async {
    await BildirimGecmisi.kaydetMetin(
      baslik: '📰 ${haber.baslik}',
      govde: haber.ozet.isNotEmpty
          ? haber.ozet
          : 'Yeni bir haber yayınlandı.',
      mesajId: 'haber-${haber.id}',
    );

    final payload = jsonEncode(<String, dynamic>{
      'haberId': haber.id,
      'title': haber.baslik,
      'body': haber.ozet,
    });

    await _localNotifications.show(
      id: haber.id.hashCode & 0x7fffffff,
      title: '📰 Yeni Haber',
      body: haber.baslik,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _bildirimKanali.id,
          _bildirimKanali.name,
          channelDescription: _bildirimKanali.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: payload,
    );
  }

  static Future<void> _konuAboneliginiUygula(String konu, bool aktif) async {
    Object? sonHata;

    for (var deneme = 1; deneme <= 3; deneme++) {
      try {
        if (aktif) {
          await FirebaseMessaging.instance.subscribeToTopic(konu);
          debugPrint('FCM konu aboneliği başarılı: $konu');
        } else {
          await FirebaseMessaging.instance.unsubscribeFromTopic(konu);
          debugPrint('FCM konu aboneliği kapatıldı: $konu');
        }
        return;
      } catch (e) {
        sonHata = e;
        debugPrint('FCM konu aboneliği başarısız ($konu) deneme $deneme/3: $e');
        if (deneme < 3) {
          await Future<void>.delayed(Duration(seconds: deneme * 2));
        }
      }
    }

    // Bir konu başarısız olduğunda diğer bildirim konularının çalışmasını
    // engelleme. Son hatayı logla ve başlatmayı sürdür.
    debugPrint('FCM konu aboneliği son hata ($konu): $sonHata');
  }

  static Future<void> konuAboneligiDegistir(
    String konu,
    bool aktif,
  ) async {
    try {
      await _konuAboneliginiUygula(konu, aktif);
    } catch (e) {
      debugPrint('Bildirim konusu değiştirilemedi: $e');
    }
  }
}

class BildirimGecmisiSayfasi extends StatefulWidget {
  const BildirimGecmisiSayfasi({super.key});

  @override
  State<BildirimGecmisiSayfasi> createState() => _BildirimGecmisiSayfasiState();
}

class _BildirimGecmisiSayfasiState extends State<BildirimGecmisiSayfasi> {
  List<Map<String, dynamic>> bildirimler = <Map<String, dynamic>>[];
  bool yukleniyor = true;

  @override
  void initState() {
    super.initState();
    _yukle();
  }

  Future<void> _yukle() async {
    final liste = await BildirimGecmisi.oku();
    if (!mounted) return;
    setState(() {
      bildirimler = liste;
      yukleniyor = false;
    });
  }

  String _tarihGoster(String? tarih) {
    final dt = DateTime.tryParse(tarih ?? '')?.toLocal();
    if (dt == null) return '';
    final gun = dt.day.toString().padLeft(2, '0');
    final ay = dt.month.toString().padLeft(2, '0');
    final saat = dt.hour.toString().padLeft(2, '0');
    final dakika = dt.minute.toString().padLeft(2, '0');
    return '$gun.$ay.${dt.year} $saat:$dakika';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Bildirimler',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: yukleniyor
          ? const Center(child: CircularProgressIndicator(color: anaYesil))
          : bildirimler.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_none, size: 64, color: Colors.grey.shade400),
                        const SizedBox(height: 16),
                        const Text(
                          'Henüz bildirim yok',
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 7),
                        const Text(
                          'Uygulamaya gelen bildirimler burada sıralanacak.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: gri, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  color: anaYesil,
                  onRefresh: _yukle,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: bildirimler.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final bildirim = bildirimler[index];
                      final baslik = bildirim['title']?.toString() ?? 'Yalova Wonder Kids';
                      final govde = bildirim['body']?.toString() ?? '';
                      final tarih = _tarihGoster(bildirim['tarih']?.toString());

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BildirimDetaySayfasi(
                                  baslik: baslik,
                                  govde: govde,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: acikYesil,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.notifications_active,
                                    color: anaYesil,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        baslik,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          color: siyah,
                                        ),
                                      ),
                                      if (govde.isNotEmpty) ...[
                                        const SizedBox(height: 5),
                                        Text(
                                          govde,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            height: 1.35,
                                            color: gri,
                                          ),
                                        ),
                                      ],
                                      if (tarih.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          tarih,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: gri,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(Icons.chevron_right, color: gri),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class BildirimDetaySayfasi extends StatelessWidget {
  final String baslik;
  final String govde;

  const BildirimDetaySayfasi({
    super.key,
    required this.baslik,
    required this.govde,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bildirim')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.notifications_active, color: anaYesil, size: 36),
                const SizedBox(height: 16),
                Text(
                  baslik,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  govde,
                  style: const TextStyle(fontSize: 16, height: 1.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ANA SAYFA
// ============================================================

class AnaSayfa extends StatefulWidget {
  const AnaSayfa({super.key});

  @override
  State<AnaSayfa> createState() => _AnaSayfaState();
}

class _AnaSayfaState extends State<AnaSayfa> {
  int seciliIndex = 0;
  bool kontrolYapiliyor = false;
  int _gizliYoneticiDokunus = 0;
  Timer? _gizliYoneticiTimer;

  void _gizliYoneticiGiris() {
    _gizliYoneticiDokunus++;
    _gizliYoneticiTimer?.cancel();
    _gizliYoneticiTimer = Timer(const Duration(seconds: 2), () {
      _gizliYoneticiDokunus = 0;
    });

    if (_gizliYoneticiDokunus >= 7) {
      _gizliYoneticiDokunus = 0;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const YoneticiGirisSayfasi()),
      );
    }
  }

  @override
  void dispose() {
    _gizliYoneticiTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // Ana sayfa açıldıktan kısa süre sonra güncelleme kontrolü.
    // DÜZELTME: Bildirim servisi de aynı şekilde ilk frame
    // basıldıktan SONRA başlatılıyor; artık izin diyalogları
    // uygulamanın açılışını (siyah ekranı) bloklamıyor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guncellemeKontrolEt();
      BildirimServisi.baslat();
    });
  }

  // ============================================================
  // GÜNCELLEME KONTROLÜ
  // ============================================================

  Future<void> _guncellemeKontrolEt() async {
    if (kontrolYapiliyor) return;

    if (mounted) {
      setState(() {
        kontrolYapiliyor = true;
      });
    }

    try {
      final response = await http
          .get(Uri.parse(versionUrl))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return;
      }

      String yeniSurum = response.body.trim();

      // Google Drive / GitHub bazen metnin başına/sonuna
      // görünmez karakter koyabilir.
      yeniSurum = yeniSurum.replaceAll('\n', '').replaceAll('\r', '').trim();

      if (yeniSurum.isEmpty) return;

      if (_surumDahaYeniMi(uygulamaSurumu, yeniSurum)) {
        if (!mounted) return;

        final apkResponse = await http
            .get(Uri.parse(apkUrlUrl))
            .timeout(const Duration(seconds: 8));

        if (apkResponse.statusCode != 200) return;

        final yeniApkUrl = apkResponse.body.trim();
        if (yeniApkUrl.isEmpty) return;

        // Yalnızca https ve bilinen bir GitHub/Release kaynağından
        // gelen bağlantıları kabul et. Bu, apk_url.txt dosyası
        // beklenmedik şekilde değiştirilirse (ör. hesap ele geçirme)
        // kullanıcının rastgele bir siteye yönlendirilmesini engeller.
        if (!_apkUrlGuvenilirMi(yeniApkUrl)) {
          return;
        }

        // Yayınlanan APK'nın beklenen SHA-256 özetini çek (opsiyonel).
        // Dosya yoksa veya boşsa, hash kontrolü atlanır fakat
        // kullanıcı yine de indirmeden önce bilgilendirilir.
        String? beklenenHash;
        try {
          final hashResponse = await http
              .get(Uri.parse(apkHashUrl))
              .timeout(const Duration(seconds: 8));

          if (hashResponse.statusCode == 200) {
            final temiz = hashResponse.body.trim().toLowerCase();
            if (temiz.length == 64) {
              beklenenHash = temiz;
            }
          }
        } catch (_) {
          // Hash dosyası alınamazsa sessizce devam et.
        }

        if (!mounted) return;

        await _guncellemePenceresiGoster(
          yeniSurum,
          yeniApkUrl,
          beklenenHash,
        );
      }
    } catch (_) {
      // Güncelleme kontrolü başarısız olursa
      // uygulama normal şekilde çalışmaya devam eder.
    } finally {
      if (mounted) {
        setState(() {
          kontrolYapiliyor = false;
        });
      }
    }
  }

  bool _apkUrlGuvenilirMi(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;

    const izinliHostler = <String>{
      'github.com',
      'raw.githubusercontent.com',
      'objects.githubusercontent.com',
    };

    return izinliHostler.contains(uri.host);
  }

  bool _surumDahaYeniMi(String mevcut, String yeni) {
    try {
      final mevcutParcalar = mevcut.split('.').map(int.parse).toList();
      final yeniParcalar = yeni.split('.').map(int.parse).toList();

      final uzunluk = mevcutParcalar.length > yeniParcalar.length
          ? mevcutParcalar.length
          : yeniParcalar.length;

      for (int i = 0; i < uzunluk; i++) {
        final mevcutSayi = i < mevcutParcalar.length ? mevcutParcalar[i] : 0;
        final yeniSayi = i < yeniParcalar.length ? yeniParcalar[i] : 0;

        if (yeniSayi > mevcutSayi) return true;
        if (yeniSayi < mevcutSayi) return false;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _guncellemePenceresiGoster(
    String yeniSurum,
    String yeniApkUrl,
    String? beklenenHash,
  ) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Row(
            children: [
              Icon(Icons.system_update, color: anaYesil),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Yeni sürüm mevcut',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          content: Text(
            'Yalova Wonder Kids uygulamasının '
            '$yeniSurum sürümü yayınlandı.\n\n'
            'Mevcut sürüm: $uygulamaSurumu\n'
            'Yeni sürüm: $yeniSurum\n\n'
            'Yeni sürümü indirerek uygulamanı güncelleyebilirsin.'
            '${beklenenHash == null ? '\n\nNot: Bu sürüm için bütünlük doğrulaması yapılamadı.' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Daha sonra'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await _apkIndirVeAc(context, yeniApkUrl, beklenenHash);
              },
              icon: const Icon(Icons.download),
              label: const Text('Güncelle'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _apkIndirVeAc(
    BuildContext context,
    String apkUrl,
    String? beklenenHash,
  ) async {
    // Hash bilgisi yoksa doğrulama yapılamaz; doğrudan tarayıcı/harici
    // uygulamaya yönlendir (eski davranış, geriye dönük uyumluluk için).
    if (beklenenHash == null) {
      final uri = Uri.parse(apkUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

    // İlerleme göstergesi ile indirme + doğrulama.
    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: anaYesil),
            SizedBox(width: 20),
            Expanded(child: Text('APK doğrulanıyor...')),
          ],
        ),
      ),
    );

    try {
      final response = await http
          .get(Uri.parse(apkUrl))
          .timeout(const Duration(seconds: 60));

      if (context.mounted) {
        Navigator.pop(context); // ilerleme diyaloğunu kapat
      }

      if (response.statusCode != 200) {
        _hataGoster(context, 'APK indirilemedi (HTTP ${response.statusCode}).');
        return;
      }

      final hesaplananHash = sha256.convert(response.bodyBytes).toString();

      if (hesaplananHash.toLowerCase() != beklenenHash.toLowerCase()) {
        _hataGoster(
          context,
          'Güvenlik uyarısı: indirilen dosyanın bütünlüğü doğrulanamadı. '
          'Güncelleme iptal edildi.',
        );
        return;
      }

      // Doğrulama başarılı: harici tarayıcı/indirici ile aç.
      final uri = Uri.parse(apkUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
      }
      _hataGoster(context, 'Güncelleme sırasında bir hata oluştu.');
    }
  }

  void _hataGoster(BuildContext context, String mesaj) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mesaj)),
    );
  }

  // ============================================================
  // ALT MENÜ
  // ============================================================

  void _menuDegistir(int index) {
    if (index == 0) {
      setState(() {
        seciliIndex = 0;
      });
      return;
    }

    if (index == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
      );
      return;
    }

    if (index == 2) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const TakimlarSayfasi(),
        ),
      );
      return;
    }

    if (index == 3) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const MaclarSayfasi(),
        ),
      );
      return;
    }

    if (index == 4) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HaberlerSayfasi()),
      );
    }
  }

  // ============================================================
  // ANA SAYFA
  // ============================================================

  @override
Widget build(BuildContext context) {
  return Scaffold(
    backgroundColor: const Color(0xFFF4F6F5),
    drawer: _yanMenu(),
    body: SafeArea(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _ywkMarkaBasligi(),
          _ywkHero(),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ywkMenuGrid(),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ywkQuizBanner(),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _sonHaberler(),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              'Yalova Wonder Kids  •  v$uygulamaSurumu',
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF8B938F),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
      ),
    ),
    bottomNavigationBar: _altMenu(),
  );
}

  Widget _ywkMarkaBasligi() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        children: [
          Row(
            children: [
              Builder(
                builder: (context) => InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Scaffold.of(context).openDrawer(),
                  child: const SizedBox(
                    width: 38,
                    height: 54,
                    child: Icon(
                      Icons.menu_rounded,
                      color: Color(0xFF173D2B),
                      size: 27,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _gizliYoneticiGiris,
                child: Image.asset(
                  'assets/yalova_wonder_kids_logo.png',
                  width: 76,
                  height: 64,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 76,
                    height: 64,
                    child: Icon(
                      Icons.sports_soccer,
                      size: 40,
                      color: anaYesil,
                    ),
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                color: Color(0xFFD9DEDB),
              ),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'YALOVA’NIN GENÇ',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF173D2B),
                        letterSpacing: .2,
                      ),
                    ),
                    Text(
                      'YETENEKLERİ',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF173D2B),
                        letterSpacing: .2,
                      ),
                    ),
                    Text(
                      'BURADA',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF159447),
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BildirimGecmisiSayfasi(),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.notifications_none_rounded,
                    color: Color(0xFF173D2B),
                    size: 26,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _ywkUstKisayol(
                  icon: Icons.emoji_events_outlined,
                  text: 'Ligler',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _ywkUstKisayol(
                  icon: Icons.groups_2_outlined,
                  text: 'Takımlar',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TakimlarSayfasi()),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _ywkUstKisayol(
                  icon: Icons.calendar_month_outlined,
                  text: 'Haftalık\nFikstür',
                  vurgulu: true,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HaftalikFiksturSayfasi(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _ywkUstKisayol(
                  icon: Icons.newspaper_outlined,
                  text: 'Haberler',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HaberlerSayfasi()),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ywkUstKisayol({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    bool vurgulu = false,
  }) {
    return Material(
      color: vurgulu ? const Color(0xFFE0F2E5) : const Color(0xFFF7F9F8),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE5EAE7)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: const Color(0xFF0B6B3C), size: 23),
              const SizedBox(height: 5),
              Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1.05,
                  color: Color(0xFF173D2B),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  Widget _ywkHero() {
    return Container(
      height: 260,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF184C34),
            Color(0xFF0B3A25),
            Color(0xFF062719),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -30,
            bottom: -35,
            child: Icon(
              Icons.sports_soccer_rounded,
              size: 215,
              color: Colors.white.withOpacity(.055),
            ),
          ),
          Positioned(
            right: 18,
            top: 20,
            child: Opacity(
              opacity: .16,
              child: Image.asset(
                'assets/yalova_wonder_kids_logo.png',
                width: 145,
                height: 145,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 30, 24, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DAHA FAZLA',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    height: 1,
                  ),
                ),
                const Text(
                  'GENÇ DAHA FAZLA',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    height: 1.08,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'YALOVA',
                  style: TextStyle(
                    color: Color(0xFF8DDB42),
                    fontSize: 47,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    letterSpacing: -1.5,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 10),
                const SizedBox(
                  width: 275,
                  child: Text(
                    'Yalova’nın genç sporcuları, yarınların büyük hikâyelerini yazıyor.',
                    style: TextStyle(
                      color: Color(0xFFE7F0EB),
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    _ywkHeroButon(
                      Icons.emoji_events_outlined,
                      'Ligleri İncele',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ywkHeroButon(
                      Icons.sports_soccer_outlined,
                      'Maçları Gör',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const MaclarSayfasi()),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ywkHeroButon(IconData icon, String text, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: const Color(0xFF0B5B35), size: 18),
              const SizedBox(width: 7),
              Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF173D2B),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ywkMenuGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ywkMenuKarti(
                Icons.emoji_events_outlined,
                'Ligler',
                'Puan durumları,\nfikstürler, istatistikler',
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ywkMenuKarti(
                Icons.groups_2_outlined,
                'Takımlar',
                'Yalova’nın takımları\nve kadrolar',
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TakimlarSayfasi()),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ywkMenuKarti(
                Icons.calendar_month_outlined,
                'Haftalık Fikstür',
                'Bu haftanın\nmaçları',
                () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const HaftalikFiksturSayfasi(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ywkMenuKarti(
                Icons.newspaper_outlined,
                'Haberler',
                'Yalova futbolundan\nson gelişmeler',
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HaberlerSayfasi()),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ywkMenuKarti(
    IconData icon,
    String baslik,
    String aciklama,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 132,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE3E8E5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.025),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFF0B6B3C), size: 30),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      baslik,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF17221C),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF0B6B3C),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                aciklama,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.25,
                  color: Color(0xFF65716A),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ywkQuizBanner() {
    return Material(
      color: const Color(0xFF073D25),
      borderRadius: BorderRadius.circular(21),
      child: InkWell(
        borderRadius: BorderRadius.circular(21),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FutbolBilgiTestiSayfasi()),
        ),
        child: Container(
          height: 152,
          padding: const EdgeInsets.fromLTRB(14, 14, 15, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(21),
            gradient: const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xFF063A23), Color(0xFF0A6738)],
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 118,
                child: Image.asset(
                  'assets/yalova_wonder_kids_logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.sports_soccer,
                    color: Colors.white,
                    size: 72,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Futbol Bilgini Test Et',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        height: 1.02,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Kaç soruda kaç doğru\nyapabileceksin?',
                      style: TextStyle(
                        color: Color(0xFFD2E3D9),
                        fontSize: 10.5,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0FA552),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Hemen Başla',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  Widget _profesyonelUstBaslik() {
    return Row(
      children: [
        Builder(
          builder: (context) => _ustIkonButonu(
            icon: Icons.menu_rounded,
            tooltip: 'Menüyü aç',
            onTap: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: _gizliYoneticiGiris,
          child: Container(
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE3E8E5)),
            ),
            child: Image.asset(
              'assets/yalova_wonder_kids_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.shield_outlined,
                color: anaYesil,
              ),
            ),
          ),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YALOVA WONDER KIDS',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.35,
                  color: Color(0xFF15221B),
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Yalova genç futbol platformu',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7B8780),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _ustIkonButonu(
          icon: Icons.notifications_none_rounded,
          tooltip: 'Bildirimler',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const BildirimGecmisiSayfasi(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _ustIkonButonu({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE3E8E5)),
          ),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, color: const Color(0xFF163A28), size: 23),
          ),
        ),
      ),
    );
  }

  Widget _profesyonelHero() {
    return Container(
      height: 232,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0A6136),
            Color(0xFF063C24),
            Color(0xFF032B1A),
          ],
          stops: [0.0, 0.58, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF063C24).withOpacity(0.20),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned(
              right: -34,
              bottom: -46,
              child: Icon(
                Icons.sports_soccer_rounded,
                size: 210,
                color: Colors.white.withOpacity(0.045),
              ),
            ),
            Positioned(
              right: 18,
              top: 17,
              child: Opacity(
                opacity: 0.22,
                child: Image.asset(
                  'assets/yalova_wonder_kids_logo.png',
                  width: 105,
                  height: 105,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.11),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.12),
                      ),
                    ),
                    child: const Text(
                      '2026 • 2027 SEZONU',
                      style: TextStyle(
                        color: Color(0xFFD7EADF),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  const SizedBox(
                    width: 245,
                    child: Text(
                      'Yalova futbolunun nabzı burada.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        height: 1.08,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  const SizedBox(
                    width: 270,
                    child: Text(
                      'Ligler, takımlar, maçlar ve genç yetenekler tek platformda.',
                      style: TextStyle(
                        color: Color(0xFFC9D9D0),
                        fontSize: 12,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      _heroAksiyon(
                        icon: Icons.emoji_events_outlined,
                        text: 'Ligleri İncele',
                        dolu: true,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LiglerSayfasi(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 9),
                      _heroAksiyon(
                        icon: Icons.sports_soccer_outlined,
                        text: 'Maçlar',
                        dolu: false,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const MaclarSayfasi(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroAksiyon({
    required IconData icon,
    required String text,
    required bool dolu,
    required VoidCallback onTap,
  }) {
    return Material(
      color: dolu ? Colors.white : Colors.white.withOpacity(0.10),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: dolu
                ? null
                : Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: dolu ? const Color(0xFF064B2A) : Colors.white,
              ),
              const SizedBox(width: 7),
              Text(
                text,
                style: TextStyle(
                  color: dolu ? const Color(0xFF064B2A) : Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bolumBasligi(String baslik, String aciklama) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                baslik,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF17221C),
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                aciklama,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF87918C),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _profesyonelHizliErisim() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _profesyonelErisimKarti(
                ikon: Icons.emoji_events_outlined,
                baslik: 'Ligler',
                aciklama: 'Puan & sezon',
                vurgu: const Color(0xFF0A6B3D),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _profesyonelErisimKarti(
                ikon: Icons.groups_2_outlined,
                baslik: 'Takımlar',
                aciklama: 'Kadrolar & profil',
                vurgu: const Color(0xFF2D5575),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TakimlarSayfasi()),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _profesyonelErisimKarti(
                ikon: Icons.sports_soccer_outlined,
                baslik: 'Maçlar',
                aciklama: 'Fikstür & sonuç',
                vurgu: const Color(0xFF9A6326),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MaclarSayfasi()),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _profesyonelErisimKarti(
                ikon: Icons.newspaper_outlined,
                baslik: 'Haberler',
                aciklama: 'Son gelişmeler',
                vurgu: const Color(0xFF8B3A3A),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HaberlerSayfasi()),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _profesyonelErisimKarti({
    required IconData ikon,
    required String baslik,
    required String aciklama,
    required Color vurgu,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE4E9E6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: vurgu.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(ikon, color: vurgu, size: 22),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.north_east_rounded,
                    color: Color(0xFFB0B8B3),
                    size: 18,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                baslik,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF19241E),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                aciklama,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF89928D),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profesyonelQuizKarti() {
    return Material(
      color: const Color(0xFF17221C),
      borderRadius: BorderRadius.circular(23),
      child: InkWell(
        borderRadius: BorderRadius.circular(23),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const FutbolBilgiTestiSayfasi(),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: const Color(0xFF25362D)),
          ),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFF254534),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.quiz_outlined,
                  color: Color(0xFFE8F5ED),
                  size: 29,
                ),
              ),
              const SizedBox(width: 15),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Futbol Bilgini Test Et',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '10 soru  •  100 puan  •  Yeni rekor',
                      style: TextStyle(
                        color: Color(0xFFAEBDB5),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                  size: 19,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profesyonelAltBilgi() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF1ED),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.verified_outlined,
            size: 20,
            color: Color(0xFF2A6647),
          ),
          SizedBox(width: 11),
          Expanded(
            child: Text(
              'Yalova amatör futbolunu tek yerde takip et.',
              style: TextStyle(
                color: Color(0xFF31513F),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _yanMenu() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
              decoration: const BoxDecoration(color: anaYesil),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Image.asset(
                      'assets/yalova_wonder_kids_logo.png',
                      fit: BoxFit.contain,
                      // DÜZELTME: asset bulunamazsa (pubspec.yaml'a
                      // eklenmemişse) uygulama çökmesin diye bir
                      // yedek gösterge ekliyoruz.
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(
                          Icons.shield_outlined,
                          color: anaYesil,
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Yalova Wonder Kids',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Yalova amatör futbol',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _menuItem(
              context,
              icon: Icons.home_outlined,
              title: 'Ana Sayfa',
              onTap: () {
                Navigator.pop(context);
              },
            ),
            _menuItem(
              context,
              icon: Icons.emoji_events_outlined,
              title: 'Ligler',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
                );
              },
            ),
            _menuItem(
              context,
              icon: Icons.groups_outlined,
              title: 'Takımlar',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TakimlarSayfasi()),
                );
              },
            ),
            _menuItem(
              context,
              icon: Icons.calendar_month_outlined,
              title: 'Fikstür',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BilgiSayfasi(
                      baslik: 'Fikstür',
                      mesaj: 'Fikstür bölümü hazırlanıyor.',
                    ),
                  ),
                );
              },
            ),
            _menuItem(
              context,
              icon: Icons.notifications_outlined,
              title: 'Bildirim Ayarları',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BildirimAyarlariSayfasi(),
                  ),
                );
              },
            ),
            _menuItem(
              context,
              icon: Icons.mail_outline,
              title: 'İletişim',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const IletisimSayfasi()),
                );
              },
            ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Yalova Wonder Kids',
                style: TextStyle(color: gri, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 3),
      leading: Icon(icon, color: anaYesil),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: siyah,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: gri, size: 20),
      onTap: onTap,
    );
  }

  Widget _ustBaslik() {
    return Row(
      children: [
        Builder(
          builder: (context) {
            return Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: acikYesil,
                borderRadius: BorderRadius.circular(13),
              ),
              child: IconButton(
                tooltip: 'Menüyü aç',
                onPressed: () {
                  Scaffold.of(context).openDrawer();
                },
                icon: const Icon(Icons.menu, color: anaYesil),
              ),
            );
          },
        ),
        const SizedBox(width: 10),
        Container(
          width: 46,
          height: 46,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.07),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: GestureDetector(
            onTap: _gizliYoneticiGiris,
            child: Image.asset(
              'assets/yalova_wonder_kids_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(Icons.shield_outlined, color: anaYesil);
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Yalova Wonder Kids',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  color: siyah,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Yalova amatör futbol',
                style: TextStyle(
                  fontSize: 12,
                  color: gri,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: acikYesil,
            borderRadius: BorderRadius.circular(13),
          ),
          child: IconButton(
            tooltip: 'Bildirimler',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BildirimGecmisiSayfasi(),
                ),
              );
            },
            icon: const Icon(Icons.notifications_none, color: anaYesil),
          ),
        ),
      ],
    );
  }

  Widget _heroAlani() {
    return Container(
      height: 205,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
        ),
        boxShadow: [
          BoxShadow(
            color: anaYesil.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -25,
            bottom: -25,
            child: Icon(
              Icons.sports_soccer,
              size: 170,
              color: Colors.white.withOpacity(0.08),
            ),
          ),
          Positioned(
            right: 22,
            top: 20,
            child: Image.asset(
              'assets/yalova_wonder_kids_logo.png',
              width: 105,
              height: 105,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const SizedBox(width: 105, height: 105);
              },
            ),
          ),
          const Positioned(
            left: 22,
            top: 25,
            right: 125,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YALOVA',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Amatör Futbol',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    height: 1.05,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'Ligler, puan durumları ve futbol dünyası burada.',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
          Positioned(
            left: 22,
            bottom: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(30),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.emoji_events, color: Colors.white, size: 17),
                  SizedBox(width: 7),
                  Text(
                    '2026-2027 Sezonu',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hizliErisimBaslik() {
    return const Row(
      children: [
        Text(
          'Hızlı Erişim',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: siyah),
        ),
        Spacer(),
        Icon(Icons.arrow_forward, size: 18, color: gri),
      ],
    );
  }

  Widget _liglerKarti() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LiglerSayfasi()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                width: 55,
                height: 55,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(Icons.emoji_events, color: anaYesil, size: 29),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ligler',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: siyah,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Sezonlara göre ligleri ve puan durumlarını gör',
                      style: TextStyle(fontSize: 12, color: gri),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 17, color: gri),
            ],
          ),
        ),
      ),
    );
  }

  Widget _takimlarKarti() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TakimlarSayfasi()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: anaYesil.withOpacity(0.12),
                child: const Icon(Icons.groups_outlined, color: anaYesil, size: 28),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Takımlar',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Takım kadroları, puan durumu ve maçlar',
                      style: TextStyle(fontSize: 11, color: gri),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: gri, size: 17),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kucukMenuKarti({
    required IconData ikon,
    required String baslik,
    String aciklama = 'Yakında',
    required Color renk,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: renk.withOpacity(0.12),
                child: Icon(ikon, color: renk, size: 25),
              ),
              const SizedBox(height: 12),
              Text(
                baslik,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(aciklama, style: const TextStyle(fontSize: 11, color: gri)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _futbolQuizKarti() {
    return Material(
      color: anaYesil,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const FutbolBilgiTestiSayfasi(),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(
                  Icons.quiz_outlined,
                  color: Colors.white,
                  size: 31,
                ),
              ),
              const SizedBox(width: 15),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Futbol Bilgini Test Et',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(width: 7),
                        Icon(Icons.sports_soccer, color: Colors.white, size: 18),
                      ],
                    ),
                    SizedBox(height: 5),
                    Text(
                      '10 soru • 100 puan • Rekorunu geliştir',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 17),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sonHaberler() {
    // DÜZELTME: ekranda yalnızca 3 haber gösterildiği hâlde tüm koleksiyon
    // indiriliyor ve istemcide sıralanıyordu. Sıralama ve sınır artık sunucuda.
    final stream = FirebaseFirestore.instance
        .collection('haberler')
        .where('yayinlandi', isEqualTo: true)
        .orderBy('tarih', descending: true)
        .limit(3)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError || snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        final haberler = snapshot.data?.docs
                .map(Haber.fromFirestore)
                .where((haber) => haber.yayinlandi)
                .toList() ??
            <Haber>[];
        haberler.sort((a, b) => b.tarih.compareTo(a.tarih));
        final sonHaberler = haberler.take(3).toList();

        if (sonHaberler.isEmpty) return const SizedBox.shrink();

        final oneCikan = sonHaberler.first;
        final digerHaberler = sonHaberler.skip(1).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Son Haberler',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: siyah,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const HaberlerSayfasi()),
                    );
                  },
                  child: const Text('Tümünü Gör'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _oneCikanHaberKarti(oneCikan),
            if (digerHaberler.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...digerHaberler.map(
                (haber) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _anaSayfaHaberKarti(haber),
                ),
              ),
            ],
          ],
        );
      },
    ); // StreamBuilder
    }

Widget _oneCikanHaberKarti(Haber haber) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => HaberDetaySayfasi(haber: haber)),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Stack(
                children: [
                  if (haber.resimUrl.isNotEmpty)
                    Image.network(
                      haber.resimUrl,
                      width: double.infinity,
                      height: 190,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _oneCikanHaberIkon(),
                    )
                  else
                    _oneCikanHaberIkon(),
                  Positioned(
                    left: 14,
                    top: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.94),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        haber.kategori.isNotEmpty ? haber.kategori : 'Genel',
                        style: const TextStyle(
                          fontSize: 10,
                          color: koyuYesil,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: anaYesil,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.arrow_forward,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    haber.baslik,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      height: 1.15,
                      color: siyah,
                    ),
                  ),
                  if (haber.ozet.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      haber.ozet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: gri,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 14, color: gri),
                      const SizedBox(width: 5),
                      Text(
                        HaberlerSayfasi._haberTarihi(haber.tarih),
                        style: const TextStyle(
                          fontSize: 10,
                          color: gri,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (haber.yazar.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        const Text('•', style: TextStyle(color: gri)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            haber.yazar,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: gri,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _oneCikanHaberIkon() {
    return Container(
      width: double.infinity,
      height: 190,
      decoration: BoxDecoration(
        color: acikYesil,
      ),
      child: const Center(
        child: Icon(Icons.newspaper, color: anaYesil, size: 58),
      ),
    );
  }

  Widget _anaSayfaHaberKarti(Haber haber) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => HaberDetaySayfasi(haber: haber)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: haber.resimUrl.isNotEmpty
                    ? Image.network(
                        haber.resimUrl,
                        width: 96,
                        height: 76,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _anaSayfaHaberIkon(),
                      )
                    : _anaSayfaHaberIkon(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: acikYesil,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              haber.kategori.isNotEmpty ? haber.kategori : 'Genel',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 9,
                                color: koyuYesil,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      haber.baslik,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      HaberlerSayfasi._haberTarihi(haber.tarih),
                      style: const TextStyle(
                        fontSize: 10,
                        color: gri,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: gri, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _anaSayfaHaberIkon() {
    return Container(
      width: 96,
      height: 76,
      decoration: BoxDecoration(
        color: acikYesil,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(Icons.newspaper, color: anaYesil, size: 32),
    );
  }

  Widget _bilgiKutusu() {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: acikYesil,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: anaYesil),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Yalova amatör futbol liglerini tek uygulamada takip edin.',
              style: TextStyle(color: koyuYesil, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _altMenu() {
    return NavigationBar(
      selectedIndex: seciliIndex,
      onDestinationSelected: _menuDegistir,
      backgroundColor: Colors.white,
      elevation: 8,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Ana Sayfa',
        ),
        NavigationDestination(
          icon: Icon(Icons.emoji_events_outlined),
          selectedIcon: Icon(Icons.emoji_events),
          label: 'Ligler',
        ),
        NavigationDestination(
          icon: Icon(Icons.groups_outlined),
          selectedIcon: Icon(Icons.groups),
          label: 'Takımlar',
        ),
        NavigationDestination(
          icon: Icon(Icons.sports_soccer_outlined),
          selectedIcon: Icon(Icons.sports_soccer),
          label: 'Maçlar',
        ),
        NavigationDestination(
          icon: Icon(Icons.newspaper_outlined),
          selectedIcon: Icon(Icons.newspaper),
          label: 'Haberler',
        ),
      ],
    );
  }
}


class HaftalikFiksturSayfasi extends StatelessWidget {
  const HaftalikFiksturSayfasi({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Haftalık Fikstür',
          style: TextStyle(
            color: Color(0xFF17221C),
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE2E8E4)),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  size: 56,
                  color: Color(0xFF0B6B3C),
                ),
                SizedBox(height: 16),
                Text(
                  'Haftalık Fikstür',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF17221C),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Henüz yayınlanmadı',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7A8580),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


// ============================================================
// TAKIM KADROSU / FUTBOLCU DETAYI
// ============================================================

class FutbolcuBilgisi {
  final String id;
  final String adSoyad;
  final int dogumYili;
  final String takimId;
  final String takim;
  final String pozisyon;
  final int formaNo;
  final String fotografUrl;

  const FutbolcuBilgisi({
    required this.id,
    required this.adSoyad,
    required this.dogumYili,
    required this.takimId,
    required this.takim,
    required this.pozisyon,
    required this.formaNo,
    required this.fotografUrl,
  });

  factory FutbolcuBilgisi.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? <String, dynamic>{};

    int sayi(dynamic value) {
      if (value is int) return value;
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return FutbolcuBilgisi(
      id: doc.id,
      adSoyad: data['adSoyad']?.toString().trim() ?? '',
      dogumYili: sayi(data['dogumYili']),
      takimId: data['takimId']?.toString().trim() ?? '',
      takim: data['takim']?.toString().trim() ?? '',
      pozisyon: data['pozisyon']?.toString().trim() ?? '',
      formaNo: sayi(data['formaNo']),
      fotografUrl: data['fotografUrl']?.toString().trim() ?? '',
    );
  }
}

String _takimFirestoreId(String value) {
  return value
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('ş', 's')
      .replaceAll('ğ', 'g')
      .replaceAll('ü', 'u')
      .replaceAll('ö', 'o')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class TakimKadroSayfasi extends StatefulWidget {
  final String takimAdi;
  final String takimLogoUrl;
  final String ligAdi;

  const TakimKadroSayfasi({
    super.key,
    required this.takimAdi,
    required this.takimLogoUrl,
    required this.ligAdi,
  });

  @override
  State<TakimKadroSayfasi> createState() => _TakimKadroSayfasiState();
}

class _TakimKadroSayfasiState extends State<TakimKadroSayfasi> {
  bool _yukleniyor = true;
  String? _hata;
  List<FutbolcuBilgisi> _oyuncular = <FutbolcuBilgisi>[];

  @override
  void initState() {
    super.initState();
    _kadroGetir();
  }

  Future<void> _kadroGetir() async {
    if (mounted) {
      setState(() {
        _yukleniyor = true;
        _hata = null;
      });
    }

    try {
      final takimId = _takimFirestoreId(widget.takimAdi);
      final snap = await FirebaseFirestore.instance
          .collection('oyuncular')
          .where('takimId', isEqualTo: takimId)
          .get();

      final oyuncular = snap.docs
          .map(FutbolcuBilgisi.fromDoc)
          .where((o) => o.adSoyad.isNotEmpty)
          .toList()
        ..sort((a, b) {
          final formaKarsilastir = a.formaNo.compareTo(b.formaNo);
          if (formaKarsilastir != 0) return formaKarsilastir;
          return a.adSoyad.toLowerCase().compareTo(b.adSoyad.toLowerCase());
        });

      if (!mounted) return;
      setState(() {
        _oyuncular = oyuncular;
        _yukleniyor = false;
      });
    } catch (e) {
      debugPrint('Kadro getirme hatası: $e');
      if (!mounted) return;
      setState(() {
        _yukleniyor = false;
        _hata = 'Kadro şu anda yüklenemiyor.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.takimAdi,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: _kadroGetir,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: anaYesil,
        onRefresh: _kadroGetir,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
          children: [
            _takimBaslikKarti(),
            const SizedBox(height: 16),
            const Text(
              'Kadro',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                color: Color(0xFF17221C),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.ligAdi,
              style: const TextStyle(
                color: gri,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            if (_yukleniyor)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(
                  child: CircularProgressIndicator(color: anaYesil),
                ),
              )
            else if (_hata != null)
              _durumKarti(
                Icons.error_outline_rounded,
                _hata!,
                buton: 'Tekrar Dene',
                onTap: _kadroGetir,
              )
            else if (_oyuncular.isEmpty)
              _durumKarti(
                Icons.groups_2_outlined,
                'Bu takım için henüz kadro yayınlanmadı.',
              )
            else
              ..._oyuncular.map(_oyuncuKarti),
          ],
        ),
      ),
    );
  }

  Widget _takimBaslikKarti() {
    final yerelLogo = GelisimTakimLogoServisi.yerelLogoGetir(widget.takimAdi);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 68,
            height: 68,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(19),
            ),
            child: yerelLogo != null
                ? Image.memory(
                    yerelLogo,
                    fit: BoxFit.contain,
                  )
                : widget.takimLogoUrl.isEmpty
                    ? const Icon(
                        Icons.shield_outlined,
                        color: anaYesil,
                        size: 38,
                      )
                    : Image.network(
                        widget.takimLogoUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.shield_outlined,
                          color: anaYesil,
                          size: 38,
                        ),
                      ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.takimAdi,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_oyuncular.length} futbolcu',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _oyuncuKarti(FutbolcuBilgisi oyuncu) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FutbolcuDetaySayfasi(
                  oyuncu: oyuncu,
                  takimLogoUrl: widget.takimLogoUrl,
                  takimAdi: widget.takimAdi,
                ),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: const Color(0xFFE4E9E6)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: acikYesil,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    oyuncu.formaNo > 0 ? '${oyuncu.formaNo}' : '-',
                    style: const TextStyle(
                      color: anaYesil,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _oyuncuMiniFoto(oyuncu),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        oyuncu.adSoyad,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF17221C),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        oyuncu.pozisyon.isEmpty
                            ? 'Pozisyon belirtilmedi'
                            : oyuncu.pozisyon,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: gri,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (oyuncu.dogumYili > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${oyuncu.dogumYili}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: gri,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(width: 5),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: anaYesil,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _oyuncuMiniFoto(FutbolcuBilgisi oyuncu) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 48,
        height: 48,
        color: const Color(0xFFEAF3ED),
        child: oyuncu.fotografUrl.isEmpty
            ? const Icon(
                Icons.person_outline_rounded,
                color: anaYesil,
                size: 30,
              )
            : Image.network(
                oyuncu.fotografUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.person_outline_rounded,
                  color: anaYesil,
                  size: 30,
                ),
              ),
      ),
    );
  }

  Widget _durumKarti(
    IconData icon,
    String mesaj, {
    String? buton,
    VoidCallback? onTap,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 34),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE4E9E6)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: anaYesil),
          const SizedBox(height: 12),
          Text(
            mesaj,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: gri,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (buton != null && onTap != null) ...[
            const SizedBox(height: 15),
            ElevatedButton(
              onPressed: onTap,
              child: Text(buton),
            ),
          ],
        ],
      ),
    );
  }
}

class FutbolcuDetaySayfasi extends StatelessWidget {
  final FutbolcuBilgisi oyuncu;
  final String takimLogoUrl;
  final String takimAdi;

  const FutbolcuDetaySayfasi({
    super.key,
    required this.oyuncu,
    required this.takimLogoUrl,
    required this.takimAdi,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Text('Oyuncu Profili', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          _profesyonelKart(),
          const SizedBox(height: 14),
          _bilgiKarti(),
        ],
      ),
    );
  }

  Widget _profesyonelKart() {
    return Container(
      height: 430,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087A3D), Color(0xFF07552D), Color(0xFF041C12)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              right: -35,
              top: 55,
              child: Icon(Icons.sports_soccer, size: 250, color: Colors.white.withOpacity(.045)),
            ),
            if (oyuncu.fotografUrl.isNotEmpty)
              Positioned.fill(
                child: Image.network(
                  oyuncu.fotografUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, __, ___) => _oyuncuPlaceholder(),
                ),
              )
            else
              _oyuncuPlaceholder(),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.transparent, const Color(0xE8071F15)],
                    stops: const [0, .48, 1],
                  ),
                ),
              ),
            ),
            if (takimLogoUrl.isNotEmpty)
              Positioned(
                top: 18,
                left: 18,
                child: Container(
                  width: 64,
                  height: 64,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                  child: Image.network(
                    takimLogoUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.shield_outlined, color: anaYesil),
                  ),
                ),
              ),
            if (oyuncu.formaNo > 0)
              Positioned(
                top: 15,
                right: 18,
                child: Text(
                  '${oyuncu.formaNo}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(.92),
                    fontSize: 64,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 22,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    oyuncu.pozisyon.isEmpty ? 'FUTBOLCU' : oyuncu.pozisyon.toUpperCase(),
                    style: const TextStyle(color: Color(0xFF72E59C), fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    oyuncu.adSoyad,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 29, height: 1.05, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.shield_outlined, color: Colors.white70, size: 17),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          takimAdi,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _oyuncuPlaceholder() {
    return Center(
      child: Icon(Icons.person_outline_rounded, color: Colors.white.withOpacity(.38), size: 145),
    );
  }

  Widget _bilgiKarti() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x0C000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Oyuncu Bilgileri', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF17221C))),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _ozetKutusu(Icons.calendar_month_outlined, 'DOĞUM', oyuncu.dogumYili > 0 ? '${oyuncu.dogumYili}' : '-')),
              const SizedBox(width: 10),
              Expanded(child: _ozetKutusu(Icons.checkroom_outlined, 'FORMA', oyuncu.formaNo > 0 ? '${oyuncu.formaNo}' : '-')),
              const SizedBox(width: 10),
              Expanded(child: _ozetKutusu(Icons.sports_soccer_outlined, 'MEVKİ', oyuncu.pozisyon.isEmpty ? '-' : oyuncu.pozisyon)),
            ],
          ),
          const SizedBox(height: 16),
          _bilgiSatiri(Icons.groups_2_outlined, 'Takım', takimAdi),
          _bilgiSatiri(Icons.person_pin_circle_outlined, 'Pozisyon', oyuncu.pozisyon.isEmpty ? '-' : oyuncu.pozisyon, son: true),
        ],
      ),
    );
  }

  Widget _ozetKutusu(IconData icon, String baslik, String deger) {
    return Container(
      constraints: const BoxConstraints(minHeight: 94),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(17)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: anaYesil, size: 21),
          const SizedBox(height: 6),
          Text(deger, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: siyah, fontSize: 13, fontWeight: FontWeight.w900)),
          const SizedBox(height: 3),
          Text(baslik, textAlign: TextAlign.center, style: const TextStyle(color: gri, fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: .5)),
        ],
      ),
    );
  }

  Widget _bilgiSatiri(IconData icon, String baslik, String deger, {bool son = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(border: Border(bottom: son ? BorderSide.none : const BorderSide(color: Color(0xFFEDF0EE)))),
      child: Row(
        children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: anaYesil, size: 19)),
          const SizedBox(width: 11),
          Text(baslik, style: const TextStyle(fontSize: 12, color: gri, fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Expanded(child: Text(deger, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5, color: siyah, fontWeight: FontWeight.w900))),
        ],
      ),
    );
  }
}

// ============================================================
// FUTBOL BİLGİNİ TEST ET
// ============================================================

class FutbolSorusu {
  final String soru;
  final List<String> secenekler;
  final int dogruIndex;
  final String kategori;
  final String aciklama;

  const FutbolSorusu({
    required this.soru,
    required this.secenekler,
    required this.dogruIndex,
    required this.kategori,
    required this.aciklama,
  });
}

const List<FutbolSorusu> _futbolSoruHavuzu = [
  FutbolSorusu(
    soru: 'Bir futbol takımı sahaya kaç oyuncuyla çıkar?',
    secenekler: ['9', '10', '11', '12'],
    dogruIndex: 2,
    kategori: 'Kurallar',
    aciklama: 'Bir takım sahaya kaleci dahil 11 oyuncuyla çıkar.',
  ),
  FutbolSorusu(
    soru: 'Penaltı noktası kale çizgisinden kaç metre uzaktadır?',
    secenekler: ['9 metre', '10 metre', '11 metre', '12 metre'],
    dogruIndex: 2,
    kategori: 'Kurallar',
    aciklama: 'Penaltı noktası kale çizgisinden 11 metre uzaklıktadır.',
  ),
  FutbolSorusu(
    soru: 'Bir oyuncunun aynı maçta 3 gol atmasına ne denir?',
    secenekler: ['Hat-trick', 'Clean sheet', 'Play-off', 'Derbi'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Aynı maçta üç gol atan oyuncu hat-trick yapmış olur.',
  ),
  FutbolSorusu(
    soru: 'Kaleci topa eliyle hangi bölgede dokunabilir?',
    secenekler: ['Orta saha', 'Kendi ceza sahası', 'Rakip ceza sahası', 'Her yerde'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Kaleci, kurallar çerçevesinde kendi ceza sahasında topa eliyle müdahale edebilir.',
  ),
  FutbolSorusu(
    soru: 'Kırmızı kart gören futbolcu için hangisi doğrudur?',
    secenekler: ['5 dakika çıkar', 'Oyundan ihraç edilir', 'Kaleye geçer', 'Sadece uyarılır'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Kırmızı kart, oyuncunun maçtan ihraç edilmesi anlamına gelir.',
  ),
  FutbolSorusu(
    soru: 'FIFA Dünya Kupası normal şartlarda kaç yılda bir düzenlenir?',
    secenekler: ['2', '3', '4', '5'],
    dogruIndex: 2,
    kategori: 'Dünya Futbolu',
    aciklama: 'Erkekler FIFA Dünya Kupası dört yılda bir düzenlenir.',
  ),
  FutbolSorusu(
    soru: '2022 FIFA Dünya Kupası’nı hangi ülke kazandı?',
    secenekler: ['Fransa', 'Arjantin', 'Brezilya', 'İspanya'],
    dogruIndex: 1,
    kategori: 'Dünya Futbolu',
    aciklama: 'Arjantin, 2022 Dünya Kupası finalinde Fransa’yı geçerek şampiyon oldu.',
  ),
  FutbolSorusu(
    soru: 'Türkiye A Milli Futbol Takımı 2002 Dünya Kupası’nı kaçıncı tamamladı?',
    secenekler: ['2.', '3.', '4.', '5.'],
    dogruIndex: 1,
    kategori: 'Milli Takım',
    aciklama: 'Türkiye 2002 Dünya Kupası’nı üçüncü tamamladı.',
  ),
  FutbolSorusu(
    soru: 'Türkiye, EURO 2008’de hangi aşamaya kadar yükseldi?',
    secenekler: ['Son 16', 'Çeyrek final', 'Yarı final', 'Final'],
    dogruIndex: 2,
    kategori: 'Milli Takım',
    aciklama: 'Türkiye EURO 2008’de yarı finale yükseldi.',
  ),
  FutbolSorusu(
    soru: '2000 yılında UEFA Kupası’nı kazanan Türk takımı hangisidir?',
    secenekler: ['Beşiktaş', 'Fenerbahçe', 'Galatasaray', 'Trabzonspor'],
    dogruIndex: 2,
    kategori: 'Türk Futbolu',
    aciklama: 'Galatasaray, 2000 UEFA Kupası finalinde Arsenal’i yenerek kupayı kazandı.',
  ),
  FutbolSorusu(
    soru: 'Ofsayt kuralı en temel olarak hangi oyuncuyla ilgilidir?',
    secenekler: ['Topu oyuna sokan kaleci', 'Hücum oyuncusu', 'Hakem', 'Teknik direktör'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Ofsayt, takım arkadaşı topu oynadığı anda hücum oyuncusunun konumuyla ilgilidir.',
  ),
  FutbolSorusu(
    soru: 'Korner hangi durumda verilir?',
    secenekler: ['Top hücum eden takımdan çıkar', 'Top savunan takımdan kale çizgisini geçer', 'Faul olur', 'Ofsayt olur'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Topa son olarak savunma takımı dokunup top kale dışında kale çizgisini geçerse korner verilir.',
  ),
  FutbolSorusu(
    soru: 'Taç atışı nasıl kullanılır?',
    secenekler: ['Tek elle', 'İki elle baş üzerinden', 'Ayakla', 'Dizle'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Taç atışı iki elle ve başın üzerinden yapılır.',
  ),
  FutbolSorusu(
    soru: 'Maçta gol yemeyen kaleci/takım için kullanılan ifade hangisidir?',
    secenekler: ['Hat-trick', 'Clean sheet', 'Golden goal', 'Pres'],
    dogruIndex: 1,
    kategori: 'Futbol Terimleri',
    aciklama: 'Bir maçı gol yemeden tamamlamak “clean sheet” olarak adlandırılır.',
  ),
  FutbolSorusu(
    soru: '“Asist” ne demektir?',
    secenekler: ['Golü hazırlayan son pas', 'Kalecinin kurtarışı', 'Taç atışı', 'Hakem kararı'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Asist, genel kullanımda golü hazırlayan son pas veya belirleyici katkıdır.',
  ),
  FutbolSorusu(
    soru: 'Santrforun temel görevi hangisidir?',
    secenekler: ['Gol üretmek', 'Sadece taç kullanmak', 'Kaleyi korumak', 'Maçı yönetmek'],
    dogruIndex: 0,
    kategori: 'Pozisyonlar',
    aciklama: 'Santrfor, hücum hattında gol üretme sorumluluğu yüksek olan oyuncudur.',
  ),
  FutbolSorusu(
    soru: 'Stoper oyuncusu genellikle hangi bölgede görev yapar?',
    secenekler: ['Savunmanın merkezinde', 'Sağ açıkta', 'Santrforda', 'Kalede'],
    dogruIndex: 0,
    kategori: 'Pozisyonlar',
    aciklama: 'Stoperler savunmanın merkezinde görev yapar.',
  ),
  FutbolSorusu(
    soru: 'Kanat oyuncusunun en sık görev yaptığı alan hangisidir?',
    secenekler: ['Sahanın kenar bölgeleri', 'Sadece ceza yayı', 'Kale çizgisinin arkası', 'Hakem alanı'],
    dogruIndex: 0,
    kategori: 'Pozisyonlar',
    aciklama: 'Kanat oyuncuları sahanın sağ veya sol kenar bölgelerinde hücuma genişlik sağlar.',
  ),
  FutbolSorusu(
    soru: 'Orta saha oyuncusunun temel rollerinden biri hangisidir?',
    secenekler: ['Savunma ile hücum arasında bağlantı kurmak', 'Sadece kalede beklemek', 'Sadece taç kullanmak', 'Hakeme yardımcı olmak'],
    dogruIndex: 0,
    kategori: 'Pozisyonlar',
    aciklama: 'Orta saha oyuncuları takımın savunma ve hücum bağlantısında önemli rol oynar.',
  ),
  FutbolSorusu(
    soru: '“Pres yapmak” ne anlama gelir?',
    secenekler: ['Rakibe baskı uygulamak', 'Oyunu durdurmak', 'Topu elle tutmak', 'Sahayı terk etmek'],
    dogruIndex: 0,
    kategori: 'Taktik',
    aciklama: 'Pres, top rakipteyken rakibe zaman ve alan bırakmamak için yapılan baskıdır.',
  ),
  FutbolSorusu(
    soru: '4-4-2 ifadesindeki sayılar neyi anlatır?',
    secenekler: ['Forma numaralarını', 'Dizilişteki oyuncu hatlarını', 'Skoru', 'Hakem sayısını'],
    dogruIndex: 1,
    kategori: 'Taktik',
    aciklama: '4-4-2; dört savunmacı, dört orta saha ve iki forvetli temel dizilişi ifade eder.',
  ),
  FutbolSorusu(
    soru: 'Bir futbol maçının normal süresi kaç dakikadır?',
    secenekler: ['80', '90', '100', '120'],
    dogruIndex: 1,
    kategori: 'Kurallar',
    aciklama: 'Normal süre iki 45 dakikalık devreden, toplam 90 dakikadan oluşur.',
  ),
  FutbolSorusu(
    soru: 'Devre arası hangi iki bölüm arasındadır?',
    secenekler: ['İki 45 dakikalık devre', 'Isınma ve maç', 'Penaltılar ve uzatma', 'Korner ve taç'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Devre arası ilk ve ikinci 45 dakikalık devre arasındadır.',
  ),
  FutbolSorusu(
    soru: 'Hakemin maç sonunda eklediği süreye ne denir?',
    secenekler: ['Uzatma/ilave süre', 'Transfer süresi', 'Mola', 'Play-off'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Oyun içindeki kayıplar için devre sonuna ilave süre eklenebilir.',
  ),
  FutbolSorusu(
    soru: 'UEFA Şampiyonlar Ligi hangi kıtadaki kulüplerin organizasyonudur?',
    secenekler: ['Avrupa', 'Asya', 'Afrika', 'Güney Amerika'],
    dogruIndex: 0,
    kategori: 'Dünya Futbolu',
    aciklama: 'UEFA Şampiyonlar Ligi Avrupa kulüplerinin en önemli organizasyonlarından biridir.',
  ),
  FutbolSorusu(
    soru: 'Copa América hangi bölgenin milli takım turnuvasıdır?',
    secenekler: ['Güney Amerika', 'Kuzey Avrupa', 'Asya', 'Okyanusya'],
    dogruIndex: 0,
    kategori: 'Dünya Futbolu',
    aciklama: 'Copa América, Güney Amerika milli takımlarının ana turnuvasıdır.',
  ),
  FutbolSorusu(
    soru: 'Lionel Messi hangi ülkenin milli takımında oynar?',
    secenekler: ['İspanya', 'Arjantin', 'Uruguay', 'Portekiz'],
    dogruIndex: 1,
    kategori: 'Futbolcular',
    aciklama: 'Lionel Messi Arjantin Milli Takımı oyuncusudur.',
  ),
  FutbolSorusu(
    soru: 'Cristiano Ronaldo hangi ülkenin milli takımında oynar?',
    secenekler: ['Portekiz', 'Brezilya', 'İtalya', 'Fransa'],
    dogruIndex: 0,
    kategori: 'Futbolcular',
    aciklama: 'Cristiano Ronaldo Portekiz Milli Takımı oyuncusudur.',
  ),
  FutbolSorusu(
    soru: 'Bir kalecinin yaptığı başarılı müdahaleye ne denir?',
    secenekler: ['Kurtarış', 'Asist', 'Ofsayt', 'Dripling'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Kalecinin golü önleyen başarılı müdahalesi kurtarış olarak adlandırılır.',
  ),
  FutbolSorusu(
    soru: '“Dripling” neyi ifade eder?',
    secenekler: ['Topla rakip geçmeyi/ilerlemeyi', 'Taç atmayı', 'Kaleci degajını', 'Hakem atışını'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Dripling, oyuncunun top kontrolüyle rakip geçmesi veya ilerlemesidir.',
  ),
  FutbolSorusu(
    soru: 'Futbolda kaptanın formasında genellikle hangi işaret bulunur?',
    secenekler: ['C harfli pazubent', 'Kırmızı kart', 'Düdük', 'Bayrak'],
    dogruIndex: 0,
    kategori: 'Futbol Kültürü',
    aciklama: 'Takım kaptanı genellikle kolunda kaptanlık pazubendi taşır.',
  ),
  FutbolSorusu(
    soru: 'Bir maç eleme usulündeyse ve eşitlik bozulmazsa hangi yöntem kullanılabilir?',
    secenekler: ['Penaltı vuruşları', 'Korner sayısı', 'Taç sayısı', 'Forma numarası'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Turnuva kurallarına göre eşitlik uzatma ve ardından penaltı vuruşlarıyla bozulabilir.',
  ),
  FutbolSorusu(
    soru: 'Serbest vuruşta barajı genellikle hangi takım kurar?',
    secenekler: ['Savunma yapan takım', 'Hücum eden takım', 'Hakemler', 'Yedek oyuncular'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Baraj, kaleyi korumak amacıyla savunma yapan takım oyuncularından oluşur.',
  ),
  FutbolSorusu(
    soru: 'Direkt serbest vuruştan doğrudan gol atılabilir mi?',
    secenekler: ['Evet', 'Hayır', 'Sadece kaleci atarsa', 'Sadece ilk yarıda'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Direkt serbest vuruştan top başka oyuncuya değmeden doğrudan gol olabilir.',
  ),
  FutbolSorusu(
    soru: 'Endirekt serbest vuruşta gol sayılması için ne gerekir?',
    secenekler: ['Topun başka bir oyuncuya değmesi', 'Topun iki kez direğe çarpması', 'Kalecinin çıkması', 'Korner kullanılması'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Endirekt serbest vuruşta gol için topun kaleye girmeden önce başka bir oyuncuya değmesi gerekir.',
  ),
  FutbolSorusu(
    soru: 'Futbol sahasındaki büyük dikdörtgen alanın adı nedir?',
    secenekler: ['Ceza sahası', 'Orta yuvarlak', 'Teknik alan', 'Korner yayı'],
    dogruIndex: 0,
    kategori: 'Saha Bilgisi',
    aciklama: 'Kalelerin önündeki büyük dikdörtgen bölge ceza sahasıdır.',
  ),
  FutbolSorusu(
    soru: 'Maç hangi noktadan başlatılır?',
    secenekler: ['Orta noktadan', 'Kornerden', 'Penaltı noktasından', 'Taç çizgisinden'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Başlama vuruşu sahanın orta noktasından yapılır.',
  ),
  FutbolSorusu(
    soru: 'Golün geçerli olması için topun ne yapması gerekir?',
    secenekler: ['Kale çizgisini tamamen geçmesi', 'Direğe değmesi', 'Kaleciye değmesi', 'Ceza sahasına girmesi'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Topun tamamı, kale direkleri arasından ve üst direğin altından kale çizgisini geçmelidir.',
  ),
  FutbolSorusu(
    soru: 'Sarı kart genel olarak neyi ifade eder?',
    secenekler: ['Resmî uyarı', 'Gol', 'Oyuncu değişikliği', 'Maç sonu'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Sarı kart, oyuncuya gösterilen resmî ihtardır.',
  ),
  FutbolSorusu(
    soru: 'Bir oyuncu aynı maçta ikinci sarı kartı görürse ne olur?',
    secenekler: ['Kırmızı kartla ihraç edilir', 'Gol verilir', 'Kaptan olur', 'Hiçbir şey olmaz'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Aynı maçtaki ikinci sarı kart, kırmızı karta ve oyuncunun ihracına yol açar.',
  ),
  FutbolSorusu(
    soru: 'VAR kısaltması futbolda neyle ilgilidir?',
    secenekler: ['Video yardımcı hakem', 'Oyuncu transferi', 'Saha bakımı', 'Kondisyon testi'],
    dogruIndex: 0,
    kategori: 'Teknoloji',
    aciklama: 'VAR, Video Assistant Referee yani Video Yardımcı Hakem sistemidir.',
  ),
  FutbolSorusu(
    soru: '“Derbi” sözcüğü genellikle nasıl bir maçı anlatır?',
    secenekler: ['Yerel veya büyük rekabet maçı', 'Hazırlık maçı', 'Antrenman', 'Penaltı çalışması'],
    dogruIndex: 0,
    kategori: 'Futbol Kültürü',
    aciklama: 'Derbi, özellikle aynı şehir/bölge veya güçlü rekabet içindeki takımların maçları için kullanılır.',
  ),
  FutbolSorusu(
    soru: '“Deplasman” ne anlama gelir?',
    secenekler: ['Rakibin sahasında oynanan maç', 'Kendi sahandaki maç', 'Antrenman', 'Transfer dönemi'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Deplasman maçı, takımın rakibinin sahasında oynadığı karşılaşmadır.',
  ),
  FutbolSorusu(
    soru: '“Ev sahibi takım” hangisidir?',
    secenekler: ['Maçın kendi sahasında oynandığı takım', 'Her zaman güçlü takım', 'İlk golü atan takım', 'Misafir takım'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Ev sahibi takım, karşılaşmayı kendi sahasında oynayan takımdır.',
  ),
  FutbolSorusu(
    soru: 'Bir oyuncunun takım arkadaşına topu aktarmasına ne denir?',
    secenekler: ['Pas', 'Faul', 'Kart', 'Ofsayt'],
    dogruIndex: 0,
    kategori: 'Temel Bilgi',
    aciklama: 'Topu takım arkadaşına aktarmak pas vermektir.',
  ),
  FutbolSorusu(
    soru: 'Topu rakipten kurallara uygun biçimde almaya ne denir?',
    secenekler: ['Top kazanma/müdahale', 'Ofsayt', 'Korner', 'Mola'],
    dogruIndex: 0,
    kategori: 'Temel Bilgi',
    aciklama: 'Kurallara uygun müdahaleyle topu rakipten almak top kazanmadır.',
  ),
  FutbolSorusu(
    soru: 'Korner vuruşu sahanın hangi bölümünden kullanılır?',
    secenekler: ['Köşe yayından', 'Orta noktadan', 'Penaltı noktasından', 'Ceza yayından'],
    dogruIndex: 0,
    kategori: 'Saha Bilgisi',
    aciklama: 'Korner vuruşu, topun çıktığı tarafa en yakın köşe alanından kullanılır.',
  ),
  FutbolSorusu(
    soru: 'Takımın başında taktik ve oyuncu yönetiminden sorumlu kişi genellikle kimdir?',
    secenekler: ['Teknik direktör', 'Spiker', 'Seyirci', 'Top toplayıcı'],
    dogruIndex: 0,
    kategori: 'Futbol Kültürü',
    aciklama: 'Teknik direktör takımın taktik, antrenman ve maç yönetiminden sorumludur.',
  ),
  FutbolSorusu(
    soru: 'Bir futbolcunun başka bir kulübe geçmesine ne denir?',
    secenekler: ['Transfer', 'Korner', 'Ofsayt', 'Avantaj'],
    dogruIndex: 0,
    kategori: 'Futbol Terimleri',
    aciklama: 'Oyuncunun kulüp değiştirmesi transfer olarak adlandırılır.',
  ),
  FutbolSorusu(
    soru: 'Hakem faul sonrası oyunu durdurmayıp hücumun sürmesine izin verirse buna ne denir?',
    secenekler: ['Avantaj', 'Ofsayt', 'Taç', 'Devre arası'],
    dogruIndex: 0,
    kategori: 'Kurallar',
    aciklama: 'Faul yapılan takım avantajlı konumdaysa hakem avantaj uygulayabilir.',
  ),
];

class FutbolBilgiTestiSayfasi extends StatefulWidget {
  const FutbolBilgiTestiSayfasi({super.key});

  @override
  State<FutbolBilgiTestiSayfasi> createState() =>
      _FutbolBilgiTestiSayfasiState();
}

class _FutbolBilgiTestiSayfasiState extends State<FutbolBilgiTestiSayfasi> {
  static const String _rekorAnahtari = 'futbol_bilgi_testi_rekor_v1';
  static final Set<String> _buOturumdaKullanilanSorular = <String>{};
  late List<FutbolSorusu> _sorular;
  int _soruIndex = 0;
  int? _seciliCevap;
  int _dogruSayisi = 0;
  int _rekor = 0;
  bool _bitti = false;

  @override
  void initState() {
    super.initState();
    _yeniOyun();
    _rekoruYukle();
  }

  void _yeniOyun() {
    // Aynı uygulama oturumunda, soru havuzu tükenene kadar daha önce
    // gösterilmiş soruları tekrar seçme. Böylece arka arkaya oynanan
    // 10 soruluk turlarda aynı sorular yeniden gelmez.
    var kullanilmamis = _futbolSoruHavuzu
        .where((soru) => !_buOturumdaKullanilanSorular.contains(soru.soru))
        .toList();

    // Havuzda yeni bir 10'lu tur için yeterli soru kalmadığında yeni
    // döngü başlat. Böylece tüm sorular görülmeden tekrar oluşmaz.
    if (kullanilmamis.length < 10) {
      _buOturumdaKullanilanSorular.clear();
      kullanilmamis = List<FutbolSorusu>.of(_futbolSoruHavuzu);
    }

    kullanilmamis.shuffle();

    // Her soruda şıkların yerini ayrıca karıştır.
    // Doğru cevabın yeni konumu da buna göre yeniden hesaplanır.
    _sorular = kullanilmamis.take(10).map((soru) {
      final dogruCevap = soru.secenekler[soru.dogruIndex];
      final karisikSecenekler = List<String>.of(soru.secenekler)..shuffle();

      return FutbolSorusu(
        soru: soru.soru,
        secenekler: karisikSecenekler,
        dogruIndex: karisikSecenekler.indexOf(dogruCevap),
        kategori: soru.kategori,
        aciklama: soru.aciklama,
      );
    }).toList();

    _buOturumdaKullanilanSorular.addAll(_sorular.map((soru) => soru.soru));

    _soruIndex = 0;
    _seciliCevap = null;
    _dogruSayisi = 0;
    _bitti = false;
  }

  Future<void> _rekoruYukle() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _rekor = prefs.getInt(_rekorAnahtari) ?? 0;
    });
  }

  void _cevapla(int index) {
    if (_seciliCevap != null || _bitti) return;
    setState(() {
      _seciliCevap = index;
      if (index == _sorular[_soruIndex].dogruIndex) {
        _dogruSayisi++;
      }
    });
  }

  Future<void> _sonraki() async {
    if (_seciliCevap == null) return;

    if (_soruIndex < _sorular.length - 1) {
      setState(() {
        _soruIndex++;
        _seciliCevap = null;
      });
      return;
    }

    final puan = _dogruSayisi * 10;
    if (puan > _rekor) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_rekorAnahtari, puan);
      _rekor = puan;
    }

    if (!mounted) return;
    setState(() {
      _bitti = true;
    });
  }

  void _tekrarOyna() {
    setState(_yeniOyun);
  }

  String _seviyeMetni(int puan) {
    if (puan == 100) return 'Futbol Efsanesi 🏆';
    if (puan >= 80) return 'Futbol Uzmanı ⭐';
    if (puan >= 60) return 'İyi Gidiyorsun ⚽';
    if (puan >= 40) return 'Yetenek Var 👏';
    return 'Isınma Turu 💪';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7F6),
      appBar: AppBar(
        title: const Text(
          'Futbol Bilgini Test Et',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: _bitti ? _sonucEkrani() : _soruEkrani(),
      ),
    );
  }

  Widget _soruEkrani() {
    final soru = _sorular[_soruIndex];
    final ilerleme = (_soruIndex + 1) / _sorular.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Soru ${_soruIndex + 1} / ${_sorular.length}',
                style: const TextStyle(
                  fontSize: 14,
                  color: gri,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: acikYesil,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_dogruSayisi * 10} puan',
                style: const TextStyle(
                  color: anaYesil,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: ilerleme,
            minHeight: 8,
            backgroundColor: Colors.black12,
            color: anaYesil,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  soru.kategori,
                  style: const TextStyle(
                    color: anaYesil,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(height: 17),
              Text(
                soru.soru,
                style: const TextStyle(
                  fontSize: 21,
                  height: 1.25,
                  fontWeight: FontWeight.w900,
                  color: siyah,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ...List.generate(soru.secenekler.length, (index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _secenekKarti(soru, index),
          );
        }),
        if (_seciliCevap != null) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, color: anaYesil, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    soru.aciklama,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: koyuYesil,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _sonraki,
              icon: Icon(
                _soruIndex == _sorular.length - 1
                    ? Icons.emoji_events_outlined
                    : Icons.arrow_forward,
              ),
              label: Text(
                _soruIndex == _sorular.length - 1
                    ? 'Sonucu Gör'
                    : 'Sonraki Soru',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _secenekKarti(FutbolSorusu soru, int index) {
    final cevaplandi = _seciliCevap != null;
    final dogru = index == soru.dogruIndex;
    final secildi = index == _seciliCevap;

    Color zemin = Colors.white;
    Color cerceve = Colors.black12;
    Color ikonZemin = const Color(0xFFF1F3F2);
    Color ikonRenk = gri;
    IconData? durumIkonu;

    if (cevaplandi && dogru) {
      zemin = acikYesil;
      cerceve = anaYesil;
      ikonZemin = anaYesil;
      ikonRenk = Colors.white;
      durumIkonu = Icons.check;
    } else if (cevaplandi && secildi && !dogru) {
      zemin = Colors.red.withOpacity(0.07);
      cerceve = Colors.red;
      ikonZemin = Colors.red;
      ikonRenk = Colors.white;
      durumIkonu = Icons.close;
    }

    return Material(
      color: zemin,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: cevaplandi ? null : () => _cevapla(index),
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: cerceve, width: cevaplandi && (dogru || secildi) ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: ikonZemin,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: durumIkonu == null
                    ? Text(
                        String.fromCharCode(65 + index),
                        style: TextStyle(
                          color: ikonRenk,
                          fontWeight: FontWeight.w900,
                        ),
                      )
                    : Icon(durumIkonu, color: ikonRenk, size: 21),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  soru.secenekler[index],
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: siyah,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sonucEkrani() {
    final puan = _dogruSayisi * 10;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 28),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  color: acikYesil,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.emoji_events,
                  color: anaYesil,
                  size: 48,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _seviyeMetni(puan),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  color: siyah,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '$puan / 100',
                style: const TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  color: anaYesil,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$_dogruSayisi doğru • ${_sorular.length - _dogruSayisi} yanlış',
                style: const TextStyle(
                  fontSize: 13,
                  color: gri,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F7F6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.workspace_premium_outlined, color: anaYesil),
                    const SizedBox(width: 8),
                    Text(
                      'En yüksek skor: $_rekor / 100',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: koyuYesil,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _tekrarOyna,
                  icon: const Icon(Icons.replay),
                  label: const Text(
                    'Tekrar Oyna',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Her oyunda 10 soru rastgele seçilir. Rekorun bu cihazda saklanır.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ============================================================
// LİGLER
// ============================================================

class LiglerSayfasi extends StatelessWidget {
  const LiglerSayfasi({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ligler', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _sezonKart(
            context,
            sezon: '2025-2026',
            aciklama: '',
            renk: anaYesil,
            ikon: Icons.emoji_events,
          ),
          const SizedBox(height: 14),
          _sezonKart(
            context,
            sezon: '2026-2027',
            aciklama: 'Yeni sezon ligleri',
            renk: Colors.blue,
            ikon: Icons.calendar_month,
          ),
        ],
      ),
    );
  }

  Widget _sezonKart(
    BuildContext context, {
    required String sezon,
    required String aciklama,
    required Color renk,
    required IconData ikon,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SezonLigleriSayfasi(sezon: sezon)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: renk.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Icon(ikon, color: renk, size: 32),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$sezon Sezonu',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        color: siyah,
                      ),
                    ),
                    if (aciklama.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(aciklama, style: const TextStyle(fontSize: 12, color: gri)),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 17, color: gri),
            ],
          ),
        ),
      ),
    );
  }
}

class YalovaAmatorSezonu2026Sayfasi extends StatelessWidget {
  const YalovaAmatorSezonu2026Sayfasi({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Süper Amatör Lig',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.emoji_events,
                  color: anaYesil,
                  size: 32,
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Süper Amatör Küme',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: siyah,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '2026-2027 sezonu',
                        style: TextStyle(
                          fontSize: 13,
                          color: gri,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          _grupKart(
            context,
            grup: 'A',
          ),

          const SizedBox(height: 14),

          _grupKart(
            context,
            grup: 'B',
          ),
        ],
      ),
    );
  }

  Widget _grupKart(
    BuildContext context, {
    required String grup,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SuperAmatorGrupSayfasi(
                grup: grup,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(
                  Icons.groups,
                  color: anaYesil,
                  size: 29,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$grup Grubu',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: siyah,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Puan durumu ve fikstür',
                      style: TextStyle(
                        fontSize: 12,
                        color: gri,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: gri,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GelisimLigleri2026Sayfasi extends StatelessWidget {
  const GelisimLigleri2026Sayfasi({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Gelişim Ligleri',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        children: [
          _gelisimBaslikKart(),
          const SizedBox(height: 18),
          ...GelisimLigVerileri.sezon2026.map(
            (lig) => GelisimLigSecimKarti(lig: lig),
          ),
        ],
      ),
    );
  }

  Widget _gelisimBaslikKart() {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue, Colors.blue.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Row(
        children: [
          Icon(Icons.auto_awesome, color: Colors.white, size: 30),
          SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '2026-2027 Gelişim Ligleri',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Yalova takımlarının mücadele ettiği TFF Gelişim Ligleri',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SEZON LİGLERİ
// ============================================================

class SezonLigleriSayfasi extends StatelessWidget {
  final String sezon;

  const SezonLigleriSayfasi({super.key, required this.sezon});

  @override
  Widget build(BuildContext context) {
    if (sezon == '2026-2027') {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            '2026-2027 Sezonu',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
          children: [
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const YalovaYerelLigler2026Sayfasi(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: acikYesil,
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: const Icon(
                          Icons.emoji_events,
                          color: anaYesil,
                          size: 29,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Yerel Ligler',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: siyah,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Yalova yerel ligleri',
                              style: TextStyle(
                                fontSize: 12,
                                color: gri,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: gri,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const GelisimLigleri2026Sayfasi(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: const Icon(
                          Icons.auto_awesome,
                          color: Colors.blue,
                          size: 29,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gelişim Ligleri',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: siyah,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'TFF Gelişim Ligleri',
                              style: TextStyle(
                                fontSize: 12,
                                color: gri,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios,
                        size: 16,
                        color: gri,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final buyukler =
        LigVerileri.sezon2025.where((e) => e.kategori == 'Büyükler').toList();
    final altyapi =
        LigVerileri.sezon2025.where((e) => e.kategori == 'Altyapı').toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '$sezon Sezonu',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 25),
        children: [
          _kategoriBasligi('Büyükler', Icons.emoji_events),
          ...buyukler.map((lig) => LigSecimKarti(lig: lig)),
          const SizedBox(height: 14),
          _kategoriBasligi('Altyapı', Icons.child_care),
          ...altyapi.map((lig) => LigSecimKarti(lig: lig)),
        ],
      ),
    );
  }

  Widget _baslikKart({
    required String baslik,
    required String aciklama,
    required IconData ikon,
    required Color renk,
  }) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [renk, renk.withOpacity(0.78)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: renk.withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(ikon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  baslik,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  aciklama,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kategoriBasligi(String baslik, IconData ikon) {
    return Padding(
      padding: const EdgeInsets.only(top: 15, bottom: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(ikon, color: anaYesil, size: 21),
          ),
          const SizedBox(width: 10),
          Text(
            baslik,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// GELİŞİM LİGİ SEÇİM KARTI
// ============================================================

class GelisimLigSecimKarti extends StatelessWidget {
  final GelisimLigBilgisi lig;

  const GelisimLigSecimKarti({super.key, required this.lig});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GelisimLigDetaySayfasi(lig: lig),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              _GelisimLigLogoGrubu(takimlar: lig.yalovaTakimlari),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lig.ad,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: siyah,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${lig.grup}  •  ${lig.yalovaTakimlari.length} Yalova takımı',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: gri,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 15, color: gri),
            ],
          ),
        ),
      ),
    );
  }
}

class _GelisimLigLogoGrubu extends StatelessWidget {
  final List<String> takimlar;

  const _GelisimLigLogoGrubu({required this.takimlar});

  @override
  Widget build(BuildContext context) {
    final gosterilecek = takimlar.take(2).toList();

    return SizedBox(
      width: 62,
      height: 50,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < gosterilecek.length; i++)
            Positioned(
              left: i * 22.0,
              top: i == 0 ? 0 : 8,
              child: _GelisimTakimLogo(
                takimAdi: gosterilecek[i],
                size: 42,
              ),
            ),
        ],
      ),
    );
  }
}

class _GelisimTakimLogo extends StatelessWidget {
  final String takimAdi;
  final double size;

  const _GelisimTakimLogo({required this.takimAdi, required this.size});

  @override
  Widget build(BuildContext context) {
    // Gelişim liglerindeki yerel takımlar için doğrulanmış logoları
    // doğrudan main.dart içinde kullanıyoruz. Böylece ASKF sitesindeki
    // eski/yanlış logo eşleşmeleri bu ekrana yansımıyor.
    final yerelLogo = GelisimTakimLogoServisi.yerelLogoGetir(takimAdi);

    Widget logoKutusu(Widget child) => Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black.withOpacity(0.06)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 5,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: child,
        );

    if (yerelLogo != null) {
      return logoKutusu(Image.memory(yerelLogo, fit: BoxFit.contain));
    }

    return FutureBuilder<String?>(
      future: GelisimTakimLogoServisi.logoGetir(takimAdi),
      builder: (context, snapshot) {
        final url = snapshot.data;
        return logoKutusu(
          url == null || url.isEmpty
              ? const Icon(Icons.shield_outlined, color: anaYesil, size: 23)
              : Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.shield_outlined,
                    color: anaYesil,
                    size: 23,
                  ),
                ),
        );
      },
    );
  }
}

class GelisimTakimLogoServisi {
  // Çiftlikköy Spor için mevcut yerel logo.
  static const String _ciftlikkoySpor1974LogoBase64 = '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';

  // U19'da Yalova FK'nın yanında gösterilecek Çiftlikköy Belediyesi SK logosu.
  static const String _ciftlikkoyBelediyesiLogoBase64 = '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';

  // DÜZELTME: base64Decode daha önce her build()'de yeniden çalışıyordu.
  // Her çağrıda yeni bir Uint8List üretildiği için Image.memory'nin
  // resim önbelleği sürekli ıskalıyor ve PNG tekrar tekrar çözülüyordu.
  // Artık çözülmüş bayt dizisi takım adına göre bir kez üretilip saklanıyor;
  // aynı nesne döndüğü için önbellek isabet ediyor.
  static const String _yalovaFkLogoBase64 = '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';

  static final Map<String, Uint8List?> _yerelLogoOnbellek = <String, Uint8List?>{};

  static Uint8List? yerelLogoGetir(String takimAdi) {
    // TFF takım adını bazen farklı yazabildiği için karşılaştırmayı
    // normalize ederek yapıyoruz. Böylece U19 Yalova FK logosu;
    // Yalova FK, Yalova FK 77 Spor, YALOVA FK 77 SPOR vb. adlarda da çıkar.
    final anahtar = _normalize(takimAdi);

    if (_yerelLogoOnbellek.containsKey(anahtar)) {
      return _yerelLogoOnbellek[anahtar];
    }

    Uint8List? cozulmus;

    if (anahtar == 'yalovafk' ||
        anahtar == 'yalovafk77spor' ||
        anahtar == 'yalovafutbolkulubu' ||
        anahtar == 'yalovafk77' ||
        anahtar.startsWith('yalovafk')) {
      // U19 Yalova FK: tüm Gelişim Ligi ekranlarında sabit logo.
      cozulmus = base64Decode(_yalovaFkLogoBase64);
    } else if (anahtar == 'calicagenclikspor') {
      cozulmus = base64Decode(_ciftlikkoySpor1974LogoBase64);
    } else if (anahtar == 'ciftlikkoybelediyespor' ||
        anahtar == 'ciftlikkoybelediyesispor kulubu' ||
        anahtar == 'ciftlikkoybelediyesispor' ||
        anahtar == 'ciftlikkoybelediyesporkulubu' ||
        anahtar.contains('ciftlikkoybelediyesi')) {
      // U19: Çiftlikköy Belediyesi Spor Kulübü için sabit yerel logo.
      cozulmus = base64Decode(_ciftlikkoyBelediyesiLogoBase64);
    }

    _yerelLogoOnbellek[anahtar] = cozulmus;
    return cozulmus;
  }
  static final Map<String, String?> _cache = <String, String?>{};
  static final Map<String, Future<String?>> _bekleyenler = <String, Future<String?>>{};

  static const Map<String, String> _sluglar = <String, String>{
    'Yalova Gücü Spor': 'yalova-gucu-spor',
    'Çiftlikköy Belediye Spor': 'ciftlikkoy-belediye-spor',
    'Yalovaspor': 'yalova-spor',
    'Yalova FK': 'yalova-fk-77-spor',
    'Yalova FK 77 Spor': 'yalova-fk-77-spor',
  };

  static Future<String?> logoGetir(String takimAdi) async {
    final anahtar = _normalize(takimAdi);
    if (_cache.containsKey(anahtar)) return _cache[anahtar];

    final kalici = await SiteVeriCache.oku(tur: 'logo', kaynak: anahtar);
    if (kalici != null) {
      final url = kalici.veri?.toString() ?? '';
      _cache[anahtar] = url.isEmpty ? null : url;
      return _cache[anahtar];
    }
    if (_bekleyenler.containsKey(anahtar)) return _bekleyenler[anahtar];

    final future = _logoGetir(takimAdi, anahtar);
    _bekleyenler[anahtar] = future;
    final sonuc = await future;
    _bekleyenler.remove(anahtar);
    return sonuc;
  }

  static Future<String?> _logoGetir(String takimAdi, String anahtar) async {
    try {
      final slug = _sluglar[takimAdi] ?? _otomatikSlug(takimAdi);
      final response = await http
          .get(
            Uri.parse('https://yalovaskf.com/takim/$slug'),
            headers: const {
              'User-Agent': 'Mozilla/5.0 YalovaWonderKids',
              'Accept': 'text/html',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return null;
      }

      final document = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
      final hedef = _normalize(takimAdi);

      for (final img in document.querySelectorAll('img')) {
        final alt = img.attributes['alt']?.trim() ?? '';
        if (alt.isEmpty || _normalize(alt) == 'image' || _normalize(alt) == 'logo') {
          continue;
        }
        if (_normalize(alt).contains(hedef) || hedef.contains(_normalize(alt))) {
          final src = img.attributes['src'] ?? '';
          final url = _mutlakUrl(src);
          if (url.isNotEmpty) {
            _cache[anahtar] = url;
            await SiteVeriCache.kaydet(tur: 'logo', kaynak: anahtar, veri: url);
            return url;
          }
        }
      }

      // Profil sayfasındaki ilk anlamlı görseli yedek olarak dene.
      for (final img in document.querySelectorAll('img')) {
        final src = img.attributes['src'] ?? '';
        if (src.isEmpty) continue;
        final alt = img.attributes['alt']?.trim() ?? '';
        if (alt.isEmpty || _normalize(alt) == 'image') continue;
        final url = _mutlakUrl(src);
        if (url.isNotEmpty) {
          _cache[anahtar] = url;
          return url;
        }
      }
    } catch (e) {
      debugPrint('Gelişim ligi logo alınamadı ($takimAdi): $e');
    }

    return null;
  }

  static String _otomatikSlug(String value) {
    return value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  static String _normalize(String value) {
    return _tffKarakterleriniDuzelt(value)
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _mutlakUrl(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return 'https://yalovaskf.com$value';
    return 'https://yalovaskf.com/$value';
  }
}

// ============================================================
// GELİŞİM LİGİ DETAY
// ============================================================

class GelisimLigDetaySayfasi extends StatefulWidget {
  final GelisimLigBilgisi lig;

  const GelisimLigDetaySayfasi({super.key, required this.lig});

  @override
  State<GelisimLigDetaySayfasi> createState() => _GelisimLigDetaySayfasiState();
}

class _GelisimLigDetaySayfasiState extends State<GelisimLigDetaySayfasi> {
  bool yukleniyor = true;
  String? hata;
  int sekme = 0; // 0: Puan Durumu, 1: Fikstür
  List<TakimPuan> puanlar = <TakimPuan>[];
  List<MacBilgisi> maclar = <MacBilgisi>[];
  int? seciliHafta;
  Timer? _otomatikYenilemeTimer;
  DateTime? _sonGuncelleme;
  bool _cacheGosteriliyor = false;
  int _istekNo = 0;

  @override
  void initState() {
    super.initState();
    _verileriGetir();

    // TFF verileri bu ekran açık kaldığı sürece düzenli olarak
    // yeniden kontrol edilir. Firestore kullanılmaz.
    _otomatikYenilemeTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) {
        if (mounted && !yukleniyor) {
          _verileriGetir(sessiz: true);
        }
      },
    );
  }

  @override
  void dispose() {
    _otomatikYenilemeTimer?.cancel();
    super.dispose();
  }

  Future<void> _verileriGetir({bool sessiz = false}) async {
    final istekNo = ++_istekNo;

    if (!sessiz) {
      setState(() {
        yukleniyor = true;
        hata = null;
      });
    }

    final cache = await GelisimLigVeriServisi.cacheOku(widget.lig);
    if (!mounted || istekNo != _istekNo) return;
    if (cache != null) {
      final cached = GelisimLigVeriServisi.cacheVeridenGetir(cache.veri);
      if (cached.puanlar.isNotEmpty || cached.maclar.isNotEmpty) {
        final haftalar = _haftaNumaralari(cached.maclar);
        setState(() {
          puanlar = cached.puanlar;
          maclar = cached.maclar;
          if (seciliHafta == null && haftalar.isNotEmpty) {
            seciliHafta = _varsayilanHafta(cached.maclar, haftalar);
          }
          yukleniyor = false;
          hata = null;
          _sonGuncelleme = cache.tarih;
          _cacheGosteriliyor = true;
        });
      }
    }

    try {
      final veriler = await GelisimLigVeriServisi.getir(widget.lig, tamFikstur: true);
      if (!mounted || istekNo != _istekNo) return;

      final haftalar = _haftaNumaralari(veriler.maclar);
      setState(() {
        puanlar = veriler.puanlar;
        maclar = veriler.maclar;
        if (seciliHafta == null && haftalar.isNotEmpty) {
          seciliHafta = _varsayilanHafta(veriler.maclar, haftalar);
        }
        yukleniyor = false;
        hata = null;
        if (veriler.cachetenGeldi) {
          // Servis canlı TFF yerine kendi fallback cache'ini döndürmüş olabilir.
          // Bu durumda cache'in gerçek zamanını koru; "az önce" gibi göstermeyelim.
          _sonGuncelleme = cache?.tarih ?? _sonGuncelleme;
          _cacheGosteriliyor = true;
        } else {
          _sonGuncelleme = DateTime.now();
          _cacheGosteriliyor = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        yukleniyor = false;
        if (!sessiz) {
          if (puanlar.isEmpty && maclar.isEmpty) {
            // DÜZELTME: TFF'nin "bu grup için veri henüz yok" durumu ile
            // gerçek bir erişim/parse hatası artık ayrı exception
            // tipleriyle geliyor. İlkinde kullanıcıya "uygulama
            // bozuldu" izlenimi veren belirsiz bir mesaj yerine, verinin
            // TFF tarafında henüz yayınlanmadığını söyleyen daha doğru
            // bir mesaj gösteriyoruz.
            hata = e is TffVeriHenuzYayinlanmadiException
                ? 'Bu grup için puan cetveli ve fikstür TFF tarafından bu sezon henüz yayınlanmadı.'
                : 'Gelişim Ligi verileri şu anda alınamıyor. Lütfen tekrar deneyin.';
          } else {
            _cacheGosteriliyor = true;
            hata = null;
          }
        }
      });
      debugPrint('Gelişim ligi veri hatası: $e');
    }
  }

  bool _takimEsit(String a, String b) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalize(a) == normalize(b);
  }

  List<int> _haftaNumaralari(List<MacBilgisi> liste) {
    final haftalar = <int>{};
    for (final mac in liste) {
      final no = int.tryParse(
        RegExp(r'\d+').firstMatch(mac.hafta)?.group(0) ?? '',
      );
      if (no != null) haftalar.add(no);
    }
    final sonuc = haftalar.toList()..sort();
    return sonuc;
  }

  int _varsayilanHafta(List<MacBilgisi> liste, List<int> haftalar) {
    if (haftalar.isEmpty) return 0;

    // En son gerçekten oynanmış hafta: sonuç girilmiş maçların en yüksek haftası.
    int? sonOynananHafta;
    for (final mac in liste) {
      if (!mac.oynandi) continue;
      final no = int.tryParse(
        RegExp(r'\d+').firstMatch(mac.hafta)?.group(0) ?? '',
      );
      if (no == null) continue;
      if (sonOynananHafta == null || no > sonOynananHafta) {
        sonOynananHafta = no;
      }
    }

    // Sonuçlu maç yoksa mevcut ilk haftayı göster.
    if (sonOynananHafta == null) return haftalar.first;

    // Pazartesi-Çarşamba: en son oynanan hafta.
    // Perşembe-Pazar: bir sonraki hafta.
    final bugun = DateTime.now().weekday;
    final hedefHafta = bugun >= DateTime.thursday
        ? sonOynananHafta + 1
        : sonOynananHafta;

    // Hedef hafta yayınlanmışsa onu seç. Yayınlanmadıysa mevcut en yakın
    // haftaya düş; böylece 30. hafta gibi uzak bir hafta otomatik seçilmez.
    if (haftalar.contains(hedefHafta)) return hedefHafta;

    if (bugun >= DateTime.thursday) {
      final sonraki = haftalar.where((hafta) => hafta > sonOynananHafta!).toList();
      if (sonraki.isNotEmpty) return sonraki.first;
    }

    final onceki = haftalar.where((hafta) => hafta <= sonOynananHafta!).toList();
    if (onceki.isNotEmpty) return onceki.last;

    return haftalar.first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.lig.ad, style: const TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: yukleniyor ? null : _verileriGetir,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _verileriGetir,
        color: anaYesil,
        child: _govde(),
      ),
    );
  }

  Widget _govde() {
    if (yukleniyor) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 150),
          Center(child: CircularProgressIndicator(color: anaYesil)),
          SizedBox(height: 15),
          Center(
            child: Text(
              'TFF verileri yükleniyor...',
              style: TextStyle(color: gri, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }

    if (hata != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 55),
          const Center(child: Icon(Icons.cloud_off, size: 58, color: Colors.orange)),
          const SizedBox(height: 16),
          const Text(
            'Veriler alınamadı',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(hata!, textAlign: TextAlign.center, style: const TextStyle(color: gri)),
          const SizedBox(height: 20),
          Center(
            child: ElevatedButton.icon(
              onPressed: _verileriGetir,
              icon: const Icon(Icons.refresh),
              label: const Text('Tekrar Dene'),
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _ustKart(),
        const SizedBox(height: 8),
        _guncellemeBilgisi(),
        const SizedBox(height: 10),
        _sekmeSecici(),
        const SizedBox(height: 12),
        sekme == 0 ? _puanDurumu() : _fikstur(),
      ],
    );
  }

  Widget _ustKart() {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.lig.ad,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  '${widget.lig.grup} • TFF Gelişim Ligleri',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _guncellemeBilgisi() {
    final zaman = _sonGuncelleme;
    final metin = zaman == null
        ? 'TFF verisi yükleniyor'
        : _cacheGosteriliyor
            ? 'Önbellekten gösteriliyor • ${cacheGuncellemeMetni(zaman)}'
            : 'TFF • ${cacheGuncellemeMetni(zaman)}';

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const Icon(Icons.sync, size: 14, color: gri),
        const SizedBox(width: 5),
        Text(
          metin,
          style: const TextStyle(fontSize: 10, color: gri, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _sekmeSecici() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
      child: Row(
        children: [
          Expanded(child: _sekmeButonu(0, 'Puan Durumu', Icons.table_chart_outlined)),
          Expanded(child: _sekmeButonu(1, 'Fikstür', Icons.calendar_month_outlined)),
        ],
      ),
    );
  }

  Widget _sekmeButonu(int index, String baslik, IconData ikon) {
    final secili = sekme == index;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => sekme = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: secili ? anaYesil : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(ikon, size: 17, color: secili ? Colors.white : gri),
            const SizedBox(width: 6),
            Text(
              baslik,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: secili ? Colors.white : siyah,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _puanDurumu() {
    if (puanlar.isEmpty) {
      return _bosKutu('Bu grup için puan durumu henüz oluşmadı.');
    }

    return Column(
      children: puanlar.map((takim) {
        final yalovaTakimi = widget.lig.yalovaTakimlari.any((ad) => _takimEsit(ad, takim.takim));
        return Container(
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(
            color: yalovaTakimi ? acikYesil : Colors.white,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: yalovaTakimi ? anaYesil.withOpacity(0.22) : Colors.black.withOpacity(0.035),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () => _takimDetayiAc(takim),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('${takim.sira}', style: const TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  _logo(takim.logoUrl, takimAdi: takim.takim),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      takim.takim,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: yalovaTakimi ? FontWeight.w900 : FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${takim.puan} P', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
                      Text('${takim.oynanan} O  ${takim.averaj >= 0 ? '+' : ''}${takim.averaj} AV', style: const TextStyle(fontSize: 9, color: gri)),
                    ],
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 19, color: gri),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _fikstur() {
    if (maclar.isEmpty) {
      return _bosKutu('Bu grup için fikstür henüz yayınlanmadı.');
    }

    final haftalar = _haftaNumaralari(maclar);
    if (haftalar.isEmpty) {
      return _bosKutu('Bu grup için fikstür haftası bulunamadı.');
    }

    final aktifHafta = seciliHafta != null && haftalar.contains(seciliHafta)
        ? seciliHafta!
        : haftalar.last;

    final haftaMaclari = maclar.where((mac) {
      final no = int.tryParse(
        RegExp(r'\d+').firstMatch(mac.hafta)?.group(0) ?? '',
      );
      return no == aktifHafta;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(15),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.035),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: aktifHafta,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, color: anaYesil),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: siyah,
              ),
              items: haftalar.reversed.map((hafta) {
                return DropdownMenuItem<int>(
                  value: hafta,
                  child: Text('$hafta. Hafta'),
                );
              }).toList(),
              onChanged: (deger) {
                if (deger == null) return;
                setState(() => seciliHafta = deger);
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (haftaMaclari.isEmpty)
          _bosKutu('$aktifHafta. haftaya ait maç bulunamadı.')
        else
          ...haftaMaclari.map(_macKarti),
      ],
    );
  }

  Widget _fiksturHenuzYayinlanmadi() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Column(
        children: [
          Icon(Icons.calendar_month_outlined, color: anaYesil, size: 30),
          SizedBox(height: 10),
          Text(
            'Fikstür henüz yayınlanmadı.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 5),
          Text(
            '2026-2027 Süper Amatör Lig fikstürü yayınlandığında burada gösterilecektir.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _macKarti(MacBilgisi mac) {
    final yalovaMac = widget.lig.yalovaTakimlari.any((ad) => _takimEsit(ad, mac.evSahibi)) ||
        widget.lig.yalovaTakimlari.any((ad) => _takimEsit(ad, mac.deplasman));

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: yalovaMac ? acikYesil : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(10)),
              child: Center(
                child: Text(
                  mac.hafta,
                  style: const TextStyle(fontSize: 9, color: anaYesil, fontWeight: FontWeight.w900),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mac.evSahibi, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(mac.deplasman, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  if (mac.tarihSaat.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(mac.tarihSaat, style: const TextStyle(fontSize: 9, color: gri)),
                  ],
                  if (mac.stadyum.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(mac.stadyum, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 8.5, color: gri)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: mac.oynandi ? anaYesil.withOpacity(0.10) : const Color(0xFFF1F3F2),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                mac.sonuc.isEmpty || mac.sonuc == '-' ? 'VS' : mac.sonuc,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bosKutu(String metin) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Text(metin, textAlign: TextAlign.center, style: const TextStyle(color: gri, fontWeight: FontWeight.w600)),
    );
  }

  Widget _logo(String url, {String? takimAdi}) {
    // Gelişim Ligi puan durumunda Yalova temsilcilerinin doğrulanmış
    // yerel logoları TFF/ASKF'den gelen eski logo URL'sine göre önceliklidir.
    // U19'daki Çiftlikköy Belediyesi SK, U14-U17'de kullanılan
    // Çiftlikköy/Çalıca logosundan farklı olduğu için lig bazında ayırıyoruz.
    if (takimAdi != null && takimAdi.isNotEmpty) {
      String yerelLogoAdi = takimAdi;

      if (widget.lig.tffPageId == 1751 &&
          (_takimEsit(takimAdi, 'Çiftlikköy Belediye Spor') ||
              _takimEsit(takimAdi, 'Çiftlikköy Belediyesi Spor Kulübü'))) {
        yerelLogoAdi = 'Çiftlikköy Belediyesi Spor Kulübü';
      }

      // Çalıca, hangi gelişim ligi puan durumunda görünürse görünsün
      // uygulamaya gömülü doğrulanmış S.K. Çiftlikköy Spor 1974 logosunu kullanır.
      if (_takimEsit(takimAdi, 'Çalıca Gençlik Spor') ||
          _takimEsit(takimAdi, 'Çalıca Gençlikspor')) {
        yerelLogoAdi = 'Çalıca Gençlik Spor';
      }

      final yerelLogo = GelisimTakimLogoServisi.yerelLogoGetir(yerelLogoAdi);
      if (yerelLogo != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.memory(
            yerelLogo,
            width: 34,
            height: 34,
            fit: BoxFit.contain,
          ),
        );
      }
    }

    if (url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.network(
          url,
          width: 34,
          height: 34,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _yedekLogo(takimAdi),
        ),
      );
    }
    return _yedekLogo(takimAdi);
  }

  Widget _yedekLogo(String? takimAdi) {
    if (takimAdi == null || takimAdi.isEmpty) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
        child: const Icon(Icons.shield_outlined, color: anaYesil, size: 21),
      );
    }

    return _GelisimTakimLogo(takimAdi: takimAdi, size: 34);
  }

  void _takimDetayiAc(TakimPuan takim) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GelisimTakimDetaySayfasi(
          lig: widget.lig,
          takim: takim,
          maclar: maclar,
        ),
      ),
    );
  }
}

// ============================================================
// GELİŞİM TAKIM DETAYI
// ============================================================

class GelisimTakimDetaySayfasi extends StatelessWidget {
  final GelisimLigBilgisi lig;
  final TakimPuan takim;
  final List<MacBilgisi> maclar;

  const GelisimTakimDetaySayfasi({
    super.key,
    required this.lig,
    required this.takim,
    required this.maclar,
  });

  bool _takimEsit(String a, String b) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalize(a) == normalize(b);
  }

  @override
  Widget build(BuildContext context) {
    final takimMaclari = maclar
        .where((mac) => _takimEsit(mac.evSahibi, takim.takim) || _takimEsit(mac.deplasman, takim.takim))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Takım Profili', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(23),
            ),
            child: Column(
              children: [
                Container(
                  width: 86,
                  height: 86,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(23)),
                  child: _GelisimTakimLogo(takimAdi: takim.takim, size: 68),
                ),
                const SizedBox(height: 12),
                Text(
                  takim.takim,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  '${lig.ad} • ${lig.grup}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(19)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Lig Durumu', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                const SizedBox(height: 11),
                Row(
                  children: [
                    _istatistikKutusu('${takim.sira}', 'Sıra'),
                    _istatistikKutusu('${takim.puan}', 'Puan'),
                    _istatistikKutusu('${takim.oynanan}', 'Oynanan'),
                    _istatistikKutusu('${takim.averaj}', 'Averaj', son: true),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('Takımın Maçları', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
              Text('${takimMaclari.length} maç', style: const TextStyle(color: gri, fontSize: 11, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          if (takimMaclari.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(17)),
              child: const Text('Takım için maç kaydı bulunmuyor.', textAlign: TextAlign.center, style: TextStyle(color: gri)),
            )
          else
            ...takimMaclari.map((mac) => _macKarti(mac)),
        ],
      ),
    );
  }

  Widget _istatistikKutusu(String deger, String baslik, {bool son = false}) {
    return Expanded(
      child: Container(
        margin: EdgeInsets.only(right: son ? 0 : 6),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF5F7F6), borderRadius: BorderRadius.circular(11)),
        child: Column(
          children: [
            Text(deger, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(baslik, style: const TextStyle(fontSize: 8.5, color: gri, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _macKarti(MacBilgisi mac) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 35,
              height: 35,
              decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(10)),
              child: Center(child: Text(mac.hafta, style: const TextStyle(fontSize: 9, color: anaYesil, fontWeight: FontWeight.w900))),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mac.evSahibi, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(mac.deplasman, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  if (mac.tarihSaat.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(mac.tarihSaat, style: const TextStyle(fontSize: 9, color: gri)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFFF1F3F2), borderRadius: BorderRadius.circular(9)),
              child: Text(mac.sonuc.isEmpty || mac.sonuc == '-' ? 'VS' : mac.sonuc, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// GELİŞİM LİGİ VERİ SERVİSİ
// ============================================================

// DÜZELTME: TFF, bir grup için puan cetveli/fikstür verisini sezon
// henüz başlamadığı veya sayfa henüz yayına alınmadığı için "hazır
// değil" mesajıyla boş dönebiliyor (tff.org üzerinde doğrulandı: grup
// seçim listesi boş + "Seçilen haftanın puan cetveli hazır değil"
// metni). Bu durum bir parse hatası DEĞİL, TFF tarafında verinin
// henüz yayınlanmamış olmasıdır. Bunu genel "çözümlenemedi"
// hatasından ayırmak için ayrı bir exception tipi kullanıyoruz;
// böylece kullanıcıya "uygulama bozuldu" izlenimi veren belirsiz bir
// mesaj yerine daha doğru bir mesaj gösterebiliyoruz.
class TffVeriHenuzYayinlanmadiException implements Exception {
  final String mesaj;
  const TffVeriHenuzYayinlanmadiException([
    this.mesaj = 'TFF bu grup için veriyi henüz yayınlamadı.',
  ]);

  @override
  String toString() => mesaj;
}

class GelisimLigVeriSonucu {
  final List<TakimPuan> puanlar;
  final List<MacBilgisi> maclar;
  final bool cachetenGeldi;

  const GelisimLigVeriSonucu({
    required this.puanlar,
    required this.maclar,
    this.cachetenGeldi = false,
  });
}

class GelisimLigVeriServisi {
  static final Map<String, int?> _grupCache = <String, int?>{};
  static final Map<String, DateTime> _grupCacheTarih = <String, DateTime>{};
  static final Map<String, Future<http.Response>> _bekleyenIstekler = <String, Future<http.Response>>{};

  static const Duration _grupBellekSuresi = Duration(minutes: 5);
  static const Duration _istekZamani = Duration(seconds: 15);

  static String _cacheKaynak(GelisimLigBilgisi lig) {
    // v3: Daha önce yanlış gruptan kaydedilmiş gelişim ligi cache'ini
    // kesin olarak devre dışı bırak. Sabit TFF grup ID'sini de anahtara
    // katıyoruz; böylece farklı grup verileri birbirine karışmaz.
    final sabitId = _sabit2026GrupId(lig);
    return 'v3-${lig.tffPageId}-${sabitId ?? 'dinamik'}-${lig.grup}';
  }

  static Future<SiteCacheKaydi?> cacheOku(GelisimLigBilgisi lig) {
    return SiteVeriCache.oku(
      tur: 'gelisim',
      kaynak: _cacheKaynak(lig),
    );
  }

  static Future<void> cacheKaydet(
    GelisimLigBilgisi lig,
    GelisimLigVeriSonucu veri,
  ) async {
    await SiteVeriCache.kaydet(
      tur: 'gelisim',
      kaynak: _cacheKaynak(lig),
      veri: <String, dynamic>{
        'puanlar': veri.puanlar.map((takim) => <String, dynamic>{
          'sira': takim.sira,
          'takim': takim.takim,
          'oynanan': takim.oynanan,
          'galibiyet': takim.galibiyet,
          'beraberlik': takim.beraberlik,
          'maglubiyet': takim.maglubiyet,
          'atilanGol': takim.atilanGol,
          'yenilenGol': takim.yenilenGol,
          'averaj': takim.averaj,
          'puan': takim.puan,
          'logoUrl': takim.logoUrl,
          'takimUrl': takim.takimUrl,
        }).toList(),
        'maclar': veri.maclar.map((mac) => <String, dynamic>{
          'hafta': mac.hafta,
          'evSahibi': mac.evSahibi,
          'deplasman': mac.deplasman,
          'sonuc': mac.sonuc,
          'tarihSaat': mac.tarihSaat,
          'stadyum': mac.stadyum,
        }).toList(),
      },
    );
  }

  static GelisimLigVeriSonucu cacheVeridenGetir(dynamic veri) {
    if (veri is! Map) {
      return const GelisimLigVeriSonucu(
        puanlar: <TakimPuan>[],
        maclar: <MacBilgisi>[],
      );
    }

    List<TakimPuan> puanlariOku(dynamic value) {
      if (value is! List) return <TakimPuan>[];
      return value.whereType<Map>().map((item) => TakimPuan(
        sira: int.tryParse(item['sira']?.toString() ?? '') ?? 0,
        takim: item['takim']?.toString() ?? '',
        oynanan: int.tryParse(item['oynanan']?.toString() ?? '') ?? 0,
        galibiyet: int.tryParse(item['galibiyet']?.toString() ?? '') ?? 0,
        beraberlik: int.tryParse(item['beraberlik']?.toString() ?? '') ?? 0,
        maglubiyet: int.tryParse(item['maglubiyet']?.toString() ?? '') ?? 0,
        atilanGol: int.tryParse(item['atilanGol']?.toString() ?? '') ?? 0,
        yenilenGol: int.tryParse(item['yenilenGol']?.toString() ?? '') ?? 0,
        averaj: int.tryParse(item['averaj']?.toString() ?? '') ?? 0,
        puan: int.tryParse(item['puan']?.toString() ?? '') ?? 0,
        logoUrl: item['logoUrl']?.toString() ?? '',
        takimUrl: item['takimUrl']?.toString() ?? '',
      )).where((takim) => takim.takim.isNotEmpty).toList();
    }

    List<MacBilgisi> maclariOku(dynamic value) {
      if (value is! List) return <MacBilgisi>[];
      return value.whereType<Map>().map((item) => MacBilgisi(
        hafta: item['hafta']?.toString() ?? '',
        evSahibi: item['evSahibi']?.toString() ?? '',
        deplasman: item['deplasman']?.toString() ?? '',
        sonuc: item['sonuc']?.toString() ?? '',
        tarihSaat: item['tarihSaat']?.toString() ?? '',
        stadyum: item['stadyum']?.toString() ?? '',
      )).where((mac) => mac.evSahibi.isNotEmpty && mac.deplasman.isNotEmpty).toList();
    }

    return GelisimLigVeriSonucu(
      puanlar: puanlariOku(veri['puanlar']),
      maclar: maclariOku(veri['maclar']),
      cachetenGeldi: true,
    );
  }

  static Future<GelisimLigVeriSonucu> getir(GelisimLigBilgisi lig, {bool tamFikstur = true}) async {
    // TFF tarafı erişilemez olduğunda son başarılı grup verisini kullan.
    final cache = await cacheOku(lig);

    // Grup ID'si her sezon değişebildiği için canlı TFF sayfasından bul.
    final groupId = await _guncelGrupIdBul(lig);
    if (groupId == null) {
      if (cache != null) return cacheVeridenGetir(cache.veri);
      throw Exception('TFF ${lig.ad} ${lig.grup} bulunamadı.');
    }

    try {
      final anaSayfaSonucu = await _grupAnaSayfaGetir(lig, groupId);

      debugPrint('TFF ANA SAYFA PUAN: ${anaSayfaSonucu.puanlar.length} takım');
      debugPrint(
        'TFF ANA SAYFA PUAN: ${anaSayfaSonucu.puanlar.map((e) => '${e.takim}: ${e.puan}').join(' | ')}',
      );

      final benzersiz = <String, MacBilgisi>{};
      void macEkle(MacBilgisi mac, {int? haftaNo}) {
        final duzeltilmis = MacBilgisi(
          hafta: mac.hafta.isNotEmpty ? mac.hafta : (haftaNo == null ? '' : '$haftaNo. Hafta'),
          evSahibi: mac.evSahibi,
          deplasman: mac.deplasman,
          sonuc: mac.sonuc,
          tarihSaat: mac.tarihSaat,
          stadyum: mac.stadyum,
        );
        final anahtar = '${duzeltilmis.hafta}|${duzeltilmis.evSahibi}|${duzeltilmis.deplasman}|${duzeltilmis.tarihSaat}|${duzeltilmis.sonuc}';
        benzersiz[anahtar] = duzeltilmis;
      }

      for (final mac in anaSayfaSonucu.maclar) {
        macEkle(mac, haftaNo: 1);
      }

      // Puan durumu TFF ana sayfasından hemen hazırdır. Tam fikstürü
      // bekletmek ekranın açılmasını gereksiz yere dakikalarca geciktirebilir.
      // Bu nedenle puan durumu önce döndürülür; tam fikstür arka planda
      // tamamlanır.
      if (!tamFikstur) {
        final ilkSonuc = GelisimLigVeriSonucu(
          puanlar: anaSayfaSonucu.puanlar,
          maclar: benzersiz.values.toList(),
        );
        unawaited(_tamFiksturuArkaPlanda(lig, groupId));
        await cacheKaydet(lig, ilkSonuc);
        return ilkSonuc;
      }

      await _tamFiksturuBenzersizTopla(lig, groupId, benzersiz, macEkle);

      final siraliMaclar = benzersiz.values.toList();
      siraliMaclar.sort((a, b) {
        final ah = int.tryParse(RegExp(r'\d+').firstMatch(a.hafta)?.group(0) ?? '') ?? 999;
        final bh = int.tryParse(RegExp(r'\d+').firstMatch(b.hafta)?.group(0) ?? '') ?? 999;
        if (ah != bh) return ah.compareTo(bh);
        return a.tarihSaat.compareTo(b.tarihSaat);
      });

      // Gelişim Ligi verilerinde manuel takım ekleme yapılmaz.
      // Puan durumu ve maçlar yalnızca TFF'den gelen canlı veriden oluşur.
      debugPrint('TFF PUAN DEBUG: ${anaSayfaSonucu.puanlar.length} takım');
      debugPrint('TFF PUAN DEBUG: ${anaSayfaSonucu.puanlar.map((e) => '${e.takim}: ${e.puan}').join(' | ')}');


      final sonuc = GelisimLigVeriSonucu(
        puanlar: anaSayfaSonucu.puanlar,
        maclar: siraliMaclar,
      );
      await cacheKaydet(lig, sonuc);
      return sonuc;
    } catch (e) {
      debugPrint('TFF canlı veri alınamadı (${lig.ad} ${lig.grup}): $e');
      if (cache != null) return cacheVeridenGetir(cache.veri);
      rethrow;
    }
  }

  static Future<void> _tamFiksturuArkaPlanda(
    GelisimLigBilgisi lig,
    int groupId,
  ) async {
    try {
      final ana = await _grupAnaSayfaGetir(lig, groupId);
      final benzersiz = <String, MacBilgisi>{};
      void macEkle(MacBilgisi mac, {int? haftaNo}) {
        final duzeltilmis = MacBilgisi(
          hafta: mac.hafta.isNotEmpty ? mac.hafta : (haftaNo == null ? '' : '$haftaNo. Hafta'),
          evSahibi: mac.evSahibi,
          deplasman: mac.deplasman,
          sonuc: mac.sonuc,
          tarihSaat: mac.tarihSaat,
          stadyum: mac.stadyum,
        );
        final anahtar = '${duzeltilmis.hafta}|${duzeltilmis.evSahibi}|${duzeltilmis.deplasman}|${duzeltilmis.tarihSaat}|${duzeltilmis.sonuc}';
        benzersiz[anahtar] = duzeltilmis;
      }
      for (final mac in ana.maclar) {
        macEkle(mac, haftaNo: 1);
      }
      await _tamFiksturuBenzersizTopla(lig, groupId, benzersiz, macEkle);
      final maclar = benzersiz.values.toList();
      maclar.sort((a, b) {
        final ah = int.tryParse(RegExp(r'\d+').firstMatch(a.hafta)?.group(0) ?? '') ?? 999;
        final bh = int.tryParse(RegExp(r'\d+').firstMatch(b.hafta)?.group(0) ?? '') ?? 999;
        if (ah != bh) return ah.compareTo(bh);
        return a.tarihSaat.compareTo(b.tarihSaat);
      });
      await cacheKaydet(lig, GelisimLigVeriSonucu(puanlar: ana.puanlar, maclar: maclar));
      debugPrint('TFF tam fikstür arka planda tamamlandı: ${lig.ad} / ${maclar.length} maç');
    } catch (e) {
      debugPrint('TFF tam fikstür arka planda alınamadı (${lig.ad}): $e');
    }
  }

  static Future<void> _tamFiksturuBenzersizTopla(
    GelisimLigBilgisi lig,
    int groupId,
    Map<String, MacBilgisi> benzersiz,
    void Function(MacBilgisi mac, {int? haftaNo}) macEkle,
  ) async {
    const toplamHafta = 30;
    const parti = 5;
    for (int baslangic = 2; baslangic <= toplamHafta; baslangic += parti) {
      final bitis = (baslangic + parti - 1) > toplamHafta
          ? toplamHafta
          : (baslangic + parti - 1);
      final futures = <Future<MapEntry<int, GelisimLigVeriSonucu?>>>[];
      for (int hafta = baslangic; hafta <= bitis; hafta++) {
        futures.add(() async {
          try {
            final veri = await _haftaGetir(lig, groupId, hafta);
            return MapEntry<int, GelisimLigVeriSonucu?>(hafta, veri);
          } catch (e) {
            debugPrint('TFF hafta alınamadı (${lig.ad} / $hafta): $e');
            return MapEntry<int, GelisimLigVeriSonucu?>(hafta, null);
          }
        }());
      }
      final sonucListesi = await Future.wait(futures);
      for (final kayit in sonucListesi) {
        final veri = kayit.value;
        if (veri == null) continue;
        for (final mac in veri.maclar) {
          macEkle(mac, haftaNo: kayit.key);
        }
      }
    }
  }

  static Future<GelisimLigVeriSonucu> _grupAnaSayfaGetir(
    GelisimLigBilgisi lig,
    int groupId,
  ) async {
    // TFF bazı grup ana sayfalarında 504 verebiliyor. Aynı grubun
    // 1. hafta URL'si çoğu zaman aynı puan cetvelini döndürdüğü için
    // önce ana sayfayı, başarısız olursa hafta=1 adresini deniyoruz.
    final urls = <String>[
      'https://www.tff.org/Default.aspx?grupID=$groupId&pageID=${lig.tffPageId}',
      'https://www.tff.org/Default.aspx?grupID=$groupId&pageID=${lig.tffPageId}&hafta=1',
    ];

    Object? sonHata;
    for (final url in urls) {
      try {
        final response = await _tffGet(url);
        final govde = _tffGovdeyiCoz(response);

        if (!_tffSayfasiGecerliMi(govde)) {
          sonHata = Exception('TFF geçerli lig sayfası döndürmedi.');
          continue;
        }

        final document = html_parser.parse(govde);
        final puanlar = _puanlariBul(document);
        final maclar = _maclariBulGuvenli(document);

        if (puanlar.isEmpty) {
          if (_tffVeriHenuzYayindaDegilMi(govde)) {
            throw const TffVeriHenuzYayinlanmadiException();
          }
          sonHata = Exception('TFF puan durumu tablosu çözümlenemedi.');
          continue;
        }

        debugPrint('TFF gelişim ligi veri kaynağı başarılı: $url');
        return GelisimLigVeriSonucu(
          puanlar: puanlar,
          maclar: maclar,
        );
      } catch (e) {
        sonHata = e;
        debugPrint('TFF grup URL başarısız: $url -> $e');
      }
    }

    throw sonHata ?? Exception('TFF gelişim ligi verisi alınamadı.');
  }

  static Future<http.Response> _tffGet(String url) async {
    final mevcut = _bekleyenIstekler[url];
    if (mevcut != null) return mevcut;

    final future = _tffGetRetry(url);
    _bekleyenIstekler[url] = future;
    try {
      return await future;
    } finally {
      _bekleyenIstekler.remove(url);
    }
  }

  static Future<http.Response> _tffGetRetry(String url) async {
    // TFF, Android istemcilerinden gelen bazı isteklerde HTTP 504
    // döndürebiliyor. Gelişim ligi isteklerini önce Firebase Cloud
    // Function üzerinden geçiriyoruz; Function sunucu tarafından TFF'ye
    // bağlanıyor. Cloud Function başarısız olursa eski doğrudan istek
    // yöntemi yine denenir.
    if (_gelisimTffUrlMu(url)) {
      try {
        final proxy = await _tffCloudGet(url);
        if (proxy.statusCode == 200) {
          debugPrint('TFF Cloud Function başarılı: $url');
          return proxy;
        }
        debugPrint('TFF Cloud Function HTTP ${proxy.statusCode}: $url');
      } catch (e) {
        debugPrint('TFF Cloud Function başarısız: $url -> $e');
      }
    }

    Object? sonHata;

    for (int deneme = 1; deneme <= 2; deneme++) {
      try {
        final response = await http
            .get(
              Uri.parse(url),
              headers: const {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36',
                'Referer': 'https://www.tff.org/',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'tr-TR,tr;q=0.9,en;q=0.7',
                'Cache-Control': 'no-cache',
                'Pragma': 'no-cache',
              },
            )
            .timeout(_istekZamani);

        if (response.statusCode == 200) return response;

        sonHata = Exception('HTTP ${response.statusCode}');
        // 4xx hatalarında aynı isteği tekrar tekrar vurmanın anlamı yok.
        if (response.statusCode >= 400 && response.statusCode < 500) break;
      } catch (e) {
        sonHata = e;
      }

      if (deneme == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }

    throw sonHata ?? Exception('TFF isteği başarısız.');
  }

  static bool _gelisimTffUrlMu(String url) {
    if (!url.contains('www.tff.org/Default.aspx')) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final pageId = int.tryParse(uri.queryParameters['pageID'] ?? '');
    return pageId != null && pageId >= 1751 && pageId <= 1755;
  }

  static Future<http.Response> _tffCloudGet(String url) async {
    final functions = FirebaseFunctions.instanceFor(region: 'europe-west1');
    final callable = functions.httpsCallable(
      'tffGelisimVeri',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );

    final result = await callable.call(<String, dynamic>{'url': url});
    final data = result.data;
    if (data is! Map) {
      throw Exception('TFF Cloud Function geçersiz veri döndürdü.');
    }

    final statusCode = int.tryParse(data['statusCode']?.toString() ?? '') ?? 500;
    final body = data['body']?.toString() ?? '';
    final headers = <String, String>{
      'content-type': data['contentType']?.toString() ?? 'text/html; charset=utf-8',
    };

    return http.Response(body, statusCode, headers: headers);
  }

  static String _tffGovdeyiCoz(http.Response response) {
    final bytes = response.bodyBytes;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';

    // TFF bazı sayfalarda UTF-8 yerine Windows-1254 / ISO-8859-9
    // karakter seti kullanabiliyor. Bu baytları UTF-8 diye okumak,
    // Ş/Ğ/İ gibi karakterleri " " haline getirir ve karakteri sonradan
    // düzeltmek artık mümkün olmaz. Önce charset bilgisini dikkate al.
    final charset1254 = contentType.contains('windows-1254') ||
        contentType.contains('cp1254') ||
        contentType.contains('iso-8859-9');

    if (charset1254) {
      return _tffKarakterleriniDuzelt(latin1.decode(bytes));
    }

    // Charset belirtilmemişse önce UTF-8 dene. Eğer geçersiz baytlar
    // nedeniyle çok sayıda replacement character oluşmuşsa, TFF'nin
    // eski Latin-1/Windows-1254 çıktısı olma ihtimaline karşı Latin-1
    // çözümlemeyi dene.
    final utf8Govde = utf8.decode(bytes, allowMalformed: true);
    final bozukSayisi = ' '.allMatches(utf8Govde).length;
    if (bozukSayisi >= 2) {
      return _tffKarakterleriniDuzelt(latin1.decode(bytes));
    }

    return _tffKarakterleriniDuzelt(utf8Govde);
  }

  static bool _tffSayfasiGecerliMi(String govde) {
    if (govde.trim().isEmpty) return false;
    final norm = _normalize(govde);
    if (norm.contains('serviceunavailable') ||
        norm.contains('temporarilyunavailable') ||
        norm.contains('internalservererror')) {
      return false;
    }
    return govde.toLowerCase().contains('<html') ||
        govde.toLowerCase().contains('<table');
  }

  // DÜZELTME: TFF sayfası HTTP 200 ve geçerli HTML ile dönebiliyor,
  // ama sayfa içeriği "bu grup/hafta için veri henüz yok" anlamına
  // gelen bir uyarı metni içeriyor olabilir (ör. "puan cetveli hazır
  // değil"). Bu durumda tabloyu "çözümleyemedik" demek yanlış olur;
  // gerçekte çözümlenecek bir tablo hiç yok. _normalize Türkçe
  // karakterleri sadeleştirdiği için TFF'nin Windows-1254 kaynaklı
  // karakter bozulmalarından etkilenmeden karşılaştırma yapabiliyoruz.
  static bool _tffVeriHenuzYayindaDegilMi(String govde) {
    final norm = _normalize(govde);
    return norm.contains('puancetvelihazirdegil') ||
        norm.contains('fiksturhazirdegil') ||
        norm.contains('henuzolusmadi') ||
        norm.contains('henuzyayinlanmadi');
  }

  static List<MacBilgisi> _maclariBulGuvenli(dom.Document document) {
    try {
      return _maclariBul(document);
    } catch (_) {
      return <MacBilgisi>[];
    }
  }

  static int? _sabit2026GrupId(GelisimLigBilgisi lig) {
    // 2026-2027 için doğrulanmış TFF grup ID'leri.
    // TFF ana sayfasındaki grup linklerini dinamik çözmek bazı yaşlarda
    // yanlış/boş sonuç verebildiği için bilinen Yalova gruplarını doğrudan kullanıyoruz.
    switch (lig.tffPageId) {
      case 1755: return 3906; // U14 - 5. Grup (2026-2027 güncel TFF)
      case 1754: return 3924; // U15 - 5. Grup (2026-2027 güncel TFF)
      case 1753: return 3875; // U16 - 6. Grup
      case 1752: return 3858; // U17 - 6. Grup
      case 1751: return 3892; // U19 - 6. Grup (2026-2027 güncel TFF)
    }
    return null;
  }

  static Future<int?> _guncelGrupIdBul(GelisimLigBilgisi lig) async {
    final bellekAnahtari = _cacheKaynak(lig);

    final sabitId = _sabit2026GrupId(lig);
    if (sabitId != null) {
      await _grupIdKaydet(lig, bellekAnahtari, sabitId);
      debugPrint('TFF 2026-2027 sabit grup ID kullanıldı: ${lig.ad} -> $sabitId');
      return sabitId;
    }
    final bellekTarihi = _grupCacheTarih[bellekAnahtari];

    // Grup ID'leri TFF tarafından sezon içinde bile değiştirilebildiği için
    // belleği kısa tutuyoruz. Eski grup sayfası yayında kalırken ana sayfadaki
    // güncel grup linki yeni bir ID'ye taşınabiliyor.
    if (_grupCache.containsKey(bellekAnahtari) &&
        bellekTarihi != null &&
        DateTime.now().difference(bellekTarihi) < _grupBellekSuresi) {
      return _grupCache[bellekAnahtari];
    }

    try {
      final url = 'https://www.tff.org/Default.aspx?pageID=${lig.tffPageId}';
      final response = await _tffGet(url);
      final govde = _tffGovdeyiCoz(response);
      if (!_tffSayfasiGecerliMi(govde)) {
        throw Exception('TFF grup listesi geçerli bir sayfa döndürmedi.');
      }

      final document = html_parser.parse(govde);
      final hedefNo = RegExp(r'\d+').firstMatch(lig.grup)?.group(0);
      if (hedefNo == null) return null;

      final adaylar = <int>[];
      void adayEkle(int? id) {
        if (id != null && id > 0 && !adaylar.contains(id)) adaylar.add(id);
      }

      bool hedefGrupMetni(String text) {
        final temiz = _tffKarakterleriniDuzelt(text).trim();
        final match = RegExp(
          r'^\s*(\d+)\s*\.?\s*GRUP\s*$',
          caseSensitive: false,
        ).firstMatch(temiz);
        return match?.group(1) == hedefNo;
      }

      // 1) En güvenilir yol: TFF'nin güncel grup menüsündeki bağlantı.
      // href/onclick/data-* ayrımı yapmadan hedef linkin tüm attribute'larını tara.
      for (final anchor in document.querySelectorAll('a')) {
        if (!hedefGrupMetni(anchor.text)) continue;
        for (final value in anchor.attributes.values) {
          adayEkle(_grupIdDegerindenCikar(value));
        }
      }

      // 2) Bazı TFF sayfalarında grup seçimi option olarak gelebiliyor.
      for (final option in document.querySelectorAll('option')) {
        if (!hedefGrupMetni(option.text)) continue;
        for (final value in option.attributes.values) {
          adayEkle(_grupIdDegerindenCikar(value));
        }
      }

      // 3) Hedef grup metni başka bir elementteyse ilgili attribute'ları tara.
      if (adaylar.isEmpty) {
        for (final element in document.querySelectorAll('[onclick], [href], [value]')) {
          if (!hedefGrupMetni(element.text)) continue;
          for (final value in element.attributes.values) {
            adayEkle(_grupIdDegerindenCikar(value));
          }
        }
      }

      // 4) DOM parser bozuk HTML nedeniyle attribute'u kaçırırsa ham HTML'de
      // "6.GRUP" gibi hedef linkin bulunduğu tag'i doğrudan tara.
      if (adaylar.isEmpty) {
        final tagRegex = RegExp(
          r'<[^>]+>\s*' +
              RegExp.escape(hedefNo) +
              r'\s*\.?\s*GRUP\s*</[^>]+>',
          caseSensitive: false,
        );
        for (final match in tagRegex.allMatches(govde)) {
          adayEkle(_grupIdDegerindenCikar(match.group(0) ?? ''));
        }
      }

      // Canlı ana sayfadan bulunan aday güncel kaynaktır. Eski grup sayfaları
      // TFF'de erişilebilir kalabildiği için eski ID'yi bunun önüne geçirmiyoruz.
      if (adaylar.isNotEmpty) {
        final adayId = adaylar.first;
        await _grupIdKaydet(lig, bellekAnahtari, adayId);
        return adayId;
      }

      // 5) TFF'nin ana sayfası bazı kategorilerde grup bağlantılarını
      // HTML attribute'larına grupID olarak yazmıyor. U19 2026-2027'de bu
      // durum görülüyor. Dinamik çözüm başarısızsa bilinen güncel U19 grup
      // ID aralığından hedef grubu üretip, sayfanın gerçekten o grubu
      // gösterdiğini doğruluyoruz. Böylece yanlış ID'yi sessizce kullanmayız.
      final dogrulanmisYedek = await _dogrulanmisGrupIdYedegi(lig, hedefNo);
      if (dogrulanmisYedek != null) {
        await _grupIdKaydet(lig, bellekAnahtari, dogrulanmisYedek);
        return dogrulanmisYedek;
      }

      debugPrint('TFF hedef grup linki bulunamadı: ${lig.ad} / ${lig.grup}');
    } catch (e) {
      debugPrint('TFF güncel grup ID alınamadı (${lig.ad}): $e');

      // Ana grup listesine geçici olarak erişilemiyorsa son bilinen ID'yi dene.
      // Bu sadece hata durumunda devreye girer; canlı sayfa başarıyla açılmışsa
      // eski ID hiçbir zaman güncel linkin önüne geçmez.
      final bellekId = _grupCache[bellekAnahtari];
      if (bellekId != null && bellekId > 0) return bellekId;

      try {
        final eski = await SiteVeriCache.oku(
          tur: 'gelisim_grup',
          kaynak: '${lig.tffPageId}-${lig.grup}',
        );
        final eskiId = int.tryParse(eski?.veri?.toString() ?? '');
        if (eskiId != null && eskiId > 0) return eskiId;
      } catch (_) {}
    }

    _grupCache.remove(bellekAnahtari);
    _grupCacheTarih.remove(bellekAnahtari);
    return null;
  }

  static Future<void> _grupIdKaydet(
    GelisimLigBilgisi lig,
    String bellekAnahtari,
    int grupId,
  ) async {
    _grupCache[bellekAnahtari] = grupId;
    _grupCacheTarih[bellekAnahtari] = DateTime.now();
    await SiteVeriCache.kaydet(
      tur: 'gelisim_grup',
      kaynak: '${lig.tffPageId}-${lig.grup}',
      veri: grupId,
    );
  }

  static int? _grupIdDegerindenCikar(String value) {
    final match = RegExp(
      r"""grupID\s*=\s*[\"']?(\d+)""",
      caseSensitive: false,
    ).firstMatch(value);
    if (match != null) return int.tryParse(match.group(1)!);

    final temiz = value.trim();
    if (RegExp(r'^\d+$').hasMatch(temiz)) {
      return int.tryParse(temiz);
    }
    return null;
  }

  static Future<int?> _dogrulanmisGrupIdYedegi(
    GelisimLigBilgisi lig,
    String hedefNo,
  ) async {
    final grupNo = int.tryParse(hedefNo);
    if (grupNo == null || grupNo <= 0) return null;

    // U19 Gelişim Ligi 2026-2027 sezonunda 1.GRUP = 3821 ve grup ID'leri
    // sıralı ilerliyor. Örn. 6.GRUP = 3826. Bu sadece dinamik tarama
    // başarısız olduğunda kullanılan bir yedektir ve aşağıda canlı sayfa
    // içeriğiyle mutlaka doğrulanır.
    int? adayId;
    if (lig.tffPageId == 1751 && grupNo >= 1 && grupNo <= 15) {
      adayId = 3820 + grupNo;
    }

    if (adayId == null) return null;

    try {
      final url =
          'https://www.tff.org/Default.aspx?grupID=$adayId&pageID=${lig.tffPageId}';
      final response = await _tffGet(url);
      final govde = _tffGovdeyiCoz(response);
      if (!_tffSayfasiGecerliMi(govde)) return null;

      final document = html_parser.parse(govde);
      final text = _normalize(document.body?.text ?? govde);
      final beklenen = _normalize('$grupNo.GRUP');

      // Başlıkta/hafta bilgisinde hedef grubun görünmesi doğrulama için yeterli.
      if (!text.contains(beklenen)) return null;

      debugPrint(
        'TFF grup ID yedeği doğrulandı: ${lig.ad} / ${lig.grup} -> $adayId',
      );
      return adayId;
    } catch (e) {
      debugPrint('TFF grup ID yedeği doğrulanamadı (${lig.ad}): $e');
      return null;
    }
  }

  static Future<GelisimLigVeriSonucu> _haftaGetir(
    GelisimLigBilgisi lig,
    int groupId,
    int hafta,
  ) async {
    final url = 'https://www.tff.org/Default.aspx?pageID=${lig.tffPageId}&grupID=$groupId&hafta=$hafta';

    final response = await _tffGet(url);
    final govde = _tffGovdeyiCoz(response);
    final document = html_parser.parse(govde);
    final puanlar = _puanlariBul(document);
    final maclar = _maclariBulGuvenli(document);
    if (puanlar.isEmpty) {
      if (_tffVeriHenuzYayindaDegilMi(govde)) {
        throw const TffVeriHenuzYayinlanmadiException();
      }
      throw Exception('TFF hafta $hafta puan durumu çözümlenemedi.');
    }

    return GelisimLigVeriSonucu(
      puanlar: puanlar,
      maclar: maclar,
    );
  }

  // ------------------------------------------------------------
  // TFF HTML TEŞHİSİ
  // ------------------------------------------------------------
  // TFF sayfası 200 dönüyor ve tablolar mevcut. Sorun, HTML'in
  // bizim beklediğimiz klasik <tr><th>Takım...</th></tr> yapısında
  // olmaması olabilir. Bu nedenle ilk birkaç satırı kontrollü şekilde
  // loglayıp gerçek yapıyı tespit ediyoruz.
  static List<TakimPuan> _puanlariBul(dom.Document document) {
    final tables = document.querySelectorAll('table');

    // TFF'nin puan cetvelinde başlık satırı "O G B M A Y AV P" şeklinde
    // geliyor; "Takım" başlığı ayrı bir HTML elemanında olabiliyor.
    // Bu yüzden önce standart başlığı, sonra da doğrudan veri satırlarını tarıyoruz.
    for (final table in tables) {
      final rows = table.querySelectorAll('tr');
      if (rows.length < 2) continue;

      for (int headerRowIndex = 0; headerRowIndex < rows.length && headerRowIndex < 10; headerRowIndex++) {
        final header = rows[headerRowIndex].querySelectorAll('th,td').map(_hucreMetni).toList();
        final normalized = header.map(_normalize).toList();
        final puanIndex = normalized.indexOf('p');
        final oIndex = normalized.indexOf('o');
        final gIndex = normalized.indexOf('g');
        final bIndex = normalized.indexOf('b');
        final mIndex = normalized.indexOf('m');
        final agIndex = normalized.indexOf('a');
        final ygIndex = normalized.indexOf('y');
        final avIndex = normalized.indexOf('av');

        if (puanIndex == -1 || oIndex == -1 || gIndex == -1 ||
            bIndex == -1 || mIndex == -1 || agIndex == -1 ||
            ygIndex == -1 || avIndex == -1) {
          continue;
        }

        // Takım hücresi başlıkta yoksa veri satırının ilk hücresidir.
        int takimIndex = normalized.indexWhere(
          (h) => h == 'takim' || h.startsWith('takim') || h.contains('takimadi'),
        );
        if (takimIndex == -1) {
          // Bazı TFF tablolarında sıra numarası ayrı hücrede,
          // takım adı ikinci hücrede geliyor. Bazılarında ise
          // "1.TAKIM ADI" tek hücrede birleşiyor.
          // Önce ilk iki hücrede gerçek takım adını bul.
          takimIndex = _takimHucreIndexBul(
            rows[headerRowIndex + 1]
                .querySelectorAll('th,td')
                .map(_hucreMetni)
                .toList(),
          );
          if (takimIndex == -1) takimIndex = 0;
        }

        final bulunanlar = <TakimPuan>[];
        for (int i = headerRowIndex + 1; i < rows.length; i++) {
          final cells = rows[i].querySelectorAll('th,td');
          final values = cells.map(_hucreMetni).toList();
          if (values.length < 9) continue;

          final takim = _temizTakimAdi(_value(values, takimIndex));

          // TFF bazı takım satırlarında isim biçimini farklı gönderebiliyor.
          // Önce 8 istatistik hücresini buluyoruz; gerçek puan satırıysa
          // takım adını mümkün olduğunca kabul ediyoruz. Böylece özellikle
          // 8. sıra gibi tek bir satırın filtrelenmesi engelleniyor.

          // TFF aynı sayfada 1. Devre / 2. Devre özet satırlarını da
          // tablo benzeri yapılarda gösterebiliyor. Bunlar takım değildir.
          final takimNormalize = _normalize(takim);
          if (takimNormalize.contains('devre')) continue;
          if (takimNormalize.contains('grup')) continue;
          if (takimNormalize.contains('hafta')) continue;
          if (takimNormalize == '1' || takimNormalize == '2') continue;
          if (takim.length < 3) continue;

          // Bu tablo için takım hücresinden sonraki 8 sayı doğrudan
          // O-G-B-M-A-Y-AV-P sırasındadır.
          final numbers = <int>[];
          for (int j = takimIndex + 1; j < values.length; j++) {
            final n = _sayisalHucre(values[j]);
            if (n != null) numbers.add(n);
          }
          if (numbers.length < 8) {
            continue;
          }

          final takimHucre = cells[takimIndex];
          final logo = takimHucre.querySelector('img');
          final anchor = takimHucre.querySelector('a');

          bulunanlar.add(TakimPuan(
            sira: _satirSiraBul(values) ?? (bulunanlar.length + 1),
            takim: takim,
            oynanan: numbers[0],
            galibiyet: numbers[1],
            beraberlik: numbers[2],
            maglubiyet: numbers[3],
            atilanGol: numbers[4],
            yenilenGol: numbers[5],
            averaj: numbers[6],
            puan: numbers[7],
            logoUrl: logo == null ? '' : _mutlakTffUrl(logo.attributes['src'] ?? ''),
            takimUrl: anchor == null ? '' : _mutlakTffUrl(anchor.attributes['href'] ?? ''),
          ));
        }

        if (bulunanlar.length >= 2) {
          bulunanlar.sort((a, b) => a.sira.compareTo(b.sira));
          return bulunanlar;
        }
      }
    }

    // Son güvenlik ağı: TFF'nin puan tablosunda takım sütunu bazen
    // başlık yapısından farklı gelebiliyor. İlk hücrede sıra numarası,
    // devamında tam 8 istatistik bulunan satırları doğrudan kabul et.
    final fallback = <String, TakimPuan>{};
    for (final table in tables) {
      final rows = table.querySelectorAll('tr');
      for (final row in rows) {
        final cells = row.querySelectorAll('th,td');
        final values = cells.map(_hucreMetni).toList();
        if (values.length < 9) continue;

        final takim = _temizTakimAdi(values.first);
        final norm = _normalize(takim);
        if (!_gecerliTakimAdi(takim) || norm.contains('devre') ||
            norm.contains('grup') || norm.contains('hafta')) {
          continue;
        }

        final numbers = <int>[];
        for (final value in values.skip(1)) {
          final n = _sayisalHucre(value);
          if (n != null) numbers.add(n);
        }
        if (numbers.length < 8) continue;

        final sira = _satirSiraBul(values);
        if (sira == null) continue;

        final takimHucre = cells.first;
        final logo = takimHucre.querySelector('img');
        final anchor = takimHucre.querySelector('a');
        final aday = TakimPuan(
          sira: sira,
          takim: takim,
          oynanan: numbers[0],
          galibiyet: numbers[1],
          beraberlik: numbers[2],
          maglubiyet: numbers[3],
          atilanGol: numbers[4],
          yenilenGol: numbers[5],
          averaj: numbers[6],
          puan: numbers[7],
          logoUrl: logo == null ? '' : _mutlakTffUrl(logo.attributes['src'] ?? ''),
          takimUrl: anchor == null ? '' : _mutlakTffUrl(anchor.attributes['href'] ?? ''),
        );

        // Normal parser hiçbir tabloyu döndüremediğinde tüm geçerli
        // satırları topluyoruz; yalnızca ilk takımı döndürmek veri kaybına
        // neden oluyordu.
        fallback[_normalize(takim)] = aday;
      }
    }

    // Son katman: bazı TFF sayfalarında (özellikle U19) puan cetveli
    // hücrelere ayrılmış görünse bile html parser satırı tek/az sayıda hücre
    // olarak döndürebiliyor. Bu durumda satırın tamamını metin olarak çöz.
    // Biçim: 1.TAKIM ADI O G B M A Y AV P
    for (final row in document.querySelectorAll('tr')) {
      final aday = _puanSatirMetnindenCoz(row.text);
      if (aday != null) {
        fallback[_normalize(aday.takim)] = aday;
      }
    }

    // TFF bazı tabloları iç içe elemanlarla ürettiğinde tr metni de yeterli
    // olmayabiliyor. Son çare olarak puan cetveline benzeyen küçük blokları tara.
    if (fallback.length < 2) {
      for (final element in document.querySelectorAll('td, li, div')) {
        final metin = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (metin.length < 8 || metin.length > 300) continue;
        final aday = _puanSatirMetnindenCoz(metin);
        if (aday != null) {
          fallback[_normalize(aday.takim)] = aday;
        }
      }
    }

    final sonuc = fallback.values.toList()
      ..sort((a, b) => a.sira.compareTo(b.sira));
    return sonuc;
  }

  static TakimPuan? _puanSatirMetnindenCoz(String hamMetin) {
    final metin = _tffKarakterleriniDuzelt(hamMetin)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Sıra + takım adı + sonda tam 8 istatistik. Takım adının içinde
    // "77", "1922" veya "A.Ş." gibi sayı/nokta bulunmasına izin verir.
    final eslesme = RegExp(
      r'^\s*(\d{1,2})\s*[.]?\s*(.+?)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s*$',
    ).firstMatch(metin);
    if (eslesme == null) return null;

    final sira = int.tryParse(eslesme.group(1) ?? '');
    final takim = _temizTakimAdi(eslesme.group(2) ?? '');
    if (sira == null || sira < 1 || sira > 99 || !_gecerliTakimAdi(takim)) {
      return null;
    }

    final sayilar = <int>[];
    for (int i = 3; i <= 10; i++) {
      final n = int.tryParse(eslesme.group(i) ?? '');
      if (n == null) return null;
      sayilar.add(n);
    }

    return TakimPuan(
      sira: sira,
      takim: takim,
      oynanan: sayilar[0],
      galibiyet: sayilar[1],
      beraberlik: sayilar[2],
      maglubiyet: sayilar[3],
      atilanGol: sayilar[4],
      yenilenGol: sayilar[5],
      averaj: sayilar[6],
      puan: sayilar[7],
    );
  }

  static int _takimHucreIndexBul(List<String> cells) {
    for (int i = 0; i < cells.length && i < 3; i++) {
      final value = cells[i].trim();
      if (RegExp(r'^\d+\.?$').hasMatch(value)) continue;
      if (_gecerliTakimAdi(value) && !_sayisalHucreMi(value)) return i;
    }
    return -1;
  }

  static bool _sayisalHucreMi(String value) => _sayisalHucre(value) != null;

  static int? _satirSiraBul(List<String> cells) {
    for (final cell in cells.take(2)) {
      final temiz = cell.replaceAll(RegExp(r'[^0-9]'), '');
      final n = int.tryParse(temiz);
      if (n != null && n > 0 && n < 100) return n;
    }
    return null;
  }

  static int? _sayisalHucre(String value) {
    final temiz = value.trim().replaceAll(',', '.');
    if (!RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(temiz)) return null;
    return int.tryParse(temiz.split('.').first);
  }

  static bool _gecerliTakimAdi(String takim) {
    final n = _normalize(takim);
    if (takim.length < 4) return false;
    if (n == 'takim' || n == 'takimadi' || n == 'bay') return false;
    if (RegExp(r'^\d+[.]?$').hasMatch(takim.trim())) return false;
    return true;
  }

  static List<MacBilgisi> _maclariBul(dom.Document document) {
    final List<MacBilgisi> maclar = <MacBilgisi>[];
    final tarihRegex = RegExp(r'\b\d{1,2}[.]\d{1,2}[.]\d{4}\b');
    final saatRegex = RegExp(r'\b\d{1,2}:\d{2}\b');

    // TFF maç skorlarını "2-1" biçiminde yayınlıyor. ':' kabul etmiyoruz;
    // aksi halde 11:00 gibi maç saati yanlışlıkla skor sanılabiliyor.
    final skorRegex = RegExp(r'(?<!\d)\d+\s*-\s*\d+(?!\d)');

    for (final table in document.querySelectorAll('table')) {
      final rows = table.querySelectorAll('tr');
      for (final row in rows) {
        final cells = row
            .querySelectorAll('th,td')
            .map(_hucreMetni)
            .where((x) => x.isNotEmpty)
            .toList();
        if (cells.isEmpty) continue;

        final satir = _tffKarakterleriniDuzelt(cells.join(' | '))
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final tarihMatch = tarihRegex.firstMatch(satir);
        if (tarihMatch == null) continue;

        String? ev;
        String? dep;
        String sonuc = '';

        // Önce klasik ayrı hücre yapısını çöz.
        for (final cellHam in cells) {
          final cell = _tffKarakterleriniDuzelt(cellHam).trim();
          if (tarihRegex.hasMatch(cell) || saatRegex.hasMatch(cell)) continue;

          final skor = skorRegex.firstMatch(cell);
          if (skor != null && cell.replaceAll(RegExp(r'\s+'), '').length <= 7) {
            sonuc = skor.group(0)!.replaceAll(' ', '');
            continue;
          }

          if (_gecerliMacTakimi(cell)) {
            if (ev == null) {
              ev = cell;
            } else if (dep == null && _normalize(cell) != _normalize(ev)) {
              dep = cell;
              break;
            }
          }
        }

        // TFF bazı haftalarda bütün maçı tek hücre/blok olarak döndürüyor:
        // 20.09.2026 11:00 EV SAHİBİ 2-1 DEPLASMAN Detaylar
        // Skoru ayraç olarak kullanarak takım adlarını doğrudan satırdan çıkar.
        final skorMatch = skorRegex.firstMatch(satir);
        if (skorMatch != null) {
          sonuc = skorMatch.group(0)!.replaceAll(' ', '');

          var sol = satir.substring(0, skorMatch.start);
          var sag = satir.substring(skorMatch.end);

          sol = sol.replaceFirst(tarihRegex, ' ');
          sol = sol.replaceFirst(saatRegex, ' ');
          sol = sol.replaceAll('|', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

          sag = sag
              .replaceAll(RegExp(r'\bDetaylar?\b', caseSensitive: false), ' ')
              .replaceAll('|', ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

          if (_gecerliMacTakimi(sol)) ev = sol;
          if (_gecerliMacTakimi(sag)) dep = sag;
        }

        // Skor henüz yoksa eski "EV - DEPLASMAN" yapısını çöz.
        if (ev == null || dep == null) {
          for (final cell in cells) {
            final parcalar = _tffKarakterleriniDuzelt(cell)
                .split(RegExp(r'\s+-\s+'))
                .map(_temizle)
                .where((x) => x.isNotEmpty)
                .toList();
            if (parcalar.length >= 2) {
              for (int j = 0; j < parcalar.length - 1; j++) {
                if (_gecerliMacTakimi(parcalar[j]) &&
                    _gecerliMacTakimi(parcalar[j + 1])) {
                  ev = parcalar[j];
                  dep = parcalar[j + 1];
                  break;
                }
              }
            }
            if (ev != null && dep != null) break;
          }
        }

        if (ev == null || dep == null) continue;

        final tarih = tarihMatch.group(0)!;
        final saat = saatRegex.firstMatch(satir)?.group(0);
        final tarihSaat = saat == null ? tarih : '$tarih $saat';
        final haftaMatch = RegExp(
          r'(\d+)\s*[.]\s*hafta',
          caseSensitive: false,
        ).firstMatch(satir);
        final hafta = haftaMatch == null ? '' : '${haftaMatch.group(1)}. Hafta';

        maclar.add(MacBilgisi(
          hafta: hafta,
          evSahibi: _temizle(ev),
          deplasman: _temizle(dep),
          sonuc: _temizle(sonuc),
          tarihSaat: tarihSaat,
          stadyum: '',
        ));
      }
    }

    // Aynı maç farklı/iç içe TFF tablolarında tekrar edebiliyor.
    // Anahtara skoru katmıyoruz. Aynı maçın hem boş hem skorlu kopyası varsa
    // skorlu olanı saklıyoruz; böylece ekranda eski boş kayıt yüzünden VS kalmaz.
    final benzersiz = <String, MacBilgisi>{};
    for (final mac in maclar) {
      final anahtar = '${mac.tarihSaat}|${_normalize(mac.evSahibi)}|${_normalize(mac.deplasman)}';
      final mevcut = benzersiz[anahtar];
      if (mevcut == null ||
          (mevcut.sonuc.trim().isEmpty && mac.sonuc.trim().isNotEmpty)) {
        benzersiz[anahtar] = mac;
      }
    }
    return benzersiz.values.toList();
  }

  static bool _gecerliMacTakimi(String value) {
    final n = _normalize(value);
    if (value.length < 4) return false;
    if (n == 'detaylar' || n == 'detay' || n == 'fikstur' || n == 'puan' ||
        n.contains('grup') || n.contains('hafta') || n.contains('devre')) return false;
    if (_muhtemelSkor(value)) return false;
    if (RegExp(r'^\d+[.]?\s*\d*$').hasMatch(value)) return false;
    if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(value)) return false;
    return true;
  }

  static bool _muhtemelSkor(String value) {
    return RegExp(r'^\d+\s*[-:]\s*\d+$').hasMatch(value.trim()) ||
        _normalize(value).contains('bekleniyor');
  }

  static bool _muhtemelTakimAdi(String value) => _gecerliMacTakimi(value);

  // TFF bazı sayfalarda Türkçe Windows-1254 karakterlerini UTF-8 yerine
  // Latin-1 benzeri şekilde çözümlenmiş olarak döndürebiliyor. Örneğin:
  // Ð=Ğ, Þ=Ş, Ý=İ, þ=ş, ý=ı, ð=ğ, ü/ö/ç ise normal kalabiliyor.
  // Önce metni düzeltip sonra parser'a veriyoruz.
  static String _tffKarakterleriniDuzelt(String value) {
    return value
        .replaceAll('Ð', 'Ğ')
        .replaceAll('Þ', 'Ş')
        .replaceAll('Ý', 'İ')
        .replaceAll('ð', 'ğ')
        .replaceAll('þ', 'ş')
        .replaceAll('ý', 'ı')
        .replaceAll('Ð', 'Ğ')
        .replaceAll('Ý', 'İ');
  }

  static String _hucreMetni(dom.Element cell) {
    String text = cell.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final alts = cell
        .querySelectorAll('img')
        .map((img) => _tffKarakterleriniDuzelt(img.attributes['alt']?.trim() ?? ''))
        .where((alt) => alt.isNotEmpty && alt.toLowerCase() != 'image')
        .toList();
    if ((text.isEmpty || text.toLowerCase() == 'image') && alts.isNotEmpty) {
      text = alts.join(' - ');
    }
    text = _tffKarakterleriniDuzelt(text);
    return text.replaceFirst(RegExp(r'^Image\s+', caseSensitive: false), '').trim();
  }

  static String _temizTakimAdi(String text) {
    return text
        .replaceAll(RegExp(r'↑\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'↓\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\d+\s*\.\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _temizle(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _value(List<String> values, int index) {
    if (index < 0 || index >= values.length) return '';
    return values[index];
  }

  static int _sayi(String text) {
    final clean = text.replaceAll(RegExp(r'[^0-9-]'), '');
    return int.tryParse(clean) ?? 0;
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _mutlakTffUrl(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return 'https://www.tff.org$value';
    return 'https://www.tff.org/$value';
  }
}

// ============================================================
// GELİŞİM LİGİ BİLGİSİ
// ============================================================

class GelisimLigBilgisi {
  final String ad;
  final String grup;
  final List<String> yalovaTakimlari;
  final int tffPageId;

  const GelisimLigBilgisi({
    required this.ad,
    required this.grup,
    required this.yalovaTakimlari,
    required this.tffPageId,
  });
}

// ============================================================
// GELİŞİM LİGİ VERİLERİ
// ============================================================

class GelisimLigVerileri {
  static const List<GelisimLigBilgisi> sezon2026 = [
    GelisimLigBilgisi(
      ad: 'U14 Gelişim Ligi',
      grup: '5. Grup',
      tffPageId: 1755,
      yalovaTakimlari: [
        'Yalova Gücü Spor',
        'Çalıca Gençlik Spor',
      ],
    ),
    GelisimLigBilgisi(
      ad: 'U15 Gelişim Ligi',
      grup: '5. Grup',
      tffPageId: 1754,
      yalovaTakimlari: [
        'Yalova Gücü Spor',
        'Çalıca Gençlik Spor',
      ],
    ),
    GelisimLigBilgisi(
      ad: 'U16 Gelişim Ligi',
      grup: '6. Grup',
      tffPageId: 1753,
      yalovaTakimlari: [
        'Yalova Gücü Spor',
        'Çalıca Gençlik Spor',
      ],
    ),
    GelisimLigBilgisi(
      ad: 'U17 Gelişim Ligi',
      grup: '6. Grup',
      tffPageId: 1752,
      yalovaTakimlari: [
        'Yalova Gücü Spor',
        'Çalıca Gençlik Spor',
      ],
    ),
    GelisimLigBilgisi(
      ad: 'U19 Gelişim Ligi',
      grup: '6. Grup',
      tffPageId: 1751,
      yalovaTakimlari: [
        'Çiftlikköy Belediyesi Spor Kulübü',
        'Yalova FK',
      ],
    ),
  ];
}

// ============================================================
// LİG SEÇİM KARTI
// ============================================================

class LigSecimKarti extends StatelessWidget {
  final LigBilgisi lig;

  const LigSecimKarti({super.key, required this.lig});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PuanDurumuSayfasi(lig: lig)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.emoji_events, color: anaYesil, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lig.ad,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: siyah,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Puan durumunu görüntüle',
                      style: TextStyle(fontSize: 11, color: gri),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 15, color: gri),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// LİG BİLGİSİ
// ============================================================

class LigBilgisi {
  final String ad;
  final String kategori;
  final String url;

  const LigBilgisi({required this.ad, required this.kategori, required this.url});
}

// ============================================================
// LİG VERİLERİ
// ============================================================

class LigVerileri {
  static const String base = 'https://yalovaskf.com/grup/';

  static const List<LigBilgisi> sezon2025 = [
    LigBilgisi(
      ad: 'Süper Amatör Lig',
      kategori: 'Büyükler',
      url: '${base}super-amator-lig-super-amator-lig-2025-2026',
    ),
    LigBilgisi(
      ad: '1. Amatör Lig A Grubu',
      kategori: 'Büyükler',
      url: '${base}1-amator-lig-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: '1. Amatör Lig B Grubu',
      kategori: 'Büyükler',
      url: '${base}1-amator-lig-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: '2. Amatör Lig A Grubu',
      kategori: 'Büyükler',
      url: '${base}2-amator-lig-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: '2. Amatör Lig B Grubu',
      kategori: 'Büyükler',
      url: '${base}2-amator-lig-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-18 Ligi',
      kategori: 'Altyapı',
      url: '${base}u-18-ligi-u-18-ligi-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-16 Ligi',
      kategori: 'Altyapı',
      url: '${base}u-16-ligi-u-16-ligi-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-15 Ligi A Grubu',
      kategori: 'Altyapı',
      url: '${base}u-15-ligi-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-15 Ligi B Grubu',
      kategori: 'Altyapı',
      url: '${base}u-15-ligi-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-14 Ligi A Grubu',
      kategori: 'Altyapı',
      url: '${base}u-14-ligi-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-14 Ligi B Grubu',
      kategori: 'Altyapı',
      url: '${base}u-14-ligi-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-13 Şenlik Ligi A Grubu',
      kategori: 'Altyapı',
      url: '${base}u-13-senlik-ligi-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-13 Şenlik Ligi B Grubu',
      kategori: 'Altyapı',
      url: '${base}u-13-senlik-ligi-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-12 Şenlik Ligi A Grubu',
      kategori: 'Altyapı',
      url: '${base}u-12-senlik-ligi-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-12 Şenlik Ligi B Grubu',
      kategori: 'Altyapı',
      url: '${base}u-12-senlik-ligi-b-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-12 Şenlik Ligi C Grubu',
      kategori: 'Altyapı',
      url: '${base}u-12-senlik-ligi-c-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-11 Şenlik Ligi A Grubu',
      kategori: 'Altyapı',
      url: '${base}u11-senlik-ligi-a-grubu-2025-2026',
    ),
    LigBilgisi(
      ad: 'U-11 Şenlik Ligi B Grubu',
      kategori: 'Altyapı',
      url: '${base}u11-senlik-ligi-b-grubu-2025-2026',
    ),
  ];
}

// ============================================================
// PUAN DURUMU
// ============================================================

class PuanDurumuSayfasi extends StatefulWidget {
  final LigBilgisi lig;

  const PuanDurumuSayfasi({super.key, required this.lig});

  @override
  State<PuanDurumuSayfasi> createState() => _PuanDurumuSayfasiState();
}

class _PuanDurumuSayfasiState extends State<PuanDurumuSayfasi> {
  bool yukleniyor = true;
  String? hata;
  DateTime? _sonGuncelleme;
  bool _cacheGosteriliyor = false;
  int _istekNo = 0;

  List<TakimPuan> takimlar = <TakimPuan>[];

  @override
  void initState() {
    super.initState();
    _verileriGetir();
  }

  Future<void> _verileriGetir() async {
    final istekNo = ++_istekNo;
    final istekLigi = widget.lig;
    hata = null;

    // Önce cihazdaki son başarılı veriyi göster. Böylece internet
    // beklenmeden ekran kullanılabilir hale gelir.
    final cache = await PuanVerileri.cacheOku(istekLigi);
    if (!mounted || istekNo != _istekNo) return;
    if (cache != null) {
      final cachedTakimlar = PuanVerileri.cacheVeridenGetir(cache.veri);
      if (cachedTakimlar.isNotEmpty && mounted) {
        setState(() {
          takimlar = cachedTakimlar;
          _sonGuncelleme = cache.tarih;
          _cacheGosteriliyor = true;
          yukleniyor = false;
          hata = null;
        });
      }
    }

    if (mounted && takimlar.isEmpty) {
      setState(() {
        yukleniyor = true;
        hata = null;
      });
    }

    try {
      final bulunanlar = await PuanVerileri.getir(istekLigi);
      if (!mounted || istekNo != _istekNo) return;

      setState(() {
        takimlar = bulunanlar;
        yukleniyor = false;
        hata = null;
        _sonGuncelleme = DateTime.now();
        _cacheGosteriliyor = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        yukleniyor = false;
        if (takimlar.isEmpty) {
          hata = 'Puan durumu şu anda alınamıyor. Lütfen tekrar deneyin.';
        } else {
          // Güncel veri alınamadıysa cache'i kullanmaya devam et.
          _cacheGosteriliyor = true;
          hata = null;
        }
      });
      debugPrint('Puan durumu hatası: $e');
    }
  }

  String _temizTakimAdi(String text) {
    return text
        .replaceAll(RegExp(r'↑\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'↓\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _hucreMetni(dom.Element cell) {
    String text = cell.text.replaceAll(RegExp(r'\s+'), ' ').trim();

    final images = cell.querySelectorAll('img');

    for (final image in images) {
      final alt = image.attributes['alt'];

      if (alt != null &&
          alt.trim().isNotEmpty &&
          (text.isEmpty || text.toLowerCase() == 'image')) {
        text = alt.trim();
      }
    }

    return text.replaceFirst(RegExp(r'^Image\s+', caseSensitive: false), '').trim();
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  String _value(List<String> values, int index) {
    if (index >= values.length) {
      return '';
    }

    return values[index];
  }

  int _sayi(String text) {
    final clean = text.replaceAll(RegExp(r'[^0-9-]'), '');
    return int.tryParse(clean) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.lig.ad,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: yukleniyor ? null : _verileriGetir,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      // DÜZELTME: aşağı çekerek yenileme eklendi.
      body: RefreshIndicator(
        onRefresh: _verileriGetir,
        color: anaYesil,
        child: _govde(),
      ),
    );
  }

  Widget _govde() {
    if (yukleniyor) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 160),
          Center(child: CircularProgressIndicator(color: anaYesil)),
          SizedBox(height: 16),
          Center(
            child: Text(
              'Puan durumu yükleniyor...',
              style: TextStyle(color: gri, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }

    if (hata != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.error_outline, size: 42, color: Colors.red),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Veriler alınamadı',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  hata!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: gri),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _verileriGetir,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _puanUstBilgi(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return _puanTablosu(constraints.maxWidth);
            },
          ),
        ),
      ],
    );
  }

  Widget _puanUstBilgi() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
      color: Colors.white,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.asset(
              'assets/yalova_wonder_kids_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(Icons.shield_outlined, color: anaYesil, size: 20);
              },
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.lig.ad,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: siyah,
                  ),
                ),
                if (_sonGuncelleme != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _cacheGosteriliyor
                        ? 'Önbellekten gösteriliyor • ${cacheGuncellemeMetni(_sonGuncelleme)}'
                        : cacheGuncellemeMetni(_sonGuncelleme),
                    style: TextStyle(
                      fontSize: 10,
                      color: _cacheGosteriliyor ? Colors.orange.shade800 : gri,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _puanTablosu(double ekranGenisligi) {
    final double toplam = ekranGenisligi - 4;
    final double takimGenisligi = toplam * 0.32;
    final double digerGenislik = (toplam - takimGenisligi) / 9;

    if (takimlar.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Gösterilecek takım bulunamadı.', style: TextStyle(color: gri))),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          _baslikSatiri(takimGenisligi, digerGenislik),
          Expanded(
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: takimlar.length,
              itemBuilder: (context, index) {
                return _takimSatiri(takimlar[index], takimGenisligi, digerGenislik);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _baslikSatiri(double takimGenisligi, double digerGenislik) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(color: koyuYesil),
      child: Row(
        children: [
          _BaslikHucre(text: '#', width: digerGenislik),
          _BaslikHucre(text: 'Takım', width: takimGenisligi, hizalama: TextAlign.left),
          _BaslikHucre(text: 'O', width: digerGenislik),
          _BaslikHucre(text: 'G', width: digerGenislik),
          _BaslikHucre(text: 'B', width: digerGenislik),
          _BaslikHucre(text: 'M', width: digerGenislik),
          _BaslikHucre(text: 'AG', width: digerGenislik),
          _BaslikHucre(text: 'YG', width: digerGenislik),
          _BaslikHucre(text: 'AV', width: digerGenislik),
          _BaslikHucre(text: 'P', width: digerGenislik),
        ],
      ),
    );
  }

  Widget _takimSatiri(TakimPuan takim, double takimGenisligi, double digerGenislik) {
    final bool ilkUc = takim.sira <= 3;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: ilkUc ? acikYesil.withOpacity(0.35) : Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TakimProfilSayfasi(lig: widget.lig, takim: takim),
            ),
          );
        },
        child: Row(
          children: [
            _Hucre('${takim.sira}', digerGenislik, bold: true, fontSize: 10),
            _Hucre(takim.takim, takimGenisligi, align: TextAlign.left, bold: true, fontSize: 10),
            _Hucre('${takim.oynanan}', digerGenislik),
            _Hucre('${takim.galibiyet}', digerGenislik),
            _Hucre('${takim.beraberlik}', digerGenislik),
            _Hucre('${takim.maglubiyet}', digerGenislik),
            _Hucre('${takim.atilanGol}', digerGenislik),
            _Hucre('${takim.yenilenGol}', digerGenislik),
            _Hucre('${takim.averaj}', digerGenislik),
            _Hucre('${takim.puan}', digerGenislik, bold: true, fontSize: 11),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// TAKIM PUANI
// ============================================================

class TakimPuan {
  final int sira;
  final String takim;
  final int oynanan;
  final int galibiyet;
  final int beraberlik;
  final int maglubiyet;
  final int atilanGol;
  final int yenilenGol;
  final int averaj;
  final int puan;
  final String logoUrl;
  final String takimUrl;

  const TakimPuan({
    required this.sira,
    required this.takim,
    required this.oynanan,
    required this.galibiyet,
    required this.beraberlik,
    required this.maglubiyet,
    required this.atilanGol,
    required this.yenilenGol,
    required this.averaj,
    required this.puan,
    this.logoUrl = '',
    this.takimUrl = '',
  });
}

// ============================================================
// PUAN VERİ SERVİSİ
// ============================================================

class PuanVerileri {
  static Future<SiteCacheKaydi?> cacheOku(LigBilgisi lig) {
    return SiteVeriCache.oku(tur: 'puan', kaynak: lig.url);
  }

  static Future<void> cacheKaydet(LigBilgisi lig, List<TakimPuan> takimlar) async {
    await SiteVeriCache.kaydet(
      tur: 'puan',
      kaynak: lig.url,
      veri: takimlar.map((takim) => <String, dynamic>{
        'sira': takim.sira,
        'takim': takim.takim,
        'oynanan': takim.oynanan,
        'galibiyet': takim.galibiyet,
        'beraberlik': takim.beraberlik,
        'maglubiyet': takim.maglubiyet,
        'atilanGol': takim.atilanGol,
        'yenilenGol': takim.yenilenGol,
        'averaj': takim.averaj,
        'puan': takim.puan,
        'logoUrl': takim.logoUrl,
        'takimUrl': takim.takimUrl,
      }).toList(),
    );
  }

  static List<TakimPuan> _cachedenPuanlariOku(dynamic veri) {
    if (veri is! List) return <TakimPuan>[];
    return veri.whereType<Map>().map((item) => TakimPuan(
      sira: int.tryParse(item['sira']?.toString() ?? '') ?? 0,
      takim: item['takim']?.toString() ?? '',
      oynanan: int.tryParse(item['oynanan']?.toString() ?? '') ?? 0,
      galibiyet: int.tryParse(item['galibiyet']?.toString() ?? '') ?? 0,
      beraberlik: int.tryParse(item['beraberlik']?.toString() ?? '') ?? 0,
      maglubiyet: int.tryParse(item['maglubiyet']?.toString() ?? '') ?? 0,
      atilanGol: int.tryParse(item['atilanGol']?.toString() ?? '') ?? 0,
      yenilenGol: int.tryParse(item['yenilenGol']?.toString() ?? '') ?? 0,
      averaj: int.tryParse(item['averaj']?.toString() ?? '') ?? 0,
      puan: int.tryParse(item['puan']?.toString() ?? '') ?? 0,
      logoUrl: item['logoUrl']?.toString() ?? '',
      takimUrl: item['takimUrl']?.toString() ?? '',
    )).where((takim) => takim.takim.isNotEmpty).toList();
  }

  static List<TakimPuan> cacheVeridenGetir(dynamic veri) {
    return _cachedenPuanlariOku(veri);
  }

  static Future<List<TakimPuan>> getir(LigBilgisi lig) async {
    final response = await http
        .get(
          Uri.parse(lig.url),
          headers: const {
            'User-Agent': 'Mozilla/5.0 YalovaWonderKids',
            'Accept': 'text/html',
          },
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Puan durumu alınamadı. HTTP ${response.statusCode}');
    }

    String govde;
    try {
      govde = utf8.decode(response.bodyBytes);
    } catch (_) {
      govde = response.body;
    }

    final document = html_parser.parse(govde);
    final tables = document.querySelectorAll('table');
    final List<TakimPuan> bulunanlar = <TakimPuan>[];

    for (final table in tables) {
      final rows = table.querySelectorAll('tr');
      if (rows.length < 2) continue;

      final header = rows.first.querySelectorAll('th,td').map(_hucreMetni).toList();
      final normalized = header.map(_normalize).toList();

      if (!normalized.contains('takim') || !normalized.contains('p')) continue;

      for (int i = 1; i < rows.length; i++) {
        final cells = rows[i].querySelectorAll('th,td');
        final values = cells.map(_hucreMetni).toList();
        if (values.length < 10) continue;

        final takim = _temizTakimAdi(_value(values, 1));
        if (takim.isEmpty || takim.toUpperCase() == 'BAY') continue;

        String logoUrl = '';
        String takimUrl = '';
        final takimHucre = cells.length > 1 ? cells[1] : null;
        if (takimHucre != null) {
          final logo = takimHucre.querySelector('img');
          final anchor = takimHucre.querySelector('a');
          if (logo != null) {
            logoUrl = _mutlakUrl(logo.attributes['src'] ?? '');
          }
          if (anchor != null) {
            takimUrl = _mutlakUrl(anchor.attributes['href'] ?? '');
          }
        }

        bulunanlar.add(
          TakimPuan(
            sira: _sayi(_value(values, 0)),
            takim: takim,
            oynanan: _sayi(_value(values, 2)),
            galibiyet: _sayi(_value(values, 3)),
            beraberlik: _sayi(_value(values, 4)),
            maglubiyet: _sayi(_value(values, 5)),
            atilanGol: _sayi(_value(values, 6)),
            yenilenGol: _sayi(_value(values, 7)),
            averaj: _sayi(_value(values, 8)),
            puan: _sayi(_value(values, 9)),
            logoUrl: logoUrl,
            takimUrl: takimUrl,
          ),
        );
      }

      if (bulunanlar.isNotEmpty) break;
    }

    if (bulunanlar.isEmpty) {
      throw Exception('Puan durumu tablosu bulunamadı.');
    }

    await cacheKaydet(lig, bulunanlar);
    return bulunanlar;
  }

  static String _hucreMetni(dom.Element cell) {
    String text = cell.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final alts = cell
        .querySelectorAll('img')
        .map((img) => img.attributes['alt']?.trim() ?? '')
        .where((alt) => alt.isNotEmpty && alt.toLowerCase() != 'image')
        .toList();

    if (alts.length >= 1 && (text.isEmpty || text.toLowerCase() == 'image')) {
      text = alts.first;
    }

    return text.replaceFirst(RegExp(r'^Image\s+', caseSensitive: false), '').trim();
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _temizTakimAdi(String text) {
    return text
        .replaceAll(RegExp(r'↑\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'↓\s*İkili Averaj', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _value(List<String> values, int index) =>
      index < values.length ? values[index] : '';

  static int _sayi(String text) {
    final clean = text.replaceAll(RegExp(r'[^0-9-]'), '');
    return int.tryParse(clean) ?? 0;
  }

  static String _mutlakUrl(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return 'https://yalovaskf.com$value';
    return 'https://yalovaskf.com/$value';
  }
}

// ============================================================
// BAŞLIK HÜCRESİ
// ============================================================

class _BaslikHucre extends StatelessWidget {
  final String text;
  final double width;
  final TextAlign hizalama;

  const _BaslikHucre({
    required this.text,
    required this.width,
    this.hizalama = TextAlign.center,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: hizalama,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ============================================================
// NORMAL HÜCRE
// ============================================================

class _Hucre extends StatelessWidget {
  final String text;
  final double width;
  final bool bold;
  final TextAlign align;
  final double fontSize;

  const _Hucre(
    this.text,
    this.width, {
    this.bold = false,
    this.align = TextAlign.center,
    this.fontSize = 9.5,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          color: siyah,
        ),
      ),
    );
  }
}

// ============================================================
// BİLGİ SAYFASI
// ============================================================

// ============================================================
// MAÇ MODELİ
// ============================================================

class MacBilgisi {
  final String hafta;
  final String evSahibi;
  final String deplasman;
  final String sonuc;
  final String tarihSaat;
  final String stadyum;

  const MacBilgisi({
    required this.hafta,
    required this.evSahibi,
    required this.deplasman,
    required this.sonuc,
    required this.tarihSaat,
    required this.stadyum,
  });

  bool get oynandi => RegExp(r'^\d+\s*-\s*\d+$').hasMatch(sonuc);
}

// ============================================================
// MAÇ VERİ SERVİSİ
// ============================================================

class MacVerileri {
  static Future<SiteCacheKaydi?> cacheOku(LigBilgisi lig) {
    return SiteVeriCache.oku(tur: 'mac', kaynak: lig.url);
  }

  static Future<void> cacheKaydet(LigBilgisi lig, List<MacBilgisi> maclar) async {
    await SiteVeriCache.kaydet(
      tur: 'mac',
      kaynak: lig.url,
      veri: maclar.map((mac) => <String, dynamic>{
        'hafta': mac.hafta,
        'evSahibi': mac.evSahibi,
        'deplasman': mac.deplasman,
        'sonuc': mac.sonuc,
        'tarihSaat': mac.tarihSaat,
        'stadyum': mac.stadyum,
      }).toList(),
    );
  }

  static List<MacBilgisi> _cachedenMaclariOku(dynamic veri) {
    if (veri is! List) return <MacBilgisi>[];
    return veri.whereType<Map>().map((item) => MacBilgisi(
      hafta: item['hafta']?.toString() ?? '',
      evSahibi: item['evSahibi']?.toString() ?? '',
      deplasman: item['deplasman']?.toString() ?? '',
      sonuc: item['sonuc']?.toString() ?? '',
      tarihSaat: item['tarihSaat']?.toString() ?? '',
      stadyum: item['stadyum']?.toString() ?? '',
    )).where((mac) => mac.evSahibi.isNotEmpty && mac.deplasman.isNotEmpty).toList();
  }

  static List<MacBilgisi> cacheVeridenGetir(dynamic veri) {
    return _cachedenMaclariOku(veri);
  }

  static Future<List<MacBilgisi>> getir(LigBilgisi lig) async {
    final response = await http
        .get(
          Uri.parse(lig.url),
          headers: const {
            'User-Agent': 'Mozilla/5.0 YalovaWonderKids',
            'Accept': 'text/html',
          },
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Maç verileri alınamadı. HTTP ${response.statusCode}');
    }

    String govde;
    try {
      govde = utf8.decode(response.bodyBytes);
    } catch (_) {
      govde = response.body;
    }

    final document = html_parser.parse(govde);
    final tablolar = document.querySelectorAll('table');
    final List<MacBilgisi> maclar = <MacBilgisi>[];

    for (final tablo in tablolar) {
      final satirlar = tablo.querySelectorAll('tr');
      if (satirlar.length < 2) continue;

      for (int i = 1; i < satirlar.length; i++) {
        final hucreler = satirlar[i]
            .querySelectorAll('th,td')
            .map(_hucreMetni)
            .where((e) => e.isNotEmpty)
            .toList();

        if (hucreler.length < 4) continue;

        // Site üzerindeki maç tablosunun sıralaması:
        // Hafta | Maç | Sonuç | Tarih/Saat | Stadyum
        String macMetni = '';
        int macIndex = -1;

        for (int j = 0; j < hucreler.length; j++) {
          final metin = hucreler[j];
          if (RegExp(r'\s+-\s+').hasMatch(metin)) {
            macMetni = metin;
            macIndex = j;
            break;
          }
        }

        if (macIndex == -1) continue;

        final takimlar = macMetni.split(RegExp(r'\s+-\s+'));
        if (takimlar.length < 2) continue;

        String sonuc = '';
        if (macIndex + 1 < hucreler.length) {
          sonuc = hucreler[macIndex + 1];
        }

        String tarihSaat = '';
        if (macIndex + 2 < hucreler.length) {
          tarihSaat = hucreler[macIndex + 2];
        }

        String stadyum = '';
        if (macIndex + 3 < hucreler.length) {
          stadyum = hucreler[macIndex + 3];
        }

        // Başlangıç hücresi çoğu sayfada hafta bilgisidir.
        final hafta = hucreler.first;

        maclar.add(
          MacBilgisi(
            hafta: hafta,
            evSahibi: _temizle(takimlar.first),
            deplasman: _temizle(takimlar.sublist(1).join(' - ')),
            sonuc: _temizle(sonuc),
            tarihSaat: _temizle(tarihSaat),
            stadyum: _temizle(stadyum),
          ),
        );
      }
    }

    if (maclar.isEmpty) {
      throw Exception('Bu lig için maç programı bulunamadı.');
    }

    await cacheKaydet(lig, maclar);
    return maclar;
  }

  static String _hucreMetni(dom.Element cell) {
    String text = cell.text.replaceAll(RegExp(r'\s+'), ' ').trim();

    final alts = cell
        .querySelectorAll('img')
        .map((img) => img.attributes['alt']?.trim() ?? '')
        .where((alt) => alt.isNotEmpty && alt.toLowerCase() != 'image')
        .toList();

    // Takım hücrelerinde isimler çoğu zaman img alt bilgisinde bulunuyor.
    if (alts.length >= 2 && !text.contains(' - ')) {
      text = alts.join(' - ');
    } else if (text.isEmpty && alts.isNotEmpty) {
      text = alts.join(' ');
    } else {
      text = text.replaceFirst(RegExp(r'^Image\s+', caseSensitive: false), '').trim();
    }

    return text;
  }

  static String _temizle(String metin) {
    return metin.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

// ============================================================
// MAÇLAR SAYFASI
// ============================================================

class MaclarSayfasi extends StatefulWidget {
  const MaclarSayfasi({super.key});

  @override
  State<MaclarSayfasi> createState() => _MaclarSayfasiState();
}

class _MaclarSayfasiState extends State<MaclarSayfasi> {
  late LigBilgisi seciliLig;
  List<MacBilgisi> maclar = <MacBilgisi>[];
  bool yukleniyor = true;
  String? hata;
  DateTime? _sonGuncelleme;
  bool _cacheGosteriliyor = false;
  int _istekNo = 0;
  int filtre = 0; // 0: Tümü, 1: Oynanan, 2: Program
  String seciliHafta = 'Tüm Haftalar';

  @override
  void initState() {
    super.initState();
    seciliLig = LigVerileri.sezon2025.first;
    _verileriGetir();
  }

  Future<void> _verileriGetir() async {
    final istekNo = ++_istekNo;
    final istekLigi = seciliLig;
    hata = null;

    final cache = await MacVerileri.cacheOku(istekLigi);
    if (!mounted || istekNo != _istekNo) return;
    if (cache != null) {
      final cachedMaclar = MacVerileri.cacheVeridenGetir(cache.veri);
      if (cachedMaclar.isNotEmpty && mounted) {
        setState(() {
          maclar = cachedMaclar;
          seciliHafta = 'Tüm Haftalar';
          _sonGuncelleme = cache.tarih;
          _cacheGosteriliyor = true;
          yukleniyor = false;
          hata = null;
        });
      }
    }

    if (mounted && maclar.isEmpty) {
      setState(() {
        yukleniyor = true;
        hata = null;
      });
    }

    try {
      final bulunanlar = await MacVerileri.getir(istekLigi);
      if (!mounted || istekNo != _istekNo) return;
      setState(() {
        maclar = bulunanlar;
        seciliHafta = 'Tüm Haftalar';
        yukleniyor = false;
        hata = null;
        _sonGuncelleme = DateTime.now();
        _cacheGosteriliyor = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        yukleniyor = false;
        if (maclar.isEmpty) {
          hata = 'Maç programı şu anda alınamıyor. Lütfen tekrar deneyin.';
        } else {
          _cacheGosteriliyor = true;
          hata = null;
        }
      });
      debugPrint('Maç verileri hatası: $e');
    }
  }

  List<String> get haftaSecenekleri {
    final haftalar = <String>{};
    for (final mac in maclar) {
      final hafta = mac.hafta.trim();
      if (hafta.isNotEmpty) {
        haftalar.add(hafta);
      }
    }

    final liste = haftalar.toList();
    liste.sort((a, b) {
      final aSayi = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '') ?? 9999;
      final bSayi = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '') ?? 9999;
      return aSayi.compareTo(bSayi);
    });
    return ['Tüm Haftalar', ...liste];
  }

  List<MacBilgisi> get filtrelenmisMaclar {
    Iterable<MacBilgisi> sonuc = maclar;

    if (seciliHafta != 'Tüm Haftalar') {
      sonuc = sonuc.where((mac) => mac.hafta.trim() == seciliHafta);
    }

    if (filtre == 1) {
      sonuc = sonuc.where((mac) => mac.oynandi);
    } else if (filtre == 2) {
      sonuc = sonuc.where((mac) => !mac.oynandi);
    }

    return sonuc.toList();
  }

  void _ligDegistir(LigBilgisi? lig) {
    if (lig == null || lig.url.isEmpty) return;
    setState(() {
      seciliLig = lig;
      filtre = 0;
      seciliHafta = 'Tüm Haftalar';
      maclar = <MacBilgisi>[];
      yukleniyor = true;
      hata = null;
      _sonGuncelleme = null;
      _cacheGosteriliyor = false;
    });
    _verileriGetir();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Maçlar', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: yukleniyor ? null : _verileriGetir,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _verileriGetir,
        color: anaYesil,
        child: _govde(),
      ),
    );
  }

  Widget _govde() {
    if (yukleniyor) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 150),
          Center(child: CircularProgressIndicator(color: anaYesil)),
          SizedBox(height: 14),
          Center(
            child: Text(
              'Maçlar yükleniyor...',
              style: TextStyle(color: gri, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }

    if (hata != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 55),
          Center(
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sports_soccer, size: 40, color: Colors.orange),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Maçlar alınamadı',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  hata!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: gri),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _verileriGetir,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final liste = filtrelenmisMaclar;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        _ligSecici(),
        const SizedBox(height: 10),
        _haftaSecici(),
        const SizedBox(height: 12),
        _ozetKart(),
        if (_sonGuncelleme != null) ...[
          const SizedBox(height: 7),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _cacheGosteriliyor
                  ? 'Önbellekten gösteriliyor • ${cacheGuncellemeMetni(_sonGuncelleme)}'
                  : cacheGuncellemeMetni(_sonGuncelleme),
              style: TextStyle(
                fontSize: 10,
                color: _cacheGosteriliyor ? Colors.orange.shade800 : gri,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _filtreler(),
        const SizedBox(height: 10),
        if (liste.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 55),
            child: Center(
              child: Text(
                'Bu filtrede maç bulunmuyor.',
                style: TextStyle(color: gri, fontWeight: FontWeight.w600),
              ),
            ),
          )
        else
          ...liste.map((mac) => _macKarti(mac)),
      ],
    );
  }

  Widget _ligSecici() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LigBilgisi>(
          value: seciliLig,
          isExpanded: true,
          items: LigVerileri.sezon2025.map((lig) {
            return DropdownMenuItem<LigBilgisi>(
              value: lig,
              child: Text(
                lig.ad,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            );
          }).toList(),
          onChanged: yukleniyor ? null : _ligDegistir,
        ),
      ),
    );
  }

  Widget _haftaSecici() {
    final secenekler = haftaSecenekleri;
    final gecerliSecim = secenekler.contains(seciliHafta) ? seciliHafta : 'Tüm Haftalar';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: gecerliSecim,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, color: anaYesil),
          items: secenekler.map((hafta) {
            return DropdownMenuItem<String>(
              value: hafta,
              child: Text(
                hafta == 'Tüm Haftalar' ? hafta : '$hafta. Hafta',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            );
          }).toList(),
          onChanged: yukleniyor
              ? null
              : (deger) {
                  if (deger == null) return;
                  setState(() {
                    seciliHafta = deger;
                  });
                },
        ),
      ),
    );
  }

  Widget _ozetKart() {
    final oynanan = maclar.where((mac) => mac.oynandi).length;
    final program = maclar.length - oynanan;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.emoji_events, color: Colors.white, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              seciliLig.ad,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$oynanan oynandı', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
              Text('$program program', style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filtreler() {
    return Row(
      children: [
        Expanded(child: _filtreButonu(0, 'Tümü')),
        const SizedBox(width: 8),
        Expanded(child: _filtreButonu(1, 'Oynanan')),
        const SizedBox(width: 8),
        Expanded(child: _filtreButonu(2, 'Program')),
      ],
    );
  }

  Widget _filtreButonu(int index, String baslik) {
    final secili = filtre == index;
    return Material(
      color: secili ? anaYesil : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => filtre = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text(
              baslik,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: secili ? Colors.white : siyah,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _takimProfiliAc(BuildContext context, String takimAdi) async {
    try {
      final puanlar = await PuanVerileri.getir(seciliLig);
      final takim = puanlar.firstWhere(
        (item) => _takimEsit(item.takim, takimAdi),
        orElse: () => TakimPuan(
          sira: 0,
          takim: takimAdi,
          oynanan: 0,
          galibiyet: 0,
          beraberlik: 0,
          maglubiyet: 0,
          atilanGol: 0,
          yenilenGol: 0,
          averaj: 0,
          puan: 0,
        ),
      );
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TakimProfilSayfasi(lig: seciliLig, takim: takim),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Takım bilgisi şu anda alınamıyor.')),
      );
    }
  }

  bool _takimEsit(String a, String b) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalize(a) == normalize(b);
  }

  Widget _macKarti(MacBilgisi mac) {
    final oynandi = mac.oynandi;

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: acikYesil,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '${mac.hafta}. Hafta',
                    style: const TextStyle(
                      color: anaYesil,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  oynandi ? 'OYNANDI' : 'PROGRAM',
                  style: TextStyle(
                    color: oynandi ? anaYesil : Colors.orange.shade800,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _takimProfiliAc(context, mac.evSahibi),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        mac.evSahibi,
                        textAlign: TextAlign.right,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                    color: oynandi ? acikYesil : const Color(0xFFF1F3F2),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    mac.sonuc.isEmpty || mac.sonuc == '-' ? 'VS' : mac.sonuc,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => _takimProfiliAc(context, mac.deplasman),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        mac.deplasman,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (mac.tarihSaat.isNotEmpty || mac.stadyum.isNotEmpty) ...[
              const SizedBox(height: 11),
              const Divider(height: 1),
              const SizedBox(height: 9),
              if (mac.tarihSaat.isNotEmpty)
                Row(
                  children: [
                    const Icon(Icons.schedule, size: 15, color: gri),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mac.tarihSaat,
                        style: const TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              if (mac.stadyum.isNotEmpty) ...[
                const SizedBox(height: 5),
                Row(
                  children: [
                    const Icon(Icons.stadium_outlined, size: 15, color: gri),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mac.stadyum,
                        style: const TextStyle(fontSize: 11, color: gri),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

}

// ============================================================
// TAKIM PROFİLİ VERİLERİ
// ============================================================

class TakimProfilDetay {
  final String adres;

  const TakimProfilDetay({
    this.adres = '',
  });
}

class TakimProfilVerileri {
  static Future<SiteCacheKaydi?> cacheOku(String takimUrl) {
    if (takimUrl.isEmpty) return Future.value(null);
    return SiteVeriCache.oku(tur: 'takim_profil', kaynak: takimUrl);
  }

  static Future<void> cacheKaydet(String takimUrl, TakimProfilDetay detay) async {
    if (takimUrl.isEmpty) return;
    await SiteVeriCache.kaydet(
      tur: 'takim_profil',
      kaynak: takimUrl,
      veri: <String, dynamic>{'adres': detay.adres},
    );
  }

  static TakimProfilDetay cachedenOku(dynamic veri) {
    if (veri is! Map) return const TakimProfilDetay();
    return TakimProfilDetay(adres: veri['adres']?.toString() ?? '');
  }

  static Future<TakimProfilDetay> getir(String takimUrl) async {
    if (takimUrl.isEmpty) return const TakimProfilDetay();

    final response = await http
        .get(
          Uri.parse(takimUrl),
          headers: const {
            'User-Agent': 'Mozilla/5.0 YalovaWonderKids',
            'Accept': 'text/html',
          },
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Takım profili alınamadı. HTTP ${response.statusCode}');
    }

    String govde;
    try {
      govde = utf8.decode(response.bodyBytes);
    } catch (_) {
      govde = response.body;
    }

    final document = html_parser.parse(govde);
    final text = document.body?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

    String adres = '';

    final adresMatch = RegExp(r'Adres\s*:?\s*(.*?)(?:\s+\d+\s+Güncel lig/grup|$)', caseSensitive: false).firstMatch(text);
    if (adresMatch != null) {
      adres = adresMatch.group(1)?.trim() ?? '';
    }

    final detay = TakimProfilDetay(
      adres: adres == '-' ? '' : adres,
    );
    await cacheKaydet(takimUrl, detay);
    return detay;
  }
}

// ============================================================
// TAKIMLAR SAYFASI
// ============================================================

class TakimlarSayfasi extends StatefulWidget {
  const TakimlarSayfasi({super.key});

  @override
  State<TakimlarSayfasi> createState() => _TakimlarSayfasiState();
}

class _TakimlarSayfasiState extends State<TakimlarSayfasi> {
  late LigBilgisi seciliLig;
  List<TakimPuan> takimlar = <TakimPuan>[];
  bool yukleniyor = true;
  String? hata;
  DateTime? _sonGuncelleme;
  bool _cacheGosteriliyor = false;
  int _istekNo = 0;
  String arama = '';

  @override
  void initState() {
    super.initState();
    seciliLig = LigVerileri.sezon2025.first;
    _verileriGetir();
  }

  Future<void> _verileriGetir() async {
    final istekNo = ++_istekNo;
    final istekLigi = seciliLig;
    hata = null;

    final cache = await PuanVerileri.cacheOku(istekLigi);
    if (!mounted || istekNo != _istekNo) return;
    if (cache != null) {
      final cachedTakimlar = PuanVerileri.cacheVeridenGetir(cache.veri);
      if (cachedTakimlar.isNotEmpty && mounted) {
        setState(() {
          takimlar = cachedTakimlar;
          _sonGuncelleme = cache.tarih;
          _cacheGosteriliyor = true;
          yukleniyor = false;
          hata = null;
        });
      }
    }

    if (mounted && takimlar.isEmpty) {
      setState(() {
        yukleniyor = true;
        hata = null;
      });
    }

    try {
      final bulunanlar = await PuanVerileri.getir(istekLigi);
      if (!mounted || istekNo != _istekNo) return;
      setState(() {
        takimlar = bulunanlar;
        yukleniyor = false;
        hata = null;
        _sonGuncelleme = DateTime.now();
        _cacheGosteriliyor = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        yukleniyor = false;
        if (takimlar.isEmpty) {
          takimlar = <TakimPuan>[];
          hata = 'Takımlar şu anda alınamıyor. Lütfen tekrar deneyin.';
        } else {
          _cacheGosteriliyor = true;
          hata = null;
        }
      });
      debugPrint('Takımlar hatası: $e');
    }
  }

  String _aramaNormalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('i\u0307', 'i')
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  List<TakimPuan> get filtrelenmisTakimlar {
    final query = _aramaNormalize(arama);
    if (query.isEmpty) return takimlar;

    // Birden fazla kelime yazıldığında tüm kelimeler takım adında aranır.
    // Böylece örneğin "golcuk spor" ve "GÖLCÜK SPOR" aynı sonucu verir.
    final kelimeler = query.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

    return takimlar.where((takim) {
      final takimAdi = _aramaNormalize(takim.takim);
      return kelimeler.every(takimAdi.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Takımlar', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: yukleniyor ? null : _verileriGetir,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _verileriGetir,
        color: anaYesil,
        child: _govde(),
      ),
    );
  }

  Widget _govde() {
    if (yukleniyor) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 150),
          Center(child: CircularProgressIndicator(color: anaYesil)),
          SizedBox(height: 14),
          Center(child: Text('Takımlar yükleniyor...', style: TextStyle(color: gri, fontWeight: FontWeight.w600))),
        ],
      );
    }

    if (hata != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 55),
          Center(
            child: Column(
              children: [
                const Icon(Icons.groups_outlined, size: 60, color: anaYesil),
                const SizedBox(height: 16),
                const Text('Takımlar alınamadı', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text(hata!, textAlign: TextAlign.center, style: const TextStyle(color: gri)),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _verileriGetir,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final liste = filtrelenmisTakimlar;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        _ligSecici(),
        const SizedBox(height: 12),
        _aramaKutusu(),
        if (arama.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 7, left: 4, right: 4),
            child: Text(
              '${filtrelenmisTakimlar.length} takım bulundu',
              style: const TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 12),
        if (_sonGuncelleme != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, right: 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _cacheGosteriliyor
                    ? 'Önbellekten gösteriliyor • ${cacheGuncellemeMetni(_sonGuncelleme)}'
                    : cacheGuncellemeMetni(_sonGuncelleme),
                style: TextStyle(
                  fontSize: 10,
                  color: _cacheGosteriliyor ? Colors.orange.shade800 : gri,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: anaYesil, size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '${takimlar.length} takım • Bir takıma dokunarak profilini açabilirsin.',
                  style: const TextStyle(color: koyuYesil, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (liste.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 55),
            child: Center(child: Text('Aramana uygun takım bulunamadı.', style: TextStyle(color: gri))),
          )
        else
          ...liste.map(_takimKarti),
      ],
    );
  }

  Widget _ligSecici() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LigBilgisi>(
          value: seciliLig,
          isExpanded: true,
          items: LigVerileri.sezon2025.map((lig) {
            return DropdownMenuItem<LigBilgisi>(
              value: lig,
              child: Text(lig.ad, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            );
          }).toList(),
          onChanged: yukleniyor
              ? null
              : (lig) {
                  if (lig == null) return;
                  setState(() {
                    seciliLig = lig;
                    arama = '';
                    takimlar = <TakimPuan>[];
                    yukleniyor = true;
                    hata = null;
                    _sonGuncelleme = null;
                    _cacheGosteriliyor = false;
                  });
                  _verileriGetir();
                },
        ),
      ),
    );
  }

  Widget _aramaKutusu() {
    return TextField(
      onChanged: (value) => setState(() => arama = value),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        hintText: 'Takım ara...',
        prefixIcon: const Icon(Icons.search, color: gri),
        suffixIcon: arama.isEmpty
            ? null
            : IconButton(onPressed: () => setState(() => arama = ''), icon: const Icon(Icons.clear)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _takimKarti(TakimPuan takim) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TakimProfilSayfasi(lig: seciliLig, takim: takim)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(14)),
                child: _logo(takim.logoUrl, 38, takimAdi: takim.takim),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(takim.takim, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 5),
                    Text('${takim.sira}. sıra • ${takim.puan} puan', style: const TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: gri),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logo(String url, double size, {String? takimAdi}) {
    final yerelLogo = takimAdi == null
        ? null
        : GelisimTakimLogoServisi.yerelLogoGetir(takimAdi);
    if (yerelLogo != null) {
      return Image.memory(
        yerelLogo,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }
    if (url.isEmpty) return Icon(Icons.shield_outlined, color: anaYesil, size: size * 0.62);
    return Image.network(
      url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Icon(Icons.shield_outlined, color: anaYesil, size: size * 0.62),
    );
  }
}

// ============================================================
// TAKIM PROFİL SAYFASI
// ============================================================

class TakimProfilSayfasi extends StatefulWidget {
  final LigBilgisi lig;
  final TakimPuan takim;

  const TakimProfilSayfasi({super.key, required this.lig, required this.takim});

  @override
  State<TakimProfilSayfasi> createState() => _TakimProfilSayfasiState();
}

class _TakimProfilSayfasiState extends State<TakimProfilSayfasi> {
  bool yukleniyor = true;
  String? hata;
  DateTime? _sonGuncelleme;
  bool _cacheGosteriliyor = false;
  late TakimPuan takim;
  TakimProfilDetay detay = const TakimProfilDetay();
  List<MacBilgisi> maclar = <MacBilgisi>[];

  @override
  void initState() {
    super.initState();
    takim = widget.takim;
    _verileriGetir();
  }

  Future<void> _verileriGetir() async {
    hata = null;

    // Profil ekranı puan + maç + adres bilgisini aynı anda kullandığı
    // için önce mevcut üç cache kaynağını gösteriyoruz.
    final puanCache = await PuanVerileri.cacheOku(widget.lig);
    final macCache = await MacVerileri.cacheOku(widget.lig);
    final profilCache = await TakimProfilVerileri.cacheOku(widget.takim.takimUrl);

    final cachedPuanlar = puanCache == null
        ? <TakimPuan>[]
        : PuanVerileri.cacheVeridenGetir(puanCache.veri);
    final cachedMaclar = macCache == null
        ? <MacBilgisi>[]
        : MacVerileri.cacheVeridenGetir(macCache.veri);
    final cachedProfil = profilCache == null
        ? const TakimProfilDetay()
        : TakimProfilVerileri.cachedenOku(profilCache.veri);

    final cacheVar = cachedPuanlar.isNotEmpty || cachedMaclar.isNotEmpty || profilCache != null;
    if (cacheVar && mounted) {
      final tarihler = <DateTime>[
        if (puanCache != null) puanCache.tarih,
        if (macCache != null) macCache.tarih,
        if (profilCache != null) profilCache.tarih,
      ];
      tarihler.sort();

      final bulunan = cachedPuanlar.where((item) => _takimEsit(item.takim, widget.takim.takim)).toList();
      final takimMaclari = cachedMaclar
          .where((mac) => _takimEsit(mac.evSahibi, widget.takim.takim) || _takimEsit(mac.deplasman, widget.takim.takim))
          .toList();

      setState(() {
        if (bulunan.isNotEmpty) takim = bulunan.first;
        detay = cachedProfil;
        maclar = takimMaclari;
        _sonGuncelleme = tarihler.isEmpty ? null : tarihler.reduce((a, b) => a.isBefore(b) ? a : b);
        _cacheGosteriliyor = true;
        yukleniyor = false;
        hata = null;
      });
    }

    if (mounted && !cacheVar) {
      setState(() {
        yukleniyor = true;
        hata = null;
      });
    }

    try {
      final results = await Future.wait([
        PuanVerileri.getir(widget.lig),
        MacVerileri.getir(widget.lig),
        TakimProfilVerileri.getir(widget.takim.takimUrl),
      ]);

      final puanlar = results[0] as List<TakimPuan>;
      final bulunan = puanlar.where((item) => _takimEsit(item.takim, widget.takim.takim)).toList();
      final tumMaclar = results[1] as List<MacBilgisi>;
      final profil = results[2] as TakimProfilDetay;

      final takimMaclari = tumMaclar
          .where((mac) => _takimEsit(mac.evSahibi, widget.takim.takim) || _takimEsit(mac.deplasman, widget.takim.takim))
          .toList();

      if (!mounted) return;
      setState(() {
        if (bulunan.isNotEmpty) takim = bulunan.first;
        detay = profil;
        maclar = takimMaclari;
        yukleniyor = false;
        hata = null;
        _sonGuncelleme = DateTime.now();
        _cacheGosteriliyor = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        yukleniyor = false;
        if (!cacheVar) {
          hata = 'Takım bilgileri şu anda alınamıyor. Lütfen tekrar deneyin.';
        } else {
          _cacheGosteriliyor = true;
          hata = null;
        }
      });
      debugPrint('Takım profil hatası: $e');
    }
  }

  bool _takimEsit(String a, String b) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalize(a) == normalize(b);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Takım Profili', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(onPressed: yukleniyor ? null : _verileriGetir, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _verileriGetir,
        color: anaYesil,
        child: _govde(),
      ),
    );
  }

  Widget _govde() {
    if (yukleniyor) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 150),
          Center(child: CircularProgressIndicator(color: anaYesil)),
          SizedBox(height: 14),
          Center(child: Text('Takım profili yükleniyor...', style: TextStyle(color: gri, fontWeight: FontWeight.w600))),
        ],
      );
    }

    if (hata != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          const Center(child: Icon(Icons.error_outline, size: 58, color: Colors.red)),
          const SizedBox(height: 16),
          Text(hata!, textAlign: TextAlign.center, style: const TextStyle(color: gri)),
          const SizedBox(height: 20),
          Center(child: ElevatedButton.icon(onPressed: _verileriGetir, icon: const Icon(Icons.refresh), label: const Text('Tekrar Dene'))),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _ustKart(),
        const SizedBox(height: 12),
        _kadroKarti(),
        const SizedBox(height: 12),
        _puanKart(),
        const SizedBox(height: 12),
        _macBasligi(),
        const SizedBox(height: 8),
        if (maclar.isEmpty)
          _bosMacKutusu()
        else
          ...maclar.map(_macKarti),
      ],
    );
  }

  Widget _ustKart() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Container(
            width: 92,
            height: 92,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26)),
            child: _logo(takim.logoUrl, 70),
          ),
          const SizedBox(height: 13),
          Text(
            takim.takim,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(widget.lig.ad, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _kadroKarti() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TakimKadroSayfasi(
                takimAdi: takim.takim,
                takimLogoUrl: takim.logoUrl,
                ligAdi: widget.lig.ad,
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE4E9E6)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.groups_2_outlined,
                  color: anaYesil,
                  size: 27,
                ),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Kadro',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF17221C),
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Takım futbolcularını görüntüle',
                      style: TextStyle(
                        fontSize: 11,
                        color: gri,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: anaYesil,
                size: 28,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _puanKart() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Lig Durumu', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(16)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${takim.sira}', style: const TextStyle(fontSize: 22, color: anaYesil, fontWeight: FontWeight.w900)),
                    const Text('Sıra', style: TextStyle(fontSize: 9, color: gri, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('${takim.puan} puan', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _istatistik('O', '${takim.oynanan}'),
              _istatistik('G', '${takim.galibiyet}'),
              _istatistik('B', '${takim.beraberlik}'),
              _istatistik('M', '${takim.maglubiyet}'),
              _istatistik('AV', '${takim.averaj}', son: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _istatistik(String baslik, String deger, {bool son = false}) {
    return Expanded(
      child: Container(
        margin: EdgeInsets.only(right: son ? 0 : 6),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF5F7F6), borderRadius: BorderRadius.circular(11)),
        child: Column(
          children: [
            Text(deger, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(baslik, style: const TextStyle(fontSize: 9, color: gri, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _macBasligi() {
    return Row(
      children: [
        const Expanded(child: Text('Maçlar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
        Text('${maclar.length} maç', style: const TextStyle(color: gri, fontSize: 11, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _bosMacKutusu() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: const Center(child: Text('Bu ligde takım için maç kaydı bulunmuyor.', style: TextStyle(color: gri))),
    );
  }

  Widget _macKarti(MacBilgisi mac) {
    final oynandi = mac.oynandi;
    final evBen = _takimEsit(mac.evSahibi, takim.takim);
    String? sonucDurumu;

    if (oynandi) {
      final parts = mac.sonuc.split(RegExp(r'\s*-\s*'));
      if (parts.length == 2) {
        final evSkor = int.tryParse(parts[0].trim());
        final depSkor = int.tryParse(parts[1].trim());
        if (evSkor != null && depSkor != null) {
          final takimSkoru = evBen ? evSkor : depSkor;
          final rakipSkoru = evBen ? depSkor : evSkor;
          sonucDurumu = takimSkoru > rakipSkoru ? 'G' : (takimSkoru == rakipSkoru ? 'B' : 'M');
        }
      }
    }

    final Color durumRengi = sonucDurumu == 'G'
        ? anaYesil
        : (sonucDurumu == 'M' ? Colors.red : Colors.orange);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 9),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            Container(
              width: 35,
              height: 35,
              decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(10)),
              child: Center(child: Text(mac.hafta, style: const TextStyle(fontSize: 10, color: anaYesil, fontWeight: FontWeight.w900))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mac.evSahibi, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(mac.deplasman, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  if (mac.tarihSaat.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(mac.tarihSaat, style: const TextStyle(fontSize: 9.5, color: gri)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                    color: sonucDurumu == null ? const Color(0xFFF1F3F2) : durumRengi.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(mac.sonuc.isEmpty || mac.sonuc == '-' ? 'VS' : mac.sonuc, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
                ),
                if (sonucDurumu != null) ...[
                  const SizedBox(height: 4),
                  Text(sonucDurumu!, style: TextStyle(fontSize: 9, color: durumRengi, fontWeight: FontWeight.w900)),
                ] else
                  const Padding(padding: EdgeInsets.only(top: 4), child: Text('PROGRAM', style: TextStyle(fontSize: 8, color: Colors.orange, fontWeight: FontWeight.w900))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _logo(String url, double size) {
    final yerelLogo = GelisimTakimLogoServisi.yerelLogoGetir(takim.takim);
    if (yerelLogo != null) {
      return Image.memory(
        yerelLogo,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }
    if (url.isEmpty) return Icon(Icons.shield_outlined, color: anaYesil, size: size * 0.62);
    return Image.network(
      url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Icon(Icons.shield_outlined, color: anaYesil, size: size * 0.62),
    );
  }
}

class BildirimAyarlariSayfasi extends StatefulWidget {
  const BildirimAyarlariSayfasi({super.key});

  @override
  State<BildirimAyarlariSayfasi> createState() => _BildirimAyarlariSayfasiState();
}

class _BildirimAyarlariSayfasiState extends State<BildirimAyarlariSayfasi> {
  bool genel = BildirimServisi.genelAktif;
  bool maclar = BildirimServisi.maclarAktif;
  bool haberler = BildirimServisi.haberlerAktif;
  bool ligler = BildirimServisi.liglerAktif;

  Future<void> _degistir({
    required String konu,
    required bool deger,
    required void Function(bool) yerelDegeriGuncelle,
  }) async {
    yerelDegeriGuncelle(deger);
    await BildirimServisi.konuAboneligiDegistir(konu, deger);
  }

  Widget _ayarKarti({
    required IconData ikon,
    required String baslik,
    required String aciklama,
    required bool deger,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        secondary: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: acikYesil,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(ikon, color: anaYesil),
        ),
        title: Text(
          baslik,
          style: const TextStyle(fontWeight: FontWeight.w800, color: siyah),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            aciklama,
            style: const TextStyle(fontSize: 12, color: gri, height: 1.35),
          ),
        ),
        value: deger,
        onChanged: onChanged,
        activeColor: anaYesil,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Bildirim Ayarları',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_active, color: anaYesil, size: 30),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hangi bildirimleri almak istiyorsun?',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: siyah,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'İstediğin bildirim türlerini açıp kapatabilirsin.',
                        style: TextStyle(fontSize: 12, color: gri, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _ayarKarti(
            ikon: Icons.notifications_active_outlined,
            baslik: 'Genel Bildirimler',
            aciklama: 'Uygulamayla ilgili önemli duyurular.',
            deger: genel,
            onChanged: (v) async {
              setState(() => genel = v);
              BildirimServisi.genelAktif = v;
              await BildirimServisi.konuAboneligiDegistir(
                BildirimServisi.genelKonu,
                v,
              );
            },
          ),
          _ayarKarti(
            ikon: Icons.sports_soccer,
            baslik: 'Maç Bildirimleri',
            aciklama: 'Maç sonuçları ve maçlarla ilgili duyurular.',
            deger: maclar,
            onChanged: (v) async {
              setState(() => maclar = v);
              BildirimServisi.maclarAktif = v;
              await BildirimServisi.konuAboneligiDegistir(
                BildirimServisi.maclarKonu,
                v,
              );
            },
          ),
          _ayarKarti(
            ikon: Icons.newspaper_outlined,
            baslik: 'Haber Bildirimleri',
            aciklama: 'Yalova amatör futbol haberleri.',
            deger: haberler,
            onChanged: (v) async {
              setState(() => haberler = v);
              BildirimServisi.haberlerAktif = v;
              await BildirimServisi.konuAboneligiDegistir(
                BildirimServisi.haberlerKonu,
                v,
              );
            },
          ),
          _ayarKarti(
            ikon: Icons.emoji_events_outlined,
            baslik: 'Lig Bildirimleri',
            aciklama: 'Lig, puan durumu ve önemli lig gelişmeleri.',
            deger: ligler,
            onChanged: (v) async {
              setState(() => ligler = v);
              BildirimServisi.liglerAktif = v;
              await BildirimServisi.konuAboneligiDegistir(
                BildirimServisi.liglerKonu,
                v,
              );
            },
          ),
          const SizedBox(height: 8),
          const Text(
            'Not: Bildirim izinleri Android cihazının sistem ayarlarından ayrıca yönetilebilir.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: gri, height: 1.4),
          ),
        ],
      ),
    );
  }
}


// ============================================================
// HABERLER
// ============================================================
// Firestore koleksiyonu: haberler
// Önerilen alanlar:
// baslik: String
// ozet: String
// icerik: String
// tarih: Timestamp
// yayinlandi: bool
// resimUrl: String (opsiyonel)

class HaberlerSayfasi extends StatelessWidget {
  const HaberlerSayfasi({super.key});

  Stream<List<Haber>> _haberleriDinle() {
    // Filtreleme ve sıralamayı uygulama tarafında yapıyoruz.
    // Böylece Firestore'da yayinlandi + tarih bileşik indeksi henüz
    // oluşturulmamış olsa bile Haberler sayfası açılabilir.
    return FirebaseFirestore.instance
        .collection('haberler')
        .limit(_haberListesiLimiti)
        .snapshots()
        .map((snapshot) {
      final haberler = snapshot.docs
          .map(Haber.fromFirestore)
          .where((haber) => haber.yayinlandi)
          .toList();
      haberler.sort((a, b) => b.tarih.compareTo(a.tarih));
      return haberler;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haberler', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: StreamBuilder<List<Haber>>(
        stream: _haberleriDinle(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _durumMesaji(
              ikon: Icons.error_outline,
              baslik: 'Haberler yüklenemedi',
              aciklama: 'Haberler şu anda alınamıyor. İnternet bağlantınızı kontrol edip tekrar deneyin.',
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: anaYesil));
          }

          final haberler = snapshot.data ?? <Haber>[];
          if (haberler.isEmpty) {
            return _durumMesaji(
              ikon: Icons.newspaper_outlined,
              baslik: 'Henüz haber yok',
              aciklama: 'Yeni haberler burada yayınlanacak.',
            );
          }

          return RefreshIndicator(
            color: anaYesil,
            onRefresh: () async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _baslikAlani(),
                const SizedBox(height: 14),
                _oneCikanHaber(context, haberler.first),
                if (haberler.length > 1) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Son Haberler',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: siyah),
                  ),
                  const SizedBox(height: 12),
                  ...haberler.skip(1).map((haber) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _haberKarti(context, haber),
                      )),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _baslikAlani() {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.newspaper_rounded, color: anaYesil, size: 24),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Yalova’dan Haberler', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: siyah)),
              SizedBox(height: 2),
              Text('Yalova amatör futbol gündemi', style: TextStyle(fontSize: 12, color: gri)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _oneCikanHaber(BuildContext context, Haber haber) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HaberDetaySayfasi(haber: haber))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                if (haber.resimUrl.isNotEmpty)
                  Image.network(
                    haber.resimUrl,
                    width: double.infinity,
                    height: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buyukIkonAlani(),
                  )
                else
                  _buyukIkonAlani(),
                Positioned(
                  left: 14,
                  top: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.94),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('ÖNE ÇIKAN', style: TextStyle(fontSize: 10, color: koyuYesil, fontWeight: FontWeight.w900)),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 16, 17, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _metaSatiri(haber),
                  const SizedBox(height: 10),
                  Text(
                    haber.baslik,
                    style: const TextStyle(fontSize: 23, height: 1.12, fontWeight: FontWeight.w900, color: siyah),
                  ),
                  if (haber.ozet.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text(haber.ozet, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.45, color: gri)),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Text(_haberTarihi(haber.tarih), style: const TextStyle(fontSize: 11, color: gri, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                        decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(12)),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Haberi Oku', style: TextStyle(fontSize: 11, color: koyuYesil, fontWeight: FontWeight.w800)),
                            SizedBox(width: 4),
                            Icon(Icons.arrow_forward_rounded, size: 15, color: koyuYesil),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _haberKarti(BuildContext context, Haber haber) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HaberDetaySayfasi(haber: haber))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: haber.resimUrl.isNotEmpty
                    ? Image.network(haber.resimUrl, width: 104, height: 104, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _kucukIkonAlani())
                    : _kucukIkonAlani(),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _metaSatiri(haber, compact: true),
                    const SizedBox(height: 6),
                    Text(haber.baslik, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, height: 1.18, fontWeight: FontWeight.w900, color: siyah)),
                    if (haber.ozet.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(haber.ozet, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, height: 1.35, color: gri)),
                    ],
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Text(_haberTarihi(haber.tarih), style: const TextStyle(fontSize: 10, color: gri, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        const Icon(Icons.chevron_right_rounded, color: gri, size: 22),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaSatiri(Haber haber, {bool compact = false}) {
    return Wrap(
      spacing: 7,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (haber.kategori.isNotEmpty)
          Container(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 9, vertical: 5),
            decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(10)),
            child: Text(haber.kategori, style: TextStyle(fontSize: compact ? 9 : 10, color: koyuYesil, fontWeight: FontWeight.w800)),
          ),
        if (haber.yazar.isNotEmpty)
          Text('Yazar: ${haber.yazar}', style: TextStyle(fontSize: compact ? 9 : 10, color: gri, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buyukIkonAlani() {
    return Container(
      width: double.infinity,
      height: 220,
      decoration: BoxDecoration(color: acikYesil),
      child: const Center(child: Icon(Icons.newspaper_rounded, color: anaYesil, size: 68)),
    );
  }

  Widget _kucukIkonAlani() {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(color: acikYesil),
      child: const Center(child: Icon(Icons.newspaper_rounded, color: anaYesil, size: 38)),
    );
  }

  Widget _durumMesaji({required IconData ikon, required String baslik, required String aciklama}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(28)),
              child: Icon(ikon, color: anaYesil, size: 44),
            ),
            const SizedBox(height: 18),
            Text(baslik, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(aciklama, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: gri, height: 1.45)),
          ],
        ),
      ),
    );
  }

  static String _haberTarihi(DateTime tarih) {
    final gun = tarih.day.toString().padLeft(2, '0');
    final ay = tarih.month.toString().padLeft(2, '0');
    final yil = tarih.year.toString();
    final saat = tarih.hour.toString().padLeft(2, '0');
    final dakika = tarih.minute.toString().padLeft(2, '0');
    return '$gun.$ay.$yil $saat:$dakika';
  }
}

class HaberDetaySayfasi extends StatelessWidget {
  final Haber haber;

  const HaberDetaySayfasi({super.key, required this.haber});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Haber',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (haber.resimUrl.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.network(
                  haber.resimUrl,
                  width: double.infinity,
                  height: 235,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _detayIkonAlani(),
                ),
              ),
            ] else
              _detayIkonAlani(),
            const SizedBox(height: 20),
            Text(
              haber.baslik,
              style: const TextStyle(
                fontSize: 25,
                height: 1.15,
                fontWeight: FontWeight.w900,
                color: siyah,
              ),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                if (haber.kategori.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(10)),
                    child: Text(haber.kategori, style: const TextStyle(fontSize: 10, color: koyuYesil, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    '${HaberlerSayfasi._haberTarihi(haber.tarih)}${haber.yazar.isNotEmpty ? ' • ${haber.yazar}' : ''}',
                    style: const TextStyle(fontSize: 12, color: gri, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (haber.ozet.isNotEmpty) ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  haber.ozet,
                  style: const TextStyle(
                    color: koyuYesil,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              haber.icerik,
              style: const TextStyle(
                fontSize: 16,
                height: 1.65,
                color: siyah,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detayIkonAlani() {
    return Container(
      width: double.infinity,
      height: 130,
      decoration: BoxDecoration(
        color: acikYesil,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Center(
        child: Icon(Icons.newspaper, color: anaYesil, size: 58),
      ),
    );
  }
}

class Haber {
  final String id;
  final String baslik;
  final String ozet;
  final String icerik;
  final DateTime tarih;
  final bool yayinlandi;
  final String resimUrl;
  final String kategori;
  final String yazar;

  const Haber({
    required this.id,
    required this.baslik,
    required this.ozet,
    required this.icerik,
    required this.tarih,
    required this.yayinlandi,
    required this.resimUrl,
    required this.kategori,
    required this.yazar,
  });

  factory Haber.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final tarihVerisi = data['tarih'];

    DateTime tarih;
    if (tarihVerisi is Timestamp) {
      tarih = tarihVerisi.toDate();
    } else if (tarihVerisi is DateTime) {
      tarih = tarihVerisi;
    } else {
      tarih = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return Haber(
      id: doc.id,
      baslik: (data['baslik'] ?? '').toString(),
      ozet: (data['ozet'] ?? '').toString(),
      icerik: (data['icerik'] ?? '').toString(),
      tarih: tarih,
      yayinlandi: data['yayinlandi'] == true,
      resimUrl: (data['resimUrl'] ?? '').toString(),
      kategori: (data['kategori'] ?? 'Genel').toString(),
      yazar: (data['yazar'] ?? '').toString(),
    );
  }
}

// ============================================================
// GİZLİ YÖNETİCİ PANELİ
// ============================================================
// Giriş Firebase Authentication ile yapılır.
// Yetki kontrolü: Firestore /adminler/{uid} belgesinde aktif == true.
// Böylece yönetici parolası APK içine gömülmez.

class YoneticiGirisSayfasi extends StatefulWidget {
  const YoneticiGirisSayfasi({super.key});

  @override
  State<YoneticiGirisSayfasi> createState() => _YoneticiGirisSayfasiState();
}

class _YoneticiGirisSayfasiState extends State<YoneticiGirisSayfasi> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _sifreController = TextEditingController();
  bool _yukleniyor = false;
  bool _sifreGizli = true;

  @override
  void dispose() {
    _emailController.dispose();
    _sifreController.dispose();
    super.dispose();
  }

  Future<void> _girisYap() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _yukleniyor = true);

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _sifreController.text,
      );

      final uid = credential.user?.uid;
      if (uid == null) throw Exception('Yönetici hesabı bulunamadı.');

      final adminDoc = await FirebaseFirestore.instance
          .collection('adminler')
          .doc(uid)
          .get();

      final aktif = adminDoc.data()?['aktif'] == true;
      if (!aktif) {
        await FirebaseAuth.instance.signOut();
        throw Exception('Bu hesap için yönetici yetkisi tanımlı değil.');
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const YoneticiPaneliSayfasi()),
      );
    } on FirebaseAuthException catch (e) {
      String mesaj = 'Giriş yapılamadı.';
      if (e.code == 'invalid-credential' || e.code == 'wrong-password' || e.code == 'user-not-found') {
        mesaj = 'E-posta veya şifre hatalı.';
      } else if (e.code == 'invalid-email') {
        mesaj = 'Geçerli bir e-posta adresi girin.';
      } else if (e.code == 'too-many-requests') {
        mesaj = 'Çok fazla deneme yapıldı. Bir süre sonra tekrar deneyin.';
      }
      _mesajGoster(mesaj);
    } catch (e) {
      _mesajGoster(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  void _mesajGoster(String mesaj) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mesaj)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yönetici Girişi', style: TextStyle(fontWeight: FontWeight.w900))),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      Container(
                        width: 76,
                        height: 76,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(24)),
                        child: Image.asset('assets/yalova_wonder_kids_logo.png', fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 18),
                      const Text('Yönetici Paneli', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 7),
                      const Text('Sadece yetkili hesaplar giriş yapabilir.', textAlign: TextAlign.center, style: TextStyle(color: gri)),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'E-posta', prefixIcon: Icon(Icons.email_outlined), border: OutlineInputBorder()),
                        validator: (v) => v == null || v.trim().isEmpty ? 'E-posta gerekli' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _sifreController,
                        obscureText: _sifreGizli,
                        decoration: InputDecoration(labelText: 'Şifre', prefixIcon: const Icon(Icons.lock_outline), border: const OutlineInputBorder(), suffixIcon: IconButton(onPressed: () => setState(() => _sifreGizli = !_sifreGizli), icon: Icon(_sifreGizli ? Icons.visibility : Icons.visibility_off))),
                        validator: (v) => v == null || v.isEmpty ? 'Şifre gerekli' : null,
                        onFieldSubmitted: (_) => _girisYap(),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _yukleniyor ? null : _girisYap,
                          icon: _yukleniyor ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
                          label: Text(_yukleniyor ? 'Giriş yapılıyor...' : 'Giriş Yap'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class YoneticiPaneliSayfasi extends StatelessWidget {
  const YoneticiPaneliSayfasi({super.key});

  Future<void> _cikisYap(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yönetim Paneli', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(tooltip: 'Çıkış yap', onPressed: () => _cikisYap(context), icon: const Icon(Icons.logout)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
        children: [
          _panelKart(
            context,
            ikon: Icons.add_circle_outline,
            baslik: 'Yeni Haber Yayınla',
            aciklama: 'Başlık, özet, içerik ve haber görseli ekle.',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HaberDuzenleSayfasi())),
          ),
          const SizedBox(height: 12),
          _panelKart(
            context,
            ikon: Icons.article_outlined,
            baslik: 'Haberleri Yönet',
            aciklama: 'Yayınlanan ve taslak haberleri düzenle veya sil.',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const YoneticiHaberlerSayfasi())),
          ),
          const SizedBox(height: 12),
          _panelKart(
            context,
            ikon: Icons.groups_2_outlined,
            baslik: 'Futbolcu Yönetimi',
            aciklama: 'Futbolcu ekle, düzenle veya kadrodan sil.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const YoneticiFutbolcularSayfasi()),
            ),
          ),
          const SizedBox(height: 12),
          _panelKart(
            context,
            ikon: Icons.notifications_active_outlined,
            baslik: 'Bildirim Gönder',
            aciklama: 'Firestore üzerinden genel bildirim yayınla.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const YoneticiBildirimGonderSayfasi()),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(18)),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, color: anaYesil),
                SizedBox(width: 10),
                Expanded(child: Text('Yönetici erişimi Firebase Authentication ve Firestore yetki kaydı ile korunur.', style: TextStyle(color: koyuYesil, fontSize: 12, height: 1.45))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelKart(BuildContext context, {required IconData ikon, required String baslik, required String aciklama, required VoidCallback onTap}) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(17)), child: Icon(ikon, color: anaYesil, size: 28)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(baslik, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)), const SizedBox(height: 5), Text(aciklama, style: const TextStyle(fontSize: 12, color: gri, height: 1.35))])),
              const Icon(Icons.chevron_right, color: gri),
            ],
          ),
        ),
      ),
    );
  }
}


// ============================================================
// YÖNETİCİ - FUTBOLCU YÖNETİMİ
// ============================================================

const List<String> _yoneticiTakimListesi = <String>[
  '19 Mayıs Atletik Spor',
  'Acarspor',
  'Altınova Belediye Spor',
  'Çiftlikköy Belediye Spor',
  'Demirspor',
  'Doğanspor',
  'Esnafspor',
  'Gençlerbirliği',
  'Kartal SK',
  'Tavşanlı Belediye Spor',
  'Teşvikiye Spor',
  'Yalova FK',
  'Yalova Gücü Spor',
  'Yalova İdmanyurdu',
  'Yalovaspor',
];

class YoneticiFutbolcularSayfasi extends StatefulWidget {
  const YoneticiFutbolcularSayfasi({super.key});

  @override
  State<YoneticiFutbolcularSayfasi> createState() =>
      _YoneticiFutbolcularSayfasiState();
}

class _YoneticiFutbolcularSayfasiState
    extends State<YoneticiFutbolcularSayfasi> {
  String _arama = '';

  Stream<List<FutbolcuBilgisi>> _oyunculariDinle() {
    return FirebaseFirestore.instance
        .collection('oyuncular')
        .snapshots()
        .map((snapshot) {
      final liste = snapshot.docs.map(FutbolcuBilgisi.fromDoc).toList();

      liste.sort((a, b) {
        final takimKarsilastirma =
            a.takim.toLowerCase().compareTo(b.takim.toLowerCase());
        if (takimKarsilastirma != 0) return takimKarsilastirma;
        return a.adSoyad.toLowerCase().compareTo(b.adSoyad.toLowerCase());
      });

      return liste;
    });
  }

  Future<bool> _yoneticiMi() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final admin = await FirebaseFirestore.instance
        .collection('adminler')
        .doc(user.uid)
        .get();

    return admin.data()?['aktif'] == true;
  }

  Future<void> _sil(FutbolcuBilgisi oyuncu) async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Futbolcuyu sil?'),
        content: Text(
          '${oyuncu.adSoyad} kadrodan ve Firestore kayıtlarından silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Sil'),
          ),
        ],
      ),
    );

    if (onay != true) return;

    try {
      if (!await _yoneticiMi()) {
        throw Exception('Bu işlem için yönetici yetkisi gerekli.');
      }

      await FirebaseFirestore.instance
          .collection('oyuncular')
          .doc(oyuncu.id)
          .delete();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${oyuncu.adSoyad} silindi.')),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final mesaj = e.code == 'permission-denied'
          ? 'Firestore yetkisi reddedildi. Oyuncular için güvenlik kuralını kontrol et.'
          : 'Futbolcu silinemedi: ${e.message ?? e.code}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mesaj)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        title: const Text(
          'Futbolcu Yönetimi',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: anaYesil,
        foregroundColor: Colors.white,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const YoneticiFutbolcuDuzenleSayfasi(),
            ),
          );
        },
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text(
          'Futbolcu Ekle',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: TextField(
              onChanged: (value) => setState(() => _arama = value.trim()),
              decoration: InputDecoration(
                hintText: 'Futbolcu veya takım ara',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<FutbolcuBilgisi>>(
              stream: _oyunculariDinle(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'Futbolcu listesi yüklenemedi.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: gri),
                      ),
                    ),
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: anaYesil),
                  );
                }

                final tumOyuncular = snapshot.data ?? <FutbolcuBilgisi>[];
                final aramaKucuk = _arama.toLowerCase();
                final oyuncular = aramaKucuk.isEmpty
                    ? tumOyuncular
                    : tumOyuncular.where((oyuncu) {
                        return oyuncu.adSoyad
                                .toLowerCase()
                                .contains(aramaKucuk) ||
                            oyuncu.takim
                                .toLowerCase()
                                .contains(aramaKucuk) ||
                            oyuncu.pozisyon
                                .toLowerCase()
                                .contains(aramaKucuk);
                      }).toList();

                if (oyuncular.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.groups_2_outlined,
                            size: 58,
                            color: anaYesil,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _arama.isEmpty
                                ? 'Henüz futbolcu eklenmedi'
                                : 'Aramana uygun futbolcu bulunamadı',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: siyah,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 100),
                  itemCount: oyuncular.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 9),
                  itemBuilder: (context, index) {
                    final oyuncu = oyuncular[index];
                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => YoneticiFutbolcuDuzenleSayfasi(
                                oyuncu: oyuncu,
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(13),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Container(
                                  width: 54,
                                  height: 54,
                                  color: acikYesil,
                                  child: oyuncu.fotografUrl.isEmpty
                                      ? const Icon(
                                          Icons.person_outline_rounded,
                                          color: anaYesil,
                                          size: 32,
                                        )
                                      : Image.network(
                                          oyuncu.fotografUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                            Icons.person_outline_rounded,
                                            color: anaYesil,
                                            size: 32,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      oyuncu.adSoyad,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w900,
                                        color: siyah,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      oyuncu.takim,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: gri,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '${oyuncu.pozisyon.isEmpty ? 'Pozisyon belirtilmedi' : oyuncu.pozisyon}'
                                      '${oyuncu.formaNo > 0 ? '  •  #${oyuncu.formaNo}' : ''}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: anaYesil,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Sil',
                                onPressed: () => _sil(oyuncu),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: gri,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class YoneticiFutbolcuDuzenleSayfasi extends StatefulWidget {
  final FutbolcuBilgisi? oyuncu;

  const YoneticiFutbolcuDuzenleSayfasi({
    super.key,
    this.oyuncu,
  });

  @override
  State<YoneticiFutbolcuDuzenleSayfasi> createState() =>
      _YoneticiFutbolcuDuzenleSayfasiState();
}

class _YoneticiFutbolcuDuzenleSayfasiState
    extends State<YoneticiFutbolcuDuzenleSayfasi> {
  static const String _digerTakim = 'Diğer / Elle Gir';

  // Cloudinary ücretsiz unsigned upload ayarları.
  // API Key / API Secret uygulamaya konulmaz.
  static const String _cloudinaryCloudName = 'tm28vmr2';
  static const String _cloudinaryUploadPreset = 'yalova_wonder_kids';

  final _formKey = GlobalKey<FormState>();
  final ImagePicker _imagePicker = ImagePicker();
  final _adSoyad = TextEditingController();
  final _dogumYili = TextEditingController();
  final _formaNo = TextEditingController();
  final _pozisyon = TextEditingController();
  final _fotografUrl = TextEditingController();
  final _ozelTakim = TextEditingController();

  String? _seciliTakim;
  bool _kaydediliyor = false;
  bool _fotografYukleniyor = false;

  bool get _duzenleme => widget.oyuncu != null;
  bool get _islemVar => _kaydediliyor || _fotografYukleniyor;

  @override
  void initState() {
    super.initState();

    final oyuncu = widget.oyuncu;
    if (oyuncu == null) return;

    _adSoyad.text = oyuncu.adSoyad;
    _dogumYili.text =
        oyuncu.dogumYili > 0 ? oyuncu.dogumYili.toString() : '';
    _formaNo.text = oyuncu.formaNo > 0 ? oyuncu.formaNo.toString() : '';
    _pozisyon.text = oyuncu.pozisyon;
    _fotografUrl.text = oyuncu.fotografUrl;

    if (_yoneticiTakimListesi.contains(oyuncu.takim)) {
      _seciliTakim = oyuncu.takim;
    } else {
      _seciliTakim = _digerTakim;
      _ozelTakim.text = oyuncu.takim;
    }
  }

  @override
  void dispose() {
    _adSoyad.dispose();
    _dogumYili.dispose();
    _formaNo.dispose();
    _pozisyon.dispose();
    _fotografUrl.dispose();
    _ozelTakim.dispose();
    super.dispose();
  }

  String get _takimAdi {
    if (_seciliTakim == _digerTakim) return _ozelTakim.text.trim();
    return _seciliTakim?.trim() ?? '';
  }

  Future<bool> _yoneticiMi() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final admin = await FirebaseFirestore.instance
        .collection('adminler')
        .doc(user.uid)
        .get();

    return admin.data()?['aktif'] == true;
  }

  Future<void> _galeridenFotografSecVeYukle() async {
    if (_islemVar) return;

    try {
      final secilen = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );

      if (secilen == null) return;

      if (mounted) {
        setState(() => _fotografYukleniyor = true);
      }

      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/$_cloudinaryCloudName/image/upload',
      );

      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _cloudinaryUploadPreset
        ..files.add(
          await http.MultipartFile.fromPath(
            'file',
            secilen.path,
            filename: secilen.name,
          ),
        );

      final streamedResponse =
          await request.send().timeout(const Duration(seconds: 60));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        String detay = '';
        try {
          final json = jsonDecode(response.body);
          detay = json['error']?['message']?.toString() ?? '';
        } catch (_) {}
        throw Exception(
          detay.isEmpty
              ? 'Fotoğraf yüklenemedi (${response.statusCode}).'
              : 'Fotoğraf yüklenemedi: $detay',
        );
      }

      final json = jsonDecode(response.body);
      final secureUrl = json['secure_url']?.toString().trim() ?? '';

      if (secureUrl.isEmpty) {
        throw Exception('Cloudinary fotoğraf adresi döndürmedi.');
      }

      if (!mounted) return;
      setState(() {
        _fotografUrl.text = secureUrl;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fotoğraf yüklendi. Şimdi futbolcuyu kaydedebilirsin.'),
        ),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fotoğraf yükleme zaman aşımına uğradı. Tekrar dene.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _fotografYukleniyor = false);
      }
    }
  }

  void _fotografiKaldir() {
    if (_islemVar) return;
    setState(() => _fotografUrl.clear());
  }

  Future<void> _kaydet() async {
    if (!_formKey.currentState!.validate()) return;

    if (_takimAdi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Takım seçmelisin.')),
      );
      return;
    }

    setState(() => _kaydediliyor = true);

    try {
      if (!await _yoneticiMi()) {
        throw Exception('Bu işlem için yönetici yetkisi gerekli.');
      }

      final user = FirebaseAuth.instance.currentUser!;
      final data = <String, dynamic>{
        'adSoyad': _adSoyad.text.trim(),
        'dogumYili': int.parse(_dogumYili.text.trim()),
        'takim': _takimAdi,
        'takimId': _takimFirestoreId(_takimAdi),
        'pozisyon': _pozisyon.text.trim(),
        'formaNo': int.parse(_formaNo.text.trim()),
        'fotografUrl': _fotografUrl.text.trim(),
        'guncelleyenUid': user.uid,
        'guncellenmeTarihi': FieldValue.serverTimestamp(),
      };

      if (_duzenleme) {
        await FirebaseFirestore.instance
            .collection('oyuncular')
            .doc(widget.oyuncu!.id)
            .update(data);
      } else {
        data['olusturanUid'] = user.uid;
        data['olusturmaTarihi'] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance.collection('oyuncular').add(data);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _duzenleme
                ? 'Futbolcu bilgileri güncellendi.'
                : 'Futbolcu kadroya eklendi.',
          ),
        ),
      );
      Navigator.pop(context);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      var mesaj = 'Futbolcu kaydedilemedi.';
      if (e.code == 'permission-denied') {
        mesaj =
            'Firestore yetkisi reddedildi. Oyuncular için güvenlik kuralını eklemelisin.';
      } else if (e.message != null && e.message!.isNotEmpty) {
        mesaj = 'Futbolcu kaydedilemedi: ${e.message}';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mesaj)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) setState(() => _kaydediliyor = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final takimSecenekleri = <String>[
      ..._yoneticiTakimListesi,
      _digerTakim,
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        title: Text(
          _duzenleme ? 'Futbolcuyu Düzenle' : 'Yeni Futbolcu',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: acikYesil,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.badge_outlined, color: anaYesil),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Kaydettiğin futbolcu seçtiğin takımın kadrosunda otomatik görünür.',
                      style: TextStyle(
                        color: koyuYesil,
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _adSoyad,
              enabled: !_islemVar,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Ad Soyad',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final deger = value?.trim() ?? '';
                if (deger.isEmpty) return 'Ad soyad gerekli';
                if (deger.length < 3) return 'Ad soyad çok kısa';
                return null;
              },
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<String>(
              value: _seciliTakim,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Takım',
                prefixIcon: Icon(Icons.shield_outlined),
                border: OutlineInputBorder(),
              ),
              items: takimSecenekleri
                  .map(
                    (takim) => DropdownMenuItem<String>(
                      value: takim,
                      child: Text(
                        takim,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _islemVar
                  ? null
                  : (value) => setState(() => _seciliTakim = value),
              validator: (value) {
                if (value == null || value.isEmpty) return 'Takım seç';
                return null;
              },
            ),
            if (_seciliTakim == _digerTakim) ...[
              const SizedBox(height: 13),
              TextFormField(
                controller: _ozelTakim,
                enabled: !_islemVar,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Takım adı',
                  prefixIcon: Icon(Icons.edit_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (_seciliTakim != _digerTakim) return null;
                  if ((value?.trim() ?? '').isEmpty) {
                    return 'Takım adını yaz';
                  }
                  return null;
                },
              ),
            ],
            const SizedBox(height: 13),
            TextFormField(
              controller: _pozisyon,
              enabled: !_islemVar,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Pozisyon',
                hintText: 'Örn. Orta Saha, Stoper, Kaleci',
                prefixIcon: Icon(Icons.sports_soccer_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if ((value?.trim() ?? '').isEmpty) return 'Pozisyon gerekli';
                return null;
              },
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _dogumYili,
                    enabled: !_islemVar,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Doğum yılı',
                      hintText: '2015',
                      prefixIcon: Icon(Icons.cake_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final yil = int.tryParse(value?.trim() ?? '');
                      if (yil == null) return 'Yıl gerekli';
                      if (yil < 2000 || yil > DateTime.now().year) {
                        return 'Geçerli yıl gir';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _formaNo,
                    enabled: !_islemVar,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Forma no',
                      hintText: '10',
                      prefixIcon: Icon(Icons.numbers),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final no = int.tryParse(value?.trim() ?? '');
                      if (no == null) return 'Numara gerekli';
                      if (no < 0 || no > 999) return 'Geçersiz';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Futbolcu Fotoğrafı',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: siyah,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE1E7E3)),
              ),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: 150,
                      height: 180,
                      color: acikYesil,
                      child: _fotografUrl.text.trim().isEmpty
                          ? const Icon(
                              Icons.person_outline_rounded,
                              size: 78,
                              color: anaYesil,
                            )
                          : Image.network(
                              _fotografUrl.text.trim(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image_outlined,
                                size: 58,
                                color: anaYesil,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 13),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: anaYesil,
                        foregroundColor: Colors.white,
                      ),
                      onPressed:
                          _islemVar ? null : _galeridenFotografSecVeYukle,
                      icon: _fotografYukleniyor
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.photo_library_outlined),
                      label: Text(
                        _fotografYukleniyor
                            ? 'Fotoğraf yükleniyor...'
                            : (_fotografUrl.text.trim().isEmpty
                                ? 'Galeriden Fotoğraf Seç'
                                : 'Fotoğrafı Değiştir'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  if (_fotografUrl.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: _islemVar ? null : _fotografiKaldir,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Fotoğrafı Kaldır'),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _fotografUrl.text.trim().isEmpty
                        ? 'Fotoğraf eklemezsen oyuncu profilinde siluet görünür.'
                        : 'Fotoğraf Cloudinary’ye yüklendi ve bu futbolcuya bağlanacak.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: gri,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: anaYesil,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                onPressed: _islemVar ? null : _kaydet,
                icon: _kaydediliyor
                    ? const SizedBox(
                        width: 19,
                        height: 19,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  _fotografYukleniyor
                      ? 'Fotoğraf yükleniyor...'
                      : (_kaydediliyor
                          ? 'Kaydediliyor...'
                          : (_duzenleme
                              ? 'Değişiklikleri Kaydet'
                              : 'Futbolcuyu Ekle')),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// ============================================================
// YÖNETİCİ - BİLDİRİM GÖNDER
// ============================================================
// Yönetici bildirimi Cloud Functions üzerinden FCM topic
// 'genel' abonelerine gönderilir.
class YoneticiBildirimGonderSayfasi extends StatefulWidget {
  const YoneticiBildirimGonderSayfasi({super.key});

  @override
  State<YoneticiBildirimGonderSayfasi> createState() =>
      _YoneticiBildirimGonderSayfasiState();
}

class _YoneticiBildirimGonderSayfasiState
    extends State<YoneticiBildirimGonderSayfasi> {
  final _formKey = GlobalKey<FormState>();
  final _baslik = TextEditingController();
  final _mesaj = TextEditingController();
  bool _gonderiliyor = false;

  @override
  void dispose() {
    _baslik.dispose();
    _mesaj.dispose();
    super.dispose();
  }

  Future<bool> _yoneticiMi(String uid) async {
    final doc = await FirebaseFirestore.instance
        .collection('adminler')
        .doc(uid)
        .get();
    return doc.data()?['aktif'] == true;
  }

  Future<void> _gonder() async {
    if (!_formKey.currentState!.validate()) return;

    final onay = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Bildirimi yayınla?'),
        content: Text(
          'Bu bildirim tüm bildirimlere izin veren kullanıcılara '
          'gönderilecektir.\n\n'
          '${_baslik.text.trim()}\n${_mesaj.text.trim()}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.send),
            label: const Text('Yayınla'),
          ),
        ],
      ),
    );

    if (onay != true) return;

    setState(() => _gonderiliyor = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        throw Exception(
          'Yönetici oturumu bulunamadı. Tekrar giriş yapın.',
        );
      }

      if (!await _yoneticiMi(user.uid)) {
        throw Exception(
          'Bu hesap için yönetici yetkisi bulunmuyor.',
        );
      }

      final callable = FirebaseFunctions.instance.httpsCallable(
        'bildirimGonder',
      );

      await callable.call(<String, dynamic>{
        'baslik': _baslik.text.trim(),
        'mesaj': _mesaj.text.trim(),
      });

      if (!mounted) return;

      _baslik.clear();
      _mesaj.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Bildirim tüm kullanıcılara gönderildi.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;

      String mesaj;

      switch (e.code) {
        case 'unauthenticated':
          mesaj = 'Yönetici oturumu bulunamadı. Tekrar giriş yapın.';
          break;
        case 'permission-denied':
          mesaj = 'Bu hesap için bildirim gönderme yetkisi bulunmuyor.';
          break;
        case 'invalid-argument':
          mesaj = 'Bildirim başlığı ve mesajı kontrol edin.';
          break;
        case 'unavailable':
          mesaj = 'Bildirim servisine şu anda ulaşılamıyor. Tekrar deneyin.';
          break;
        default:
          mesaj = e.message ?? 'Bildirim gönderilemedi.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mesaj)),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;

      var mesaj = 'Bildirim gönderilemedi.';

      if (e.code == 'permission-denied') {
        mesaj = 'Firestore/Firebase yetkisi reddedildi.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mesaj)),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _gonderiliyor = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Bildirim Gönder',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: acikYesil,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.campaign_outlined, color: anaYesil),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Blaze planı gerektirmez. Bildirim uygulama açıkken veya kullanıcı uygulamayı yeniden açtığında gösterilir.',
                      style: TextStyle(
                        color: koyuYesil,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _baslik,
              enabled: !_gonderiliyor,
              maxLength: 80,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Bildirim başlığı',
                hintText: 'Örn. Haftanın maçları belli oldu',
                prefixIcon: Icon(Icons.title),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final deger = v?.trim() ?? '';
                if (deger.isEmpty) return 'Başlık gerekli';
                if (deger.length > 80) return 'Başlık en fazla 80 karakter olabilir';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _mesaj,
              enabled: !_gonderiliyor,
              minLines: 4,
              maxLines: 7,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Mesaj',
                hintText: 'Kullanıcıya gösterilecek kısa mesajı yaz...',
                prefixIcon: Icon(Icons.message_outlined),
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (v) {
                final deger = v?.trim() ?? '';
                if (deger.isEmpty) return 'Mesaj gerekli';
                if (deger.length > 240) return 'Mesaj en fazla 240 karakter olabilir';
                return null;
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Hedef: Tüm kullanıcılar • Genel bildirimler',
              style: TextStyle(color: gri, fontSize: 12),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _gonderiliyor ? null : _gonder,
                icon: _gonderiliyor
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  _gonderiliyor ? 'Yayınlanıyor...' : 'Bildirimi Yayınla',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class YoneticiHaberlerSayfasi extends StatelessWidget {
  const YoneticiHaberlerSayfasi({super.key});

  Future<void> _sil(BuildContext context, String id) async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Haberi sil?'),
        content: const Text('Bu işlem geri alınamaz.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')), ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil'))],
      ),
    );
    if (onay != true) return;
    await FirebaseFirestore.instance.collection('haberler').doc(id).delete();
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Haber silindi.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Haberleri Yönet', style: TextStyle(fontWeight: FontWeight.w900))),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HaberDuzenleSayfasi())), icon: const Icon(Icons.add), label: const Text('Yeni Haber')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('haberler')
            .orderBy('tarih', descending: true)
            .limit(_haberListesiLimiti)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Haberler alınamadı.'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: anaYesil));
          final docs = [...snapshot.data!.docs]..sort((a, b) {
            final at = a.data()['tarih'];
            final bt = b.data()['tarih'];
            final ad = at is Timestamp ? at.toDate() : DateTime(1970);
            final bd = bt is Timestamp ? bt.toDate() : DateTime(1970);
            return bd.compareTo(ad);
          });
          if (docs.isEmpty) return const Center(child: Text('Henüz haber yok.', style: TextStyle(color: gri)));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final doc = docs[i];
              final data = doc.data();
              final baslik = (data['baslik'] ?? '').toString();
              final yayinlandi = data['yayinlandi'] == true;
              return Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: CircleAvatar(backgroundColor: yayinlandi ? acikYesil : Colors.orange.withOpacity(.12), child: Icon(yayinlandi ? Icons.public : Icons.edit_note, color: yayinlandi ? anaYesil : Colors.orange)),
                  title: Text(baslik.isEmpty ? 'Başlıksız haber' : baslik, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(yayinlandi ? 'Yayında' : 'Taslak', style: TextStyle(color: yayinlandi ? anaYesil : Colors.orange, fontWeight: FontWeight.w700)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'duzenle') Navigator.push(context, MaterialPageRoute(builder: (_) => HaberDuzenleSayfasi(mevcutHaber: Haber.fromFirestore(doc))));
                      if (value == 'sil') _sil(context, doc.id);
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'duzenle', child: Text('Düzenle')), PopupMenuItem(value: 'sil', child: Text('Sil'))],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class HaberDuzenleSayfasi extends StatefulWidget {
  final Haber? mevcutHaber;
  const HaberDuzenleSayfasi({super.key, this.mevcutHaber});

  @override
  State<HaberDuzenleSayfasi> createState() => _HaberDuzenleSayfasiState();
}

class _HaberDuzenleSayfasiState extends State<HaberDuzenleSayfasi> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baslik;
  late final TextEditingController _ozet;
  late final TextEditingController _icerik;
  late final TextEditingController _yazar;
  late final TextEditingController _resimUrl;
  String _kategori = 'Genel';
  late DateTime _tarih;
  bool _yayinlandi = true;
  bool _kaydediliyor = false;

  static const List<String> _kategoriler = [
    'Genel',
    'Maç',
    'Transfer',
    'Takım',
    'Lig',
    'Altyapı',
    'Kulüp',
    'Duyuru',
  ];

  @override
  void initState() {
    super.initState();
    final h = widget.mevcutHaber;
    _baslik = TextEditingController(text: h?.baslik ?? '');
    _ozet = TextEditingController(text: h?.ozet ?? '');
    _icerik = TextEditingController(text: h?.icerik ?? '');
    _yazar = TextEditingController(text: h?.yazar ?? '');
    _resimUrl = TextEditingController(text: h?.resimUrl ?? '');
    _kategori = _kategoriler.contains(h?.kategori) ? h!.kategori : 'Genel';
    _tarih = h?.tarih ?? DateTime.now();
    _yayinlandi = h?.yayinlandi ?? true;
  }

  @override
  void dispose() {
    _baslik.dispose();
    _ozet.dispose();
    _icerik.dispose();
    _yazar.dispose();
    _resimUrl.dispose();
    super.dispose();
  }

  Future<void> _tarihSec() async {
    final tarih = await showDatePicker(
      context: context,
      initialDate: _tarih,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale('tr', 'TR'),
    );
    if (tarih == null || !mounted) return;
    final saat = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_tarih),
    );
    if (saat == null || !mounted) return;
    setState(() {
      _tarih = DateTime(tarih.year, tarih.month, tarih.day, saat.hour, saat.minute);
    });
  }

  Future<void> _kaydet() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _kaydediliyor = true);
    try {
      final ref = widget.mevcutHaber == null
          ? FirebaseFirestore.instance.collection('haberler').doc()
          : FirebaseFirestore.instance.collection('haberler').doc(widget.mevcutHaber!.id);

      final veri = <String, dynamic>{
        'baslik': _baslik.text.trim(),
        'ozet': _ozet.text.trim(),
        'icerik': _icerik.text.trim(),
        'kategori': _kategori,
        'yazar': _yazar.text.trim(),
        'resimUrl': _resimUrl.text.trim(),
        'yayinlandi': _yayinlandi,
        'tarih': Timestamp.fromDate(_tarih),
        'guncellemeTarihi': FieldValue.serverTimestamp(),
      };
      await ref.set(veri, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_yayinlandi ? 'Haber yayınlandı.' : 'Haber taslak olarak kaydedildi.')),
      );
      Navigator.pop(context);
    } catch (e) {
      debugPrint('Haber kaydetme hatası: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Haber kaydedilemedi. İnternet bağlantısını ve Firestore yetkisini kontrol et.')),
        );
      }
    } finally {
      if (mounted) setState(() => _kaydediliyor = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      );

  String _tarihMetni() {
    final gun = _tarih.day.toString().padLeft(2, '0');
    final ay = _tarih.month.toString().padLeft(2, '0');
    final yil = _tarih.year.toString();
    final saat = _tarih.hour.toString().padLeft(2, '0');
    final dakika = _tarih.minute.toString().padLeft(2, '0');
    return '$gun.$ay.$yil $saat:$dakika';
  }

  Widget _bolumBasligi(String baslik, String aciklama, IconData ikon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(12)),
            child: Icon(ikon, color: anaYesil, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(baslik, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(aciklama, style: const TextStyle(fontSize: 11, color: gri)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _onizleme() {
    final url = _resimUrl.text.trim();
    if (url.isEmpty) {
      return Container(
        height: 130,
        decoration: BoxDecoration(color: acikYesil, borderRadius: BorderRadius.circular(18)),
        child: const Center(child: Icon(Icons.newspaper, color: anaYesil, size: 48)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Image.network(
        url,
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          height: 130,
          color: Colors.grey.shade100,
          alignment: Alignment.center,
          child: const Text('Görsel önizlenemedi.'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final duzenleme = widget.mevcutHaber != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(duzenleme ? 'Haberi Düzenle' : 'Yeni Haber', style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 35),
          children: [
            _bolumBasligi('Haber Bilgileri', 'Okuyucunun göreceği temel bilgiler', Icons.article_outlined),
            TextFormField(
              controller: _baslik,
              decoration: _decoration('Haber başlığı', Icons.title, hint: 'Örn. Yalova’da haftanın maçları belli oldu'),
              textInputAction: TextInputAction.next,
              validator: (v) => v == null || v.trim().isEmpty ? 'Başlık gerekli' : null,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _kategori,
              decoration: _decoration('Kategori', Icons.category_outlined),
              items: _kategoriler.map((kategori) => DropdownMenuItem(value: kategori, child: Text(kategori))).toList(),
              onChanged: _kaydediliyor ? null : (v) => setState(() => _kategori = v ?? 'Genel'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _yazar,
              decoration: _decoration('Yazar', Icons.person_outline, hint: 'Örn. Yalova Wonder Kids'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _ozet,
              maxLines: 3,
              decoration: _decoration('Kısa özet', Icons.short_text, hint: 'Haberin 1-2 cümlelik özeti'),
            ),
            const SizedBox(height: 20),
            _bolumBasligi('Haber İçeriği', 'Haberi detaylı olarak yaz', Icons.edit_note_outlined),
            TextFormField(
              controller: _icerik,
              minLines: 9,
              maxLines: 18,
              decoration: _decoration('Haber içeriği', Icons.article_outlined, hint: 'Haber metnini buraya yaz...'),
              validator: (v) => v == null || v.trim().isEmpty ? 'İçerik gerekli' : null,
            ),
            const SizedBox(height: 20),
            _bolumBasligi('Yayın Bilgileri', 'Tarih ve yayın durumunu belirle', Icons.schedule),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _kaydediliyor ? null : _tarihSec,
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_month_outlined, color: anaYesil),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Yayın tarihi', style: TextStyle(fontSize: 12, color: gri)), const SizedBox(height: 3), Text(_tarihMetni(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))])),
                      const Icon(Icons.edit_calendar_outlined, color: gri),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Hemen yayınla', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(_yayinlandi ? 'Haber kullanıcıların Haberler bölümünde görünecek.' : 'Haber taslak olarak saklanacak.'),
              value: _yayinlandi,
              onChanged: _kaydediliyor ? null : (v) => setState(() => _yayinlandi = v),
            ),
            const SizedBox(height: 20),
            _bolumBasligi('Kapak Görseli', 'İnternetteki bir görselin HTTPS adresini kullan', Icons.image_outlined),
            TextFormField(
              controller: _resimUrl,
              keyboardType: TextInputType.url,
              decoration: _decoration('Kapak görseli URL', Icons.link, hint: 'https://...'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _onizleme(),
            const SizedBox(height: 7),
            const Text('Not: Firebase Storage şu an Spark planda kullanılamıyor. Bu nedenle kapak görseli şimdilik HTTPS URL ile ekleniyor.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: gri, height: 1.4)),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _kaydediliyor ? null : _kaydet,
                icon: _kaydediliyor ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(_yayinlandi ? Icons.publish : Icons.save_outlined),
                label: Text(_kaydediliyor ? 'Kaydediliyor...' : (_yayinlandi ? 'Haber Yayınla' : 'Taslak Kaydet')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BilgiSayfasi extends StatelessWidget {
  final String baslik;
  final String mesaj;

  const BilgiSayfasi({super.key, required this.baslik, required this.mesaj});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(baslik, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(Icons.construction, size: 46, color: anaYesil),
              ),
              const SizedBox(height: 20),
              Text(baslik, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 9),
              Text(
                mesaj,
                textAlign: TextAlign.center,
                style: const TextStyle(color: gri, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// İLETİŞİM
// ============================================================

class IletisimSayfasi extends StatelessWidget {
  const IletisimSayfasi({super.key});

  static final Uri instagramUri = Uri.parse('https://www.instagram.com/yalovawonderkids/');

  Future<void> _instagramAc(BuildContext context) async {
    try {
      if (await canLaunchUrl(instagramUri)) {
        await launchUrl(instagramUri, mode: LaunchMode.externalApplication);
        return;
      }

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Instagram açılamadı. Lütfen tekrar deneyin.')),
      );
    } catch (_) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Instagram açılamadı. Lütfen tekrar deneyin.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('İletişim', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Column(
              children: [
                Icon(Icons.mail_outline, color: anaYesil, size: 46),
                SizedBox(height: 14),
                Text(
                  'Yalova Wonder Kids',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: koyuYesil,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Bize Ulaşın',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: siyah, fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 10),
                Text(
                  'Öneri, haber, fotoğraf, hata bildirimi veya '
                  'Yalova amatör futboluyla ilgili konularda '
                  'bizimle Instagram üzerinden iletişime geçebilirsiniz.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: gri, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => _instagramAc(context),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2EAF7),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        Icons.camera_alt_outlined,
                        color: Color(0xFFC13584),
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 15),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Instagram\'dan Bize Ulaşın',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: siyah,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            '@yalovawonderkids',
                            style: TextStyle(fontSize: 13, color: gri),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, color: gri, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: anaYesil),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Instagram uygulaması yüklüyse profiliniz '
                    'Instagram\'da açılır. Yüklü değilse bağlantı '
                    'tarayıcıda açılır.',
                    style: TextStyle(color: gri, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SuperAmatorGrupSayfasi extends StatelessWidget {
  final String grup;

  const SuperAmatorGrupSayfasi({
    super.key,
    required this.grup,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Süper Amatör - $grup Grubu',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                const Icon(Icons.groups, color: anaYesil, size: 32),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '$grup Grubu',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: siyah,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _menuKarti(
            context,
            ikon: Icons.emoji_events,
            baslik: 'Puan Durumu',
            aciklama: '$grup Grubu puan durumu',
          ),
          const SizedBox(height: 9),
          _menuKarti(
            context,
            ikon: Icons.calendar_month,
            baslik: 'Fikstür',
            aciklama: '$grup Grubu maç programı',
          ),
        ],
      ),
    );
  }

  Widget _menuKarti(
    BuildContext context, {
    required IconData ikon,
    required String baslik,
    required String aciklama,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () {
          if (baslik == 'Puan Durumu') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SuperAmatorPuanDurumuSayfasi(grup: grup),
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(ikon, color: anaYesil, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      baslik,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: siyah,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      aciklama,
                      style: const TextStyle(fontSize: 11, color: gri),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 15, color: gri),
            ],
          ),
        ),
      ),
    );
  }
}


class SuperAmatorPuanDurumuSayfasi extends StatelessWidget {
  final String grup;

  const SuperAmatorPuanDurumuSayfasi({
    super.key,
    required this.grup,
  });

  static const List<String> aGrubu = [
    'Acar Spor',
    'Yeşilova Spor',
    'Gençlerbirliği Spor',
    'Sultaniye Spor',
    'Armutlu Belediye Spor',
    'RMK Marine Tavşanlı Belediye Spor',
    'Altınova Belediye Spor',
    'Kaytazdere Belediye Spor',
  ];

  static const List<String> bGrubu = [
    'Yalova Üniversitesi Spor',
    'Kocadereköy Spor',
    'Taşköprü Spor',
    'Doğan Spor',
    'Soğucak Spor',
    'Demir Spor',
    'Safranyolu Doğuş Spor',
    'Çınarcık Belediye Spor',
  ];

  List<String> get takimlar => grup == 'A' ? aGrubu : bGrubu;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Süper Amatör $grup Grubu',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Column(
        children: [
          _puanUstBilgi(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final toplam = constraints.maxWidth - 4;
                final takimGenisligi = toplam * 0.32;
                final digerGenislik = (toplam - takimGenisligi) / 9;

                return _puanTablosu(
                  context,
                  takimGenisligi,
                  digerGenislik,
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 9, 14, 12),
            child: Text(
              'Sezon henüz başlamadığı için tüm takımlar 0 puanla başlamaktadır.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: gri),
            ),
          ),
        ],
      ),
    );
  }

  Widget _puanUstBilgi() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
      color: Colors.white,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.asset(
              'assets/yalova_wonder_kids_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(Icons.shield_outlined, color: anaYesil, size: 20);
              },
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              '2026-2027 Süper Amatör $grup Grubu',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: siyah,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _puanTablosu(
    BuildContext context,
    double takimGenisligi,
    double digerGenislik,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          _baslikSatiri(takimGenisligi, digerGenislik),
          Expanded(
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: takimlar.length,
              itemBuilder: (context, index) {
                return _takimSatiri(
                  context,
                  sira: index + 1,
                  takim: takimlar[index],
                  takimGenisligi: takimGenisligi,
                  digerGenislik: digerGenislik,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _baslikSatiri(double takimGenisligi, double digerGenislik) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(color: koyuYesil),
      child: Row(
        children: [
          _BaslikHucre(text: '#', width: digerGenislik),
          _BaslikHucre(text: 'Takım', width: takimGenisligi, hizalama: TextAlign.left),
          _BaslikHucre(text: 'O', width: digerGenislik),
          _BaslikHucre(text: 'G', width: digerGenislik),
          _BaslikHucre(text: 'B', width: digerGenislik),
          _BaslikHucre(text: 'M', width: digerGenislik),
          _BaslikHucre(text: 'AG', width: digerGenislik),
          _BaslikHucre(text: 'YG', width: digerGenislik),
          _BaslikHucre(text: 'AV', width: digerGenislik),
          _BaslikHucre(text: 'P', width: digerGenislik),
        ],
      ),
    );
  }

  Widget _takimSatiri(
    BuildContext context, {
    required int sira,
    required String takim,
    required double takimGenisligi,
    required double digerGenislik,
  }) {
    final bool ilkUc = sira <= 3;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: ilkUc ? acikYesil.withOpacity(0.35) : Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SuperAmatorTakimProfilSayfasi(
                takimAdi: takim,
                grup: grup,
              ),
            ),
          );
        },
        child: Row(
          children: [
            _Hucre('$sira', digerGenislik, bold: true, fontSize: 10),
            _Hucre(takim.toUpperCase(), takimGenisligi, align: TextAlign.left, bold: true, fontSize: 10),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik),
            _Hucre('0', digerGenislik, bold: true, fontSize: 11),
          ],
        ),
      ),
    );
  }
}

class SuperAmatorTakimProfilSayfasi extends StatelessWidget {
  final String takimAdi;
  final String grup;

  const SuperAmatorTakimProfilSayfasi({
    super.key,
    required this.takimAdi,
    required this.grup,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Takım Profili', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF087A3D), Color(0xFF064B2A)],
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(Icons.shield_outlined, color: anaYesil, size: 48),
                ),
                const SizedBox(height: 13),
                Text(
                  takimAdi,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Süper Amatör Lig $grup Grubu • 2026-2027',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Color(0xFFE4E9E6)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Takım Bilgileri',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: siyah),
                ),
                SizedBox(height: 10),
                Text(
                  '2026-2027 sezonu takım bilgileri hazırlanıyor.',
                  style: TextStyle(fontSize: 12, color: gri, height: 1.4),
                ),
                SizedBox(height: 6),
                Text(
                  'Fikstür yayınlandığında takım maçları bu bölümde gösterilecektir.',
                  style: TextStyle(fontSize: 12, color: gri, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class YalovaYerelLigler2026Sayfasi extends StatelessWidget {
  const YalovaYerelLigler2026Sayfasi({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Yerel Ligler',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 25),
        children: [
          _kategoriBasligi('Büyükler', Icons.emoji_events),
          _ligKarti(
            context,
            baslik: 'Süper Amatör Lig A Grubu',
            aciklama: 'Puan durumunu görüntüle',
            grup: 'A',
          ),
          _ligKarti(
            context,
            baslik: 'Süper Amatör Lig B Grubu',
            aciklama: 'Puan durumunu görüntüle',
            grup: 'B',
          ),
        ],
      ),
    );
  }

  Widget _kategoriBasligi(String baslik, IconData ikon) {
    return Padding(
      padding: const EdgeInsets.only(top: 15, bottom: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: acikYesil,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(ikon, color: anaYesil, size: 21),
          ),
          const SizedBox(width: 10),
          Text(
            baslik,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ligKarti(
    BuildContext context, {
    required String baslik,
    required String aciklama,
    required String grup,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SuperAmatorGrupSayfasi(grup: grup),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: acikYesil,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.emoji_events,
                  color: anaYesil,
                  size: 23,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      baslik,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: siyah,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      aciklama,
                      style: const TextStyle(
                        fontSize: 11,
                        color: gri,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 15,
                color: gri,
              ),
            ],
          ),
        ),
      ),
    );
  }
}