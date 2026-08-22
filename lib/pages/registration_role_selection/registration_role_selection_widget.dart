import '/components/button/button_widget.dart';
import '/components/role_card/role_card_widget.dart';
import '/components/text_field/text_field_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'registration_role_selection_model.dart';
export 'registration_role_selection_model.dart';

class RegistrationRoleSelectionWidget extends StatefulWidget {
  const RegistrationRoleSelectionWidget({super.key});

  static String routeName = 'RegistrationRoleSelection';
  static String routePath = '/registrationRoleSelection';

  @override
  State<RegistrationRoleSelectionWidget> createState() =>
      _RegistrationRoleSelectionWidgetState();
}

class _RegistrationRoleSelectionWidgetState
    extends State<RegistrationRoleSelectionWidget> {
  late RegistrationRoleSelectionModel _model;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => RegistrationRoleSelectionModel());
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
        body: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              child: Container(
                height: 280.0,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      FlutterFlowTheme.of(context).primary,
                      Color(0xFF1B691B)
                    ],
                    stops: [0.0, 1.0],
                    begin: AlignmentDirectional(0.0, -1.0),
                    end: AlignmentDirectional(0, 1.0),
                  ),
                  shape: BoxShape.rectangle,
                ),
                child: Stack(
                  alignment: AlignmentDirectional(-1.0, -1.0),
                  children: [
                    Align(
                      alignment: AlignmentDirectional(1.2, -0.5),
                      child: Icon(
                        Icons.map_rounded,
                        color: FlutterFlowTheme.of(context).onBackground10,
                        size: 400.0,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional(-1.0, 1.0),
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 48.0,
                              height: 48.0,
                              decoration: BoxDecoration(
                                color: FlutterFlowTheme.of(context).onPrimary20,
                                borderRadius: BorderRadius.circular(12.0),
                                shape: BoxShape.rectangle,
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Container(
                                  child: Container(
                                    alignment: AlignmentDirectional(0.0, 0.0),
                                    child: Icon(
                                      Icons.groups_rounded,
                                      color: FlutterFlowTheme.of(context)
                                          .onSurface,
                                      size: 30.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              'Tu Comunidad',
                              style: FlutterFlowTheme.of(context)
                                  .headlineLarge
                                  .override(
                                    font: GoogleFonts.cabin(
                                      fontWeight: FontWeight.w900,
                                      fontStyle: FlutterFlowTheme.of(context)
                                          .headlineLarge
                                          .fontStyle,
                                    ),
                                    color: FlutterFlowTheme.of(context)
                                        .onBackground,
                                    letterSpacing: 0.0,
                                    fontWeight: FontWeight.w900,
                                    fontStyle: FlutterFlowTheme.of(context)
                                        .headlineLarge
                                        .fontStyle,
                                    lineHeight: 1.2,
                                  ),
                            ),
                            Text(
                              'Conectando el comercio rural de Guatemala',
                              style: FlutterFlowTheme.of(context)
                                  .bodyLarge
                                  .override(
                                    font: GoogleFonts.sourceSans3(
                                      fontWeight: FlutterFlowTheme.of(context)
                                          .bodyLarge
                                          .fontWeight,
                                      fontStyle: FlutterFlowTheme.of(context)
                                          .bodyLarge
                                          .fontStyle,
                                    ),
                                    color: FlutterFlowTheme.of(context)
                                        .onBackground90,
                                    letterSpacing: 0.0,
                                    fontWeight: FlutterFlowTheme.of(context)
                                        .bodyLarge
                                        .fontWeight,
                                    fontStyle: FlutterFlowTheme.of(context)
                                        .bodyLarge
                                        .fontStyle,
                                    lineHeight: 1.5,
                                  ),
                            ),
                          ].divide(SizedBox(height: 8.0)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Container(
                child: SingleChildScrollView(
                  primary: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Container(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Crea tu cuenta',
                                    style: FlutterFlowTheme.of(context)
                                        .titleLarge
                                        .override(
                                          font: GoogleFonts.cabin(
                                            fontWeight: FontWeight.bold,
                                            fontStyle:
                                                FlutterFlowTheme.of(context)
                                                    .titleLarge
                                                    .fontStyle,
                                          ),
                                          color: FlutterFlowTheme.of(context)
                                              .primaryText,
                                          letterSpacing: 0.0,
                                          fontWeight: FontWeight.bold,
                                          fontStyle:
                                              FlutterFlowTheme.of(context)
                                                  .titleLarge
                                                  .fontStyle,
                                          lineHeight: 1.3,
                                        ),
                                  ),
                                  wrapWithModel(
                                    model: _model.textFieldModel1,
                                    updateCallback: () => safeSetState(() {}),
                                    child: TextFieldWidget(
                                      label: 'Nombre completo',
                                      labelPresent: true,
                                      helper: '',
                                      helperPresent: false,
                                      leadingIcon: Icon(
                                        Icons.person_outline_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primaryText,
                                        size: 24.0,
                                      ),
                                      leadingIconPresent: true,
                                      trailingIconPresent: false,
                                      hint: 'Ej. Juan Pérez',
                                      value: '',
                                      onChange: '',
                                      onSubmit: '',
                                      variant: 'outlined',
                                      error: false,
                                    ),
                                  ),
                                  wrapWithModel(
                                    model: _model.textFieldModel2,
                                    updateCallback: () => safeSetState(() {}),
                                    child: TextFieldWidget(
                                      label: 'Número de teléfono',
                                      labelPresent: true,
                                      helper: '',
                                      helperPresent: false,
                                      leadingIcon: Icon(
                                        Icons.phone_android_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primaryText,
                                        size: 24.0,
                                      ),
                                      leadingIconPresent: true,
                                      trailingIconPresent: false,
                                      hint: '5555-5555',
                                      value: '',
                                      onChange: '',
                                      onSubmit: '',
                                      variant: 'outlined',
                                      error: false,
                                    ),
                                  ),
                                  wrapWithModel(
                                    model: _model.textFieldModel3,
                                    updateCallback: () => safeSetState(() {}),
                                    child: TextFieldWidget(
                                      label: 'Comunidad / Municipio',
                                      labelPresent: true,
                                      helper: '',
                                      helperPresent: false,
                                      leadingIcon: Icon(
                                        Icons.location_on_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primaryText,
                                        size: 24.0,
                                      ),
                                      leadingIconPresent: true,
                                      trailingIconPresent: false,
                                      hint: 'Ej. Tecpán, Chimaltenango',
                                      value: '',
                                      onChange: '',
                                      onSubmit: '',
                                      variant: 'outlined',
                                      error: false,
                                    ),
                                  ),
                                ].divide(SizedBox(height: 16.0)),
                              ),
                              Divider(
                                height: 16.0,
                                thickness: 1.0,
                                indent: 0.0,
                                endIndent: 0.0,
                                color: FlutterFlowTheme.of(context).alternate,
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Selecciona tu rol',
                                        style: FlutterFlowTheme.of(context)
                                            .titleMedium
                                            .override(
                                              font: GoogleFonts.cabin(
                                                fontWeight: FontWeight.bold,
                                                fontStyle:
                                                    FlutterFlowTheme.of(context)
                                                        .titleMedium
                                                        .fontStyle,
                                              ),
                                              color:
                                                  FlutterFlowTheme.of(context)
                                                      .primaryText,
                                              letterSpacing: 0.0,
                                              fontWeight: FontWeight.bold,
                                              fontStyle:
                                                  FlutterFlowTheme.of(context)
                                                      .titleMedium
                                                      .fontStyle,
                                              lineHeight: 1.4,
                                            ),
                                      ),
                                      Text(
                                        '¿Cómo participarás en la red?',
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
                                              color:
                                                  FlutterFlowTheme.of(context)
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
                                    ].divide(SizedBox(height: 4.0)),
                                  ),
                                  wrapWithModel(
                                    model: _model.roleCardModel1,
                                    updateCallback: () => safeSetState(() {}),
                                    child: RoleCardWidget(
                                      description:
                                          'Busca productos locales y recíbelos en tu punto más cercano.',
                                      icon: Icon(
                                        Icons.shopping_basket_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primary,
                                        size: 32.0,
                                      ),
                                      targetRole: 'buyer',
                                      title: 'Comprador',
                                      tone:
                                          FlutterFlowTheme.of(context).primary,
                                    ),
                                  ),
                                  wrapWithModel(
                                    model: _model.roleCardModel2,
                                    updateCallback: () => safeSetState(() {}),
                                    child: RoleCardWidget(
                                      description:
                                          'Vende tus productos y llega a más clientes en la ruta.',
                                      icon: Icon(
                                        Icons.store_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primary,
                                        size: 32.0,
                                      ),
                                      targetRole: 'seller',
                                      title: 'Vendedor / Tienda',
                                      tone:
                                          FlutterFlowTheme.of(context).tertiary,
                                    ),
                                  ),
                                  wrapWithModel(
                                    model: _model.roleCardModel3,
                                    updateCallback: () => safeSetState(() {}),
                                    child: RoleCardWidget(
                                      description:
                                          'Gana dinero aprovechando tus viajes y espacios disponibles.',
                                      icon: Icon(
                                        Icons.local_shipping_rounded,
                                        color: FlutterFlowTheme.of(context)
                                            .primary,
                                        size: 32.0,
                                      ),
                                      targetRole: 'delivery',
                                      title: 'Repartidor',
                                      tone: FlutterFlowTheme.of(context).info,
                                    ),
                                  ),
                                ].divide(SizedBox(height: 16.0)),
                              ),
                              Padding(
                                padding: EdgeInsetsDirectional.fromSTEB(
                                    0.0, 0.0, 0.0, 24.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    InkWell(
                                      splashColor: Colors.transparent,
                                      focusColor: Colors.transparent,
                                      hoverColor: Colors.transparent,
                                      highlightColor: Colors.transparent,
                                      onTap: () async {
                                        context.goNamed(
                                            MarketplaceHubWidget.routeName);
                                      },
                                      child: wrapWithModel(
                                        model: _model.buttonModel1,
                                        updateCallback: () =>
                                            safeSetState(() {}),
                                        child: ButtonWidget(
                                          iconPresent: false,
                                          iconEndPresent: false,
                                          content: 'Unirse a la Red',
                                          variant: 'primary',
                                          size: 'large',
                                          fullWidth: true,
                                          loading: false,
                                          disabled: false,
                                        ),
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.max,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          '¿Ya tienes cuenta?',
                                          style: FlutterFlowTheme.of(context)
                                              .bodyMedium
                                              .override(
                                                font: GoogleFonts.sourceSans3(
                                                  fontWeight:
                                                      FlutterFlowTheme.of(
                                                              context)
                                                          .bodyMedium
                                                          .fontWeight,
                                                  fontStyle:
                                                      FlutterFlowTheme.of(
                                                              context)
                                                          .bodyMedium
                                                          .fontStyle,
                                                ),
                                                color:
                                                    FlutterFlowTheme.of(context)
                                                        .secondaryText,
                                                letterSpacing: 0.0,
                                                fontWeight:
                                                    FlutterFlowTheme.of(context)
                                                        .bodyMedium
                                                        .fontWeight,
                                                fontStyle:
                                                    FlutterFlowTheme.of(context)
                                                        .bodyMedium
                                                        .fontStyle,
                                                lineHeight: 1.5,
                                              ),
                                        ),
                                        wrapWithModel(
                                          model: _model.buttonModel2,
                                          updateCallback: () =>
                                              safeSetState(() {}),
                                          child: ButtonWidget(
                                            iconPresent: false,
                                            iconEndPresent: false,
                                            content: 'Iniciar Sesión',
                                            variant: 'ghost',
                                            size: 'small',
                                            fullWidth: false,
                                            loading: false,
                                            disabled: false,
                                          ),
                                        ),
                                      ].divide(SizedBox(width: 4.0)),
                                    ),
                                  ].divide(SizedBox(height: 16.0)),
                                ),
                              ),
                            ].divide(SizedBox(height: 24.0)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
