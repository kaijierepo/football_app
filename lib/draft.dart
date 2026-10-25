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
double? potentialFor(List<DraftLeg> legs, int unit, double stake, int multiple) {
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
/// `unit` is the 关数 (M) of a 全组合过关 plan: `1` = 单关, `n` = 串关, and
/// `1 < M < n` = M串1 过关. `unit <= 0` means "not chosen yet" and defaults to
/// the full parlay (multi-select).
class DraftModel extends ChangeNotifier {
  final List<DraftLeg> _legs = [];
  String title = '';
  double stake = 2;
  int unit = 0;
  int multiple = 1;

  List<DraftLeg> get legs => List.unmodifiable(_legs);
  int get count => _legs.length;

  /// Distinct matches in the draft.
  int get matchCount => matchCountOf(_legs);

  /// The effective 关数 = matches per ticket, clamped to `[1, matchCount]`,
  /// defaulting to the full parlay.
  int get effectiveUnit {
    final n = matchCount;
    if (n == 0) return 0;
    if (unit <= 0) return n;
    return unit.clamp(1, n).toInt();
  }

  /// Number of bets (注数): same-match options are alternatives inside a
  /// ticket, not separate legs.
  int get bets {
    final u = effectiveUnit;
    if (u <= 0) return 0;
    return betsFor(_legs, u);
  }

  bool contains(DraftLeg leg) => _legs.any((l) => l.sameAs(leg));

  /// Toggle a leg: re-tapping the same match+market+pick removes it.
  /// Returns true when the leg was added, false when removed.
  bool toggle(DraftLeg leg) {
    final i = _legs.indexWhere((l) => l.sameAs(leg));
    if (i >= 0) {
      _legs.removeAt(i);
      _clampUnit();
      notifyListeners();
      return false;
    }
    _legs.add(leg);
    _clampUnit();
    notifyListeners();
    return true;
  }

  void removeAt(int index) {
    _legs.removeAt(index);
    _clampUnit();
    notifyListeners();
  }

  void setUnit(int value) {
    unit = value;
    _clampUnit();
    notifyListeners();
  }

  void _clampUnit() {
    if (_legs.isEmpty) {
      unit = 0;
    } else if (unit <= 0) {
      // keep "auto" until the user explicitly picks a 关数
    } else {
      unit = unit.clamp(1, matchCountOf(_legs)).toInt();
    }
  }

  void clear() {
    _legs.clear();
    title = '';
    stake = 2;
    unit = 0;
    multiple = 1;
    notifyListeners();
  }

  Future<void> save(ApiClient client) async {
    final body = <String, dynamic>{
      'title': title.trim(),
      'play_type': effectiveUnit == 1 ? 'single' : 'parlay',
      'unit': effectiveUnit,
      'multiple': multiple,
      'stake': stake,
      'legs': _legs
          .map((l) => {
                'match_id': l.matchId,
                'home_team': l.homeTeam,
                'away_team': l.awayTeam,
                'market': l.market,
                'pick': l.pick,
                'line': l.line,
                'odds': l.odds,
                'label': l.label,
              })
          .toList(),
    };
    await client.post('/api/plans', body);
    clear();
  }
}

final DraftModel draft = DraftModel();
