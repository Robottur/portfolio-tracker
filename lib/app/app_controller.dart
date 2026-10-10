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
  Publisher? _publisher;
  LedgerScanner? _scanner;
  Future<void> _tail = Future.value();
  Future<void>? _resuming;
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

  /// Reopens the saved folder at startup; any failure means access is lost.
  Future<void> restore(Future<RecordFolder?> Function(String) reopen) async {
    final saved = prefs.folderLocation;
    if (saved == null) return;
    try {
      final f = await reopen(saved);
      if (f == null) throw StateError(_folderUnreadable);
      await openFolder(f, saved);
    } on Object {
      _reopenFailed = true;
      notifyListeners();
    }
  }

  // Publisher forbids concurrent publish/retryPending, so all of them queue here.
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _tail.then((_) => f());
    _tail = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  /// Publishes a record and rescans; callers get PublishException on failure.
  Future<void> publishRecord(LedgerRecord r) => _serial(() async {
    try {
      await _publisher!.publish(r);
    } finally {
      await _rescanNow();
    }
  });

  Future<void> openFolder(
    RecordFolder f,
    String location, {
    String? createName,
  }) async {
    if (createName != null) {
      // A missing descriptor next to old records is a sync gap, not a new portfolio.
      if ((await f.listRecordFiles()).isNotEmpty) {
        throw StateError(
          'This folder already contains records. '
          'Open it as an existing portfolio instead.',
        );
      }
      if (!await f.createDescriptor(
        PortfolioDescriptor.create(createName).encode(),
      )) {
        throw StateError('This folder already contains a portfolio');
      }
    }
    final scanner = LedgerScanner(f, _retained);
    final result = await scanner.scan(nowUtc: _nowUtc());
    scan = result;
    if (result.descriptor == null) {
      notifyListeners();
      throw StateError(result.fileIssues.first.message);
    }
    // Loaded whatever the source settings: manual prices live in this store
    // and a later setManual rewrites all of them.
    await prices.load();
    _folder = f;
    _scanner = scanner;
    _publisher = Publisher(f, _pending);
    _reopenFailed = false;
    if (result.complete) lastValidScan = result;
    await prefs.setFolderLocation(location);
    notifyListeners();
  }

  Future<void> rescan() => _serial(_rescanNow);

  Future<void> _rescanNow() async {
    final s = _scanner;
    if (s == null) return;
    final result = await s.scan(nowUtc: _nowUtc());
    scan = result;
    if (result.complete) lastValidScan = result;
    notifyListeners();
  }

  /// A second call while one is running gets the same Future.
  Future<void> onResume() =>
      _resuming ??= _serial(_resume).whenComplete(() => _resuming = null);

  Future<void> _resume() async {
    final id = (scan?.descriptor ?? lastValidScan?.descriptor)?.portfolioId;
    if (_folder == null || id == null) return;
    // Failures here surface through the rescan (e.g. "Folder could not be read").
    try {
      await _publisher!.retryPending(portfolioId: id);
    } on Object {
      // shortcut: other pending-retry errors are not shown, upgrade with a status line.
    }
    try {
      await _rescanNow();
    } on Object {
      // shortcut: a failed rescan keeps the previous scan, upgrade with a status line.
    }
    try {
      await refreshPrices();
    } on Object {
      // Price refresh is best effort; the coordinator records source errors.
    }
  }

  Future<void> refreshPrices({bool manual = false}) async {
    if (prefs.enabledSources.isEmpty) return;
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
    await prefs.setEnabledSources(next);
    notifyListeners();
    // Manual: the 5-minute throttle would skip the first refresh after enabling.
    if (on) await refreshPrices(manual: true);
  }

  Future<void> setPrivacy(bool on) async {
    await prefs.setPrivacyMode(on);
    notifyListeners();
  }
}
