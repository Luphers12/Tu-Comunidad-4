import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/bottom_nav_child7/bottom_nav_child7_widget.dart';
import '/components/button/button_widget.dart';
import '/components/settings_row/settings_row_widget.dart';
import '/components/stat_pill/stat_pill_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'user_profile_settings_model.dart';
export 'user_profile_settings_model.dart';

class UserProfileSettingsWidget extends StatefulWidget {
  const UserProfileSettingsWidget({super.key});

  static String routeName = 'UserProfileSettings';
  static String routePath = '/userProfileSettings';

  @override
  State<UserProfileSettingsWidget> createState() =>
      _UserProfileSettingsWidgetState();
}

class _UserProfileSettingsWidgetState extends State<UserProfileSettingsWidget> {
  late UserProfileSettingsModel _model;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => UserProfileSettingsModel());
  }

  @override
  void dispose() {
    _model.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SingleChildScrollView(
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 260.0,
                child: Stack(
                  alignment: AlignmentDirectional(-1.0, -1.0),
                  children: [
                    ClipRRect(
                      child: Container(
                        height: 200.0,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              FlutterFlowTheme.of(context).primary,
                              Color(0xFF1B5E20)
                            ],
                            stops: [0.0, 1.0],
                            begin: AlignmentDirectional(0.0, -1.0),
                            end: AlignmentDirectional(0, 1.0),
                          ),
                          shape: BoxShape.rectangle,
                        ),
                        child: Align(
                          alignment: AlignmentDirectional(1.2, -0.5),
                          child: Icon(
                            Icons.map_rounded,
                            color: FlutterFlowTheme.of(context).onBackground5,
                            size: 300.0,
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional(0.0, 1.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 100.0,
                            height: 100.0,
                            decoration: BoxDecoration(
                              color: FlutterFlowTheme.of(context)
                                  .secondaryBackground,
                              borderRadius: BorderRadius.circular(32.0),
                              shape: BoxShape.rectangle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(4.0),
                              child: Container(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(28.0),
                                  child: CachedNetworkImage(
                                    fadeInDuration: Duration(milliseconds: 0),
                                    fadeOutDuration: Duration(milliseconds: 0),
                                    imageUrl:
                                        'https://dimg.dreamflow.cloud/v1/image/Maya%20Alvarado%2C%20rural%20entrepreneur',
                                    width: 92.0,
                                    height: 92.0,
                                    fit: BoxFit.cover,
                                    alignment: Alignment(0.0, 0.0),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                'Maya Alvarado',
                                style: FlutterFlowTheme.of(context)
                                    .headlineSmall
                                    .override(
                                      font: GoogleFonts.cabin(
                                        fontWeight: FontWeight.bold,
                                        fontStyle: FlutterFlowTheme.of(context)
                                            .headlineSmall
                                            .fontStyle,
                                      ),
                                      color: FlutterFlowTheme.of(context)
                                          .primaryText,
                                      letterSpacing: 0.0,
                                      fontWeight: FontWeight.bold,
                                      fontStyle: FlutterFlowTheme.of(context)
                                          .headlineSmall
                                          .fontStyle,
                                      lineHeight: 1.3,
                                    ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.max,
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.location_on_rounded,
                                    color: FlutterFlowTheme.of(context)
                                        .onBackground,
                                    size: 14.0,
                                  ),
                                  Text(
                                    'Comunidad Tecpán, Chimaltenango',
                                    style: FlutterFlowTheme.of(context)
                                        .bodySmall
                                        .override(
                                          font: GoogleFonts.sourceSans3(
                                            fontWeight:
                                                FlutterFlowTheme.of(context)
                                                    .bodySmall
                                                    .fontWeight,
                                            fontStyle:
                                                FlutterFlowTheme.of(context)
                                                    .bodySmall
                                                    .fontStyle,
                                          ),
                                          color: FlutterFlowTheme.of(context)
                                              .secondaryText,
                                          letterSpacing: 0.0,
                                          fontWeight:
                                              FlutterFlowTheme.of(context)
                                                  .bodySmall
                                                  .fontWeight,
                                          fontStyle:
                                              FlutterFlowTheme.of(context)
                                                  .bodySmall
                                                  .fontStyle,
                                          lineHeight: 1.4,
                                        ),
                                  ),
                                ].divide(SizedBox(width: 4.0)),
                              ),
                            ].divide(SizedBox(height: 4.0)),
                          ),
                        ].divide(SizedBox(height: 16.0)),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: Container(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Mi Impacto en la Red',
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
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            wrapWithModel(
                              model: _model.statPillModel1,
                              updateCallback: () => safeSetState(() {}),
                              child: StatPillWidget(
                                icon: Icon(
                                  Icons.local_shipping_rounded,
                                  color: FlutterFlowTheme.of(context).primary,
                                  size: 18.0,
                                ),
                                label: 'Entregas',
                                tone: FlutterFlowTheme.of(context).primary,
                                value: '128',
                              ),
                            ),
                            wrapWithModel(
                              model: _model.statPillModel2,
                              updateCallback: () => safeSetState(() {}),
                              child: StatPillWidget(
                                icon: Icon(
                                  Icons.storefront_rounded,
                                  color: FlutterFlowTheme.of(context).primary,
                                  size: 18.0,
                                ),
                                label: 'Ventas',
                                tone: FlutterFlowTheme.of(context).tertiary,
                                value: 'Q 3,420',
                              ),
                            ),
                          ].divide(SizedBox(width: 16.0)),
                        ),
                      ].divide(SizedBox(height: 16.0)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: FlutterFlowTheme.of(context).secondaryBackground,
                        borderRadius: BorderRadius.circular(16.0),
                        shape: BoxShape.rectangle,
                        border: Border.all(
                          color: FlutterFlowTheme.of(context).alternate,
                          width: 1.0,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.rectangle,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Padding(
                                  padding: EdgeInsetsDirectional.fromSTEB(
                                      24.0, 16.0, 24.0, 16.0),
                                  child: Container(
                                    child: Text(
                                      'Mi Actividad',
                                      style: FlutterFlowTheme.of(context)
                                          .labelLarge
                                          .override(
                                            font: GoogleFonts.sourceSans3(
                                              fontWeight: FontWeight.bold,
                                              fontStyle:
                                                  FlutterFlowTheme.of(context)
                                                      .labelLarge
                                                      .fontStyle,
                                            ),
                                            color: FlutterFlowTheme.of(context)
                                                .primary,
                                            letterSpacing: 0.0,
                                            fontWeight: FontWeight.bold,
                                            fontStyle:
                                                FlutterFlowTheme.of(context)
                                                    .labelLarge
                                                    .fontStyle,
                                            lineHeight: 1.3,
                                          ),
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 152.16,
                                  height: 1.0,
                                  decoration: BoxDecoration(
                                    color:
                                        FlutterFlowTheme.of(context).alternate,
                                    shape: BoxShape.rectangle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel1,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.inventory_2_rounded,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle: 'Rastreo de compras y suministros',
                              target: 'OrderTracking',
                              title: 'Mis Pedidos',
                            ),
                          ),
                          Divider(
                            height: 16.0,
                            thickness: 1.0,
                            indent: 56.0,
                            endIndent: 0.0,
                            color: FlutterFlowTheme.of(context).alternate,
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel2,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.help,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle: 'Gestionar mis viajes y espacios',
                              target: 'DeliveryPartnerPortal',
                              title: 'Rutas de Reparto',
                            ),
                          ),
                          Divider(
                            height: 16.0,
                            thickness: 1.0,
                            indent: 56.0,
                            endIndent: 0.0,
                            color: FlutterFlowTheme.of(context).alternate,
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel3,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.point_of_sale_rounded,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle: 'Inventario de mi tienda local',
                              target: 'SellerDashboard',
                              title: 'Panel de Vendedor',
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: FlutterFlowTheme.of(context).secondaryBackground,
                        borderRadius: BorderRadius.circular(16.0),
                        shape: BoxShape.rectangle,
                        border: Border.all(
                          color: FlutterFlowTheme.of(context).alternate,
                          width: 1.0,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.rectangle,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Padding(
                                  padding: EdgeInsetsDirectional.fromSTEB(
                                      24.0, 16.0, 24.0, 16.0),
                                  child: Container(
                                    child: Text(
                                      'Comunidad',
                                      style: FlutterFlowTheme.of(context)
                                          .labelLarge
                                          .override(
                                            font: GoogleFonts.sourceSans3(
                                              fontWeight: FontWeight.bold,
                                              fontStyle:
                                                  FlutterFlowTheme.of(context)
                                                      .labelLarge
                                                      .fontStyle,
                                            ),
                                            color: FlutterFlowTheme.of(context)
                                                .primary,
                                            letterSpacing: 0.0,
                                            fontWeight: FontWeight.bold,
                                            fontStyle:
                                                FlutterFlowTheme.of(context)
                                                    .labelLarge
                                                    .fontStyle,
                                            lineHeight: 1.3,
                                          ),
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 126.12,
                                  height: 1.0,
                                  decoration: BoxDecoration(
                                    color:
                                        FlutterFlowTheme.of(context).alternate,
                                    shape: BoxShape.rectangle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel4,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.groups_rounded,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle: '24 vecinos conectados en Tecpán',
                              target: 'OrderTracking',
                              title: 'Mi Red Local',
                            ),
                          ),
                          Divider(
                            height: 16.0,
                            thickness: 1.0,
                            indent: 56.0,
                            endIndent: 0.0,
                            color: FlutterFlowTheme.of(context).alternate,
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel5,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.map_rounded,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle: 'Ver mapa de recolección rural',
                              target: 'PickupPointsMap',
                              title: 'Puntos de Entrega',
                            ),
                          ),
                          Divider(
                            height: 16.0,
                            thickness: 1.0,
                            indent: 56.0,
                            endIndent: 0.0,
                            color: FlutterFlowTheme.of(context).alternate,
                          ),
                          wrapWithModel(
                            model: _model.settingsRowModel6,
                            updateCallback: () => safeSetState(() {}),
                            child: SettingsRowWidget(
                              icon: Icon(
                                Icons.settings_rounded,
                                color: FlutterFlowTheme.of(context).primaryText,
                                size: 20.0,
                              ),
                              subtitle:
                                  'Idioma (K\'iche\'/Español), Notificaciones',
                              target: 'OrderTracking',
                              title: 'Configuración',
                            ),
                          ),
                        ],
                      ),
                    ),
                    wrapWithModel(
                      model: _model.buttonModel,
                      updateCallback: () => safeSetState(() {}),
                      child: ButtonWidget(
                        iconPresent: false,
                        iconEndPresent: false,
                        content: 'Cerrar Sesión',
                        variant: 'ghost',
                        size: 'medium',
                        fullWidth: true,
                        loading: false,
                        disabled: false,
                      ),
                    ),
                  ].divide(SizedBox(height: 24.0)),
                ),
              ),
              Align(
                alignment: AlignmentDirectional(0.0, 1.0),
                child: Container(
                  child: wrapWithModel(
                    model: _model.bottomNavModel,
                    updateCallback: () => safeSetState(() {}),
                    child: BottomNavWidget(
                      child: () => BottomNavChild7Widget(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
