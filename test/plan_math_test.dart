import 'package:flutter_test/flutter_test.dart';
import 'package:football_flutter_app/betting.dart';
import 'package:football_flutter_app/draft.dart';
import 'package:football_flutter_app/models.dart';

DraftLeg leg(String matchId, String market, String pick, String odds) =>
    DraftLeg(
      matchId: matchId,
      homeTeam: 'H$matchId',
      awayTeam: 'A$matchId',
      market: market,
      pick: pick,
      line: '',
      odds: odds,
      label: pick,
    );

void main() {
  test('same-match options are alternatives, not separate parlay legs', () {
    final legs = [
      leg('A', 'wdw', 'home', '2.0'),
      leg('A', 'correct_score', '2-1', '8.0'),
      leg('B', 'wdw', 'away', '3.0'),
    ];
    expect(matchCountOf(legs), 2);
    // A has 2 options, B has 1 => 2 tickets for 2串1.
    expect(betsFor(legs, 2), 2);
    // A's best option is 8.0, B is 3.0 => stake 2 x 8.0 x 3.0 = 48.
    expect(potentialFor(legs, 2, 2, 1), closeTo(48.0, 1e-9));
    // Single: each match pays its own highest option (never sums options).
    expect(betsFor(legs, 1), 3);
    expect(potentialFor(legs, 1, 2, 1), closeTo(2 * (8.0 + 3.0), 1e-9));
  });

  test('multiple scores in one match: max payout uses highest odds only', () {
    final legs = [
      leg('A', 'correct_score', '1-0', '6.0'),
      leg('A', 'correct_score', '2-0', '9.0'),
    ];
    expect(betsFor(legs, 1), 2);
    // Only one score can happen: 2 x 9.0 = 18, not 2 x (6 + 9) = 30.
    expect(potentialFor(legs, 1, 2, 1), closeTo(18.0, 1e-9));
  });

  test('three matches with two options each, 2串1 = 12 bets', () {
    final legs = [
      for (final m in ['A', 'B', 'C']) ...[
        leg(m, 'wdw', 'home', '2.0'),
        leg(m, 'total_goals', '3', '3.0'),
      ],
    ];
    expect(matchCountOf(legs), 3);
    expect(betsFor(legs, 2), 12);
    // Each match's best option is 3.0; 3 pairs x (3*3) x stake 2 = 54.
    expect(potentialFor(legs, 2, 2, 1), closeTo(54.0, 1e-9));
  });

  test('任九 bets: 9 singles = 1, extra matches multiply', () {
    expect(renjiuBets(List.filled(9, 1)), 1);
    expect(renjiuBets(List.filled(10, 1)), 10);
    // 9 matches, one double: C(9,9) with 2 options = 2.
    expect(renjiuBets([...List.filled(8, 1), 2]), 2);
    // 11 matches, one double: either include it (C(10,8) x 2 = 90) or not
    // (C(10,9) = 10), total 100.
    expect(renjiuBets([...List.filled(10, 1), 2]), 100);
    // Unselected matches (0) are ignored; fewer than 9 yields no ticket.
    expect(renjiuBets(List.filled(8, 1)), 0);
    expect(renjiuBets([...List.filled(8, 1), 0]), 0);
    // All 14 matches with 3 outcomes: C(14,9) x 3^9 = 2002 x 19683.
    expect(renjiuBets(List.filled(14, 3)), 39405366);
  });

  test('multi-select 过关方式 adds tickets and max payouts', () {
    final legs = [
      for (final m in ['A', 'B', 'C']) leg(m, 'wdw', 'home', '2.0'),
    ];
    final model = DraftModel();
    for (final l in legs) {
      model.toggle(l);
    }
    model.setUnits([1, 2, 3]);
    expect(model.effectiveUnits, [1, 2, 3]);
    // 单关 3 + 2串1 C(3,2)=3 + 3串1 1 = 7 注.
    expect(model.bets, 7);
    final total = [
      1,
      2,
      3,
    ].map((u) => potentialFor(legs, u, 2, 1)!).reduce((a, b) => a + b);
    // 单关 2x6=12, 2串1 2x(4x3)=24, 3串1 2x8=16 => 52.
    expect(total, closeTo(52.0, 1e-9));
  });

  test('Plan modeLabel shows every selected 过关方式', () {
    final plan = Plan.fromJson({
      'id': 'p2',
      'play_type': 'parlay',
      'units': [1, 2, 3],
      'legs': [
        {'match_id': 'A', 'market': 'wdw', 'pick': 'home'},
        {'match_id': 'B', 'market': 'wdw', 'pick': 'away'},
        {'match_id': 'C', 'market': 'wdw', 'pick': 'home'},
      ],
    });
    expect(plan.effectiveUnits, [1, 2, 3]);
    expect(plan.modeLabel, '单关+2串1+3串1');
  });

  test('Plan effectiveUnit is clamped to distinct matches', () {
    final plan = Plan.fromJson({
      'id': 'p1',
      'play_type': 'parlay',
      'unit': 3, // legacy: stored as leg count
      'legs': [
        {'match_id': 'A', 'market': 'wdw', 'pick': 'home'},
        {'match_id': 'A', 'market': 'correct_score', 'pick': '2-1'},
        {'match_id': 'B', 'market': 'wdw', 'pick': 'away'},
      ],
    });
    expect(plan.matchCount, 2);
    expect(plan.effectiveUnit, 2);
  });
}
