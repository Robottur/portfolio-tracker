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

  /// What the UI shows: the last complete scan while the current one is broken.
  List<Transaction> get displayTransactions =>
      scan != null && !scan!.complete && lastValidScan != null
      ? lastValidScan!.ledger.transactions
      : transactions;
  ReplayResult get displayReplay => replay(displayTransactions, through: today);

  PeriodResult displayPeriod(Period p) => computePeriod(
    period: p,
    today: today,
    transactions: displayTransactions,
    prices: prices,
    calendar: _calendar,
  );

  int get issueCount =>
      (scan?.ledger.issues.length ?? 0) +
      (scan?.fileIssues.length ?? 0) +
      displayReplay.issues.length;

  bool get displayIncomplete =>
      (scan != null && !scan!.complete && lastValidScan == null) ||
      !displayReplay.valid;

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
    // Queued so the swap never lands under a running restore/export/publish.
    await _serial(() async {
      final scanner = LedgerScanner(f, _retained);
      final result = await scanner.scan(nowUtc: _nowUtc());
      // A refused folder leaves all state as it was.
      final descriptor = result.descriptor;
      if (descriptor == null) {
        // With nothing open there is no state to protect; keep the reason visible.
        if (_folder == null) {
          scan = result;
          notifyListeners();
        }
        throw StateError(result.fileIssues.first.message);
      }
      // Loaded whatever the source settings: manual prices live in this store
      // and a later setManual rewrites all of them.
      await prices.load();
      await prefs.setFolderLocation(location);
      if (lastValidScan?.descriptor?.portfolioId != descriptor.portfolioId) {
        lastValidScan = null;
      }
      scan = result;
      _folder = f;
      _scanner = scanner;
      _publisher = Publisher(f, _pending);
      _reopenFailed = false;
      if (result.complete) lastValidScan = result;
      notifyListeners();
    });
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
      _resuming ??= _resumeAll().whenComplete(() => _resuming = null);

  Future<void> _resumeAll() async {
    await _serial(_resume);
    // Outside the queue: a save must never wait on the network.
    try {
      await refreshPrices();
    } on Object {
      // Price refresh is best effort; the coordinator records source errors.
    }
  }

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

  static const readOnlyMessage =
      'This folder was written by a newer app version. Update the app to edit it.';

  /// Next free slot on [date]: highest existing dayOrder + 10 (default 10).
  int nextDayOrder(DateTime date) {
    var max = 0;
    for (final t in transactions) {
      if (t.effectiveDate == date && t.dayOrder > max) max = t.dayOrder;
    }
    return max + 10;
  }

  /// Replay of the current ledger with [candidate] added, replacing
  /// [replacingTransactionId]; a null candidate previews a void.
  ReplayResult previewChange({
    Transaction? candidate,
    String? replacingTransactionId,
  }) {
    final leaves = scan?.ledger.leaves ?? const <String, LedgerRecord>{};
    final txs = [
      for (final e in leaves.entries)
        if (e.key != replacingTransactionId &&
            e.value.operation == RecordOp.upsert)
          e.value.transaction!,
      ?candidate,
    ];
    return replay(txs, through: today);
  }

  /// Issues in [preview] that the current ledger does not already have.
  List<LedgerIssue> newIssues(ReplayResult preview) {
    String key(LedgerIssue i) =>
        '${i.kind.index}|${i.message}|${i.recordIds.join(',')}';
    final have = {for (final i in replayNow.issues) key(i)};
    return [
      for (final i in preview.issues)
        if (!have.contains(key(i))) i,
    ];
  }

  Future<void> addTransaction(Transaction t) async => _write(
    t,
    null,
    (d) => LedgerRecord.newUpsert(
      portfolioId: d,
      deviceId: prefs.deviceId,
      transaction: t,
      now: _nowUtc(),
    ),
  );

  Future<void> correctTransaction(
    String transactionId,
    Transaction t, {
    String? expectedRecordId,
  }) async {
    final leaf = _upsertLeaf(transactionId, expectedRecordId);
    return _write(
      t,
      transactionId,
      (d) => LedgerRecord.newUpsert(
        portfolioId: d,
        deviceId: prefs.deviceId,
        transaction: t,
        transactionId: transactionId,
        supersedes: [leaf.recordId],
        now: _nowUtc(),
      ),
    );
  }

  Future<void> voidTransaction(
    String transactionId, {
    String? expectedRecordId,
  }) async {
    final leaf = _upsertLeaf(transactionId, expectedRecordId);
    return _write(
      null,
      transactionId,
      (d) => LedgerRecord.newVoid(
        portfolioId: d,
        deviceId: prefs.deviceId,
        transactionId: transactionId,
        supersedes: [leaf.recordId],
        now: _nowUtc(),
      ),
    );
  }

  /// Supersedes every competing leaf; a null [chosen] voids the transaction.
  Future<void> resolveConflict(
    String transactionId,
    Transaction? chosen, {
    Set<String>? expectedLeafIds,
  }) async {
    _checkWritable();
    final ids = <String>[
      for (final r
          in scan?.ledger.conflicted[transactionId] ?? <LedgerRecord>[])
        r.recordId,
    ];
    if (ids.isEmpty) throw StateError('This transaction has no conflict');
    if (expectedLeafIds != null &&
        (expectedLeafIds.length != ids.length ||
            !expectedLeafIds.containsAll(ids))) {
      throw StateError(changedMessage);
    }
    return _write(
      chosen,
      transactionId,
      (d) => chosen == null
          ? LedgerRecord.newVoid(
              portfolioId: d,
              deviceId: prefs.deviceId,
              transactionId: transactionId,
              supersedes: ids,
              now: _nowUtc(),
            )
          : LedgerRecord.newUpsert(
              portfolioId: d,
              deviceId: prefs.deviceId,
              transaction: chosen,
              transactionId: transactionId,
              supersedes: ids,
              now: _nowUtc(),
            ),
    );
  }

  static const changedMessage =
      'This transaction changed on another device. Reopen it to see the latest version.';

  void _checkWritable() {
    if (scan?.descriptor == null || _publisher == null) {
      throw StateError('The portfolio folder is not available.');
    }
    if (scan!.readOnly) throw StateError(readOnlyMessage);
  }

  LedgerRecord _upsertLeaf(String transactionId, String? expectedRecordId) {
    _checkWritable();
    final leaf = scan!.ledger.leaves[transactionId];
    if (leaf == null || leaf.operation != RecordOp.upsert) {
      throw StateError('This transaction can no longer be changed');
    }
    if (expectedRecordId != null && leaf.recordId != expectedRecordId) {
      throw StateError(changedMessage);
    }
    return leaf;
  }

  Future<void> _write(
    Transaction? t,
    String? replacing,
    LedgerRecord Function(String portfolioId) build,
  ) async {
    _checkWritable();
    if (t != null) {
      final errors = t.validate(today: today);
      if (errors.isNotEmpty) throw StateError(errors.first);
    }
    final issues = newIssues(
      previewChange(candidate: t, replacingTransactionId: replacing),
    );
    if (issues.isNotEmpty) throw StateError(issues.first.message);
    return publishRecord(build(scan!.descriptor!.portfolioId));
  }

  void _checkOpen() {
    if (_folder == null || _publisher == null) {
      throw StateError('The portfolio folder is not available.');
    }
  }

  Future<CopyReport> exportTo(RecordFolder dest) async {
    _checkOpen();
    return _serial(() => copyLedger(_folder!, dest));
  }

  Future<CopyReport> restoreFrom(RecordFolder src) async {
    _checkOpen();
    if (scan?.readOnly ?? false) throw StateError(readOnlyMessage);
    return _serial(() async {
      try {
        return await copyLedger(src, _folder!);
      } finally {
        await _rescanNow();
      }
    });
  }

  Future<int> republishMissing() async {
    _checkOpen();
    return _serial(() async {
      try {
        return await _scanner!.republishMissing(_publisher!);
      } finally {
        await _rescanNow();
      }
    });
  }

  Future<void> setManualPrice(
    String instrumentId,
    DateTime date,
    Decimal price,
  ) async {
    _checkOpen();
    await _serial(() async {
      await prices.setManual(instrumentId, date, price, nowUtc: _nowUtc());
      notifyListeners();
    });
  }

  Future<void> removeManualPrice(String instrumentId, DateTime date) async {
    _checkOpen();
    await _serial(() async {
      await prices.removeManual(instrumentId, date);
      notifyListeners();
    });
  }

  /// Sources the user can consent to, for the settings screen.
  List<PriceSource> get sources => List.unmodifiable(_sources);

  Future<void> setPrivacy(bool on) async {
    await prefs.setPrivacyMode(on);
    notifyListeners();
  }
}
