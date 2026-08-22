import '/components/nav_item/nav_item_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'bottom_nav_child_model.dart';
export 'bottom_nav_child_model.dart';

class BottomNavChildWidget extends StatefulWidget {
  const BottomNavChildWidget({super.key});

  @override
  State<BottomNavChildWidget> createState() => _BottomNavChildWidgetState();
}

class _BottomNavChildWidgetState extends State<BottomNavChildWidget> {
  late BottomNavChildModel _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => BottomNavChildModel());
  }

  @override
  void dispose() {
    _model.maybeDispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          splashColor: Colors.transparent,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: () async {
            context.goNamed(MarketplaceHubWidget.routeName);
          },
          child: wrapWithModel(
            model: _model.navItemModel1,
            updateCallback: () => safeSetState(() {}),
            child: NavItemWidget(
              label: 'Mercado',
              icon: Icon(
                Icons.store_rounded,
                color: Color(0xFF228B22),
                size: 50.0,
              ),
              target: 'MarketplaceHub',
              selected: true,
            ),
          ),
        ),
        InkWell(
          splashColor: Colors.transparent,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: () async {
            context.goNamed(OrderTrackingWidget.routeName);
          },
          child: wrapWithModel(
            model: _model.navItemModel2,
            updateCallback: () => safeSetState(() {}),
            child: NavItemWidget(
              label: 'Pedidos',
              icon: Icon(
                Icons.inventory_2_rounded,
                color: Color(0xFFB68A5A),
                size: 50.0,
              ),
              target: 'OrderTracking',
              selected: false,
            ),
          ),
        ),
        InkWell(
          splashColor: Colors.transparent,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: () async {
            context.goNamed(PickupPointsMapWidget.routeName);
          },
          child: wrapWithModel(
            model: _model.navItemModel3,
            updateCallback: () => safeSetState(() {}),
            child: NavItemWidget(
              label: 'Tu Comunidad',
              icon: FaIcon(
                FontAwesomeIcons.map,
                color: Color(0xFF008080),
                size: 50.0,
              ),
              target: 'DeliveryPartnerPortal',
              selected: false,
            ),
          ),
        ),
        InkWell(
          splashColor: Colors.transparent,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: () async {
            context.goNamed(UserProfileSettingsWidget.routeName);
          },
          child: wrapWithModel(
            model: _model.navItemModel4,
            updateCallback: () => safeSetState(() {}),
            child: NavItemWidget(
              label: 'Perfil',
              icon: Icon(
                Icons.person_rounded,
                color: FlutterFlowTheme.of(context).primaryText,
                size: 50.0,
              ),
              target: 'UserProfileSettings',
              selected: false,
            ),
          ),
        ),
      ],
    );
  }
}
