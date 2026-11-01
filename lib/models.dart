// Data models for the `web_app.py` JSON API. All `fromJson` factories are
// defensive: missing / null fields fall back to sensible defaults so a partial
// server response never crashes the UI.

String _s(dynamic v) => v?.toString() ?? '';
double _d(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

int _i(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

// API responses mix real JSON booleans with SQLite's 0/1 integers.
bool _b(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

/// A single match with odds + Poisson probabilities + optional settled result.
class Match {
  Match.fromJson(Map<String, dynamic> j)
    : matchId = _s(j['match_id']).isNotEmpty ? _s(j['match_id']) : _s(j['id']),
      matchNum = _s(j['match_num']),
      matchDate = _s(j['match_date']),
      matchTime = _s(j['match_time']),
      region = _s(j['region']),
      league = _s(j['league']),
      homeTeam = _s(j['home_team']),
      awayTeam = _s(j['away_team']),
      salesStatus = _s(j['sales_status']),
      finished = _b(j['finished']) || _s(j['status']) == 'finished',
      started = _b(j['started']),
      kickoffTs = _i(j['kickoff_ts']),
      liveStatus = _s(j['live_status']),
      liveElapsed = j['live_elapsed'] is num ? _i(j['live_elapsed']) : null,
      homeGoals = j['home_goals'] is num ? _i(j['home_goals']) : null,
      awayGoals = j['away_goals'] is num ? _i(j['away_goals']) : null,
      homeWin = _d(j['home_win']),
      draw = _d(j['draw']),
      awayWin = _d(j['away_win']),
      over25 = _d(j['over_25']),
      under25 = _d(j['under_25']),
      bttsYes = _d(j['btts_yes']),
      bttsNo = _d(j['btts_no']),
      poissonAvailable = j.containsKey('poisson_available')
          ? _b(j['poisson_available'])
          : true,
      marketBlended = _b(j['market_blended']),
      homeXg = j['home_xg'] is num ? _d(j['home_xg']) : null,
      awayXg = j['away_xg'] is num ? _d(j['away_xg']) : null,
      had = _odds(j['had']),
      hhad = _odds(j['hhad']),
      crs = _odds(j['crs']),
      ttg = _odds(j['ttg']),
      hafu = _odds(j['hafu']),
      single = _singleFlags(j['single']),
      topScores = _topScores(j['top_scores']),
      verdicts = ModelVerdicts.parse(j['verdicts']);

  final String matchId, matchNum, matchDate, matchTime, region, league;
  final String homeTeam, awayTeam, salesStatus;
  final bool finished, started;

  /// Epoch seconds of the real kickoff (service-date quirks resolved server
  /// side). 0 when unknown; used to hide expired matches without a round-trip.
  final int kickoffTs;
  final String liveStatus;
  final int? liveElapsed;
  final int? homeGoals, awayGoals;
  final double homeWin, draw, awayWin, over25, under25, bttsYes, bttsNo;
  final bool poissonAvailable;

  /// True when 1X2 / O2.5 were blended with the 竞彩 market (xG and BTTS stay
  /// pure model output).
  final bool marketBlended;
  final double? homeXg, awayXg;
  final Map<String, String> had, hhad, crs, ttg, hafu;

  /// 体彩 per-pool 单关 flags (keys `had` / `hhad` / `crs` / `ttg` / `hafu`).
  /// Empty when the feed doesn't report it (demo rows, older archives).
  final Map<String, bool> single;
  final List<TopScore> topScores;

  /// Whether this market can be bought as 单关: true / false when 体彩 says
  /// so, null when unknown (callers should not block on null).
  bool? singleFor(String market) {
    final key = switch (market) {
      'wdw' => 'had',
      'handicap' => 'hhad',
      'half_full' => 'hafu',
      'correct_score' => 'crs',
      'total_goals' => 'ttg',
      _ => null,
    };
    return key == null ? null : single[key];
  }

  /// Poisson pre-match snapshot graded against the final score (history rows
  /// only; null when the match has no snapshot or has not finished).
  final ModelVerdicts? verdicts;

  int? get totalGoals =>
      (homeGoals != null && awayGoals != null) ? homeGoals! + awayGoals! : null;

  /// True once the kickoff timestamp has passed (local clock vs server epoch).
  bool get kickoffPassed {
    if (kickoffTs <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= kickoffTs;
  }

  /// A match that has started but not finished, i.e. the 实况 view applies.
  bool get inPlay => !finished && (started || kickoffPassed || liveStatus.isNotEmpty);
  String get finalScore =>
      (homeGoals != null && awayGoals != null) ? '$homeGoals - $awayGoals' : '';
  String get outcomeLabel {
    if (homeGoals == null || awayGoals == null) return '';
    if (homeGoals! > awayGoals!) return '主胜';
    if (homeGoals! < awayGoals!) return '客胜';
    return '平局';
  }

  static Map<String, String> _odds(dynamic v) {
    final out = <String, String>{};
    if (v is Map) {
      v.forEach((k, val) => out[k.toString()] = val?.toString() ?? '');
    }
    return out;
  }

  static Map<String, bool> _singleFlags(dynamic v) {
    final out = <String, bool>{};
    if (v is Map) {
      v.forEach((k, val) => out[k.toString().toLowerCase()] = _b(val));
    }
    return out;
  }

  static List<TopScore> _topScores(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => TopScore(_s(e['score']), _d(e['probability'])))
        .toList();
  }
}

class TopScore {
  TopScore(this.score, this.probability);
  final String score;
  final double probability;
}

/// One graded pick from the Poisson pre-match snapshot.
class VerdictEntry {
  VerdictEntry.fromJson(Map<String, dynamic> j)
    : pick = _s(j['pick']),
      prob = _d(j['prob']),
      hit = _b(j['hit']);

  final String pick;
  final double prob;
  final bool hit;
}

/// The top-score pick, plus whether the real score landed in the model's top 3.
class ScoreVerdict {
  ScoreVerdict.fromJson(Map<String, dynamic> j)
    : pick = _s(j['pick']),
      prob = _d(j['prob']),
      hit = _b(j['hit']),
      inTop3 = _b(j['in_top3']),
      top3 = (j['top3'] is List)
          ? (j['top3'] as List).map(_s).toList()
          : const [];

  final String pick;
  final double prob;
  final bool hit;
  final bool inTop3;
  final List<String> top3;
}

/// All Poisson snapshot verdicts for a finished match.
class ModelVerdicts {
  ModelVerdicts.fromJson(Map<String, dynamic> j)
    : finalScore = _s(j['final_score']),
      homeXg = j['home_xg'] is num ? _d(j['home_xg']) : null,
      awayXg = j['away_xg'] is num ? _d(j['away_xg']) : null,
      outcome = _entry(j['outcome']),
      overUnder = _entry(j['over_under']),
      btts = _entry(j['btts']),
      scoreTop = j['score_top'] is Map
          ? ScoreVerdict.fromJson(
              Map<String, dynamic>.from(j['score_top'] as Map),
            )
          : null;

  final String finalScore;
  final double? homeXg, awayXg;
  final VerdictEntry? outcome, overUnder, btts;
  final ScoreVerdict? scoreTop;

  static ModelVerdicts? parse(dynamic v) =>
      v is Map ? ModelVerdicts.fromJson(Map<String, dynamic>.from(v)) : null;

  static VerdictEntry? _entry(dynamic v) =>
      v is Map ? VerdictEntry.fromJson(Map<String, dynamic>.from(v)) : null;
}

/// One leg of a plan (or one stored LLM prediction), plus its verdict fields.
class Leg {
  Leg.fromJson(Map<String, dynamic> j)
    : matchId = _s(j['match_id']),
      matchNum = _s(j['match_num']),
      homeTeam = _s(j['home_team']),
      awayTeam = _s(j['away_team']),
      market = _s(j['market']),
      pick = _s(j['pick']),
      line = j['line']?.toString(),
      odds = _s(j['odds']),
      label = _s(j['label']),
      result = _s(j['result']),
      score = j['score']?.toString(),
      finished = _b(j['finished']);

  final String matchId, matchNum, homeTeam, awayTeam, market, pick, odds, label;
  final String? line, score;
  final String result;
  final bool finished;
}

/// A saved plan (user or LLM) with verdict + payout already computed server-side.
class Plan {
  Plan.fromJson(Map<String, dynamic> j)
    : id = _s(j['id']),
      createdAt = _s(j['created_at']),
      title = _s(j['title']),
      playType = _s(j['play_type']),
      stake = _d(j['stake']),
      source = _s(j['source']),
      model = _s(j['model']),
      unit = _i(j['unit']),
      units = (j['units'] is List)
          ? (j['units'] as List).map(_i).where((u) => u > 0).toList()
          : const [],
      multiple = _i(j['multiple']),
      status = _s(j['status']),
      kind = _s(j['kind']),
      legs = (j['legs'] is List)
          ? (j['legs'] as List)
                .whereType<Map>()
                .map((e) => Leg.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      payout = Payout.fromJson(j['payout']);

  final String id, createdAt, title, playType, source, model, status;

  /// Recommendation category for LLM plans: mixed / wdw / correct_score /
  /// high_odds / total_goals. Empty for user plans and legacy rows.
  final String kind;
  final double stake;
  final int unit;
  final List<int> units;
  final int multiple;
  final List<Leg> legs;
  final Payout payout;

  bool get isParlay => playType == 'parlay';
  bool get isLlm => source == 'llm';

  /// 任选九场: any 9 of the selected matches, one outcome each.
  bool get isRenjiu => playType == 'renjiu';

  /// Number of distinct matches. Same-match markets are alternatives, not
  /// separate parlay legs.
  int get matchCount => legs.map((l) => l.matchId).toSet().length;

  /// Selected 过关方式 (M串1). Legacy plans only stored one `unit`.
  List<int> get effectiveUnits {
    final matches = matchCount;
    if (matches == 0) return const [];
    if (units.isNotEmpty) {
      final valid = units.where((u) => u <= matches).toSet().toList()..sort();
      if (valid.isNotEmpty) return valid;
    }
    final fallback = isParlay ? matches : 1;
    return [fallback.clamp(1, matches).toInt()];
  }

  /// Largest selected 关数 (kept for compatibility with single-unit callers).
  int get effectiveUnit {
    final list = effectiveUnits;
    if (list.isEmpty) return 1;
    return list.reduce((a, b) => a > b ? a : b);
  }

  /// e.g. 单关, 2串1, or 单关+2串1+3串1 when several 过关方式 are selected.
  String get modeLabel {
    if (isRenjiu) return '任选9场';
    final list = effectiveUnits;
    if (list.length == 1 && list.first <= 1) return '单关';
    return list.map((u) => u <= 1 ? '单关' : '$u串1').join('+');
  }
}

class Payout {
  Payout.fromJson(dynamic j)
    : returnAmount = (j is Map && j['return'] is num) ? _d(j['return']) : null,
      profit = (j is Map && j['profit'] is num) ? _d(j['profit']) : null,
      potential = (j is Map && j['potential'] is num)
          ? _d(j['potential'])
          : null,
      totalCost = (j is Map && j['total_cost'] is num)
          ? _d(j['total_cost'])
          : null,
      bets = (j is Map) ? _i(j['bets']) : 0,
      floating = (j is Map) && _b(j['floating']),
      reason = (j is Map) ? _s(j['reason']) : '';

  final double? returnAmount, profit, potential, totalCost;
  final int bets;

  /// 任九 wins pay the official floating pool, so no amount is known yet.
  final bool floating;
  final String reason;
}

/// A single LLM per-market prediction (from `/api/llm/predictions`).
class LlmPrediction {
  LlmPrediction.fromJson(Map<String, dynamic> j)
    : model = _s(j['model']),
      matchId = _s(j['match_id']),
      market = _s(j['market']),
      pick = _s(j['pick']),
      prob = j['prob'] is num ? _d(j['prob']) : null,
      reason = _s(j['reason']),
      result = _s(j['result']),
      finished = _b(j['finished']),
      score = j['score']?.toString();

  final String model, matchId, market, pick, reason, result;
  final double? prob;
  final bool finished;
  final String? score;
}

/// Match injuries + lineups from `/api/matches/<id>/info`.
class MatchInfo {
  MatchInfo.fromJson(Map<String, dynamic> j)
    : injuries = _rows(j['injuries']),
      lineups = _rows(j['lineups']),
      meta = j['meta'] is Map
          ? FixtureMeta.fromJson(Map<String, dynamic>.from(j['meta'] as Map))
          : const FixtureMeta.empty(),
      error = _s(j['error']),
      fixtureId = j['fixture_id'] is num ? _i(j['fixture_id']) : null;

  final List<InfoRow> injuries;
  final List<InfoRow> lineups;
  final FixtureMeta meta;

  /// Non-empty when the server could not resolve the match in API-Football.
  final String error;
  final int? fixtureId;

  static List<InfoRow> _rows(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => InfoRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

class InfoRow {
  InfoRow.fromJson(Map<String, dynamic> j)
    : team = _s(j['team_chinese']),
      player = _s(j['player_name']),
      position = _s(j['position']),
      number = j['number'] is num ? _i(j['number']) : null,
      kind = _s(j['kind']),
      reason = _s(j['reason']),
      status = _s(j['status']),
      isStarting = _b(j['is_starting']);

  final String team, player, position, kind, reason, status;
  final int? number;
  final bool isStarting;
}

/// One finished match in a team's recent form, scored relative to that team.
class FormFixture {
  FormFixture.fromJson(Map<String, dynamic> j)
    : fixtureId = j['fixture_id'] is num ? _i(j['fixture_id']) : null,
      playedAt = _i(j['played_at']),
      leagueName = _s(j['league_name']),
      homeName = _s(j['home_name']),
      awayName = _s(j['away_name']),
      homeGoals = _i(j['home_goals']),
      awayGoals = _i(j['away_goals']),
      isHome = _b(j['is_home']),
      forGoals = _i(j['for_goals']),
      againstGoals = _i(j['against_goals']),
      result = _s(j['result']);

  final int? fixtureId;
  final int playedAt;
  final String leagueName, homeName, awayName, result;
  final int homeGoals, awayGoals, forGoals, againstGoals;
  final bool isHome;

  DateTime? get playedDate =>
      playedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(playedAt * 1000) : null;
}

/// One team's recent form: last N overall + last N home or away.
class TeamForm {
  TeamForm.fromJson(Map<String, dynamic> j, {required bool homeSide})
    : overall = _fixtures(j['overall']),
      subset = _fixtures(j[homeSide ? 'home' : 'away']);

  final List<FormFixture> overall;
  final List<FormFixture> subset;

  static List<FormFixture> _fixtures(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => FormFixture.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

class MatchForm {
  MatchForm.fromJson(Map<String, dynamic> j)
    : homeTeam = _s(j['home_team']),
      awayTeam = _s(j['away_team']),
      home = TeamForm.fromJson(
          j['home'] is Map ? Map<String, dynamic>.from(j['home'] as Map) : const {},
          homeSide: true),
      away = TeamForm.fromJson(
          j['away'] is Map ? Map<String, dynamic>.from(j['away'] as Map) : const {},
          homeSide: false),
      error = _s(j['error']);

  final String homeTeam, awayTeam;
  final TeamForm home, away;
  final String error;
}

/// One live event (goal / card / substitution / VAR) from API-Football.
class MatchEvent {
  MatchEvent.fromJson(Map<String, dynamic> j)
    : minute = _i(j['minute']),
      extra = j['extra'] is num ? _i(j['extra']) : null,
      side = _s(j['side']),
      kind = _s(j['kind']),
      detail = _s(j['detail']),
      player = _s(j['player']),
      assist = _s(j['assist']),
      comments = _s(j['comments']),
      score = _s(j['score']);

  final int minute;
  final int? extra;
  final String side, kind, detail, player, assist, comments, score;

  /// "67'" / "90+3'".
  String get clock =>
      extra != null && extra! > 0 ? "$minute+$extra'" : "$minute'";
}

/// One home/away comparison row (possession, shots, corners…) in 实况.
class MatchStat {
  MatchStat.fromJson(Map<String, dynamic> j)
    : type = _s(j['type']),
      homeText = _statText(j['home']),
      awayText = _statText(j['away']),
      homeValue = _statValue(j['home']),
      awayValue = _statValue(j['away']);

  final String type, homeText, awayText;
  final double? homeValue, awayValue;

  /// API-Football returns ints, percentages ("55%") or null.
  static String _statText(dynamic v) {
    if (v == null) return '-';
    if (v is num) return v.round().toString();
    return _s(v);
  }

  static double? _statValue(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(_s(v).replaceAll('%', '').trim());
  }
}

/// Live state + event feed for one match.
class LiveMatchInfo {
  LiveMatchInfo.fromJson(Map<String, dynamic> j)
    : status = _s(j['status']),
      elapsed = j['elapsed'] is num ? _i(j['elapsed']) : null,
      isLive = _b(j['is_live']) || _liveStatuses.contains(_s(j['status'])),
      homeGoals = j['home_goals'] is num ? _i(j['home_goals']) : null,
      awayGoals = j['away_goals'] is num ? _i(j['away_goals']) : null,
      events = _events(j['events']),
      stats = _stats(j['stats']),
      error = _s(j['error']);

  static const Set<String> _liveStatuses = {
    '1H', 'HT', '2H', 'ET', 'BT', 'P', 'LIVE', 'INT', 'SUSP',
  };

  final String status, error;
  final int? elapsed, homeGoals, awayGoals;
  final bool isLive;
  final List<MatchEvent> events;
  final List<MatchStat> stats;

  static List<MatchEvent> _events(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => MatchEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static List<MatchStat> _stats(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => MatchStat.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// Venue / round / referee from the fixture payload.
class FixtureMeta {
  const FixtureMeta(this.venue, this.city, this.round, this.referee);
  const FixtureMeta.empty() : this('', '', '', '');

  FixtureMeta.fromJson(Map<String, dynamic> j)
    : venue = _s(j['venue']),
      city = _s(j['city']),
      round = _s(j['round']),
      referee = _s(j['referee']);

  final String venue, city, round, referee;

  bool get isEmpty =>
      venue.isEmpty && city.isEmpty && round.isEmpty && referee.isEmpty;
}

/// One team's season aggregates from `/team-stats`.
class TeamStatsBlock {
  TeamStatsBlock.fromJson(Map<String, dynamic> j)
    : form = _s(j['form']),
      played = _i((j['played'] as Map?)?['total']),
      wins = _i((j['wins'] as Map?)?['total']),
      draws = _i((j['draws'] as Map?)?['total']),
      loses = _i((j['loses'] as Map?)?['total']),
      goalsFor = _num((j['goals_for'] as Map?)?['total']),
      goalsAgainst = _num((j['goals_against'] as Map?)?['total']),
      avgFor = _num((j['goals_for'] as Map?)?['avg']),
      avgAgainst = _num((j['goals_against'] as Map?)?['avg']),
      avgHomeFor = _num((j['goals_for'] as Map?)?['avg_home']),
      avgAwayFor = _num((j['goals_for'] as Map?)?['avg_away']),
      cleanSheets = _i((j['clean_sheet'] as Map?)?['total']),
      failedToScore = _i((j['failed_to_score'] as Map?)?['total']),
      formations = (j['formations'] as List? ?? const [])
          .map(_s)
          .where((s) => s.isNotEmpty)
          .toList();

  final String form;
  final int played, wins, draws, loses, cleanSheets, failedToScore;
  final double goalsFor, goalsAgainst, avgFor, avgAgainst;
  final double? avgHomeFor, avgAwayFor;
  final List<String> formations;

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(_s(v)) ?? 0;
  }
}

class MatchTeamStats {
  MatchTeamStats.fromJson(Map<String, dynamic> j)
    : homeTeam = _s(j['home_team']),
      awayTeam = _s(j['away_team']),
      home = j['home'] is Map
          ? TeamStatsBlock.fromJson(Map<String, dynamic>.from(j['home'] as Map))
          : null,
      away = j['away'] is Map
          ? TeamStatsBlock.fromJson(Map<String, dynamic>.from(j['away'] as Map))
          : null,
      error = _s(j['error']);

  final String homeTeam, awayTeam, error;
  final TeamStatsBlock? home, away;
}

/// One previous meeting in the head-to-head list.
class H2HRow {
  H2HRow.fromJson(Map<String, dynamic> j)
    : date = _s(j['date']),
      league = _s(j['league']),
      homeId = _i(j['home_id']),
      awayId = _i(j['away_id']),
      homeName = _s(j['home_name']),
      awayName = _s(j['away_name']),
      homeGoals = _i(j['home_goals']),
      awayGoals = _i(j['away_goals']);

  final String date, league, homeName, awayName;
  final int homeId, awayId, homeGoals, awayGoals;
}

class MatchH2H {
  MatchH2H.fromJson(Map<String, dynamic> j)
    : rows = (j['rows'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => H2HRow.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      homeId = _i(j['home_id']),
      awayId = _i(j['away_id']),
      homeTeam = _s(j['home_team']),
      awayTeam = _s(j['away_team']),
      error = _s(j['error']);

  final List<H2HRow> rows;
  final int homeId, awayId;
  final String homeTeam, awayTeam, error;
}

/// One player's line in the match rating tables.
class PlayerRating {
  PlayerRating.fromJson(Map<String, dynamic> j)
    : name = _s(j['name']),
      number = j['number'] is num ? _i(j['number']) : null,
      position = _s(j['position']),
      rating = j['rating'] is num ? _d(j['rating']) : null,
      minutes = j['minutes'] is num ? _i(j['minutes']) : null,
      goals = _i(j['goals']),
      assists = _i(j['assists']),
      yellow = _i(j['yellow']),
      red = _i(j['red']),
      substitute = _b(j['substitute']);

  final String name, position;
  final int? number, minutes;
  final double? rating;
  final int goals, assists, yellow, red;
  final bool substitute;
}

class TeamRatings {
  TeamRatings.fromJson(Map<String, dynamic> j)
    : team = _s(j['team']),
      averageRating = j['average_rating'] is num ? _d(j['average_rating']) : null,
      players = (j['players'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => PlayerRating.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      best = j['best'] is Map
          ? PlayerRating.fromJson(Map<String, dynamic>.from(j['best'] as Map))
          : null;

  final String team;
  final double? averageRating;
  final List<PlayerRating> players;
  final PlayerRating? best;
}

class FixturePlayers {
  FixturePlayers.fromJson(Map<String, dynamic> j)
    : teams = (j['teams'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => TeamRatings.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      status = _s(j['status']),
      error = _s(j['error']);

  final List<TeamRatings> teams;
  final String status, error;
}

/// Season key player (aggregate, not a single match).
class KeyPlayer {
  KeyPlayer.fromJson(Map<String, dynamic> j)
    : name = _s(j['name']),
      position = _s(j['position']),
      appearances = _i(j['appearances']),
      goals = _i(j['goals']),
      assists = _i(j['assists']),
      rating = j['rating'] is num ? _d(j['rating']) : null;

  final String name, position;
  final int appearances, goals, assists;
  final double? rating;
}

class TeamSquad {
  TeamSquad.fromJson(Map<String, dynamic> j)
    : team = _s(j['team']),
      coachName = _s((j['coach'] as Map?)?['name']),
      coachSince = _s((j['coach'] as Map?)?['since']),
      players = (j['players'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => KeyPlayer.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  final String team, coachName, coachSince;
  final List<KeyPlayer> players;
}

/// One injured player's absence record.
class AbsenceRow {
  AbsenceRow.fromJson(Map<String, dynamic> j)
    : player = _s(j['player']),
      team = _s(j['team']),
      kind = _s(j['kind']),
      reason = _s(j['reason']),
      since = _s(j['since']),
      until = _s(j['until']),
      past = _i(j['past']);

  final String player, team, kind, reason, since, until;
  final int past;
}

class MatchSquad {
  MatchSquad.fromJson(Map<String, dynamic> j)
    : home = j['home'] is Map
          ? TeamSquad.fromJson(Map<String, dynamic>.from(j['home'] as Map))
          : null,
      away = j['away'] is Map
          ? TeamSquad.fromJson(Map<String, dynamic>.from(j['away'] as Map))
          : null,
      absences = (j['absences'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AbsenceRow.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      error = _s(j['error']);

  final TeamSquad? home, away;
  final List<AbsenceRow> absences;
  final String error;
}

/// Live win probabilities from `/odds/live`.
class LiveOdds {
  LiveOdds.fromJson(Map<String, dynamic> j)
    : live = _b(j['live']),
      home = j['home'] is num ? _d(j['home']) : null,
      draw = j['draw'] is num ? _d(j['draw']) : null,
      away = j['away'] is num ? _d(j['away']) : null,
      books = _i(j['books']),
      bttsYes = j['btts'] is Map && (j['btts'] as Map)['yes'] is num
          ? _d((j['btts'] as Map)['yes'])
          : null;

  final bool live;
  final double? home, draw, away, bttsYes;
  final int books;
}

/// Consensus bookmaker probabilities for the whole market set.
class MarketOdds {
  MarketOdds.fromJson(Map<String, dynamic> j)
    : home = j['home'] is num ? _d(j['home']) : null,
      draw = j['draw'] is num ? _d(j['draw']) : null,
      away = j['away'] is num ? _d(j['away']) : null,
      books = _i(j['books']),
      bttsYes = _sub(j, 'btts', 'yes'),
      bttsNo = _sub(j, 'btts', 'no'),
      over25 = _sub(j, 'ou25', 'over'),
      under25 = _sub(j, 'ou25', 'under'),
      homeDraw = _sub(j, 'double_chance', 'home_draw'),
      homeAway = _sub(j, 'double_chance', 'home_away'),
      drawAway = _sub(j, 'double_chance', 'draw_away'),
      asianLine = _s((j['asian'] as Map?)?['line']),
      asianHome = _sub(j, 'asian', 'home'),
      asianAway = _sub(j, 'asian', 'away');

  final double? home, draw, away, bttsYes, bttsNo, over25, under25;
  final double? homeDraw, homeAway, drawAway, asianHome, asianAway;
  final String asianLine;
  final int books;

  bool get isEmpty => home == null && bttsYes == null && over25 == null;

  static double? _sub(Map<String, dynamic> j, String parent, String key) {
    final node = j[parent];
    if (node is! Map) return null;
    final v = node[key];
    return v is num ? _d(v) : null;
  }
}
