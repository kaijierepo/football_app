import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../betting.dart';
import '../draft.dart';
import '../match_sections.dart';
import '../models.dart';
import '../widgets.dart';
import 'draft_page.dart';

class MatchInfoPage extends StatefulWidget {
  const MatchInfoPage({super.key, required this.client, required this.match});

  final ApiClient client;
  final Match match;

  @override
  State<MatchInfoPage> createState() => _MatchInfoPageState();
}

class _MatchInfoPageState extends State<MatchInfoPage> {
  static const _marketOrder = [
    'wdw', 'handicap', 'total_goals', 'correct_score',
  ];

  bool _loading = true;
  String? _error;
  MatchInfo? _info;
  bool _infoLoading = false;
  String? _infoError;
  DateTime? _infoFetchedAt;
  List<LlmPrediction> _predictions = [];
  bool _predictionsGenerating = false;
  bool _pollScheduled = false;
  int _pollAttempts = 0;

  /// In-play view: while the match is live the first tab becomes a live text
  /// feed instead of model predictions.
  LiveMatchInfo? _live;
  bool _liveMode = false;
  bool _liveLoading = false;
  String? _liveError;
  Timer? _liveTimer;
  LiveOdds? _liveOdds;

  @override
  void initState() {
    super.initState();
    // A match that is already in play opens straight into the live view, so
    // the model tab never flashes while the first /events call is in flight.
    _liveMode = widget.match.inPlay;
    _load();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  /// Fast path: model predictions render immediately; injuries/lineups are
  /// lazy-loaded in the background so the slow API-Football call never blocks.
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _pollAttempts = 0;
    // Live data and predictions are independent; start the live fetch first so
    // an in-play page paints its score and feed without waiting on the slower
    // prediction request.
    if (_liveMode || _shouldProbeLive(widget.match)) _loadLive(force: force);
    await _loadPredictions();
    if (mounted) setState(() => _loading = false);
    _loadInfo(force: force);
  }

  /// Only spend an API-Football call when the match might be in play: started
  /// but unfinished, or kickoff is within the next 15 minutes / last 4 hours.
  bool _shouldProbeLive(Match m) {
    if (m.finished) return false;
    if (m.inPlay) return true;
    final now = DateTime.now();
    if (m.kickoffTs > 0) {
      final gap = now.millisecondsSinceEpoch ~/ 1000 - m.kickoffTs;
      return gap >= -15 * 60 && gap <= 4 * 3600;
    }
    final time = m.matchTime.isEmpty ? '00:00' : m.matchTime;
    final normalized = time.split(':').length >= 3 ? time : '$time:00';
    final kickoff = DateTime.tryParse('${m.matchDate}T$normalized');
    if (kickoff == null) return false;
    return now.isAfter(kickoff.subtract(const Duration(minutes: 15))) &&
        now.isBefore(kickoff.add(const Duration(hours: 4)));
  }

  Future<void> _loadLive({bool force = false}) async {
    if (_liveLoading) return;
    setState(() {
      _liveLoading = true;
      _liveError = null;
    });
    try {
      final matchId = Uri.encodeComponent(widget.match.matchId);
      final data = await widget.client.get(
        '/api/matches/$matchId/events${force ? '?refresh=1' : ''}',
      );
      if (!mounted) return;
      final info = LiveMatchInfo.fromJson(data);
      setState(() {
        _live = info;
        _liveMode = info.isLive || _liveMode;
        _liveLoading = false;
      });
      if (info.isLive) {
        _refreshLineupsIfMissing();
        _loadLiveOdds(force: force);
      }
      _scheduleLivePoll(info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liveError = e.toString();
        _liveLoading = false;
      });
      _scheduleLivePoll(_live);
    }
  }

  /// Poll every 15s while in play; check every 60s near kickoff so the tab
  /// flips to the live feed on its own.
  void _scheduleLivePoll(LiveMatchInfo? info) {
    _liveTimer?.cancel();
    if (!mounted) return;
    const ended = {'FT', 'AET', 'PEN'};
    if (info != null && ended.contains(info.status)) return;
    final Duration delay;
    if (info?.isLive == true) {
      delay = const Duration(seconds: 15);
    } else if (_shouldProbeLive(widget.match)) {
      delay = const Duration(seconds: 60);
    } else {
      return;
    }
    _liveTimer = Timer(delay, () {
      if (mounted) _loadLive();
    });
  }

  Future<void> _loadPredictions() async {
    try {
      final data = await widget.client.get('/api/llm/predictions');
      if (!mounted) return;
      final preds = (data['predictions'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => LlmPrediction.fromJson(Map<String, dynamic>.from(e)))
          .where((p) => p.matchId == widget.match.matchId)
          .where((p) => p.market != 'over_under')
          .toList();
      final generating = data['generating'] == true;
      setState(() {
        _predictions = preds;
        _predictionsGenerating = generating;
        _error = null;
      });
      if (preds.isEmpty && generating) _schedulePredictionPoll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// The server generates today's LLM predictions in the background; poll a
  /// few times so this page fills itself instead of asking the user to visit
  /// the 模型 page.
  void _schedulePredictionPoll() {
    if (_pollScheduled || _pollAttempts >= 20) return;
    _pollScheduled = true;
    _pollAttempts++;
    Timer(const Duration(seconds: 15), () {
      _pollScheduled = false;
      if (mounted && _predictions.isEmpty) _loadPredictions();
    });
  }

  /// In-play bookmaker win probabilities — a second opinion next to the raw
  /// score, refreshed with the live poll.
  Future<void> _loadLiveOdds({bool force = false}) async {
    try {
      final matchId = Uri.encodeComponent(widget.match.matchId);
      final data = await widget.client.get(
        '/api/matches/$matchId/live-odds${force ? '?refresh=1' : ''}',
      );
      if (!mounted) return;
      final odds = LiveOdds.fromJson(data);
      setState(() => _liveOdds = odds.live ? odds : null);
    } catch (_) {
      // Odds are a bonus; the live feed must never fail because of them.
    }
  }

  /// Lineups are published shortly before kickoff; a page opened earlier got
  /// an empty answer. Re-ask at most every 2 minutes while in play so the XI
  /// shows up on its own instead of waiting for the refresh button.
  void _refreshLineupsIfMissing() {
    if (_infoLoading) return;
    if (_info != null && _info!.lineups.isNotEmpty) return;
    final last = _infoFetchedAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    _loadInfo(force: true);
  }

  Future<void> _loadInfo({bool force = false}) async {
    // Lineups are published ~1h before kickoff; a page opened earlier caches
    // an empty answer, so the refresh button must bypass this guard.
    if (_infoLoading) return;
    if (_info != null && !force) return;
    setState(() {
      _infoLoading = true;
      _infoError = null;
    });
    try {
      final matchId = Uri.encodeComponent(widget.match.matchId);
      final data = await widget.client.get(
        '/api/matches/$matchId/info${force ? '?refresh=1' : ''}',
      );
      if (!mounted) return;
      setState(() => _info = MatchInfo.fromJson(data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _infoError = e.toString());
    } finally {
      _infoFetchedAt = DateTime.now();
      if (mounted) setState(() => _infoLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${m.homeTeam} vs ${m.awayTeam}'),
          actions: [
            IconButton(
              onPressed: () => _load(force: true),
              icon: const Icon(Icons.refresh),
            ),
            ListenableBuilder(
              listenable: draft,
              builder: (_, _) => Badge(
                isLabelVisible: draft.count > 0,
                label: Text('${draft.count}'),
                child: IconButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DraftPage(client: widget.client))),
                  icon: const Icon(Icons.receipt_long),
                ),
              ),
            ),
          ],
          bottom: TabBar(
            labelPadding: const EdgeInsets.symmetric(horizontal: 2),
            tabs: [
              _liveMode
                  ? const Tab(
                      icon: Icon(Icons.podcasts, size: 20), text: '实况')
                  : const Tab(
                      icon: Icon(Icons.smart_toy, size: 20), text: '模型预测'),
              const Tab(
                  icon: Icon(Icons.receipt_long, size: 20), text: '投注选项'),
              const Tab(icon: Icon(Icons.history, size: 20), text: '近期战绩'),
              const Tab(
                  icon: Icon(Icons.medical_services, size: 20), text: '伤病'),
              const Tab(icon: Icon(Icons.groups, size: 20), text: '首发'),
            ],
          ),
        ),
        // In live mode the first tab renders from the match data we already
        // have; blocking it on the prediction request is what used to make the
        // model page flash for a few seconds after tapping an in-play match.
        body: _liveMode
            ? _tabBody(m)
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('加载失败：$_error'))
                    : _tabBody(m),
      ),
    );
  }

  Widget _tabBody(Match m) {
    return TabBarView(
      children: [
        _liveMode ? _liveTab(m) : _modelTab(m),
        _bettingTab(m),
        _FormTab(client: widget.client, matchId: m.matchId),
        _injuriesTab(),
        _lineupsTab(),
      ],
    );
  }

  Widget _modelTab(Match m) {
    final meta = _metaLine();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (meta != null) ...[meta, const SizedBox(height: 12)],
        _sectionTitle(
            m.marketBlended ? '泊松模型（市场校准）' : '泊松模型',
            Icons.insights,
            gold),
        const SizedBox(height: 8),
        ..._poissonSection(m),
        const SizedBox(height: 20),
        _sectionTitle('模型预测', Icons.smart_toy, green),
        const SizedBox(height: 8),
        ..._predictionSections(),
      ],
    );
  }

  Widget _liveTab(Match m) {
    final live = _live;
    final events = live?.events ?? const <MatchEvent>[];
    final feed = live == null ? const <_FeedItem>[] : _liveFeed(m, live);
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([_loadLive(force: true), _loadInfo(force: true)]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(14),
        children: [
          _liveHeader(m, live),
          if (_metaLine() != null) ...[
            const SizedBox(height: 8),
            _metaLine()!,
          ],
          if (live != null && live.stats.isNotEmpty) ...[
            const SizedBox(height: 16),
            _sectionTitle('技术统计', Icons.insights, gold),
            const SizedBox(height: 8),
            _statsBlock(m, live.stats),
          ],
          const SizedBox(height: 18),
          _sectionTitle('实况文字转播', Icons.podcasts, red),
          const SizedBox(height: 8),
          if (live == null && _liveError != null)
            EmptyBox('实况加载失败：$_liveError')
          else if (live == null)
            const EmptyBox('实况加载中…')
          else if (events.isEmpty)
            EmptyBox(live.error.isNotEmpty
                ? '实况不可用：${live.error}'
                : '暂无比赛事件：可能刚开赛，或该赛事不在 API-Football 覆盖范围。')
          else
            ...feed.map(_feedRow),
          const SizedBox(height: 20),
          _sectionTitle('时间线', Icons.timeline, green),
          const SizedBox(height: 8),
          if (events.isEmpty)
            const EmptyBox('暂无时间线数据')
          else
            ...events.map((e) => _timelineRow(m, e)),
          if (_liveLoading && live != null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _liveHeader(Match m, LiveMatchInfo? live) {
    final hg = live?.homeGoals ?? m.homeGoals;
    final ag = live?.awayGoals ?? m.awayGoals;
    final score = (hg != null && ag != null) ? '$hg - $ag' : 'vs';
    final status = _liveStatusLabel(live?.status ?? m.liveStatus);
    final minute = live?.elapsed ?? m.liveElapsed;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.homeTeam,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(score,
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w800)),
                ),
                Expanded(
                  child: Text(
                    m.awayTeam,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: red, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  [if (status.isNotEmpty) status, if (minute != null) "$minute'"]
                      .join(' · '),
                  style: const TextStyle(
                      fontSize: 12.5, color: red, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (_liveOdds != null) ...[
              const SizedBox(height: 10),
              _liveOddsRow(_liveOdds!),
            ],
          ],
        ),
      ),
    );
  }

  /// Bookmaker in-play win probabilities (博彩滚球).
  Widget _liveOddsRow(LiveOdds odds) {
    Widget cell(String label, double? value, Color color) => Expanded(
          child: Column(children: [
            Text(value == null ? '-' : pct(value),
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            Text(label, style: const TextStyle(fontSize: 10, color: muted)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8F6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        cell('主胜', odds.home, green),
        cell('平局', odds.draw, gold),
        cell('客胜', odds.away, orange),
      ]),
    );
  }

  /// Venue / round / referee, available once /info has resolved the fixture.
  Widget? _metaLine() {
    final meta = _info?.meta;
    if (meta == null || meta.isEmpty) return null;
    final venue = [meta.city, meta.venue].where((s) => s.isNotEmpty).join(' ');
    final bits = [
      if (meta.round.isNotEmpty) meta.round,
      if (venue.isNotEmpty) venue,
      if (meta.referee.isNotEmpty) '裁判 ${meta.referee}',
    ];
    if (bits.isEmpty) return null;
    return Row(
      children: [
        const Icon(Icons.place_outlined, size: 14, color: muted),
        const SizedBox(width: 4),
        Expanded(
          child: Text(bits.join(' · '),
              style: const TextStyle(fontSize: 11.5, color: muted)),
        ),
      ],
    );
  }

  String _liveStatusLabel(String status) {
    return switch (status) {
      '1H' => '上半场',
      'HT' => '中场休息',
      '2H' => '下半场',
      'ET' => '加时赛',
      'BT' => '加时中场',
      'P' => '点球大战',
      'INT' => '比赛中断',
      'SUSP' => '比赛暂停',
      'LIVE' => '进行中',
      'FT' => '已完场',
      'AET' => '加时完场',
      'PEN' => '点球完场',
      _ => '',
    };
  }

  /// API-Football has no commentary endpoint; each event becomes one sentence.
  /// Substitution direction (in vs out) is inconsistent across fixtures, so it
  /// is shown neutrally: "换人：球队 A / B".
  String _commentary(Match m, MatchEvent e) {
    final team = e.side == 'home'
        ? m.homeTeam
        : e.side == 'away'
            ? m.awayTeam
            : '';
    final score = e.score.isNotEmpty ? '，比分 ${e.score}' : '';
    final player = e.player.isNotEmpty ? e.player : '-';
    switch (e.kind) {
      case 'goal':
        return '进球！$team $player'
            '${e.assist.isNotEmpty ? '（助攻 ${e.assist}）' : ''}$score';
      case 'penalty':
        return '点球命中！$team $player$score';
      case 'own_goal':
        return '乌龙球！$team $player$score';
      case 'missed_penalty':
        return '罚失点球：$team $player';
      case 'yellow':
        return '黄牌：$team $player';
      case 'red':
        return '红牌：$team $player';
      case 'second_yellow':
        return '两黄变一红：$team $player';
      case 'subst':
        final other = e.assist.isNotEmpty ? e.assist : '-';
        return '换人：$team $player / $other';
      case 'var':
        final note = e.detail.isNotEmpty ? e.detail : e.comments;
        return 'VAR：$team${note.isNotEmpty ? ' $note' : ''}';
      default:
        final note = e.comments.isNotEmpty ? e.comments : e.detail;
        return note.isNotEmpty ? '$team $note'.trim() : '$team 比赛事件';
    }
  }

  static const Set<String> _startedStatuses = {
    '1H', 'HT', '2H', 'ET', 'BT', 'P', 'LIVE', 'INT', 'SUSP',
    'FT', 'AET', 'PEN',
  };
  static const Set<String> _finishedStatuses = {'FT', 'AET', 'PEN'};
  static const Set<String> _secondHalfStatuses = {'2H', 'ET', 'BT', 'P'};

  /// 实况 is more than the raw timeline: the same events, newest first, are
  /// bracketed by phase markers (开球/半场/完场) so the feed reads like a live
  /// broadcast even though API-Football has no commentary endpoint.
  List<_FeedItem> _liveFeed(Match m, LiveMatchInfo live) {
    final status = live.status.isNotEmpty ? live.status : m.liveStatus;
    final started =
        live.elapsed != null ||
        live.events.isNotEmpty ||
        _startedStatuses.contains(status);
    if (!started) return const [];
    final finished = _finishedStatuses.contains(status);
    final secondHalf = _secondHalfStatuses.contains(status) || finished;
    final halfTime = status == 'HT' || secondHalf;

    final feed = <_FeedItem>[];
    if (finished) feed.add(const _FeedItem('终场', '全场结束', phase: true));
    var marked = false;
    for (final e in live.events) {
      if (halfTime && !marked && e.minute <= 45) {
        if (secondHalf) {
          feed.add(const _FeedItem("46'", '下半场开始', phase: true));
        }
        feed.add(const _FeedItem("45'", '半场结束', phase: true));
        marked = true;
      }
      feed.add(_FeedItem(e.clock, _commentary(m, e)));
    }
    if (halfTime && !marked) {
      if (secondHalf) feed.add(const _FeedItem("46'", '下半场开始', phase: true));
      feed.add(const _FeedItem("45'", '半场结束', phase: true));
    }
    feed.add(const _FeedItem("0'", '比赛开始', phase: true));
    return feed;
  }

  Widget _feedRow(_FeedItem item) =>
      item.phase ? _phaseRow(item.text) : _commentaryRow(item.clock, item.text);

  Widget _phaseRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1, color: Color(0xFFE3EAE5))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12, color: muted, fontWeight: FontWeight.w600),
            ),
          ),
          const Expanded(child: Divider(height: 1, color: Color(0xFFE3EAE5))),
        ],
      ),
    );
  }

  Widget _commentaryRow(String clock, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 42,
            child: Text(clock,
                style: const TextStyle(
                    fontSize: 12, color: muted, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _statsBlock(Match m, List<MatchStat> stats) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.homeTeam,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: green),
                  ),
                ),
                Expanded(
                  child: Text(
                    m.awayTeam,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: orange),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...stats.map(_statRow),
          ],
        ),
      ),
    );
  }

  Widget _statRow(MatchStat stat) {
    final home = stat.homeValue ?? 0;
    final away = stat.awayValue ?? 0;
    final total = home + away;
    final share = total > 0 ? home / total : 0.5;
    final homeFlex = (share * 1000).round().clamp(1, 999);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(stat.homeText,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: Text(
                  stat.type,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11.5, color: muted),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  stat.awayText,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Row(
              children: [
                Expanded(
                  flex: homeFlex,
                  child: Container(height: 4, color: green),
                ),
                Expanded(
                  flex: 1000 - homeFlex,
                  child: Container(height: 4, color: orange),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineRow(Match m, MatchEvent e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F8F6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(e.clock,
                style: const TextStyle(
                    fontSize: 12, color: muted, fontWeight: FontWeight.w600)),
          ),
          _eventGlyph(e),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_commentary(m, e),
                style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _eventGlyph(MatchEvent e) {
    switch (e.kind) {
      case 'goal':
      case 'penalty':
        return const Icon(Icons.sports_soccer, size: 18, color: green);
      case 'own_goal':
        return const Icon(Icons.sports_soccer, size: 18, color: red);
      case 'missed_penalty':
        return const Icon(Icons.block, size: 18, color: muted);
      case 'yellow':
        return _cardGlyph(gold);
      case 'red':
      case 'second_yellow':
        return _cardGlyph(red);
      case 'subst':
        return const Icon(Icons.swap_horiz, size: 18,
            color: Color(0xFF3A6EA5));
      case 'var':
        return const Icon(Icons.videocam_outlined, size: 18, color: muted);
      default:
        return const Icon(Icons.circle, size: 12, color: muted);
    }
  }

  Widget _cardGlyph(Color color) {
    return Container(
      width: 11,
      height: 15,
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
    );
  }

  String _path(String suffix) =>
      '/api/matches/${Uri.encodeComponent(widget.match.matchId)}/$suffix';

  Widget _bettingTab(Match m) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _sectionTitle('投注选项', Icons.receipt_long, orange),
        const SizedBox(height: 8),
        ..._bettingSections(m),
        _sectionTitle('市场参考', Icons.public, green),
        const SizedBox(height: 8),
        LazySection<MarketOdds>(
          client: widget.client,
          path: _path('market'),
          parse: MarketOdds.fromJson,
          builder: (o) => o.isEmpty ? null : marketBlock(o),
          emptyText: '暂无外部市场赔率（通常开赛前一天更新）。',
        ),
      ],
    );
  }

  Widget _injuriesTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _sectionTitle('伤病', Icons.medical_services, orange),
        const SizedBox(height: 4),
        ..._injuriesWidgets(),
        const SizedBox(height: 16),
        _sectionTitle('缺阵历史', Icons.history_toggle_off, orange),
        const SizedBox(height: 8),
        LazySection<MatchSquad>(
          client: widget.client,
          path: _path('squad'),
          parse: MatchSquad.fromJson,
          builder: (s) => s.absences.isEmpty ? null : absenceBlock(s),
          emptyText: '暂无缺阵历史记录。',
        ),
      ],
    );
  }

  Widget _lineupsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _sectionTitle('首发', Icons.groups, green),
        const SizedBox(height: 4),
        ..._lineupsWidgets(),
        const SizedBox(height: 16),
        _sectionTitle('本场评分', Icons.grade, gold),
        const SizedBox(height: 8),
        LazySection<FixturePlayers>(
          client: widget.client,
          path: _path('players'),
          parse: FixturePlayers.fromJson,
          builder: (p) => p.teams.isEmpty ? null : ratingsBlock(p),
          emptyText: '暂无评分（开赛后才会生成）。',
        ),
        const SizedBox(height: 16),
        _sectionTitle('赛季关键球员', Icons.star_outline, green),
        const SizedBox(height: 8),
        LazySection<MatchSquad>(
          client: widget.client,
          path: _path('squad'),
          parse: MatchSquad.fromJson,
          builder: (s) {
            final hasPlayers = (s.home?.players.isNotEmpty ?? false) ||
                (s.away?.players.isNotEmpty ?? false);
            return hasPlayers ? squadBlock(s) : null;
          },
          emptyText: '暂无球员数据。',
        ),
      ],
    );
  }

  List<Widget> _injuriesWidgets() {
    if (_infoLoading) return const [EmptyBox('伤病信息加载中…')];
    if (_infoError != null) return [EmptyBox('伤病信息加载失败：$_infoError')];
    final info = _info;
    if (info == null) return const [EmptyBox('伤病信息加载中…')];
    if (info.error.isNotEmpty) return [EmptyBox('伤病信息不可用：${info.error}')];
    if (info.injuries.isEmpty) {
      return const [EmptyBox('API-Football 暂无该场伤病数据（通常赛前才更新）。')];
    }
    return info.injuries.map(_injuryRow).toList();
  }

  List<Widget> _lineupsWidgets() {
    if (_infoLoading) return const [EmptyBox('首发信息加载中…')];
    if (_infoError != null) return [EmptyBox('首发信息加载失败：$_infoError')];
    final info = _info;
    if (info == null) return const [EmptyBox('首发信息加载中…')];
    if (info.error.isNotEmpty) return [EmptyBox('首发信息不可用：${info.error}')];
    if (info.lineups.isEmpty) {
      return const [EmptyBox('首发信息尚未公布（通常开赛前 1 小时左右发布）。')];
    }
    return _groupLineups(info.lineups);
  }

  List<Widget> _predictionSections() {
    if (_predictions.isEmpty) {
      if (_predictionsGenerating) {
        return const [
          EmptyBox('AI 模型预测生成中…（通常 1–2 分钟，完成后本页会自动刷新）'),
        ];
      }
      return const [
        EmptyBox('暂无 AI 模型预测：后台生成可能失败了，点右上角刷新重试。'
            '上方「泊松模型」为本地统计模型，无需生成。'),
      ];
    }
    final byModel = <String, List<LlmPrediction>>{};
    for (final p in _predictions) {
      byModel.putIfAbsent(p.model.isEmpty ? '未知模型' : p.model, () => []).add(p);
    }
    return byModel.entries.map((e) {
      final rows = [...e.value]
        ..sort((a, b) => _marketOrder.indexOf(a.market).compareTo(_marketOrder.indexOf(b.market)));
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.smart_toy, color: green, size: 18),
                const SizedBox(width: 8),
                Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              ...rows.map(_predRow),
            ],
          ),
        ),
      );
    }).toList();
  }

  Widget _predRow(LlmPrediction p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 82,
          child: Text(marketLabel[p.market] ?? p.market,
              style: const TextStyle(fontSize: 13, color: muted)),
        ),
        Expanded(
          child: Text(legPickLabel(p.market, p.pick, ''),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        if (p.prob != null)
          Text(pct(p.prob!), style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 10),
        VerdictBadge(p.result),
      ]),
    );
  }

  List<Widget> _poissonSection(Match m) {
    if (!m.poissonAvailable) {
      return const [
        EmptyBox('该场没有赛前泊松快照（官方接口只保留在售赛事，无法补算）。'),
      ];
    }
    return [
      _probBar('主胜', m.homeWin, green),
      _probBar('平局', m.draw, gold),
      _probBar('客胜', m.awayWin, orange),
      const SizedBox(height: 4),
      Text('大 2.5 ${pct(m.over25)} · 双方进球 ${pct(m.bttsYes)}',
          style: const TextStyle(fontSize: 12)),
      if (m.topScores.isNotEmpty)
        Text('热门比分：${m.topScores.take(3).map((e) => e.score).join(' / ')}',
            style: const TextStyle(fontSize: 12, color: muted)),
      if (m.had.isNotEmpty)
        Text(
          '官方胜平负：${m.had['home']} / ${m.had['draw']} / ${m.had['away']}',
          style: const TextStyle(fontSize: 12, color: muted),
        ),
    ];
  }

  Widget _probBar(String label, double v, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 44,
              child: Text(label,
                  style: const TextStyle(color: muted, fontSize: 12))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: v.clamp(0, 1),
                color: color,
                backgroundColor: const Color(0xFFE7ECE8),
                minHeight: 7,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
              width: 48,
              child: Text(pct(v),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  List<Widget> _bettingSections(Match m) {
    return marketsFor(m).map((mk) {
      final opts = optionsFor(m, mk);
      final title = mk == 'handicap'
          ? '${marketLabel[mk]}（${lineText(m.hhad['line'])}）'
          : (marketLabel[mk] ?? mk);
      final cols = switch (mk) {
        'correct_score' => 6,
        'total_goals' => 4,
        'wdw' || 'handicap' || 'half_full' => 3,
        _ => 2,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 4),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 0,
              crossAxisSpacing: 0,
              mainAxisExtent: 40,
            ),
            children: opts.map((o) => _optionCell(m, mk, o)).toList(),
          ),
          const SizedBox(height: 14),
        ],
      );
    }).toList();
  }

  Widget _optionCell(Match m, String market, BetOption o) {
    final leg = DraftLeg(
      matchId: m.matchId,
      matchNum: m.matchNum,
      homeTeam: m.homeTeam,
      awayTeam: m.awayTeam,
      market: market,
      pick: o.value,
      line: o.line ?? '',
      odds: o.odds,
      label: o.label,
    );
    final top = switch (market) {
      'correct_score' => pickLabel[o.value] ?? o.value,
      'handicap' => pickLabel[o.value] ?? o.label,
      'half_full' => pickLabel[o.value] ?? o.value,
      'total_goals' => o.value,
      _ => o.label,
    };
    return ListenableBuilder(
      listenable: draft,
      builder: (_, _) {
        final selected = draft.contains(leg);
        return InkWell(
          onTap: () => _toggleLeg(leg),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? red : Colors.white,
              border: Border.all(
                color: selected ? red : const Color(0xFFE3E9E3),
                width: selected ? 1.4 : 0.6,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(top,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                        color: selected ? Colors.white : const Color(0xFF17211F))),
                const SizedBox(height: 1),
                Text(o.odds.isEmpty ? '-' : o.odds,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        color: selected ? Colors.white70 : muted)),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleLeg(DraftLeg leg) {
    draft.toggle(leg);
  }

  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _injuryRow(InfoRow r) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${r.player}  ${r.team.isNotEmpty ? '（${r.team}）' : ''}'),
      subtitle: Text(
        [if (r.kind.isNotEmpty) r.kind, if (r.reason.isNotEmpty) r.reason,
         if (r.status.isNotEmpty) r.status].join(' · '),
      ),
      trailing: Text(r.kind, style: const TextStyle(color: orange, fontSize: 12)),
    );
  }

  List<Widget> _groupLineups(List<InfoRow> rows) {
    final byTeam = <String, List<InfoRow>>{};
    for (final r in rows) {
      byTeam.putIfAbsent(r.team.isEmpty ? '未知' : r.team, () => []).add(r);
    }
    return byTeam.entries.map((e) {
      final starting = e.value.where((r) => r.isStarting).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: starting.isEmpty
                ? [const Text('（无首发数据）', style: TextStyle(color: muted))]
                : starting
                    .map((r) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF4F1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            r.number != null ? '${r.number} ${r.player}' : r.player,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ))
                    .toList(),
          ),
          const SizedBox(height: 12),
        ],
      );
    }).toList();
  }
}

/// 近期战绩 tab: both teams' last-10 results, plus the home team's home form
/// and the away team's away form. Fetched lazily so the rest of the detail page
/// is not blocked by the API-Football round-trip.
class _FormTab extends StatefulWidget {
  const _FormTab({required this.client, required this.matchId});

  final ApiClient client;
  final String matchId;

  @override
  State<_FormTab> createState() => _FormTabState();
}

class _FormTabState extends State<_FormTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  MatchForm? _form;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final matchId = Uri.encodeComponent(widget.matchId);
      final data = await widget.client.get('/api/matches/$matchId/form');
      if (!mounted) return;
      setState(() => _form = MatchForm.fromJson(data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          EmptyBox('近期战绩加载失败：$_error'),
          Center(
            child: TextButton(onPressed: _load, child: const Text('重试')),
          ),
        ],
      );
    }
    final form = _form;
    if (form == null) return const EmptyBox('暂无近期战绩数据');
    if (form.error.isNotEmpty) return EmptyBox('近期战绩不可用：${form.error}');
    final matchId = Uri.encodeComponent(widget.matchId);
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _teamFormCard(form.homeTeam, form.home,
            subsetLabel: '近 10 主场', icon: Icons.home_outlined),
        const SizedBox(height: 18),
        _teamFormCard(form.awayTeam, form.away,
            subsetLabel: '近 10 客场', icon: Icons.flight_takeoff),
        const SizedBox(height: 18),
        sectionTitle('交锋记录', Icons.compare_arrows, green),
        const SizedBox(height: 8),
        LazySection<MatchH2H>(
          client: widget.client,
          path: '/api/matches/$matchId/h2h',
          parse: MatchH2H.fromJson,
          builder: (h) => h.rows.isEmpty ? null : h2hBlock(h),
          emptyText: '暂无交锋记录',
        ),
        const SizedBox(height: 18),
        sectionTitle('赛季数据', Icons.bar_chart, gold),
        const SizedBox(height: 8),
        LazySection<MatchTeamStats>(
          client: widget.client,
          path: '/api/matches/$matchId/team-stats',
          parse: MatchTeamStats.fromJson,
          builder: (s) => s.home == null && s.away == null ? null : teamStatsBlock(s),
          emptyText: '暂无赛季数据',
        ),
      ],
    );
  }

  Widget _teamFormCard(
    String team,
    TeamForm form, {
    required String subsetLabel,
    required IconData icon,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: green, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(team,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ]),
            const SizedBox(height: 8),
            _summary(form.overall),
            const SizedBox(height: 12),
            const Text('近 10 场',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            ..._fixtureRows(form.overall, empty: '暂无近期比赛'),
            const SizedBox(height: 12),
            Text(subsetLabel,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            ..._fixtureRows(form.subset, empty: '暂无数据'),
          ],
        ),
      ),
    );
  }

  Widget _summary(List<FormFixture> rows) {
    final n = rows.length;
    var w = 0, d = 0, l = 0, gf = 0, ga = 0;
    for (final r in rows) {
      gf += r.forGoals;
      ga += r.againstGoals;
      if (r.result == 'W') {
        w++;
      } else if (r.result == 'D') {
        d++;
      } else {
        l++;
      }
    }
    Widget chip(String label, String value) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFEEF4F1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('$label $value', style: const TextStyle(fontSize: 12)),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        chip('场次', '$n'),
        chip('胜/平/负', '$w/$d/$l'),
        chip('进球', '$gf'),
        chip('失球', '$ga'),
      ],
    );
  }

  List<Widget> _fixtureRows(List<FormFixture> rows, {required String empty}) {
    if (rows.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(empty,
              style: const TextStyle(color: muted, fontSize: 12)),
        ),
      ];
    }
    return rows.map(_fixtureRow).toList();
  }

  Widget _fixtureRow(FormFixture r) {
    final color = switch (r.result) {
      'W' => green,
      'D' => gold,
      'L' => red,
      _ => muted,
    };
    final date = r.playedDate;
    final dateText = date == null ? '' : '${date.month}/${date.day}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(r.result,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          child: Text('${r.isHome ? '主' : '客'} $dateText',
              style: const TextStyle(fontSize: 11, color: muted)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.homeName} ${r.homeGoals}-${r.awayGoals} ${r.awayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
              if (r.leagueName.isNotEmpty)
                Text(r.leagueName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: muted)),
            ],
          ),
        ),
      ]),
    );
  }
}

/// One line of the 实况 feed: either an event or a phase marker.
class _FeedItem {
  const _FeedItem(this.clock, this.text, {this.phase = false});

  final String clock, text;
  final bool phase;
}
