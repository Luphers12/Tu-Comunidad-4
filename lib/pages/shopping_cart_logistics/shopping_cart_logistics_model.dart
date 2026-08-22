import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/cart_item/cart_item_widget.dart';
import '/components/route_option/route_option_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'shopping_cart_logistics_widget.dart' show ShoppingCartLogisticsWidget;
import 'package:flutter/material.dart';

class ShoppingCartLogisticsModel
    extends FlutterFlowModel<ShoppingCartLogisticsWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for CartItem.
  late CartItemModel cartItemModel1;
  // Model for CartItem.
  late CartItemModel cartItemModel2;
  // Model for RouteOption.
  late RouteOptionModel routeOptionModel1;
  // Model for RouteOption.
  late RouteOptionModel routeOptionModel2;
  // Model for RouteOption.
  late RouteOptionModel routeOptionModel3;
  // Model for Button.
  late ButtonModel buttonModel;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    cartItemModel1 = createModel(context, () => CartItemModel());
    cartItemModel2 = createModel(context, () => CartItemModel());
    routeOptionModel1 = createModel(context, () => RouteOptionModel());
    routeOptionModel2 = createModel(context, () => RouteOptionModel());
    routeOptionModel3 = createModel(context, () => RouteOptionModel());
    buttonModel = createModel(context, () => ButtonModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    cartItemModel1.dispose();
    cartItemModel2.dispose();
    routeOptionModel1.dispose();
    routeOptionModel2.dispose();
    routeOptionModel3.dispose();
    buttonModel.dispose();
    bottomNavModel.dispose();
  }
}
