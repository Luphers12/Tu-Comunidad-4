import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/dashboard_stat/dashboard_stat_widget.dart';
import '/components/order_item/order_item_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'seller_dashboard_widget.dart' show SellerDashboardWidget;
import 'package:flutter/material.dart';

class SellerDashboardModel extends FlutterFlowModel<SellerDashboardWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for DashboardStat.
  late DashboardStatModel dashboardStatModel1;
  // Model for DashboardStat.
  late DashboardStatModel dashboardStatModel2;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for Button.
  late ButtonModel buttonModel2;
  // Model for Button.
  late ButtonModel buttonModel3;
  // Model for OrderItem.
  late OrderItemModel orderItemModel1;
  // Model for OrderItem.
  late OrderItemModel orderItemModel2;
  // Model for OrderItem.
  late OrderItemModel orderItemModel3;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    dashboardStatModel1 = createModel(context, () => DashboardStatModel());
    dashboardStatModel2 = createModel(context, () => DashboardStatModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    buttonModel2 = createModel(context, () => ButtonModel());
    buttonModel3 = createModel(context, () => ButtonModel());
    orderItemModel1 = createModel(context, () => OrderItemModel());
    orderItemModel2 = createModel(context, () => OrderItemModel());
    orderItemModel3 = createModel(context, () => OrderItemModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    dashboardStatModel1.dispose();
    dashboardStatModel2.dispose();
    buttonModel1.dispose();
    buttonModel2.dispose();
    buttonModel3.dispose();
    orderItemModel1.dispose();
    orderItemModel2.dispose();
    orderItemModel3.dispose();
    bottomNavModel.dispose();
  }
}
