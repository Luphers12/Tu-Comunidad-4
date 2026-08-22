import '/components/nav_item/nav_item_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'bottom_nav_child5_model.dart';
export 'bottom_nav_child5_model.dart';

class BottomNavChild5Widget extends StatefulWidget {
  const BottomNavChild5Widget({super.key});

  @override
  State<BottomNavChild5Widget> createState() => _BottomNavChild5WidgetState();
}

class _BottomNavChild5WidgetState extends State<BottomNavChild5Widget> {
  late BottomNavChild5Model _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => BottomNavChild5Model());
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
          model: _model.navItemModel2,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Mis Pedidos',
            icon: Icon(
              Icons.local_shipping_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'OrderTracking',
            selected: true,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel3,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Puntos',
            icon: Icon(
              Icons.location_on_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'PickupPointsMap',
            selected: false,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel4,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Perfil',
            icon: Icon(
              Icons.person_rounded,
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
