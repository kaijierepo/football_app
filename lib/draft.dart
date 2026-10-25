import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// One selected bet in the current plan draft, aligned with the
/// `POST /api/plans` legs contract.
class DraftLeg {
  DraftLeg({
    required this.matchId,
    required this.homeTeam,
    required this.awayTeam,
    required this.market,
    required this.pick,
    required this.line,
    required this.odds,
    required this.label,
  });

  final String matchId, homeTeam, awayTeam, market, pick, line, odds, label;

  bool sameAs(DraftLeg other) =>
      matchId == other.matchId && market == other.market && pick == other.pick;
}

int combCount(int n, int k) {
  if (k < 0 || k > n) return 0;
  k = k > n - k ? n - k : k;
  var r = 1;
  for (var i = 0; i < k; i++) {
    r = r * (n - i) ~/ (i + 1);
  }
  return r;
}

List<List<int>> _combinations(int n, int k) {
  final out = <List<int>>[];
  void go(int start, List<int> cur) {
    if (cur.length == k) {
      out.add(List.of(cur));
      return;
    }
    for (var i = start; i < n; i++) {
      cur.add(i);
      go(i + 1, cur);
      cur.removeLast();
    }
  }

  go(0, []);
  return out;
}

/// Leg indices grouped by match. A parlay ticket takes at most one option from
/// each match, so these groups (not individual legs) get combined.
List<List<int>> _groupIndexes(List<DraftLeg> legs) {
  final index = <String, int>{};
  final groups = <List<int>>[];
  for (var i = 0; i < legs.length; i++) {
    final gi = index.putIfAbsent(legs[i].matchId, () {
      groups.add(<int>[]);
      return groups.length - 1;
    });
    groups[gi].add(i);
  }
  return groups;
}

int matchCountOf(List<DraftLeg> legs) => _groupIndexes(legs).length;

/// 注数: Σ over `unit`-match combinations of Π(options per involved match).
int betsFor(List<DraftLeg> legs, int unit) {
  final groups = _groupIndexes(legs);
  final n = groups.length;
  if (n == 0) return 0;
  final u = unit.clamp(1, n).toInt();
  var total = 0;
  for (final combo in _combinations(n, u)) {
    var p = 1;
    for (final gi in combo) {
      p *= groups[gi].length;
    }
    total += p;
  }
  return total;
}

/// Theoretical maximum return for a grouped 全组合 plan.
///
/// A match can only finish one way, so for each match only the selected option
/// with the **highest odds** can be the winning one — options within the same
/// match are alternatives and their payouts never add up. Each ticket's best
/// case is the product of the per-match max odds; tickets are summed.
/// Returns null when any option lacks numeric odds (无法计算).
double? potentialFor(
  List<DraftLeg> legs,
  int unit,
  double stake,
  int multiple,
) {
  final groups = _groupIndexes(legs);
  final n = groups.length;
  if (n == 0) return null;
  final u = unit.clamp(1, n).toInt();
  final maxOdds = <double>[];
  for (final g in groups) {
    double? best;
    for (final i in g) {
      final o = double.tryParse(legs[i].odds);
      if (o == null || o <= 0) return null;
      if (best == null || o > best) best = o;
    }
    maxOdds.add(best!);
  }
  var sum = 0.0;
  for (final combo in _combinations(n, u)) {
    var product = 1.0;
    for (final gi in combo) {
      product *= maxOdds[gi];
    }
    sum += product;
  }
  return stake * multiple * sum;
}

/// In-memory plan draft (single / multi match). A singleton [draft] is shared
/// across pages; the home shell + match detail page listen for the badge count.
///
/// `units` holds the selected 过关方式: `1` = 单关, `n` = 串关, and
/// `1 < M < n` = M串1. Several can be selected at once (自由过关). An empty
/// set means "not chosen yet" and defaults to the full parlay.
class DraftModel extends ChangeNotifier {
  final List<DraftLeg> _legs = [];
  final Set<int> _units = {};
  String title = '';
  double stake = 2;
  int multiple = 1;

  List<DraftLeg> get legs => List.unmodifiable(_legs);
  int get count => _legs.length;

  /// Distinct matches in the draft.
  int get matchCount => matchCountOf(_legs);

  /// Selected 过关方式, clamped to `[1, matchCount]`; empty means the full
  /// parlay (the default).
  List<int> get effectiveUnits {
    final n = matchCount;
    if (n == 0) return const [];
    if (_units.isEmpty) return [n];
    final valid = _units.where((u) => u >= 1 && u <= n).toSet().toList()
      ..sort();
    return valid.isEmpty ? [n] : valid;
  }

  /// Largest selected 关数 (compatibility helper).
  int get effectiveUnit {
    final list = effectiveUnits;
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a > b ? a : b);
  }

  /// Number of bets (注数): same-match options are alternatives inside a
  /// ticket, not separate legs. Multiple 过关方式 add their tickets together.
  int get bets {
    var total = 0;
    for (final unit in effectiveUnits) {
      total += betsFor(_legs, unit);
    }
    return total;
  }

  bool contains(DraftLeg leg) => _legs.any((l) => l.sameAs(leg));

  /// Toggle a leg: re-tapping the same match+market+pick removes it.
  /// Returns true when the leg was added, false when removed.
  bool toggle(DraftLeg leg) {
    final i = _legs.indexWhere((l) => l.sameAs(leg));
    if (i >= 0) {
      _legs.removeAt(i);
      _clampUnits();
      notifyListeners();
      return false;
    }
    _legs.add(leg);
    _clampUnits();
    notifyListeners();
    return true;
  }

  void removeAt(int index) {
    _legs.removeAt(index);
    _clampUnits();
    notifyListeners();
  }

  void setUnits(Iterable<int> values) {
    _units
      ..clear()
      ..addAll(values);
    _clampUnits();
    notifyListeners();
  }

  void _clampUnits() {
    if (_legs.isEmpty) {
      _units.clear();
      return;
    }
    final n = matchCountOf(_legs);
    _units.removeWhere((u) => u < 1 || u > n);
  }

  void clear() {
    _legs.clear();
    _units.clear();
    title = '';
    stake = 2;
    multiple = 1;
    notifyListeners();
  }

  Future<void> save(ApiClient client) async {
    final units = effectiveUnits;
    final body = <String, dynamic>{
      'title': title.trim(),
      'play_type': units.length == 1 && units.first == 1 ? 'single' : 'parlay',
      'unit': units.isEmpty ? null : units.last,
      'units': units,
      'multiple': multiple,
      'stake': stake,
      'legs': _legs
          .map(
            (l) => {
              'match_id': l.matchId,
              'home_team': l.homeTeam,
              'away_team': l.awayTeam,
              'market': l.market,
              'pick': l.pick,
              'line': l.line,
              'odds': l.odds,
              'label': l.label,
            },
          )
          .toList(),
    };
    await client.post('/api/plans', body);
    clear();
  }
}

final DraftModel draft = DraftModel();
