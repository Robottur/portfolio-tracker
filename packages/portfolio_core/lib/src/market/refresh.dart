import '../dates.dart';
import '../model/instrument.dart';
import 'consent_client.dart';
import 'price.dart';
import 'price_store.dart';
import 'source.dart';

class SourceStatus {
  DateTime? lastSuccess;
  String? lastError;
  DateTime? retryNotBefore;
}

class RefreshReport {
  RefreshReport({
    this.fetched = 0,
    List<String>? errors,
    this.skippedNotDue = false,
  }) : errors = errors ?? [];
  int fetched;
  final List<String> errors;
  final bool skippedNotDue;
}

const _latestEvery = Duration(minutes: 5);
const _maxBackoff = 60;

/// Decides which enabled source serves which instrument, and never calls a
/// source the user has not enabled.
class RefreshCoordinator {
  RefreshCoordinator({
    required this.sources,
    required this.enabledSourceIds,
    required this.store,
    required this.nowUtc,
  });

  final List<PriceSource> sources;
  final Set<String> Function() enabledSourceIds;
  final PriceStore store;
  final DateTime Function() nowUtc;

  final Map<String, SourceStatus> _status = {};
  final Map<String, int> _failures = {};
  DateTime? _lastLatestStart;

  Map<String, SourceStatus> get status => Map.unmodifiable(_status);

  static Set<String> hostsFor(Iterable<PriceSource> enabled) => {
    for (final s in enabled) ...s.domains,
  };

  String? _latestId(AssetClass c, Set<String> on) => switch (c) {
    AssetClass.bistShare => 'yahoo',
    AssetClass.fx => on.contains('yahoo') ? 'yahoo' : 'tcmb',
    AssetClass.crypto => 'btcturk',
    AssetClass.gold => 'gold',
  };

  static String _closesId(AssetClass c) => switch (c) {
    AssetClass.bistShare => 'isyatirim',
    AssetClass.fx => 'tcmb',
    AssetClass.crypto => 'btcturk',
    AssetClass.gold => 'gold',
  };

  Future<RefreshReport> refresh({
    required List<Instrument> current,
    required Map<DateTime, List<Instrument>> history,
    bool manual = false,
  }) async {
    final now = nowUtc();
    final last = _lastLatestStart;
    if (!manual && last != null && now.difference(last) < _latestEvery) {
      return RefreshReport(skippedNotDue: true);
    }
    _lastLatestStart = now;

    final on = enabledSourceIds();
    final byId = {for (final s in sources) s.id: s};
    final report = RefreshReport();
    final denied = <String>{};

    // Null when the source is off, unknown, in backoff or just refused consent.
    PriceSource? usable(String? id) {
      final s = id == null || !on.contains(id) ? null : byId[id];
      if (s == null || denied.contains(s.id)) return null;
      final retry = _status[s.id]?.retryNotBefore;
      if (retry != null && nowUtc().isBefore(retry)) return null;
      return s;
    }

    Future<void> call(
      PriceSource s,
      Future<List<PriceObservation>> Function() fetch,
    ) async {
      final st = _status.putIfAbsent(s.id, SourceStatus.new);
      try {
        final obs = await fetch();
        await store.addFetched(obs);
        report.fetched += obs.length;
        st
          ..lastSuccess = nowUtc()
          ..lastError = null
          ..retryNotBefore = null;
        _failures.remove(s.id);
      } on ConsentDeniedException {
        denied.add(s.id);
        st.lastError = 'Source is disabled';
      } on Object catch (e) {
        final msg = e is SourceException ? e.message : e.runtimeType.toString();
        final n = (_failures[s.id] ?? 0) + 1;
        _failures[s.id] = n;
        final backoff = Duration(
          minutes: n > 6 ? _maxBackoff : (1 << (n - 1)).clamp(1, _maxBackoff),
        );
        st
          ..lastError = msg
          ..retryNotBefore = nowUtc().add(
            (e is SourceException ? e.retryAfter : null) ?? backoff,
          );
        report.errors.add('${s.id}: $msg');
      }
    }

    final groups = <String, List<Instrument>>{};
    for (final i in current) {
      final id = _latestId(i.assetClass, on);
      if (usable(id) != null) groups.putIfAbsent(id!, () => []).add(i);
    }
    for (final e in groups.entries) {
      await call(byId[e.key]!, () => byId[e.key]!.latest(e.value));
    }

    for (final e in history.entries) {
      final day = e.key;
      for (final i in e.value) {
        final cached = store.closeOnOrBefore(i.id, day);
        if (cached != null && daysBetween(cached.sessionDate, day) <= 7) {
          continue;
        }
        final s = usable(_closesId(i.assetClass));
        if (s == null) continue;
        await call(
          s,
          () => s.closes(i, day.subtract(const Duration(days: 10)), day),
        );
      }
    }
    return report;
  }
}
