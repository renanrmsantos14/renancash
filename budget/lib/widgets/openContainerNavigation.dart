import 'package:budget/functions.dart';
import 'package:flutter/material.dart';

class OpenContainerNavigation extends StatelessWidget {
  OpenContainerNavigation({
    Key? key,
    required this.openPage,
    required this.button,
    this.closedColor,
    this.borderRadius = 250,
    this.closedElevation,
    this.customBorderRadius,
    this.onClosed,
    this.onOpen,
  }) : super(key: key);

  final Widget openPage;
  final Widget Function(VoidCallback openContainer) button;
  final Color? closedColor;
  final double borderRadius;
  final double? closedElevation;
  final BorderRadiusGeometry? customBorderRadius;
  final VoidCallback? onClosed;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    // Mesma transição do resto do app (fade + 8 px, 220 ms). O "container
    // transform" de 400 ms recortava e escalava a página inteira a cada
    // quadro e engasgava ao abrir uma transação.
    Widget child = button(() async {
      if (onOpen != null) onOpen!();
      await pushRoute(context, openPage);
      if (onClosed != null) onClosed!();
    });
    return ClipRRect(
      borderRadius: customBorderRadius ??
          BorderRadiusDirectional.circular(borderRadius),
      child: Container(
        color: closedColor ?? Colors.transparent,
        child: child,
      ),
    );
  }
}
