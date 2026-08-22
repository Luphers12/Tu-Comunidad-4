import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'timeline_step_model.dart';
export 'timeline_step_model.dart';

class TimelineStepWidget extends StatefulWidget {
  const TimelineStepWidget({
    super.key,
    String? location,
    String? time,
    String? title,
    bool? active,
    bool? last,
  })  : this.location = location ?? 'Punto de Entrega: Central Sololá',
        this.time = time ?? '10:45 AM',
        this.title = title ?? 'Pedido Entregado',
        this.active = active ?? false,
        this.last = last ?? false;

  final String location;
  final String time;
  final String title;
  final bool active;
  final bool last;

  @override
  State<TimelineStepWidget> createState() => _TimelineStepWidgetState();
}

class _TimelineStepWidgetState extends State<TimelineStepWidget> {
  late TimelineStepModel _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => TimelineStepModel());
  }

  @override
  void dispose() {
    _model.maybeDispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 16.0,
              height: 16.0,
              decoration: BoxDecoration(
                color: valueOrDefault<Color>(
                  valueOrDefault<bool>(
                    widget.active,
                    false,
                  )
                      ? FlutterFlowTheme.of(context).success
                      : FlutterFlowTheme.of(context).alternate,
                  FlutterFlowTheme.of(context).alternate,
                ),
                borderRadius: BorderRadius.circular(9999.0),
                shape: BoxShape.rectangle,
                border: Border.all(
                  color: valueOrDefault<Color>(
                    valueOrDefault<bool>(
                      widget.active,
                      false,
                    )
                        ? FlutterFlowTheme.of(context).success
                        : FlutterFlowTheme.of(context).alternate,
                    FlutterFlowTheme.of(context).alternate,
                  ),
                  width: valueOrDefault<double>(
                    valueOrDefault<bool>(
                      widget.active,
                      false,
                    )
                        ? 2.0
                        : 2.0,
                    2.0,
                  ),
                ),
              ),
            ),
            if (valueOrDefault<bool>(
              valueOrDefault<bool>(
                widget.last,
                false,
              )
                  ? false
                  : true,
              true,
            ))
              Container(
                width: 2.0,
                height: 40.0,
                decoration: BoxDecoration(
                  color: valueOrDefault<Color>(
                    valueOrDefault<bool>(
                      widget.active,
                      false,
                    )
                        ? FlutterFlowTheme.of(context).success
                        : FlutterFlowTheme.of(context).alternate,
                    FlutterFlowTheme.of(context).alternate,
                  ),
                  shape: BoxShape.rectangle,
                ),
              ),
          ],
        ),
        Expanded(
          flex: 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                valueOrDefault<String>(
                  widget.title,
                  'Pedido Entregado',
                ),
                style: FlutterFlowTheme.of(context).bodyLarge.override(
                      font: GoogleFonts.sourceSans3(
                        fontWeight:
                            FlutterFlowTheme.of(context).bodyLarge.fontWeight,
                        fontStyle:
                            FlutterFlowTheme.of(context).bodyLarge.fontStyle,
                      ),
                      color: valueOrDefault<Color>(
                        valueOrDefault<bool>(
                          widget.active,
                          false,
                        )
                            ? FlutterFlowTheme.of(context).primaryText
                            : FlutterFlowTheme.of(context).secondaryText,
                        FlutterFlowTheme.of(context).secondaryText,
                      ),
                      letterSpacing: 0.0,
                      fontWeight:
                          FlutterFlowTheme.of(context).bodyLarge.fontWeight,
                      fontStyle:
                          FlutterFlowTheme.of(context).bodyLarge.fontStyle,
                      lineHeight: 1.5,
                    ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    color: FlutterFlowTheme.of(context).secondaryText,
                    size: 14.0,
                  ),
                  Text(
                    valueOrDefault<String>(
                      widget.time,
                      '10:45 AM',
                    ),
                    style: FlutterFlowTheme.of(context).labelSmall.override(
                          font: GoogleFonts.sourceSans3(
                            fontWeight: FlutterFlowTheme.of(context)
                                .labelSmall
                                .fontWeight,
                            fontStyle: FlutterFlowTheme.of(context)
                                .labelSmall
                                .fontStyle,
                          ),
                          color: FlutterFlowTheme.of(context).secondaryText,
                          letterSpacing: 0.0,
                          fontWeight: FlutterFlowTheme.of(context)
                              .labelSmall
                              .fontWeight,
                          fontStyle:
                              FlutterFlowTheme.of(context).labelSmall.fontStyle,
                          lineHeight: 1.2,
                        ),
                  ),
                ].divide(SizedBox(width: 4.0)),
              ),
              Text(
                valueOrDefault<String>(
                  widget.location,
                  'Punto de Entrega: Central Sololá',
                ),
                maxLines: 1,
                style: FlutterFlowTheme.of(context).bodySmall.override(
                      font: GoogleFonts.sourceSans3(
                        fontWeight:
                            FlutterFlowTheme.of(context).bodySmall.fontWeight,
                        fontStyle:
                            FlutterFlowTheme.of(context).bodySmall.fontStyle,
                      ),
                      color: FlutterFlowTheme.of(context).secondaryText,
                      letterSpacing: 0.0,
                      fontWeight:
                          FlutterFlowTheme.of(context).bodySmall.fontWeight,
                      fontStyle:
                          FlutterFlowTheme.of(context).bodySmall.fontStyle,
                      lineHeight: 1.4,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ].divide(SizedBox(height: 4.0)),
          ),
        ),
      ].divide(SizedBox(width: 16.0)),
    );
  }
}
