import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// ------------------------------------------------------------------ tokens
/// Near-black background.
const kBg = Color(0xFF0B0B0D);

/// Card / sheet surface.
const kSurface = Color(0xFF141417);

/// Raised surface (inputs, chips).
const kSurface2 = Color(0xFF1B1B1F);

/// Hairline borders.
const kOutline = Color(0xFF26262C);

const kTextPrimary = Color(0xFFF2F2F5);
const kTextSecondary = Color(0xFF9A9AA4);
const kTextTertiary = Color(0xFF63636C);

/// The single accent: a soft violet that sits quietly next to black & grey.
const kAccent = Color(0xFF9A8CF0);

/// Accent for fills behind text/icons.
const kAccentDim = Color(0xFF26223A);

// ----------------------------------------------------------------- widgets
/// Frosted, translucent pill used for the map HUD.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(8), this.radius = 22});
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: const Color(0xB3101013),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: child,
          ),
        ),
      );
}

/// Round glass HUD button.
class HudButton extends StatelessWidget {
  const HudButton({super.key, this.icon, this.child, required this.onTap, required this.tooltip, this.badge});
  final IconData? icon;
  final Widget? child;
  final VoidCallback onTap;
  final String tooltip;
  final int? badge;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Tooltip(
          message: tooltip,
          child: GestureDetector(
            onTap: onTap,
            child: Glass(
              radius: 24,
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: 46,
                height: 46,
                child: Stack(alignment: Alignment.center, children: [
                  child ?? Icon(icon, size: 20, color: kTextPrimary),
                  if (badge != null && badge! > 0)
                    Positioned(
                      top: 7,
                      right: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(8)),
                        child: Text('$badge', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.black)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      );
}

class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
      );
}

/// Small uppercase section label.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Row(children: [
          Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: kTextTertiary)),
          const Spacer(),
          ?trailing,
        ]),
      );
}

/// Selectable pill used inside the filter panel.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.selected, required this.onTap, this.dot});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? kAccentDim : kSurface2,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? kAccent.withValues(alpha: 0.6) : kOutline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot != null) ...[
              Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 7),
            ],
            Text(label, style: TextStyle(fontSize: 13, color: selected ? kTextPrimary : kTextSecondary, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
          ]),
        ),
      );
}

/// A section of options inside a [FilterDropdown].
class FilterSection {
  const FilterSection({required this.title, required this.options, this.onClear});
  final String title;
  final List<FilterOption> options;
  final VoidCallback? onClear;
}

class FilterOption {
  const FilterOption({required this.label, required this.selected, required this.onTap, this.dot});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;
}

/// Full-width "Filters" button that pops out a large panel (rarity,
/// variant, genre...) anchored beneath it.
class FilterDropdown extends StatefulWidget {
  const FilterDropdown({super.key, required this.sections, required this.activeCount, required this.onReset, this.summary});

  /// Built lazily so the panel always reflects current selections.
  final List<FilterSection> Function() sections;
  final int activeCount;
  final VoidCallback onReset;
  final String? summary;

  @override
  State<FilterDropdown> createState() => _FilterDropdownState();
}

class _FilterDropdownState extends State<FilterDropdown> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _buttonKey = GlobalKey();

  void _toggle() => setState(() => _portal.isShowing ? _portal.hide() : _portal.show());

  @override
  Widget build(BuildContext context) {
    final open = _portal.isShowing;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          final screen = MediaQuery.sizeOf(context);
          final w = _buttonKey.currentContext?.size?.width ?? screen.width - 24;
          return Stack(children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggle,
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, 8),
              child: Align(
                alignment: Alignment.topLeft,
                child: _Panel(
                  width: w,
                  maxHeight: screen.height * 0.62,
                  sections: widget.sections,
                  onReset: () {
                    widget.onReset();
                    setState(() {});
                  },
                  onDone: _toggle,
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
          ]);
        },
        child: GestureDetector(
          onTap: _toggle,
          child: Container(
            key: _buttonKey,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: kSurface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: open ? kAccent.withValues(alpha: 0.6) : kOutline),
            ),
            child: Row(children: [
              const Icon(Icons.tune_rounded, size: 20, color: kTextSecondary),
              const SizedBox(width: 10),
              const Text('Filters', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (widget.activeCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: kAccentDim, borderRadius: BorderRadius.circular(10)),
                  child: Text('${widget.activeCount}', style: const TextStyle(fontSize: 12, color: kAccent, fontWeight: FontWeight.w700)),
                ),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.summary ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextTertiary)),
              ),
              AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 150), child: const Icon(Icons.expand_more_rounded, color: kTextSecondary)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.width, required this.maxHeight, required this.sections, required this.onReset, required this.onDone, required this.onChanged});
  final double width;
  final double maxHeight;
  final List<FilterSection> Function() sections;
  final VoidCallback onReset;
  final VoidCallback onDone;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final secs = sections();
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kOutline),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 12))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final s in secs) ...[
                  SectionLabel(
                    s.title,
                    trailing: s.onClear == null || !s.options.any((o) => o.selected)
                        ? null
                        : GestureDetector(
                            onTap: () {
                              s.onClear!();
                              onChanged();
                            },
                            child: const Text('Clear', style: TextStyle(fontSize: 12, color: kAccent)),
                          ),
                  ),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final o in s.options)
                      Pill(
                        label: o.label,
                        selected: o.selected,
                        dot: o.dot,
                        onTap: () {
                          o.onTap();
                          onChanged();
                        },
                      ),
                  ]),
                ],
              ]),
            ),
          ),
          const Divider(height: 1, color: kOutline),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              TextButton(onPressed: onReset, child: const Text('Reset all')),
              const Spacer(),
              FilledButton(onPressed: onDone, child: const Text('Done')),
            ]),
          ),
        ]),
      ),
    );
  }
}
