import '/flutter_flow/flutter_flow_icon_button.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'agent_card_model.dart';
export 'agent_card_model.dart';

class AgentCardWidget extends StatefulWidget {
  const AgentCardWidget({
    super.key,
    String? name,
    this.phone,
    required this.role,
    String? transport,
    this.photoUrl,
    required this.routeName,
    required this.status,
    required this.eta,
    required this.transporType,
    required this.maxxWeightKg,
    required this.maxxVolumeM3,
    required this.maxPackages,
    required this.availableSpacePercent,
    required this.supportsColdChain,
    required this.supportsFragile,
    required this.routeRole,
  })  : this.name = name ?? '',
        this.transport = transport ?? 'Pick-up de Carga - Ruta 4';

  final String name;
  final String? phone;
  final String? role;
  final String transport;

  /// Foto de Perfil
  final String? photoUrl;

  /// Ruta Ctual Del Conductor
  final String? routeName;

  /// Estado actual del conductor
  final String? status;

  /// Tiempo estimado de llegada
  final String? eta;

  /// Tipo De Vehiculo Utilizado para realizar el servicio
  final String? transporType;

  /// Peso Maximo De Carga Permitido
  final double? maxxWeightKg;

  /// Volumen Maximo De Carga
  final double? maxxVolumeM3;

  /// Cantidad maxima de packetes que puede transportar el vehiculo
  final int? maxPackages;

  /// Percentaje de espacio de carga disponible actualmente en el veiculo
  final double? availableSpacePercent;

  /// Indica Si El vehiculo Esta Equipado para tranportar  productos que
  /// requieren cadena fria
  final bool? supportsColdChain;

  /// Indica si el veiculo esta autorizado y equipado para transportar carga
  /// fragil
  final bool? supportsFragile;

  /// Funcion asignada al veiculo o conductor dentro de la ruta actual
  final String? routeRole;

  @override
  State<AgentCardWidget> createState() => _AgentCardWidgetState();
}

class _AgentCardWidgetState extends State<AgentCardWidget> {
  late AgentCardModel _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => AgentCardModel());
  }

  @override
  void dispose() {
    _model.maybeDispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      splashColor: Colors.transparent,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      onTap: () async {
        context.pushNamed(UserProfileSettingsWidget.routeName);
      },
      child: Container(
        decoration: BoxDecoration(
          color: FlutterFlowTheme.of(context).surfaceVariant,
          borderRadius: BorderRadius.circular(16.0),
          shape: BoxShape.rectangle,
          border: Border.all(
            color: FlutterFlowTheme.of(context).alternate,
            width: 1.0,
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
                  width: 48.0,
                  height: 48.0,
                  decoration: BoxDecoration(
                    color: FlutterFlowTheme.of(context).primary,
                    shape: BoxShape.circle,
                  ),
                  alignment: AlignmentDirectional(0.0, 0.0),
                  child: Container(
                    width: 200.0,
                    height: 200.0,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                    ),
                    child: Image.network(
                      widget.photoUrl!,
                      fit: BoxFit.cover,
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
                          widget.role,
                          'REPARTIDOR COMUNITARIO',
                        ),
                        style: FlutterFlowTheme.of(context).labelSmall.override(
                              font: GoogleFonts.sourceSans3(
                                fontWeight: FontWeight.bold,
                                fontStyle: FlutterFlowTheme.of(context)
                                    .labelSmall
                                    .fontStyle,
                              ),
                              color: FlutterFlowTheme.of(context).primary,
                              fontSize: 13.0,
                              letterSpacing: 0.0,
                              fontWeight: FontWeight.bold,
                              fontStyle: FlutterFlowTheme.of(context)
                                  .labelSmall
                                  .fontStyle,
                              lineHeight: 1.2,
                            ),
                      ),
                      Text(
                        valueOrDefault<String>(
                          widget.name,
                          'Juan Delgado',
                        ),
                        style: FlutterFlowTheme.of(context).titleLarge.override(
                              font: GoogleFonts.cabin(
                                fontWeight: FlutterFlowTheme.of(context)
                                    .titleLarge
                                    .fontWeight,
                                fontStyle: FlutterFlowTheme.of(context)
                                    .titleLarge
                                    .fontStyle,
                              ),
                              letterSpacing: 0.0,
                              fontWeight: FlutterFlowTheme.of(context)
                                  .titleLarge
                                  .fontWeight,
                              fontStyle: FlutterFlowTheme.of(context)
                                  .titleLarge
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
                            Icons.local_shipping_rounded,
                            color: FlutterFlowTheme.of(context).secondaryText,
                            size: 14.0,
                          ),
                          InkWell(
                            splashColor: Colors.transparent,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            onTap: () async {},
                            child: Text(
                              '${widget.transporType}.${widget.routeName}${widget.availableSpacePercent?.toString()} % . ${widget.maxxWeightKg?.toString()} kg . ${widget.maxxVolumeM3?.toString()} m3${widget.maxPackages?.toString()} Paq.',
                              maxLines: 3,
                              style: FlutterFlowTheme.of(context)
                                  .bodySmall
                                  .override(
                                    font: GoogleFonts.sourceSans3(
                                      fontWeight: FontWeight.w600,
                                      fontStyle: FlutterFlowTheme.of(context)
                                          .bodySmall
                                          .fontStyle,
                                    ),
                                    color: FlutterFlowTheme.of(context)
                                        .secondaryText,
                                    fontSize: 14.0,
                                    letterSpacing: 0.0,
                                    fontWeight: FontWeight.w600,
                                    fontStyle: FlutterFlowTheme.of(context)
                                        .bodySmall
                                        .fontStyle,
                                    lineHeight: 1.4,
                                  ),
                            ),
                          ),
                        ].divide(SizedBox(width: 4.0)),
                      ),
                    ].divide(SizedBox(height: 4.0)),
                  ),
                ),
                FlutterFlowIconButton(
                  borderRadius: 9999.0,
                  buttonSize: 40.0,
                  fillColor: FlutterFlowTheme.of(context).success,
                  icon: Icon(
                    Icons.call_rounded,
                    color: FlutterFlowTheme.of(context).onSuccess,
                    size: 24.0,
                  ),
                  onPressed: () async {
                    await launchURL('tel:+50252026370');
                  },
                ),
              ].divide(SizedBox(width: 16.0)),
            ),
          ),
        ),
      ),
    );
  }
}
