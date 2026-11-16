import 'package:flutter/material.dart';

/// 单条弹幕的悬停/点击菜单。
///
/// 只提供仓库已有能力的动作：复制原文、屏蔽此弹幕、关闭。
class DanmakuMenu extends StatelessWidget {
  const DanmakuMenu({
    required this.text,
    required this.onCopy,
    required this.onClose,
    this.userName,
    this.onBlock,
    this.onPointerEnter,
    this.onPointerLeave,
    super.key,
  });

  final String text;
  final String? userName;
  final VoidCallback onCopy;
  final VoidCallback? onBlock;
  final VoidCallback onClose;
  final VoidCallback? onPointerEnter;
  final VoidCallback? onPointerLeave;

  @override
  Widget build(BuildContext context) {
    final name = userName?.trim();
    return MouseRegion(
      onEnter: (_) => onPointerEnter?.call(),
      onExit: (_) => onPointerLeave?.call(),
      child: Material(
        color: const Color(0xE6121214),
        borderRadius: BorderRadius.circular(6),
        elevation: 6,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (name != null && name.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFBDBDBD),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              _MenuButton(label: '复制', onPressed: onCopy),
              if (onBlock != null)
                _MenuButton(label: '屏蔽此弹幕', onPressed: onBlock!),
              _MenuButton(label: '关闭', onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 12.5),
      ),
      child: Text(label),
    );
  }
}

/// 把菜单放在条目下方；下方放不下时放到上方，并水平限制在视口内。
class DanmakuMenuLayoutDelegate extends SingleChildLayoutDelegate {
  const DanmakuMenuLayoutDelegate({
    required this.anchorX,
    required this.itemTop,
    required this.itemHeight,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  final double anchorX;
  final double itemTop;
  final double itemHeight;
  final double viewportWidth;
  final double viewportHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(viewportWidth, viewportHeight));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    const pointerInset = 24.0;
    final maxLeft = (size.width - childSize.width - margin).clamp(
      0.0,
      double.infinity,
    );
    final left = (anchorX - pointerInset).clamp(margin, maxLeft);
    final below = itemTop + itemHeight + 2;
    final above = itemTop - childSize.height - 4;
    final top = below + childSize.height <= size.height - margin
        ? below
        : (above < margin ? margin : above);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(DanmakuMenuLayoutDelegate oldDelegate) {
    return anchorX != oldDelegate.anchorX ||
        itemTop != oldDelegate.itemTop ||
        itemHeight != oldDelegate.itemHeight ||
        viewportWidth != oldDelegate.viewportWidth ||
        viewportHeight != oldDelegate.viewportHeight;
  }
}
