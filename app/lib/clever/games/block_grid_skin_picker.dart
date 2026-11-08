import 'package:flutter/material.dart';

import '../lux.dart';
import 'block_grid_skins.dart';

/// Opens the Blok Merkezi skin picker as a bottom sheet. Opening it marks new skins as seen.
Future<void> showBlockSkinPicker(BuildContext context, BlockSkinStore store) {
  store.markSeen();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BlockSkinPicker(store: store, onPicked: () => Navigator.of(context).maybePop()),
  );
}

/// Grid of every skin: unlocked ones are selectable, locked ones show their unlock condition and
/// how far the player is.
class BlockSkinPicker extends StatelessWidget {
  final BlockSkinStore store;
  final VoidCallback? onPicked;
  const BlockSkinPicker({super.key, required this.store, this.onPicked});

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.82;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Container(
        constraints: BoxConstraints(maxHeight: maxH),
        decoration: BoxDecoration(
          gradient: Lux.velvetCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: Lux.line),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Lux.line, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              Text('Görünümler', style: Lux.display(24, color: Lux.goldLight)),
              const SizedBox(height: 4),
              Text('En yüksek bölüm: ${store.level} · Temizlenen: ${store.lines}',
                  style: Lux.ui(13, color: Lux.muted)),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: BlockSkins.all.length,
                  itemBuilder: (context, i) => _card(context, BlockSkins.all[i]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, BlockSkin skin) {
    final open = store.isUnlocked(skin);
    final chosen = store.skin.id == skin.id;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      key: ValueKey('skin-${skin.id}'),
      onTap: open
          ? () async {
              await store.select(skin);
              onPicked?.call();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Lux.cardDeep,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: chosen ? skin.accent : Lux.line, width: chosen ? 2 : 1),
          boxShadow: chosen ? [BoxShadow(color: skin.accent.withValues(alpha: 0.35), blurRadius: 14)] : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(
                        opacity: open ? 1 : 0.32,
                        child: CustomPaint(painter: SkinPreviewPainter(skin, dpr)),
                      ),
                      if (!open) const Center(child: Icon(Icons.lock_rounded, color: Lux.goldLight, size: 30)),
                      if (chosen)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(color: skin.accent, shape: BoxShape.circle),
                            child: const Icon(Icons.check_rounded, size: 16, color: Colors.black),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(skin.name, style: Lux.ui(16, color: open ? Lux.ink : Lux.muted, weight: FontWeight.w700)),
            const SizedBox(height: 2),
            if (open)
              Text(skin.blurb, maxLines: 2, overflow: TextOverflow.ellipsis, style: Lux.ui(12, color: Lux.muted))
            else ...[
              Text(skin.unlockText, maxLines: 3, style: Lux.ui(11.5, color: Lux.goldLight)),
              const SizedBox(height: 5),
              _bar(store.lines / skin.unlockLines, skin),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(double k, BlockSkin skin) {
    final level = store.level / skin.unlockLevel;
    final best = (k > level ? k : level).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: best,
        minHeight: 5,
        backgroundColor: Lux.line,
        valueColor: AlwaysStoppedAnimation(skin.accent),
      ),
    );
  }
}
