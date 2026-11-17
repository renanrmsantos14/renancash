import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:budget/widgets/iconButtonScaled.dart';
import 'package:budget/widgets/tappableTextEntry.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/showDatePicker.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class SelectDateRange extends StatefulWidget {
  const SelectDateRange({
    super.key,
    required this.initialStartDate,
    required this.initialEndDate,
    required this.onSelectedStartDate,
    required this.onSelectedEndDate,
    this.padding = const EdgeInsetsDirectional.symmetric(vertical: 10),
  });
  final DateTime? initialStartDate;
  final DateTime? initialEndDate;
  final Function(DateTime?) onSelectedStartDate;
  final Function(DateTime?) onSelectedEndDate;
  final EdgeInsetsDirectional padding;

  @override
  State<SelectDateRange> createState() => _SelectDateRangeState();
}

class _SelectDateRangeState extends State<SelectDateRange> {
  late DateTime? selectedStartDate = widget.initialStartDate;
  late DateTime? selectedEndDate = widget.initialEndDate;

  // Rótulo de cada data: sem ele, "12 de novembro" e "Para sempre" não dizem o que são.
  Widget _rotulo(String texto) => Padding(
        padding: const EdgeInsetsDirectional.only(top: 4),
        child: TextFont(
          text: texto,
          fontSize: 13,
          textColor: getColor(context, "textLight"),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: Column(
        children: [
          _rotulo("Início"),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: TappableTextEntry(
                  title: getWordedDateShortMore(
                    selectedStartDate ?? DateTime.now(),
                    includeYear: true,
                  ),
                  placeholder: "",
                  onTap: () async {
                    final DateTime? picked = await showCustomDatePicker(
                        context, selectedStartDate ?? DateTime.now());
                    selectedStartDate = picked ?? selectedStartDate;
                    if (selectedStartDate != null &&
                        selectedEndDate?.isBefore(selectedStartDate!) == true) {
                      widget.onSelectedStartDate(selectedEndDate);
                      selectedStartDate = selectedEndDate;
                      widget.onSelectedEndDate(picked ?? selectedStartDate);
                      selectedEndDate = picked ?? selectedStartDate;
                    } else {
                      widget.onSelectedStartDate(selectedStartDate);
                    }
                    setState(() {});
                  },
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                  internalPadding: EdgeInsetsDirectional.symmetric(
                      vertical: 5, horizontal: 4),
                  padding: EdgeInsetsDirectional.symmetric(
                      vertical: 3, horizontal: 5),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedExpanded(
                expand: selectedEndDate != null,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(top: 5, bottom: 0),
                  child: Icon(
                    Icons.arrow_downward_rounded,
                    size: 25,
                  ),
                ),
              ),
            ],
          ),
          _rotulo("Fim"),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: TappableTextEntry(
                  title: selectedEndDate == null
                      ? ""
                      : getWordedDateShortMore(
                          selectedEndDate ?? DateTime.now(),
                          includeYear: true),
                  placeholder: "until-forever".tr(),
                  showPlaceHolderWhenTextEquals: "",
                  onTap: () async {
                    final DateTime? picked = await showCustomDatePicker(
                        context, selectedEndDate ?? DateTime.now());
                    selectedEndDate = picked ?? selectedEndDate;
                    if (selectedStartDate != null &&
                        selectedEndDate?.isBefore(selectedStartDate!) == true) {
                      widget.onSelectedEndDate(selectedStartDate);
                      selectedEndDate = selectedStartDate;
                      widget.onSelectedStartDate(picked ?? selectedStartDate);
                      selectedStartDate = picked ?? selectedStartDate;
                    } else {
                      widget.onSelectedEndDate(selectedEndDate);
                    }
                    setState(() {});
                  },
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                  internalPadding: EdgeInsetsDirectional.symmetric(
                      vertical: 5, horizontal: 4),
                  padding: EdgeInsetsDirectional.symmetric(
                      vertical: 3, horizontal: 5),
                ),
              ),
              AnimatedSizeSwitcher(
                child: selectedEndDate != null
                    ? Opacity(
                        key: ValueKey(1),
                        opacity: 0.5,
                        child: IconButtonScaled(
                          tooltip: "clear".tr(),
                          iconData: Icons.close_rounded,
                          iconSize: 16,
                          scale: 1.5,
                          onTap: () {
                            setState(() {
                              selectedEndDate = null;
                            });
                            widget.onSelectedEndDate(selectedEndDate);
                          },
                        ),
                      )
                    : Container(
                        key: ValueKey(2),
                      ),
              )
            ],
          ),
        ],
      ),
    );
  }
}
