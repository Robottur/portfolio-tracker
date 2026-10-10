import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:portfolio_core/portfolio_core.dart';

import 'device_prefs.dart';

const _folderUnreadable = 'Folder could not be read';

class AppController extends ChangeNotifier {
  AppController({
    required this.prefs,
    required Directory privateDir,
    required http.Client network,
    DateTime Function()? nowUtc,
  }) : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc()),
       _pending = DirBlobStore(Directory('${privateDir.path}/pending')),
       _retained = DirBlobStore(Directory('${privateDir.path}/retained')),
       prices = PriceStore(
         DirBlobStore(Directory('${privateDir.path}/prices')),
       ) {
    final client = ConsentClient(
      network,
      () => RefreshCoordinator.hostsFor(_enabledSources()),
    );
    _sources = [
      YahooSource(client, nowUtc: _nowUtc),
      IsYatirimSource(client, nowUtc: _nowUtc),
      GoldSource(client, nowUtc: _nowUtc),
      TcmbSource(client, nowUtc: _nowUtc),
      BtcTurkSource(client, nowUtc: _nowUtc),
    ];
    refresher = RefreshCoordinator(
      sources: _sources,
      enabledSourceIds: () => prefs.enabledSources,
      store: prices,
      nowUtc: _nowUtc,
    );
  }

  final DevicePrefs prefs;
  final PriceStore prices;
  late final RefreshCoordinator refresher;
  final DateTime Function() _nowUtc;
  final BlobStore _pending;
  final BlobStore _retained;
  late final List<PriceSource> _sources;

  RecordFolder? _folder;
  Publisher? publisher;
  LedgerScanner? _scanner;
  bool _pricesLoaded = false;
  bool _reopenFailed = false;

  ScanResult? scan;
  ScanResult? lastValidScan;

  Iterable<PriceSource> _enabledSources() =>
      _sources.where((s) => prefs.enabledSources.contains(s.id));

  bool get folderAccessLost =>
      _reopenFailed ||
      (scan?.fileIssues.any((i) => i.message == _folderUnreadable) ?? false);

  bool get privacyMode => prefs.privacyMode;
  DateTime get today => istanbulToday(_nowUtc());
  List<Transaction> get transactions => scan?.ledger.transactions ?? const [];
  ReplayResult get replayNow => replay(transactions, through: today);

  TradingCalendar get _calendar =>
      TradingCalendar(prices.knownBistTradingDays());

  PeriodResult period(Period p) => computePeriod(
    period: p,
    today: today,
    transactions: transactions,
    prices: prices,
    calendar: _calendar,
  );

  /// The saved folder could not be reopened (permission revoked or gone).
  void markFolderUnavailable() {
    _reopenFailed = true;
    notifyListeners();
  }

  Future<void> openFolder(
    RecordFolder f,
    String location, {
    String? createName,
  }) async {
    if (createName != null &&
        !await f.createDescriptor(
          PortfolioDescriptor.create(createName).encode(),
        )) {
      throw StateError('This folder already contains a portfolio');
    }
    final scanner = LedgerScanner(f, _retained);
    final result = await scanner.scan(nowUtc: _nowUtc());
    scan = result;
    if (result.descriptor == null) {
      notifyListeners();
      throw StateError(result.fileIssues.first.message);
    }
    _folder = f;
    _scanner = scanner;
    publisher = Publisher(f, _pending);
    _reopenFailed = false;
    if (result.complete) lastValidScan = result;
    prefs.folderLocation = location;
    notifyListeners();
  }

  Future<void> rescan() async {
    final s = _scanner;
    if (s == null) return;
    final result = await s.scan(nowUtc: _nowUtc());
    scan = result;
    if (result.complete) lastValidScan = result;
    notifyListeners();
  }

  Future<void> onResume() async {
    final id = scan?.descriptor?.portfolioId;
    if (_folder == null || id == null) return;
    await publisher!.retryPending(portfolioId: id);
    await rescan();
    await refreshPrices();
  }

  Future<void> refreshPrices({bool manual = false}) async {
    if (prefs.enabledSources.isEmpty) return;
    if (!_pricesLoaded) {
      await prices.load();
      _pricesLoaded = true;
    }
    final txs = transactions;
    await refresher.refresh(
      current: [
        for (final p in replayNow.positions.values)
          if (p.quantity > Decimal.zero) p.instrument,
      ],
      history: historicalPriceNeeds(
        today: today,
        transactions: txs,
        calendar: _calendar,
      ),
      manual: manual,
    );
    notifyListeners();
  }

  Future<void> setSourceEnabled(String id, bool on) async {
    final next = {...prefs.enabledSources};
    on ? next.add(id) : next.remove(id);
    prefs.enabledSources = next;
    notifyListeners();
    // Manual: the 5-minute throttle would skip the first refresh after enabling.
    if (on) await refreshPrices(manual: true);
  }

  Future<void> setPrivacy(bool on) async {
    prefs.privacyMode = on;
    notifyListeners();
  }
}
