import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pickup_card2_model.dart';
export 'pickup_card2_model.dart';

class PickupCard2Widget extends StatefulWidget {
  const PickupCard2Widget({
    super.key,
    String? distance,
    String? hours,
    String? name,
    bool? active,
    String? type,
  })  : this.distance = distance ?? '0.8 km',
        this.hours = hours ?? '8:00 AM - 6:00 PM',
        this.name = name ?? 'Tienda La Bendición',
        this.active = active ?? true,
        this.type = type ?? 'tienda';

  final String distance;
  final String hours;
  final String name;
  final bool active;
  final String type;

  @override
  State<PickupCard2Widget> createState() => _PickupCard2WidgetState();
}

class _PickupCard2WidgetState extends State<PickupCard2Widget> {
  late PickupCard2Model _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => PickupCard2Model());
  }

  @override
  void dispose() {
    _model.maybeDispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(0.0, 0.0, 0.0, 16.0),
      child: Container(
        child: Container(
          decoration: BoxDecoration(
            color: FlutterFlowTheme.of(context).secondaryBackground,
            borderRadius: BorderRadius.circular(16.0),
            shape: BoxShape.rectangle,
            border: Border.all(
              color: valueOrDefault<Color>(
                valueOrDefault<bool>(
                  widget.active,
                  true,
                )
                    ? FlutterFlowTheme.of(context).primary
                    : FlutterFlowTheme.of(context).alternate,
                FlutterFlowTheme.of(context).primary,
              ),
              width: valueOrDefault<double>(
                valueOrDefault<bool>(
                  widget.active,
                  true,
                )
                    ? 1.0
                    : 1.0,
                1.0,
              ),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Container(
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 48.0,
                    height: 48.0,
                    decoration: BoxDecoration(
                      color: valueOrDefault<Color>(
                        valueOrDefault<bool>(
                          widget.active,
                          true,
                        )
                            ? FlutterFlowTheme.of(context).primary10
                            : FlutterFlowTheme.of(context).secondaryBackground,
                        FlutterFlowTheme.of(context).primary10,
                      ),
                      borderRadius: BorderRadius.circular(12.0),
                      shape: BoxShape.rectangle,
                    ),
                    alignment: AlignmentDirectional(0.0, 0.0),
                    child: Container(
                      width: 24.0,
                      height: 24.0,
                      child: Stack(
                        alignment: AlignmentDirectional(0.0, 0.0),
                        children: [
                          if (valueOrDefault<bool>(
                            valueOrDefault<String>(
                                      widget.type,
                                      'tienda',
                                    ) ==
                                    'tienda'
                                ? true
                                : false,
                            true,
                          ))
                            Icon(
                              Icons.store_rounded,
                              color: valueOrDefault<Color>(
                                valueOrDefault<bool>(
                                  widget.active,
                                  true,
                                )
                                    ? FlutterFlowTheme.of(context).primary
                                    : FlutterFlowTheme.of(context)
                                        .secondaryText,
                                FlutterFlowTheme.of(context).primary,
                              ),
                              size: 24.0,
                            ),
                          if (valueOrDefault<bool>(
                            valueOrDefault<String>(
                                      widget.type,
                                      'tienda',
                                    ) ==
                                    'tienda'
                                ? false
                                : true,
                            false,
                          ))
                            Icon(
                              Icons.local_shipping_rounded,
                              color: valueOrDefault<Color>(
                                valueOrDefault<bool>(
                                  widget.active,
                                  true,
                                )
                                    ? FlutterFlowTheme.of(context).primary
                                    : FlutterFlowTheme.of(context)
                                        .secondaryText,
                                FlutterFlowTheme.of(context).primary,
                              ),
                              size: 24.0,
                            ),
                        ],
                      ),
                    ),
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
                            widget.name,
                            'Tienda La Bendición',
                          ),
                          style: FlutterFlowTheme.of(context)
                              .titleMedium
                              .override(
                                font: GoogleFonts.cabin(
                                  fontWeight: FontWeight.bold,
                                  fontStyle: FlutterFlowTheme.of(context)
                                      .titleMedium
                                      .fontStyle,
                                ),
                                color: FlutterFlowTheme.of(context).primaryText,
                                letterSpacing: 0.0,
                                fontWeight: FontWeight.bold,
                                fontStyle: FlutterFlowTheme.of(context)
                                    .titleMedium
                                    .fontStyle,
                                lineHeight: 1.4,
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
                                widget.hours,
                                '8:00 AM - 6:00 PM',
                              ),
                              style: FlutterFlowTheme.of(context)
                                  .labelSmall
                                  .override(
                                    font: GoogleFonts.sourceSans3(
                                      fontWeight: FlutterFlowTheme.of(context)
                                          .labelSmall
                                          .fontWeight,
                                      fontStyle: FlutterFlowTheme.of(context)
                                          .labelSmall
                                          .fontStyle,
                                    ),
                                    color: FlutterFlowTheme.of(context)
                                        .secondaryText,
                                    letterSpacing: 0.0,
                                    fontWeight: FlutterFlowTheme.of(context)
                                        .labelSmall
                                        .fontWeight,
                                    fontStyle: FlutterFlowTheme.of(context)
                                        .labelSmall
                                        .fontStyle,
                                    lineHeight: 1.2,
                                  ),
                            ),
                          ].divide(SizedBox(width: 4.0)),
                        ),
                      ].divide(SizedBox(height: 4.0)),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        valueOrDefault<String>(
                          widget.distance,
                          '0.8 km',
                        ),
                        style: FlutterFlowTheme.of(context).labelLarge.override(
                              font: GoogleFonts.sourceSans3(
                                fontWeight: FontWeight.bold,
                                fontStyle: FlutterFlowTheme.of(context)
                                    .labelLarge
                                    .fontStyle,
                              ),
                              color: FlutterFlowTheme.of(context).primary,
                              letterSpacing: 0.0,
                              fontWeight: FontWeight.bold,
                              fontStyle: FlutterFlowTheme.of(context)
                                  .labelLarge
                                  .fontStyle,
                              lineHeight: 1.3,
                            ),
                      ),
                      Text(
                        'distancia',
                        style: FlutterFlowTheme.of(context).labelSmall.override(
                              font: GoogleFonts.sourceSans3(
                                fontWeight: FlutterFlowTheme.of(context)
                                    .labelSmall
                                    .fontWeight,
                                fontStyle: FlutterFlowTheme.of(context)
                                    .labelSmall
                                    .fontStyle,
                              ),
                              color: FlutterFlowTheme.of(context).accent3,
                              letterSpacing: 0.0,
                              fontWeight: FlutterFlowTheme.of(context)
                                  .labelSmall
                                  .fontWeight,
                              fontStyle: FlutterFlowTheme.of(context)
                                  .labelSmall
                                  .fontStyle,
                              lineHeight: 1.2,
                            ),
                      ),
                    ].divide(SizedBox(height: 4.0)),
                  ),
                ].divide(SizedBox(width: 16.0)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
