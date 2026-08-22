import '/components/radio/radio_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pickup_card_model.dart';
export 'pickup_card_model.dart';

class PickupCardWidget extends StatefulWidget {
  const PickupCardWidget({
    super.key,
    String? distance,
    String? name,
    bool? selected,
  })  : this.distance = distance ?? 'A 500m de ti',
        this.name = name ?? 'Tienda Doña María - Centro',
        this.selected = selected ?? true;

  final String distance;
  final String name;
  final bool selected;

  @override
  State<PickupCardWidget> createState() => _PickupCardWidgetState();
}

class _PickupCardWidgetState extends State<PickupCardWidget> {
  late PickupCardModel _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => PickupCardModel());
  }

  @override
  void dispose() {
    _model.maybeDispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FlutterFlowTheme.of(context).secondaryBackground,
        borderRadius: BorderRadius.circular(16.0),
        shape: BoxShape.rectangle,
        border: Border.all(
          color: valueOrDefault<Color>(
            valueOrDefault<bool>(
              widget.selected,
              true,
            )
                ? FlutterFlowTheme.of(context).primary
                : FlutterFlowTheme.of(context).alternate,
            FlutterFlowTheme.of(context).primary,
          ),
          width: valueOrDefault<double>(
            valueOrDefault<bool>(
              widget.selected,
              true,
            )
                ? 1.0
                : 1.0,
            1.0,
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Container(
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40.0,
                height: 40.0,
                decoration: BoxDecoration(
                  color: valueOrDefault<Color>(
                    valueOrDefault<bool>(
                      widget.selected,
                      true,
                    )
                        ? FlutterFlowTheme.of(context).primary10
                        : FlutterFlowTheme.of(context).secondaryBackground,
                    FlutterFlowTheme.of(context).primary10,
                  ),
                  borderRadius: BorderRadius.circular(9999.0),
                  shape: BoxShape.rectangle,
                ),
                alignment: AlignmentDirectional(0.0, 0.0),
                child: Icon(
                  Icons.store_rounded,
                  color: valueOrDefault<Color>(
                    valueOrDefault<bool>(
                      widget.selected,
                      true,
                    )
                        ? FlutterFlowTheme.of(context).primary
                        : FlutterFlowTheme.of(context).secondaryText,
                    FlutterFlowTheme.of(context).primary,
                  ),
                  size: 24.0,
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
                        'Tienda Doña María - Centro',
                      ),
                      style: FlutterFlowTheme.of(context).bodyMedium.override(
                            font: GoogleFonts.sourceSans3(
                              fontWeight: FontWeight.bold,
                              fontStyle: FlutterFlowTheme.of(context)
                                  .bodyMedium
                                  .fontStyle,
                            ),
                            color: FlutterFlowTheme.of(context).primaryText,
                            letterSpacing: 0.0,
                            fontWeight: FontWeight.bold,
                            fontStyle: FlutterFlowTheme.of(context)
                                .bodyMedium
                                .fontStyle,
                            lineHeight: 1.5,
                          ),
                    ),
                    Text(
                      valueOrDefault<String>(
                        widget.distance,
                        'A 500m de ti',
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
                            fontStyle: FlutterFlowTheme.of(context)
                                .labelSmall
                                .fontStyle,
                            lineHeight: 1.2,
                          ),
                    ),
                  ].divide(SizedBox(height: 4.0)),
                ),
              ),
              wrapWithModel(
                model: _model.radioModel,
                updateCallback: () => safeSetState(() {}),
                child: RadioWidget(
                  label: 'Email Notifications',
                  subtitle: 'Receive weekly updates',
                  color: FlutterFlowTheme.of(context).primary,
                  isSelected: valueOrDefault<bool>(
                    widget.selected,
                    true,
                  ),
                  hasSubtitle: false,
                  disabled: false,
                ),
              ),
            ].divide(SizedBox(width: 16.0)),
          ),
        ),
      ),
    );
  }
}
