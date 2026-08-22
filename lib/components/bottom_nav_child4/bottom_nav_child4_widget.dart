import '/components/nav_item/nav_item_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'bottom_nav_child4_model.dart';
export 'bottom_nav_child4_model.dart';

class BottomNavChild4Widget extends StatefulWidget {
  const BottomNavChild4Widget({super.key});

  @override
  State<BottomNavChild4Widget> createState() => _BottomNavChild4WidgetState();
}

class _BottomNavChild4WidgetState extends State<BottomNavChild4Widget> {
  late BottomNavChild4Model _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => BottomNavChild4Model());
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
        wrapWithModel(
          model: _model.navItemModel1,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Rutas',
            icon: Icon(
              Icons.map_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'DeliveryPartnerPortal',
            selected: true,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel2,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Tienda',
            icon: Icon(
              Icons.store_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'MarketplaceHub',
            selected: false,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel3,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Mis Viajes',
            icon: Icon(
              Icons.history_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'OrderTracking',
            selected: false,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel4,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Perfil',
            icon: Icon(
              Icons.account_circle_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'UserProfileSettings',
            selected: false,
          ),
        ),
      ],
    );
  }
}
