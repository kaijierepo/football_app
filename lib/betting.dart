import 'models.dart';
import 'widgets.dart';

/// Shared betting-option logic (extracted from the old PlanBuilderPage).
/// Maps a [Match]'s odds into the sporttery betting categories so both the
/// match detail page and the plan draft use the exact same options + odds.

class BetOption {
  BetOption(this.value, this.label, this.odds, [this.line]);

  final String value, label, odds;
  final String? line;
}

/// A match and every option selected for it. A parlay ticket takes at most
/// one option per match, so plans are grouped and counted this way.
class LegGroup {
  LegGroup(this.matchId, this.homeTeam, this.awayTeam, this.legs);

  final String matchId, homeTeam, awayTeam;
  final List<Leg> legs;
}

/// Group legs by match in first-appearance order.
List<LegGroup> groupLegs(List<Leg> legs) {
  final index = <String, int>{};
  final out = <LegGroup>[];
  for (final l in legs) {
    final i = index[l.matchId];
    if (i == null) {
      index[l.matchId] = out.length;
      out.add(LegGroup(l.matchId, l.homeTeam, l.awayTeam, [l]));
    } else {
      out[i].legs.add(l);
    }
  }
  return out;
}

List<List<int>> combinationsOf(int n, int k) {
  final out = <List<int>>[];
  if (k < 0 || k > n) return out;
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

/// Number of 注 for a `unit`-match parlay over grouped options:
/// Σ over match combinations of Π(options per involved match).
int betsForGroups(List<LegGroup> groups, int unit) {
  final n = groups.length;
  if (n == 0) return 0;
  final u = unit.clamp(1, n).toInt();
  var total = 0;
  for (final combo in combinationsOf(n, u)) {
    var p = 1;
    for (final i in combo) {
      p *= groups[i].legs.length;
    }
    total += p;
  }
  return total;
}

/// 任选九场注数: choose any 9 of the selected matches and take one outcome in
/// each; multi-outcome matches are 复式. This is the coefficient of x^9 in
/// Π(1 + count[i]·x), computed with a small DP.
int renjiuBets(List<int> optionCounts) {
  final dp = List<int>.filled(10, 0);
  dp[0] = 1;
  for (final count in optionCounts) {
    if (count <= 0) continue;
    for (var k = 9; k >= 1; k--) {
      dp[k] += dp[k - 1] * count;
    }
  }
  return dp[9];
}

/// Which play types are bettable for this match (based on available odds).
List<String> marketsFor(Match m) {
  final out = <String>['wdw'];
  if (m.hhad.isNotEmpty) out.add('handicap');
  if (m.hafu.isNotEmpty) out.add('half_full');
  if (m.crs.isNotEmpty || m.topScores.isNotEmpty) out.add('correct_score');
  out.add('total_goals');
  return out;
}

/// 半全场胜平负：前半 = 半场结果，后半 = 全场结果（h 主 / d 平 / a 客）。
const List<String> halfFullPicks = [
  'hh', 'hd', 'ha', 'dh', 'dd', 'da', 'ah', 'ad', 'aa',
];

/// All selectable options (with odds) for a given [market].
List<BetOption> optionsFor(Match m, String market) {
  switch (market) {
    case 'wdw':
      return [
        BetOption('home', '主胜', m.had['home'] ?? ''),
        BetOption('draw', '平局', m.had['draw'] ?? ''),
        BetOption('away', '客胜', m.had['away'] ?? ''),
      ];
    case 'handicap':
      return [
        BetOption('home', '主胜（${lineText(m.hhad['line'])}）', m.hhad['home'] ?? '', m.hhad['line']),
        BetOption('draw', '平局（${lineText(m.hhad['line'])}）', m.hhad['draw'] ?? '', m.hhad['line']),
        BetOption('away', '客胜（${lineText(m.hhad['line'])}）', m.hhad['away'] ?? '', m.hhad['line']),
      ];
    case 'half_full':
      return [
        for (final k in halfFullPicks)
          BetOption(k, pickLabel[k] ?? k, m.hafu[k] ?? ''),
      ];
    case 'correct_score':
      if (m.crs.isNotEmpty) {
        return m.crs.entries
            .map((e) => BetOption(e.key, pickLabel[e.key] ?? '比分 ${e.key}', e.value))
            .toList();
      }
      return m.topScores
          .take(5)
          .map((s) => BetOption(s.score, '比分 ${s.score}', pct(s.probability)))
          .toList();
    case 'total_goals':
      return [
        for (var i = 0; i <= 6; i++) BetOption('$i', '$i球', m.ttg['$i'] ?? ''),
        BetOption('7+', '7+球', m.ttg['7+'] ?? ''),
      ];
  }
  return const [];
}
