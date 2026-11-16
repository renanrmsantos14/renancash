import 'package:budget/colors.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

class NoResults extends StatelessWidget {
  const NoResults({
    Key? key,
    required this.message,
    this.tintColor,
    this.padding,
    this.noSearchResultsVariation = false,
  }) : super(key: key);
  final String message;
  final Color? tintColor;
  final EdgeInsetsDirectional? padding;
  final bool noSearchResultsVariation;

  @override
  Widget build(BuildContext context) {
    // Vazio curto e monocromático: ícone discreto e uma frase.
    return FadeIn(
      duration: Duration(milliseconds: 200),
      child: Center(
        child: Padding(
          padding: padding ??
              EdgeInsetsDirectional.only(top: 48, end: 30, start: 30),
          child: Column(
            children: [
              Icon(
                noSearchResultsVariation
                    ? Icons.search_off_rounded
                    : Icons.inbox_outlined,
                size: 32,
                color: getColor(context, "textLight"),
              ),
              SizedBox(height: 12),
              TextFont(
                maxLines: 4,
                fontSize: 14,
                text: message,
                textAlign: TextAlign.center,
                textColor: getColor(context, "textLight"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
