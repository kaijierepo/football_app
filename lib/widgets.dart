import 'package:flutter/material.dart';

/// Shared formatting + small widgets used across pages.

const Color green = Color(0xFF0B7D69);
const Color orange = Color(0xFFD96B3B);
const Color gold = Color(0xFFD9A128);
const Color red = Color(0xFFC0392B);
const Color muted = Color(0xFF66736F);

const Map<String, String> marketLabel = {
  'wdw': '胜平负',
  'handicap': '让球胜平负',
  'correct_score': '比分',
  'total_goals': '总进球数',
  'over_under': '大小球',
};

/// Short market names for chips in grouped views.
const Map<String, String> marketShort = {
  'wdw': '胜平负',
  'handicap': '让球',
  'correct_score': '比分',
  'total_goals': '进球',
  'over_under': '大小球',
};

/// Distinct accent per market so grouped plans are scannable at a glance.
Color marketColor(String market) => switch (market) {
  'wdw' => gold,
  'handicap' => const Color(0xFF6C5CE7),
  'correct_score' => orange,
  'total_goals' => green,
  'over_under' => const Color(0xFF2D6CDF),
  _ => muted,
};

/// Thin colored tag: [marketShort] on the market's accent background.
class MarketTag extends StatelessWidget {
  const MarketTag(this.market, {super.key});

  final String market;

  @override
  Widget build(BuildContext context) {
    final color = marketColor(market);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        marketShort[market] ?? market,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

const Map<String, String> pickLabel = {
  'home': '主胜',
  'draw': '平局',
  'away': '客胜',
  'over': '大',
  'under': '小',
  'other_home': '胜其他',
  'other_draw': '平其他',
  'other_away': '负其他',
};

String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

String lineText(dynamic line) {
  if (line == null) return '';
  final n = double.tryParse(line.toString()) ?? 0;
  if (n == 0) return '平手盘';
  return n > 0 ? '主队受让${_fmtNum(n)}球' : '主队让${_fmtNum(-n)}球';
}

String _fmtNum(double n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

/// Concise handicap line, e.g. "+1" / "-1" / "0" (让球 sign style).
String lineShort(dynamic line) {
  if (line == null) return '';
  final s = line.toString().trim();
  if (s.isEmpty) return '';
  final n = double.tryParse(s) ?? 0;
  if (n == 0) return '0';
  return n > 0 ? '+${_fmtNum(n)}' : _fmtNum(n);
}

/// Human label for a leg's pick given its market.
String legPickLabel(String market, String pick, String label) {
  if (market == 'correct_score') {
    return pickLabel[pick] ?? '比分 $pick';
  }
  if (market == 'total_goals') {
    return pick == '7+' ? '7+球' : '$pick球';
  }
  if (market == 'over_under') {
    return pick == 'over' ? '大 2.5 球' : '小 2.5 球';
  }
  if (label.isNotEmpty) return label;
  return pickLabel[pick] ?? pick;
}

class VerdictBadge extends StatelessWidget {
  const VerdictBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    Color color;
    Color bg;
    switch (text) {
      case 'hit':
      case 'won':
      case '已命中':
      case '已中奖':
        color = green;
        bg = const Color(0xFFE1F2EC);
        break;
      case 'miss':
      case 'lost':
      case '未命中':
        color = red;
        bg = const Color(0xFFFBE5E1);
        break;
      default:
        color = muted;
        bg = const Color(0xFFEEF1EE);
    }
    final label = switch (text) {
      'hit' || 'won' => '命中',
      'miss' || 'lost' => '未中',
      'pending' || '待开奖' => '待开奖',
      _ => text.isEmpty ? '待开奖' : text,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class StatPill extends StatelessWidget {
  const StatPill(this.label, this.hits, this.n, {super.key});

  final String label;
  final int hits;
  final int n;

  @override
  Widget build(BuildContext context) {
    final rate = n == 0 ? null : (hits / n * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD8E1D7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(width: 6),
          Text(
            '$hits/$n',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: (rate != null && rate >= 50) ? green : red,
            ),
          ),
          if (rate != null)
            Text(' $rate%', style: const TextStyle(color: muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class EmptyBox extends StatelessWidget {
  const EmptyBox(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: Text(text, style: const TextStyle(color: muted)),
    ),
  );
}
