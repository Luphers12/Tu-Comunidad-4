import '/components/nav_item/nav_item_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'bottom_nav_child7_model.dart';
export 'bottom_nav_child7_model.dart';

class BottomNavChild7Widget extends StatefulWidget {
  const BottomNavChild7Widget({super.key});

  @override
  State<BottomNavChild7Widget> createState() => _BottomNavChild7WidgetState();
}

class _BottomNavChild7WidgetState extends State<BottomNavChild7Widget> {
  late BottomNavChild7Model _model;

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => BottomNavChild7Model());
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
            label: 'Mercado',
            icon: Icon(
              Icons.storefront_rounded,
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
            label: 'Mapa',
            icon: Icon(
              Icons.help,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'PickupPointsMap',
            selected: false,
          ),
        ),
        wrapWithModel(
          model: _model.navItemModel3,
          updateCallback: () => safeSetState(() {}),
          child: NavItemWidget(
            label: 'Pedidos',
            icon: Icon(
              Icons.local_shipping_rounded,
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
              Icons.person_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 24.0,
            ),
            target: 'UserProfileSettings',
            selected: true,
          ),
        ),
      ],
    );
  }
}
